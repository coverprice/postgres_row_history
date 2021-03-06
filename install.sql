/*
Installs the components necessary for logging either snapshots of row changes, or just the deltas of row changes.


- `changeset` table: stores metadata about a _set_ of changes.
- `changeset_row_history_snapshot` table: when using the "snapshot" approach, stores complete data about a
  specific row change, belonging to a single `changeset` entry.
- `changeset_row_history_delta` table: when using the "delta" approach, stores just the modified fields about a
  specific row change, belonging to a single `changeset` entry.
- `changeset_new` function: a convenience method for setting up a new changeset.
- `changeset_reset` function: a convenience method for updating the last changeset created with `changeset_new`.
- `changeset_update_delete_trigger_{snapshot,delta}` & `changeset_truncate_trigger_{snapshot,delta}` functions: the
  2 triggers each for snapshot/delta approaches that insert the changes into `changeset_row_history_{snapshot,delta}`
  respectively.
*/

DROP TABLE IF EXISTS changeset CASCADE;
CREATE TABLE changeset (
  id int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY
  , time timestamp with time zone NOT NULL
  , operation text NOT NULL
  , params jsonb
  , user_id text NOT NULL
);

DROP TABLE IF EXISTS changeset_row_history_snapshot CASCADE;
CREATE TABLE changeset_row_history_snapshot (
  id int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY
  , changeset_id int REFERENCES changeset(id) NOT NULL
  , changetype text NOT NULL    -- INSERT/UPDATE/DELETE/TRUNCATE
  , table_name text NOT NULL
  , record jsonb            -- current state. If DELETED/TRUNCATED, this will be NULL.
  , old_record jsonb        -- previous contents (for UPDATE/DELETE/TRUNCATE)
);

DROP TABLE IF EXISTS changeset_row_history_delta CASCADE;
CREATE TABLE changeset_row_history_delta (
  id int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY
  , changeset_id int REFERENCES changeset(id) NOT NULL
  , changetype text NOT NULL
  , table_name text NOT NULL
  , change jsonb NOT NULL
);


/*
Function: changeset_new()

Purpose: Sets up the database state to record a new change.
It just inserts the given data into the change table and sets the local setting that will be passed to the trigger
if/when it is called. It assumes a transaction has already been started; it will emit a warning if not, and any
changes will subsequently fail.
*/
CREATE OR REPLACE FUNCTION changeset_new
    ( v_operation text
    , v_params jsonb
    , v_user_id text
    ) RETURNS int
  LANGUAGE plpgsql
AS $$
DECLARE
  v_changeset_id changeset.id%TYPE;
BEGIN
  INSERT INTO changeset(time, operation, params, user_id)
  VALUES(CURRENT_TIMESTAMP, v_operation, v_params, v_user_id)
  RETURNING id INTO v_changeset_id;

  PERFORM set_config('changeset.changeset_id', v_changeset_id::text, true);   -- Last parameter is 'is_local'

  RETURN v_changeset_id;
END;
$$;


/*
Function: changeset_reset()

Purpose: Resets the operation & params for the last changeset created with `changeset_new`.

This is often useful when the app has difficulty knowing which operation/params to store at the beginning of
the transaction (which is when `changeset_new` must be called), but does know the appropriate values at the end.
For example, if the app wanted to record the total number of changes in the changeset summary, it can set a dummy
value during `changeset_new`, calculate the running total during the update, and then call `changeset_reset` at
the end to replace the placeholder with the final value.

Note: that updating the user_id is not supported; in practice, the app never wants to update this value, so it's
ommitted.
*/
CREATE OR REPLACE FUNCTION changeset_reset
    ( v_operation text
    , v_params jsonb
    ) RETURNS VOID
  LANGUAGE plpgsql
AS $$
DECLARE
  _changeset_id text := current_setting('changeset.changeset_id', true);    -- 2nd param means no exception thrown if not set, it just returns empty string.
BEGIN
  IF _changeset_id !~ '^\d+$' THEN
    RAISE EXCEPTION 'changeset_reset called but changeset.changeset_id setting is not an integer. changeset_new was not called prior to this?';
  END IF;

  UPDATE changeset
  SET operation=v_operation, params=v_params
  WHERE id = _changeset_id::bigint;
END;
$$;


