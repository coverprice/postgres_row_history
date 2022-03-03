# Postgres Row History

## What is this?

Sample code for a PostgreSQL trigger that automatically logs a table's changes to a history table (aka audit table,
changelog, etc). This is a solution for [Change Data Capture](https://en.wikipedia.org/wiki/Change_data_capture)
classes of problems.

#### Setup
1. Create a history tables. One table stores metadata about a set of changes, and the other stores the changes
   themselves.
2. Configure the trigger on any tables as you want to log. You can specify which columns are logged.

#### Usage
1. The application begins a transaction.
2. The application calls a special function to set the change metadata; WHO is making the
   change, WHEN it's being made, and a 1-line summary of WHAT the set of changes is about.
3. The application modifies logged tables (`INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`). The before/after state is
   logged to the history table, and associated with the overall change metadata set up in (2). The application
   can perform as many operations as it likes, each is logged similarly.
4. The application commits the transaction (and thus the table modifications and the history logs).

#### Reading the log
The `changeset` table's rows are equivalent to git log entries. Each set of changes has a unique ID, date, user,
and 1-line summary.

The `changeset_row_history` table's rows records a specific change made to logged tables. Each row is associated
with a `changeset` row. Each entry has a datestamp to order the changes within a specific changeset.

These two tables are sufficient for browsing recent changes to a table (similar to reading a git log).

More sophisticated tools (not included with this sample code) can also use this data to reconstruct the original
tables at any given time.

## What problem does it solve?

Use it in situations where you want to know who changed a row/column, when they changed it, what the changes were,
and why it was changed. (This is like inspecting a `git log` of commits, or a `git blame`).

Our use case was to log Access Control changes. Our previous solution was to format this data in YAML files and store
it in a Git repo, which gave us a powerful changelog but data modification was difficult. This tool adds that powerful
changelog ability to the RDBMS.


## Design considerations

- The application must be aware of the system. The trigger fail with an exception if changes are attempted outside
  transaction or if changeset metadata has not been specified. This prevents poorly-written app-code from
  accidentally modifying a logged table without first setting up a changeset.
- Triggers functions are generic, and any table-specific options are passed in as parameters. No need for customized
  trigger functions for each logged tables.
- Should support ignoring certain columns, that the user may not want to log because they're too noisy, large,
  or just not that useful.

### Caveats

- Changes are stored in JSONB format, so this cannot handle data types that can't be represented in JSONB.
- It's still possible for there to be race conditions when using TRUNCATE because in Postgres a TRUNCATE is "seen"
  outside its transaction.
- Primary keys are expected to be immutable, so updates to primary key values are **not logged**. E.g. if you
  `UPDATE foo SET id=2 WHERE id=1`, this will not log the old/new values.


## Install & Usage

### Installation

Run [`install.sql`](./install.sql) to create:

- `changeset` table: stores metadata about a _set_ of changes.
- `changeset_row_history` table: stores data about a specific change belonging to a single `changeset` entry.
- `changeset_new` function: a convenience method for setting up a new changeset.
- `changeset_update_delete_trigger` & `changeset_truncate_trigger` functions: the triggers that insert the changes
  into `changeset_row_history`.


### Configuration

To configure a table's changes to be automatically log, create 2 triggers on the table.

The following example configures the triggers on a table `test_data`. See [`sample_config.sql`](./sample_config.sql).

```
CREATE TRIGGER test_update_delete_trg
  AFTER INSERT OR UPDATE OR DELETE
  ON test_data
  FOR EACH ROW EXECUTE PROCEDURE changeset_update_delete_trigger(
    '{"test_id"}'                   -- primary key IDs (always logged)
    , '{"col_to_ignore_updates"}'   -- ignore these columns only when updating
    , '{"col_to_always_ignore"}'    -- always ignore these columns
  )
;

CREATE TRIGGER test_truncate_trg
  BEFORE TRUNCATE
  ON test_data
  FOR EACH STATEMENT EXECUTE PROCEDURE changeset_truncate_trigger(
    , '{"col_to_always_ignore"}'    -- always ignore these columns
  )
;
```

The `changeset_update_delete_trigger` function parameters represent lists of columns:
- **param 1**: list of primary key columns (at least 1). These column names/values are always logged.
- **param 2**: list of columns (0-many) to ignore durung UPDATE operations. These might be ignored because they are noisy,
  too large to log, or simply not useful to log. E.g. a `last_updated` timestamp column.
- **param 3**: list of columns (0-many) to always ignore, regardless of whether the operation is INSERT, DELETE, UPDATE,
  or TRUNCATE. These might be ignored for the same reasons as param 2. e.g. a `last_updated` column or large text
  column.

The `changeset_truncate_trigger` function parameter also represents a list of columns:
- **param 1**: (Same as param 3 of `changeset_update_delete_trigger` defined above)

PostgreSQL trigger function params must be strings, so the required format is a string that represents a Postgres
ARRAY of strings (type `text[]`). Examples:

- `'{}'` : Empty list
- `'{"foo"}'` : 1 list element
- `'{"foo","bar","baz"}'` : multiple list elements


### Logging a change

See [`sample_usage.sql`](./sample_usage.sql) for complete examples.

1) In your app, begin a transaction.

