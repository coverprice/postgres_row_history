# Postgres Row History

## What is this?

Sample code for a PostgreSQL trigger that automatically logs a table's changes to a history table (aka audit table,
changelog, etc). This is a solution for [Change Data Capture](https://en.wikipedia.org/wiki/Change_data_capture)
classes of problems. For example, this sample code may be useful for those who store data in Git via JSON/YAML files,
and wish to migrate it to a RDBMS without sacrificing the benefits of Git's commit log and diffs.

## What problem does it solve?

Use it in situations where you want to know who changed a row/column, when they changed it, what the changes were,
and why it was changed. (This is like inspecting a `git log` of commits, or a `git blame`).

The use case that prompted development of this sample code was to log Access Control changes. Our previous solution
was to format this data in YAML files and store it in a Git repo, which gave us a powerful changelog but data
modification was manual and error-prone. This tool adds that powerful changelog ability to the RDBMS.

## Solution strategies

This sample code covers 2 approaches:
- **Snapshot**: Logs a before/after snapshot of each affected row.
- **Delta**: Log only the changes to each row.

Each approach has various pros/cons:

### Snapshot

Pros:
- Easy to view the state of a given row at a given time.
- A comprehensive & complete history is unnecessary to reconstitute the state of a row at a specific time, so this
  approach can be easily applied to existing populated tables where the prior change history is unknown.
- The independence of each log entry from others also means that older log entries can be discarded without
  adversely affecting the reconstitution of later rows.
- It is insensitive to schema changes. If columns are added/removed, this does not affect logging or the algorithm to
  reconstitute a row.

Cons:
- Requires (minor) code to identify which fields changed.
- Full row snapshots mean potentially significantly increased storage requirements.

The ease of which rows can be reconstituted at a given point in time makes this approach useful for applications
that need to "roll back" changes to a prior version. It also suits applications that want to add auditing to tables
that already have data.


### Delta

Pros:
- Easy to directly view what fields changed.
- This approach is space-efficient. (NB: The sample code's implementation chooses to store a field's "after" state in
  addition to logging its "before" state. This is technically unnecessary and less space-efficient, but does make it trivial
  to compare before/after values).

Cons:
- Requires additional code to reconstitute a row's exact state at a particular moment in time.
- To accurately and consistently reconstitute a row at a given time, it requires the full history of the row.
- Schema changes are not record, which may make it difficult to write an algorithm to reconstitute the state of
  a row, since the "apply changes to previous state" algorithm must also take into account any schema changes.

This approach is useful for those who are mainly interested in viewing what changed and when (vs reconstituting the
state at a given time). It's also useful for applications concerned about efficient storage use.


## Usage overview

#### Install
1. Create history tables. One table stores metadata about a set of changes, and the other stores the changes
   themselves.
2. Create Postgresql stored procedures, to be used as triggers.
3. Configure the triggers on any tables as you want to log, using **either** the "snapshot" approach **or** the
   "delta" approach. In both cases, you specify which columns are logged vs ignored.

#### Usage
1. The application begins a transaction.
2. The application calls a special function to set the change metadata; **who** is making the
   change, **when** it's being made, and a 1-line summary of **what** the set of changes is about.
3. The application modifies logged tables (`INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`). The before/after state is
   logged to the history table, and associated with the overall change metadata set up in step 2. The application
   can perform as many operations as it likes, each is logged similarly.
4. The application commits the transaction, which thusly also commits the table modifications and the history logs.

#### Reading the log
The `changeset` table's rows are equivalent to `git log` entries. Each set of changes has a unique ID, date, user,
and 1-line user-provided human readable summary.

The `changeset_row_history_snapshot` / `changeset_row_history_delta` table's rows record the table changes themselves.
The "snapshot" approach stores the entire before/after state of the affected row, and the "delta" before/after row
stores just the fields that changed.
In both cases, these changes are stored as JSONB blobs of `field:value`. Each row is associated
with a `changeset` row. Each entry has a datestamp to order the changes within a specific changeset.

    Snapshot approach
    -----------------
    Changeset
      ID: 1234
      Summary: "Ticket #1234, promote Bob from Developer to Admin"
      Change time: 2022-02-22 02:22
      
      change_row_history:
           changeset_id: 1234
           changed_table: 'user_group_members'
           change_type: 'UPDATE'
           change_time: 2022-02-22 02:22
           record: {
               user_group_id: 7890,
               user_id: 5656,
               role: 'Admin'
           }
           old_record: {
               user_group_id: 7890,
               user_id: 5656,
               role: 'Developer'
           }


    Delta approach
    --------------
    Changeset
      ID: 1234
      Summary: "Ticket #1234, promote Bob from Developer to Admin"
      Change time: 2022-02-22 02:22
      
      change_row_history:
           changeset_id: 1234
           changed_table: 'user_group_members'
           change_type: 'UPDATE'
           change_time: 2022-02-22 02:22
           fields: {
               user_group_id: 7890,
               user_id: 5656,
               old: {
                   role: 'Developer'
               },
               new: {
                   role: 'Admin'
               }
           }

The `changeset` and `change_row_history_{snapshot,delta}` tables are sufficient for browsing recent changes to a
table (similar to reading a git log).

See below for details on reconstituting the state of a row.

## Design considerations

- The application must be aware of this changeset system. The trigger fail with an exception if changes are attempted outside
  transaction or if changeset metadata has not been specified. The intention is to prevent poorly-written app-code from
  accidentally modifying a logged table without first setting up a changeset.
- Triggers functions are generic, and any table-specific options are passed in as parameters. No need for customized
  trigger functions for each logged table.
- Supports ignoring user-specified columns because (for example) they contain derived data, they're too noisy, they're too
  large to log, or cannot be expressed in JSONB (which stores the state of the fields).

### Caveats

- Changes are stored in JSONB format, so this cannot handle data types that can't be represented in JSONB.
- While this code supports logging `TRUNCATE` changes, it's still possible for there to be race conditions when using
  `TRUNCATE` because in Postgres a `TRUNCATE` is "seen" outside its transaction.
- Primary keys are expected to be immutable, so updates to primary key values are **not logged**. E.g. if you
  `UPDATE foo SET id=2 WHERE id=1`, this will not log the old/new values. (Of course, the sample code can be easily
  modified to do this if desired)


## Install & Usage

### Installation

Both approaches use a shared [`install.sql`](./install.sql) SQL scripts that adds the necessary tables and stored
procedures. Running this script will create:
- `changeset` table: stores metadata about a _set_ of changes.
- `changeset_row_history_snapshot` table: stores data about a changes made using the "snapshot" approach. This is
  a full snapshot of the modified row.
- `changeset_row_history_delta` table: stores data about a changes made using the "delta" approach. This is
  just the before/after modified fields.
- `changeset_new` function: a convenience stored-procedure for setting up a new changeset.
- `{enable,disable}_changeset_tracking_{snapshot,delta}` functions: convenience stored-procedure for enabling/disabling
  tracking on a given table, using either the snapshot or delta approaches respectively.
- `changeset_update_delete_trigger` & `changeset_truncate_trigger` functions: the triggers that insert the changes
  into `changeset_row_history`.


### Configuration

To configure a table's changes to be automatically log, call `enable_changeset_tracking_snapshot` or
`enable_changeset_tracking_delta` stored procs, depending on which approach you want to use. This will
add the triggers to the given table.

See the [`snapshot_sample_usage.sql`](./snapshot_sample_usage.sql) and [`delta_sample_usage.sql`](./delta_sample_usage.sql)
files for worked examples.

Notes on parameters:
- Some parameters are comma-separated lists of columns. Because of the way triggers accept parameters, these must be
  specifed in the format `'{"item1","item2","..."}'`. (That is, everything inside the single quotes is required, including
  the braces.) Examples: `'{}'` is the empty list, `'{"foo"}'` is 1 list element, and `'{"foo","bar","baz"}'` is multiple list elements.
- `pkey_cols`: ("delta" approach only) list of primary key columns (at least 1). These column names/values are always logged.
- `ignore_update_cols`: list of columns (0-many) to ignore durung UPDATE operations. These might be ignored because they are
   noisy (e.g. a `last_updated_time` column), or contain derived information (e.g. search tokenizations).
- `ignore_cols`: list of columns (0-many) to always ignore, regardless of whether the operation is INSERT, DELETE, UPDATE,
  or TRUNCATE. The application might choose to ignore these because (for example) they have a data type that cannot be
  represented in JSONB, or are too large to log.


### Logging a change

See the [`snapshot_sample_usage.sql`](./snapshot_sample_usage.sql) and [`delta_sample_usage.sql`](./delta_sample_usage.sql)
files for worked examples.

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

3) Proceed with your changes. Call `INSERT`, `DELETE`, `UPDATE` and/or `TRUNCATE` operations that involve the configured
table. For each modified row, a corresponding entry will be logged in the `changeset_row_history` table. See
"What is stored" below for details.