/*
Trigger that handles INSERT, UPDATE and DELETE operations for the "snapshot" approach. This is a row-level trigger.

Parameters:
1) v_ignore_update_cols: string containing literal text array of any column names to ignore ONLY during
   UPDATEs, e.g. {'last_updated'}
2) v_ignore_cols: string containing literal text array of any column names to NEVER log.
   e.g. {'huge_expensive_field_we_dont_need_to_log'}

NB: We'd rather pass text arrays directly, but triggers only support passing string params, so we pass string
literals and cast to ::text[] inside the trigger.

Note: You're more likely to use v_ignore_update_cols than v_ignore_cols. v_ignore_update_cols avoids logging updates
to "noisy" or derived columns that don't provide much value (from a logging POV) and may be redundant anyway, like
'last_updated'. However during DELETE/TRUNCATE (i.e. not UPDATE) you still want a copy of that info as part of a
full table log, if you ever needed to restore the entire row, so these will still be logged on DELETE/TRUNCATE.

v_ignore_cols is a list of columns to completely ignore regardless of the operation type, and is intended for
columns that won't matter during a restore, or columns that can't be converted to JSONB (e.g. BLOBs), or can't
be efficiently stored, e.g. very large text fields that you don't care about. Since these are pretty rare, it's
common for this param to be empty.

*/
CREATE OR REPLACE FUNCTION changeset_update_delete_trigger_snapshot() RETURNS trigger
  SECURITY DEFINER
  LANGUAGE plpgsql
  AS $$
DECLARE
  v_ignore_update_cols text[] := TG_ARGV[0]::text[];
  v_ignore_cols text[] := TG_ARGV[1]::text[];
  _new_record jsonb;
  _old_record jsonb;
  _changeset_id text := current_setting('changeset.changeset_id', true);    -- 2nd param means no exception thrown if not set, it just returns empty string.
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- record both old/new rows
    _new_record := to_jsonb(NEW) - v_ignore_cols - v_ignore_update_cols;   -- NB: this removes any columns we want to ignore
    _old_record := to_jsonb(OLD) - v_ignore_cols - v_ignore_update_cols;
    IF _new_record = _old_record THEN  -- If only ignored columns are updated then there's nothing to log
      RETURN NULL;
    END IF;

  ELSIF TG_OP = 'INSERT' THEN
    -- record a copy of the new row
    _new_record := to_jsonb(NEW) - v_ignore_cols;

  ELSIF TG_OP = 'DELETE' THEN
    -- record a copy of the deleted row
    _old_record := to_jsonb(OLD) - v_ignore_cols;

  END IF;

  /*
  NB: Only check if a changeset has been configured just before we write. This is so that UPDATEs that *only*
  modify ignored columns do not have to set up a changeset. If no other operations are performed in the transaction,
  then this lets the app avoid unnecessarily creating a `changeset` record (which would exist with no
  `changeset_row_history_snapshot` records).
  */
  IF _changeset_id !~ '^\d+$' THEN
    RAISE EXCEPTION 'changeset_update_delete_trigger_snapshot called but changeset.changeset_id setting is not an integer.';
  END IF;

  INSERT INTO changeset_row_history_snapshot
    ( changeset_id
    , changetype
    , table_name
    , record
    , old_record
    ) VALUES
    ( _changeset_id::int
    , TG_OP
    , TG_TABLE_NAME
    , _new_record
    , _old_record
    );

  RETURN NULL; -- Ignored
END;
$$;


/*
Trigger that handles TRUNCATE operations for the "snapshot" approach. This is a statement-level trigger.
Parameters:
1) v_ignore_cols: (same definition as for changeset_update_delete_trigger_snapshot)
*/
CREATE OR REPLACE FUNCTION changeset_truncate_trigger_snapshot() RETURNS trigger
  SECURITY DEFINER
  LANGUAGE plpgsql
  AS $$
DECLARE
  v_ignore_cols text := TG_ARGV[0];    -- containing a text-literal of a ::text[]
  _old_item RECORD;
  _changeset_id text := current_setting('changeset.changeset_id', true);    -- 2nd param means no exception thrown if not set, it just returns empty string.
BEGIN
  IF _changeset_id !~ '^\d+$' THEN
    RAISE EXCEPTION 'changeset_truncate_trigger_snapshot called but changeset.changeset_id setting is not an integer.';
  END IF;

  IF TG_OP != 'TRUNCATE' THEN
    RAISE EXCEPTION 'changeset_truncate_trigger_snapshot must only be called for the TRUNCATE operation';
  END IF;

  EXECUTE format('INSERT INTO changeset_row_history_snapshot (changeset_id, changetype, table_name, record, old_record)'
      ' SELECT $1, $2, %L, NULL, to_jsonb(%I.*) - $3::text[]'
      ' FROM %I', TG_TABLE_NAME, TG_TABLE_NAME, TG_TABLE_NAME)
  USING _changeset_id::int, TG_OP, v_ignore_cols;

  RETURN NULL; -- Ignored
