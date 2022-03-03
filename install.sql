/*
Installs the components necessary for logging changes to tables.

- `changeset` table: stores metadata about a _set_ of changes.
- `changeset_row_history` table: stores data about a specific change belonging to a single `changeset` entry.
- `changeset_new` function: a convenience method for setting up a new changeset.
- `changeset_update_delete_trigger` & `changeset_truncate_trigger` functions: the triggers that insert the changes
  into `changeset_row_history`.

*/

DROP TABLE IF EXISTS changeset CASCADE;
CREATE TABLE changeset (
  id int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY
  , time timestamp with time zone NOT NULL
  , description text NOT NULL
  , user_id text NOT NULL
);

DROP TABLE IF EXISTS changeset_row_history CASCADE;
CREATE TABLE changeset_row_history (
  id int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY
  , change_id int REFERENCES changeset(id) NOT NULL
  , changetype text NOT NULL
  , table_name text NOT NULL
  , change jsonb NOT NULL
);


/*
Function: changeset_new()

Purpose: Sets up the database state to record a new change.
It just inserts the given data into the change table and sets the local setting that will be passed to the trigger if/when it is called.
It assumes a transaction has already been started; it will emit a warning if not, and any changes will subsequently fail.
*/
CREATE OR REPLACE FUNCTION changeset_new
    ( description text
    , user_id text
    ) RETURNS int
  LANGUAGE plpgsql
AS $$
DECLARE
  change_id changeset.id%TYPE;
BEGIN
  INSERT INTO changeset(time, description, user_id)
  VALUES(CURRENT_TIMESTAMP, description, user_id)
  RETURNING id INTO change_id;

  PERFORM set_config('changesetger.change_id', change_id::text, true);   -- Last parameter is 'is_local'

  RETURN change_id;
END;
$$;


/*
Trigger that handles UPDATE and DELETE operations, a row-level trigger.

Parameters:
1) v_pkey_cols: string containing a literal text array of the table-to-log's primary key column name(s). e.g. in 'raw' format this might be
     ARRAY['user_id'], or {'user_id'}, and when converted to a string (i.e. quoting & escaping single quotes) this would be '{"user_id"}'
2) v_ignore_update_cols: string containing literal text array of any column names to ignore ONLY during UPDATEs, e.g. {'last_updated'}
3) v_ignore_cols: string containing literal text array of any column names to NEVER log. e.g. {'huge_expensive_field_we_dont_need_to_log'}

NB: We'd rather pass text arrays directly, but triggers only support passing string params, so we pass string literals and cast
to ::text[] inside the trigger.

Note: You're more likely to use ignore_update_cols than ignore_cols. ignore_update_cols avoids logging updates to "noisy" columns
that don't provide much value (from a logging POV) and may be redundant anyway, like 'last_updated'. However during
DELETE/TRUNCATE (i.e. not UPDATE) you still want a copy of that info as part of a full table log, if you ever needed to restore
the entire row, so these will still be logged on DELETE/TRUNCATE.

ignore_cols is a list of columns to completely ignore regardless of the operation type, and is intended for columns
that won't matter during a restore, or columns that can't be converted to JSONB (e.g. BLOBs), or can't be efficiently stored
e.g. very large text fields that you don't care about. Since these are pretty rare, it's likely for this param to be empty.

*/
CREATE OR REPLACE FUNCTION changeset_update_delete_trigger() RETURNS trigger
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
  _change_id text := current_setting('changeset.change_id', true);    -- 2nd param means no exception thrown if not set, it just returns empty string.
  _pkey_col_name text;
BEGIN
  IF _change_id !~ '^\d+$' THEN
    RAISE EXCEPTION 'changeset_update_delete_trigger called but changeset.change_id setting is not an integer.';
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
    INSERT INTO changeset_row_history (change_id, changetype, table_name, change)
      VALUES (_change_id::int, TG_OP, TG_TABLE_NAME, _to_insert);
  END IF;

  RETURN NULL; -- Ignored
END;
$$;


/*
Trigger that handles TRUNCATE operations, a statement-level trigger.
Parameters:
1) v_ignore_cols: (same definition as for changeset_update_delete_trigger)
*/
CREATE OR REPLACE FUNCTION changeset_truncate_trigger() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
DECLARE
  v_ignore_cols text := TG_ARGV[0];    -- containing a text-literal of a ::text[]
  _old_item RECORD;
  _change_id text := current_setting('changeset.change_id', true);    -- 2nd param means no exception thrown if not set, it just returns empty string.
BEGIN
  IF _change_id !~ '^\d+$' THEN
    RAISE EXCEPTION 'changeset_truncate_trigger called but changeset.change_id setting is not an integer.';
  END IF;

  IF TG_OP != 'TRUNCATE' THEN
    RAISE EXCEPTION 'changeset_truncate_trigger must only be called for the TRUNCATE operation';
  END IF;

  EXECUTE format('INSERT INTO changeset_row_history (change_id, changetype, table_name, change)'
      ' SELECT $1, $2, %L, to_jsonb(%I.*) - $3::text[]'
      ' FROM %I', TG_TABLE_NAME, TG_TABLE_NAME, TG_TABLE_NAME)
  USING _change_id::int, TG_OP, v_ignore_cols;

  RETURN NULL; -- Ignored
END;
$$;