2) Call `changeset_new(<description>, <user id>)`. This will insert a new `changeset` row with the description,
   user ID, and the current time. It will also configure a local session var so that subsequent changes to the
   configured tables will be associated with this new changeset row.

- **description**: a 1-line human-readable summary of the changes (same as a git commit message).
- **user ID**: an arbitrary string describing the user who is making these changes. It's recommended to use
  a unique and immutable user identifier. (The code could easily modify the `changeset.user_id` column to be a
  foreign key of some `users` table, if available. But beware: the changeset represents all history, so don't link
  it to a `users` table if those users may be deleted.)

Example:
```
SELECT changeset_new('Ticket #12345: Add John Smith to the Administrators group', 'alice.simpson');
```

3) Proceed with your changes. Call INSERT, DELETE, UPDATE and/or TRUNCATE operations that involve the configured table.
For each modified row, a corresponding entry will be logged in the `changeset_row_history` table. See "What is stored"
below for details.

4) Commit the transaction. **NB**: if you rollback the transaction, the `changeset` and any `changeset_row_history`
   entries will also be removed.

Committing the transaction will also clear the var used by the trigger to connect changes with a `changeset` entry.
This prevents the app from inadvertently modifying the table outside of a transaction. Doing so results in a
DB exception.


## What is stored

The `changeset` table has 1 row per set of changes, and describes Who made the change, When it was made, and
What was changed.

The `changeset_row_history` table has a list of changes, linked to exactly 1 `changeset` entry. The columns:

- `id`: Unique ID on this table. Monotonically increasing, so can be used to order row changes within a change.
- `change_id`: Foreign key of the `changeset.change_id` setup in the previous step.
- `changetype`: the operation type, one of `INSERT`, `DELETE`, `UPDATE`, or `TRUNCATE`.
- `table_name`: the name of the modified table.
- `change`: JSONB summary of the changes (see below for details).

**Important**: `changeset_row_history` entries all share a timestamp (in `changeset`), so when reconstructing the
state of a row, it is necessary to order events within a change using the `changeset_row_history.id` column.
Each `changeset_row_history` entry doesn't have its own timestamp because (a) the resolution of timestamps is too
granular to be useful for reliable ordering within a change, and (b) the `CURRENT_TIMESTAMP` function that
is ostensibly useful here actually returns the same value for the duration of the entire transaction, so it's
useless for ordering events within a transaction.


### `change` format

The `change` column's JSONB format depends on the type of change.

For `INSERT`, `DELETE`, or `TRUNCATE` it is simply a JSONB column-name:value for all columns (except ignored ones).
```
{
    'some_id': 1111,
    'foo': 1,
    'bar': 'hello',
}
```

For `UPDATE`, it contains the primary key value(s) and *only* changed columns. E.g.

```
INSERT INTO my_table (some_id, foo, bar, wiz) VALUES (1111, 1, 'hello', 2);

[some time later]
BEGIN;
SELECT changeset_new('Some description', 'some_user_id');  -- Configure change
UPDATE my_table SET foo=9, bar="world" WHERE some_id=1111;
COMMIT;
```

The `change` field for the UPDATE:
```
{
    'some_id': 1111,          # Primary key. Always stored.
    'foo': {
        'o': 1,               # 'o' means 'old value'
        'n': 9,               # 'n' means 'new value'
    },
    'bar': {
        'o': "hello",
        'n': "world",
    },
}
```
NB: Column `wiz` is not included in the record because it was not updated.


