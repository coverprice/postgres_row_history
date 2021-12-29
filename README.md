# Postgres Row History

## What is this?

Sample code for a PostgreSQL trigger that automatically logs a table's changes to a history table (aka audit table,
changelog, etc).

This is a solution for the class of problem known as [Change Data Capture](https://en.wikipedia.org/wiki/Change_data_capture).


## What problem does it solve?

We were storing data in YAML files, stored in Github repos which was reliable, durable, and each
data point had a changelog that specified Who/What/When. But changes were hard to automate, and YAML was a poor
substitute for an RDBMS. Moving the data to an RDBMS was obviously the correct choice, but we didn't
want to lose that git changelog. This set of tools solves that.


## How is it used?

(This is an overview; more detailed instructions are in the Install & Usage section below.)

1) One-time installation + configuration on the tables you want to log.
2) Begin a transaction.
3) Call a Postgres function to init a change, specifying the same info you give in a git commit; WHO is making the
   change, WHEN it's being made, and a 1-line summary of WHAT the change is about.
4) Modify your configured tables with INSERT, UPDATE, DELETE, TRUNCATE.
5) Commit the transaction.

At the end, there will be 1 new row in the `changelog` table providing metadata about the change (c.f. a git log
entry), and 1-many rows associated with it in the `changelog_row_history` table that detail the delta values that were
INSERT'ed, UPDATE'd, DELETE'd, or TRUNCATE'd.


## Design considerations

- Fails if changes are attempted outside a transaction. This prevents poorly-written app-code from accidentally
  modifying a logged table without first setting up a changelog.
- Triggers functions are generic, and any table-specific options are passed in as parameters. No need for customized
  trigger functions for each logged tables.
- Should support ignoring certain columns, that the user may not want to log because they're too noisy, large,
  or just not that useful.

### Caveats

- Changes are stored in JSONB format, so this cannot handle data types that can't be represented in JSONB.
- It's still possible for there to be race conditions when using TRUNCATE because in Postgres a TRUNCATE is "seen"
  outside its transaction.


## Install & Usage

### Installation

Run [`install.sql`](./install.sql) to create:

- `changelog` table: stores metadata about a _set_ of changes.
- `changelog_row_history` table: stores data about a specific change belonging to a single `changelog` entry.
- `changelog_new` function: a convenience method for setting up a new changelog.
- `changelog_update_delete_trigger` & `changelog_truncate_trigger` functions: the triggers that insert the changes
  into `changelog_row_history`.


### Configuration

To configure a table's changes to be automatically log, create 2 triggers on the table.

The following example configures the triggers on a table `test_data`. See [`sample_config.sql`](./sample_config.sql).

```
CREATE TRIGGER test_update_delete_trg
  AFTER INSERT OR UPDATE OR DELETE
  ON test_data
  FOR EACH ROW EXECUTE PROCEDURE changelog_update_delete_trigger(
    '{"test_id"}'                   -- primary key IDs (always logged)
    , '{"col_to_ignore_updates"}'   -- ignore these columns only when updating
    , '{"col_to_always_ignore"}'    -- always ignore these columns
  )
;

CREATE TRIGGER test_truncate_trg
  BEFORE TRUNCATE
  ON test_data
  FOR EACH STATEMENT EXECUTE PROCEDURE changelog_truncate_trigger(
    , '{"col_to_always_ignore"}'    -- always ignore these columns
  )
;
```

The `changelog_update_delete_trigger` function parameters represent lists of columns:
- **param 1**: list of primary key columns (at least 1). These column names/values are always logged.
- **param 2**: list of columns (0-many) to ignore durung UPDATE operations. These might be ignored because they are noisy,
  too large to log, or simply not useful to log. E.g. a `last_updated` timestamp column.
- **param 3**: list of columns (0-many) to always ignore, regardless of whether the operation is INSERT, DELETE, UPDATE,
  or TRUNCATE. These might be ignored for the same reasons as param 2. e.g. a `last_updated` column or large text
  column.

The `changelog_truncate_trigger` function parameter also represents a list of columns:
- **param 1**: (Same as param 3 of `changelog_update_delete_trigger` defined above)

PostgreSQL trigger function params must be strings, so the required format is a string that represents a Postgres
ARRAY of strings (type `text[]`). Examples:

- `'{}'` : Empty list
- `'{"foo"}'` : 1 entry
- `'{"foo","bar","baz"}'` : multiple entries


### Logging a change

See [`sample_usage.sql`](./sample_usage.sql) for complete examples.

1) In your app, begin a transaction.

2) Call `changelog_new(<description>, <user id>)`. This will insert a new `changelog` row with the description,
   user ID, and the current time. It will also configure a local session var so that subsequent changes to the
   configured tables will be associated with this new changelog row.

- **description**: a 1-line human-readable summary of the changes (same as a git commit message).
- **user ID**: an arbitrary string describing the user who is making these changes. It's recommended to use
  a unique and immutable user identifier. (The code could easily modify the `changelog.user_id` column to be a
  foreign key of some `users` table, if available. But beware: the changelog represents all history, so don't link
  it to a `users` table if those users may be deleted.)

Example:
```
SELECT changelog_new('Ticket #12345: Add John Smith to the Administrators group', 'alice.simpson');
```

3) Proceed with your changes. Call INSERT, DELETE, UPDATE and/or TRUNCATE operations that involve the configured table.
For each modified row, a corresponding entry will be logged in the `changelog_row_history` table. See "What is stored"
below for details.