END;
$$;


/*
Enable/disable changelog convenience functions for "snapshot" approach.
*/
CREATE OR REPLACE FUNCTION enable_changeset_tracking_snapshot
    ( table_ref regclass
    , ignore_update_cols text
    , ignore_cols text
    ) RETURNS VOID
  VOLATILE
  SECURITY DEFINER
  LANGUAGE plpgsql
  AS $$
DECLARE
  stmt text;
BEGIN
  stmt = format('
    CREATE TRIGGER changeset_i_u_d_snapshot
      AFTER INSERT OR UPDATE OR DELETE
      ON %I
      FOR EACH ROW EXECUTE PROCEDURE changeset_update_delete_trigger_snapshot(%L, %L)'
    , table_ref, ignore_update_cols, ignore_cols);
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = table_ref AND tgname = 'changeset_i_u_d_snapshot') THEN
    EXECUTE stmt;
  END IF;

  stmt = format('
    CREATE TRIGGER changeset_truncate_snapshot
      BEFORE TRUNCATE
      ON %I
      FOR EACH STATEMENT EXECUTE PROCEDURE changeset_truncate_trigger_snapshot(%L)'
    , table_ref, ignore_cols);
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = table_ref AND tgname = 'changeset_truncate_snapshot') THEN
    EXECUTE stmt;
  END IF;
END;
$$;


CREATE OR REPLACE FUNCTION disable_changeset_tracking_snapshot(table_ref regclass) RETURNS VOID
  VOLATILE
  SECURITY DEFINER
  LANGUAGE plpgsql
  AS $$
DECLARE
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS changeset_i_u_d_snapshot ON %I CASCADE', table_ref);
  EXECUTE format('DROP TRIGGER IF EXISTS changeset_truncate_snapshot ON %I CASCADE', table_ref);
END;
$$;


/*
Trigger that handles INSERT, UPDATE and DELETE operations for the "delta" approach. This is a row-level trigger.

Parameters:
1) v_pkey_cols: string containing a literal text array of the table-to-log's primary key column name(s). e.g. in
   'raw' format this might be ARRAY['user_id'], or {'user_id'}, and when converted to a string (i.e. quoting &
   escaping single quotes) this would be '{"user_id"}'
2) v_ignore_update_cols: <identical to the definition in changeset_update_delete_trigger_snapshot above>
3) v_ignore_cols: <identical to the definition in changeset_update_delete_trigger_snapshot above>

*/
CREATE OR REPLACE FUNCTION changeset_update_delete_trigger_delta() RETURNS trigger
  SECURITY DEFINER
  LANGUAGE plpgsql
  AS $$
DECLARE
  v_pkey_cols text[] := TG_ARGV[0]::text[];
  v_ignore_update_cols text[] := TG_ARGV[1]::text[];
  v_ignore_cols text[] := TG_ARGV[2]::text[];
  _new_row jsonb;
  _old_row jsonb;
  _to_insert jsonb;
  _old_item RECORD;
  _changes_made boolean := false;
  _changeset_id text := current_setting('changeset.changeset_id', true);    -- 2nd param means no exception thrown if not set, it just returns empty string.
  _pkey_col_name text;