4) Commit the transaction. **NB**: if you rollback the transaction, the `changeset` and any `changeset_row_history`
   entries will also be rolled back.

Committing the transaction will also clear the var used by the trigger to connect changes with a `changeset` entry.
This prevents the app from inadvertently modifying the table outside of a transaction. Doing so results in a
DB exception.


## What is stored, and how

In both approaches, the `changeset` table has 1 row per set of changes, and describes Who made the change, When it
was made, and an application-provided summary of What was changed.

For the `changeset_row_history` table, both "snapshot" and "delta" approaches share the following metadata fields,
used to describe a single change within the changeset:
- `id`: Unique ID on this table. Monotonically increasing, so can be used to order row changes within a change.
- `change_id`: Foreign key of the `changeset.change_id` setup in the previous step.
- `changetype`: the operation type, one of `INSERT`, `DELETE`, `UPDATE`, or `TRUNCATE`.
- `table_name`: the name of the modified table.

In the "snapshot" approach, the actual changes are stored in `change_new` and `change_old` JSON columns.

In the "delta" approach, the change format is more complex. Broadly-speaking it only captures the differences, and any
columns marked to be 'always logged'.

### "Delta" approach `change` format

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

**Important**: `changeset_row_history_delta` entries all share a timestamp (in `changeset`), so when reconstructing the
state of a row, it is necessary to order events within a change using the `changeset_row_history.id` column.
Each `changeset_row_history` entry doesn't have its own timestamp because (a) the resolution of timestamps is too
granular to be useful for reliable ordering within a change, and (b) the `CURRENT_TIMESTAMP` function that
is ostensibly useful here actually returns the same value for the duration of the entire transaction, so it's
useless for ordering events within a transaction.