## Reconstructing state at a given point in time

To reconstruct the state of a row or the entire table at a specific point in time _t_, use a simple algorithm:
Starting from a known state, replay logged changes in order until you reach the desired time.

This can be done either forwards or backwards: Forwards starts from an empty table and apply changes forward in time,
and backwards starts from a copy of the current table, and applies changes in reverse.  Which one is more efficient
depends on whether the desired time _t_ is nearer the beginning or the end of the changeset.

### Reconstructing the entire table at a specific time

To reconstruct the table at a time _t_, the following pseudo-code starts with the current state and applies
changes backwards in time.

1) Copy the original table into a temporary table. (Tip: Use `SELECT INTO ...`)

2) Retrieve the changes in reverse order. Example code to retrieve all changes for table `MY_TABLE`:

    SELECT c.*, crh.*
    FROM changeset AS c
        JOIN changeset_row_history AS crh ON (c.id = crh.change_id)
    WHERE crh.table_name = 'MY_TABLE'
    ORDER BY c.time DESC, crh.id DESC;

2.1) For each change row:

2.2) If there are no more rows, or if `changeset.change_time` < _t_ then exit. The temporary table contains the
  contents at time _t_.

2.3) Based on `changeset_row_history.changetype`, do the following:

  * `UPDATE`: apply the old values to the temp table. e.g. if the change record is for `id:123`, `foo->o` = 1,
     and `foo->n` = 2, then run `UPDATE _temp_MY_TABLE SET foo = 1 WHERE id = 123`.
  * `DELETE` or `TRUNCATE`: INSERT the row into the table using the information from the `change` column.
  * `INSERT`: DELETE the row from the table using the information from the `change` column.

2.4) Go to 2.1


### Reconstructing a single row at a specific time

To reconstruct a single row's state at time _t_, it's assumed in advance that you know the primary key ID of the row.
The above algorithm can be applied in the same way, except that:

* instead of maintaining a temporary table to apply changes to, just store a temporary row (in memory, say)
* add a filter to the SQL that retrieves the changes to only return rows that apply to the row of interest.


## FAQ

#### Do updates _need_ to be within a transaction?

No, you could rework the code to use a SESSION variable instead. However this opens the door for application bugs
that inadvertantly modify the logged tables; a SESSION variable means any changes will be logged against the
last `changeset` to be configured using `changeset_new()`, even if those changes have nothing to do with that
`changeset` entry.

#### Is it necessary to store both OLD & NEW values for UPDATEs?

Technically it's not necessary to store NEW values when logging an UPDATE. This is a trade-off between storage space
& convenience. The supplied implementation falls on the side of convenience.

If storing the OLD & NEW deltas:
- _Pro_: inspecting the OLD/NEW row by itself is enough to see what changed. There's no need to look at additional rows.
  This is more human-friendly. No program is needed to reconstruct row state.
- _Con_: the records take up more space.

If storing only OLD deltas:
- _Pro_: Saves more space
- _Con_: Can't look at a specific change and see what the new values are, you _must_ run the reconstruction algorithm
  to derive the state at a specific time.

NB 1: Regardless of which you choose, simply looking at a single `changeset_row_history` entry will not give you
the _entire_ state of a row at a given time... you will always need a simple algorithm for that (see above).

NB 2: If the choice concerns you, start with OLD & NEW. If space becomes a concern, you can switch to OLD-only by
updating the logging triggers to only record OLD values, and deleting all the NEW info.


#### Are DDL changes (aka schema changes) logged?

No, DDL changes made to the table are not recorded. DDL changes should be recorded elsewhere (perhaps manually) as
they may significantly impact the "reconstruct table/row at a specific time" algorithm. It will need to take schema
changes into account, especially column renames.


#### Are primary key updates supported?

No. Primary keys are expected to be immutable, so the algorithm special-cases them.

With some minor changes, updates to primary keys could be supported; but updating primary keys at all seems like
a code smell.


#### How do I use this with Django?

There is no Django-specific support, but [sample instructions](Django.md) are provided.


## Resources

* see https://www.postgresql.org/docs/13/plpgsql-trigger.html
* [Using `current_setting` vars in trigger functions](https://stackoverflow.com/questions/51880905/how-to-use-variable-settings-in-trigger-functions)