BEGIN
  IF _changeset_id !~ '^\d+$' THEN
    RAISE EXCEPTION 'changeset_update_delete_trigger_delta called but changeset.changeset_id setting is not an integer.';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- record just the changed fields
    _new_row := to_jsonb(NEW);
    _old_row := to_jsonb(OLD) - v_ignore_cols - v_ignore_update_cols;   -- NB: this removes any columns we want to ignore
    _to_insert := '{}'::jsonb;

    FOR _old_item IN
      SELECT key, value FROM jsonb_each(_old_row)
    LOOP
      IF _old_item.value IS DISTINCT FROM _new_row->_old_item.key THEN
        _to_insert := jsonb_set(_to_insert, ARRAY[_old_item.key], jsonb_build_object('o', _old_item.value, 'n', _new_row->_old_item.key), true);
        _changes_made := true;
      END IF;
    END LOOP;
    IF _changes_made THEN
      -- record the primary key ID of the row that changed.
      FOREACH _pkey_col_name IN ARRAY v_pkey_cols
      LOOP
        _to_insert := jsonb_set(_to_insert, ARRAY[_pkey_col_name], _new_row->_pkey_col_name);
      END LOOP;
    END IF;

  ELSIF TG_OP = 'INSERT' THEN
    -- record a copy of the new row
    _to_insert := to_jsonb(NEW) - v_ignore_cols;  -- NB: this removes any columns we want to ignore
    _changes_made := true;

  ELSIF TG_OP = 'DELETE' THEN
    -- record a copy of the deleted row
    _to_insert := to_jsonb(OLD) - v_ignore_cols;  -- NB: this removes any columns we want to ignore
    _changes_made := true;

  END IF;

  IF _changes_made THEN
    INSERT INTO changeset_row_history_delta (changeset_id, changetype, table_name, change)
      VALUES (_changeset_id::int, TG_OP, TG_TABLE_NAME, _to_insert);
  END IF;

  RETURN NULL; -- Ignored
END;
$$;


/*
Trigger that handles TRUNCATE operations for the "delta" approach. This is a statement-level trigger.
Parameters:
1) v_ignore_cols: (same definition as for changeset_update_delete_trigger_delta)
*/
CREATE OR REPLACE FUNCTION changeset_truncate_trigger_delta() RETURNS trigger
  SECURITY DEFINER
  LANGUAGE plpgsql
  AS $$
DECLARE
  v_ignore_cols text := TG_ARGV[0];    -- containing a text-literal of a ::text[]
  _old_item RECORD;
  _changeset_id text := current_setting('changeset.changeset_id', true);    -- 2nd param means no exception thrown if not set, it just returns empty string.
BEGIN
  IF _changeset_id !~ '^\d+$' THEN
    RAISE EXCEPTION 'changeset_truncate_trigger_delta called but changeset.changeset_id setting is not an integer.';
  END IF;

  IF TG_OP != 'TRUNCATE' THEN
    RAISE EXCEPTION 'changeset_truncate_trigger_delta must only be called for the TRUNCATE operation';
  END IF;

  EXECUTE format('INSERT INTO changeset_row_history_delta (changeset_id, changetype, table_name, change)'
      ' SELECT $1, $2, %L, to_jsonb(%I.*) - $3::text[]'
      ' FROM %I', TG_TABLE_NAME, TG_TABLE_NAME, TG_TABLE_NAME)
  USING _changeset_id::int, TG_OP, v_ignore_cols;

  RETURN NULL; -- Ignored
END;
$$;


/*
Enable/disable changelog convenience functions for "delta" approach.
*/
CREATE OR REPLACE FUNCTION enable_changeset_tracking_delta
    ( table_ref regclass
    , pkey_cols text
    , ignore_update_cols text
    , ignore_cols text
    ) RETURNS VOID
  VOLATILE
  SECURITY DEFINER
  LANGUAGE plpgsql
  AS $$
DECLARE
  stmt text;
BEGIN
  stmt = format('
    CREATE TRIGGER changeset_i_u_d_delta
      AFTER INSERT OR UPDATE OR DELETE
      ON %I
      FOR EACH ROW EXECUTE PROCEDURE changeset_update_delete_trigger_delta(%L, %L, %L)'
    , table_ref, pkey_cols, ignore_update_cols, ignore_cols);
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = table_ref AND tgname = 'changeset_i_u_d_delta') THEN
    EXECUTE stmt;
  END IF;

  stmt = format('
    CREATE TRIGGER changeset_truncate_delta
      BEFORE TRUNCATE
      ON %I
      FOR EACH STATEMENT EXECUTE PROCEDURE changeset_truncate_trigger_delta(%L)'
    , table_ref, ignore_cols);
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = table_ref AND tgname = 'changeset_truncate_delta') THEN
    EXECUTE stmt;
  END IF;
END;
$$;


CREATE OR REPLACE FUNCTION disable_changeset_tracking_delta(table_ref regclass) RETURNS VOID
  VOLATILE
  SECURITY DEFINER
  LANGUAGE plpgsql
  AS $$
DECLARE
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS changeset_i_u_d_delta ON %I CASCADE', table_ref);
  EXECUTE format('DROP TRIGGER IF EXISTS changeset_truncate_delta ON %I CASCADE', table_ref);
END;
$$;