4) Commit the transaction. **NB**: if you rollback the transaction, the `changelog` and any `changelog_row_history`
   entries will also be removed.

Committing the transaction will also clear the var used by the trigger to connect changes with a `changelog` entry.
This prevents the app from inadvertently modifying the table outside of a transaction. Doing so results in a
DB exception.


## What is stored

The `changelog` table has 1 row per set of changes, and describes Who made the change, When it was made, and
What was changed.

The `changelog_row_history` table has a list of changes, linked to exactly 1 `changelog` entry. The columns:

- `id`: Unique ID on this table. Monotonically increasing, so can be used to order row changes within a change.
- `change_id`: Foreign key of the `changelog.change_id` setup in the previous step.
- `changetype`: the operation type, one of `INSERT`, `DELETE`, `UPDATE`, or `TRUNCATE`.
- `table_name`: the name of the modified table.
- `change`: JSONB summary of the changes.

**Important**: `changelog_row_history` entries all share a timestamp (in `changelog`), so when reconstructing the
state of a row, it is necessary to order events within a change using the `changelog_row_history.id` column.
Each `changelog_row_history` entry doesn't have its own timestamp because (a) the resolution of timestamps is too
granular to be useful for reliable ordering within a change, and (b) the `CURRENT_TIMESTAMP` function that
is ostensibly useful here actually returns the same value for the duration of the entire transaction, so it's
useless for ordering events within a transaction.


### `change` column format

The `change` column's format depends on the type of change.

An UPDATE contains the primary key value(s), and *only* changed columns. E.g.

```
INSERT INTO my_table (some_id, foo, bar) VALUES (1111, 1, 2);

[some time later]
BEGIN;
SELECT changelog_new('Some description', 'some_user_id');  -- Configure change
UPDATE my_table SET foo=9, bar=10 WHERE some_id=1111;
COMMIT;
```

The `change` field for the UPDATE:
```
{
    'some_id': 1111,          # Primary key. Always stored.
    'old': {
        'foo': 1,
        'bar': 2,
    },
    'new': {
        'foo': 9,
        'bar': 10,
    },
}
```

An `INSERT`, `DELETE`, or `TRUNCATE` will store the whole row, e.g.
```
{
    'some_id': 1111,
    'foo': 1,
    'bar': 2,
}
```

## Determining a row's state at a given point in time

Sometimes it's useful to reconstruct the state of a row (or table) at a specific point in time. The `changelog` only
contains row changes (deltas), so reconstruction is typically a matter of starting with the current known state,
and applying changes in reverse until the desired time is reached.

To reconstruct a single row's state at time _t_.

1) Set `row_state` to be the current row in the table.
2) Walk the set of changes applied to the row, sorted into reverse order. For each change:
   2.1) if `changelog.change_time` < _t_ then return `row_state`.
   2.2) Apply the inverse of the change to `row_state`. E.g.
        For an UPDATE, if 'foo->old' = 1 and 'foo->new' = 2, then set `row_state.foo` to 1.
        For a DELETE, set `state` to the row state logged in the change.
        For an INSERT, set `row_state` to `NULL` (means "did not exist").
3) If there are no more change rows, return `row_state`.

For step 2, it's necessary to retrieve the changes to a specific row, in reverse order.
For example, to find all changes that affect table `MY_TABLE`, row with primary key `1234`, where the primary key
column is `MY_ID`:

    SELECT c.*, crh.*
    FROM changelog AS c
        JOIN changelog_row_history AS crh ON (c.id = crh.change_id)
    WHERE crh.table_name = 'MY_TABLE'
      AND crh.change -> MY_ID = 1234
	ORDER BY c.time DESC, crh.id DESC;


## FAQ

**Q**: Do updates _need_ to be within a transaction?

**A**: No, you could rework the code to use a SESSION variable instead. However this opens the door for application bugs
     that inadvertantly modify the logged tables; a SESSION variable means any changes will be logged against the
     last `changelog` to be configured using `changelog_new()`, even if those changes have nothing to do with that
     `changelog` entry.

**Q**: When updating, do you need to store both the NEW and OLD values? Why not just store the OLD values?

**A**: Storing NEW values is a trade-off between storage space & convenience.

Whether you store NEW & OLD, or just OLD, simply looking at a single `changelog_row_history` entry will not give you
the entire state of a row at a given time... you will always need a simple program for that (see above).

If storing the OLD & NEW deltas:
- _Pro_: inspecting the 2 OLD/NEW rows is enough to see what changed. There's no need to look at additional rows.
  This is more human friendly. No program is needed, just SELECT on the DB.
- _Con_: takes up more space, since storing OLD & NEW is slightly redundant.

If storing only OLD & NEW deltas:
- _Pro_: Saves more space
- _Con_: Can't look at a specific change and see what the new values are, you _must_ run the reconstruction algorithm
  to derive the state at a specific time.

NB: If choosing concerns you, start with OLD & NEW. If space becomes a concern, you can switch to OLD-only by
updating the logging triggers to only record OLD values, and deleting all the NEW info.


## Resources

* see https://www.postgresql.org/docs/13/plpgsql-trigger.html
* [Using `current_setting` vars in trigger functions](https://stackoverflow.com/questions/51880905/how-to-use-variable-settings-in-trigger-functions)