## Reconstituting the state of a row at a given point in time

Reconstitute the state of a row in the "snapshot" approach is trivial, because the entire state can be read from the single
changelog entry. However for the "delta" approach more sophisticated code (not included with this sample code) must be used
to start at a "known state" (such as the row's creation state snapshot or current state) and walk forward/backward in time
(respectively) applying any field changes along the way, to arrive at the state at the desired time. This approach is
therefore very sensitive to data loss and any schema changes.

### Snapshot
Given a time _t_, search the changelog for any references to the the desired row, and the state can be read out from the
`change_row_history_snapshot` row for latest time <= _t_. A `changetype` of `INSERT`, `UPDATE` means that `record` should
be used, whereas a `changetype` of `TRUNCATE` or `DELETE` means that the row no longer existed at time _t_. 

### Delta

Reconstituting a single row's state at time _t_ assumes that you know have the full history of
the row between some known state and time _t_. Starting at a known full state of the row (either its initial state,
or its current state), walk the history "towards" time _t_, applying any found changes to the in-memory state.
When you arrive at time _t_, the in-memory state should reflect the state of the row. (This elides the significant problem
of handling schema changes)


## FAQ

#### What is the recommended index to use for time deltas?

(Taken from an article linked to in the Resources section below): For time slices, we need an index on the timestamp column.
Since the table is append-only and the ts column is populated by insertion date, our values for timestamp are naturally in
ascending order. PostgreSQL's builtin [BRIN index](https://www.postgresql.org/docs/current/brin-intro.html) can leverage
that correlation between value and physical location to produce an index that, at scale, is many hundreds of times smaller
than the default (BTREE index) with faster lookup times.

For example:

    CREATE INDEX record_timestamp_idx ON changeset USING brin(time);


#### Both approaches have trade-offs. Is there a hybrid approach?

Yes, you could conceivably mix "snapshot" and "delta" for the best of both worlds, at the price of increased complexity.
For example, if an app cared about space efficiency but did not care about logs older than 1 month, it could
periodically reconstitute the state of rows exactly 1 month ago and store them as snapshots, while using the "delta"
approach for the interim time period. This would allow the app to shed the delta logs before the snapshot point and
reap the benefits of the "delta" approach's more efficient storage usage, without sacrificing the ability to
reconstitute rows within the previous month.


#### Do updates _need_ to be within a transaction?

No. If you wanted to remove the transaction, you could modify the code to use a `SESSION` variable instead so that the
changeset setup code could "communicate" with the triggers. However this opens the door for application bugs
that inadvertantly modify the logged tables; a `SESSION` variable means any changes will be logged against the
last `changeset` to be configured using `changeset_new()`, even if those changes have nothing to do with that
`changeset` entry.


#### In the "delta" approach, is it strictly necessary to store both OLD & NEW values for UPDATEs?

No, you could just store OLD values for even more space efficiency. OLD & NEW are stored as a convenience, to make it
easy to see the contents of a specific changeset without having to reconstitute the before/after rows first.


#### Are DDL changes (aka schema changes) logged?

No, DDL changes made to the table are not recorded. This does not affect the "snapshot" approach to reconstituting the
state of a row because it stores the complete state. But the "delta" approach's reconstitution algorithm is very sensitive
to DDL changes. They must be recorded elsewhere (perhaps manually). The reconstitution algorithm must take these schema
changes into account, especially column renames.


#### In the "delta" approach, are primary key updates supported?

No. Primary keys are expected to be immutable, so the algorithm special-cases them.

With some minor changes, updates to primary keys could be supported; but updating primary keys at all seems like
a code smell.


#### How do I use this with Django?

There is no Django-specific support, but [sample instructions](Django.md) are provided.


## Resources

* see https://www.postgresql.org/docs/13/plpgsql-trigger.html
* [Using `current_setting` vars in trigger functions](https://stackoverflow.com/questions/51880905/how-to-use-variable-settings-in-trigger-functions)
* A useful [blog post](https://supabase.com/blog/2022/03/08/audit) (and subsequent
  [Hacker News discussion](https://news.ycombinator.com/item?id=30615470)) covers the "snapshot" approach in-depth.
