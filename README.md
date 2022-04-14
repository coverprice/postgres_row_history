- **[Overview](./README.md)**
- [Installation, Configuration, & Usage](./INSTALL.md)
- [FAQ](./FAQ.md)
- [Storage & Reconstitution](./STORAGE.md)


# Postgres Row History

## What is this?

Sample code for a PostgreSQL trigger that automatically logs a table's changes to a history table (aka audit table,
changelog, etc). This is a solution for [Change Data Capture](https://en.wikipedia.org/wiki/Change_data_capture)
classes of problems.

## What problem does it solve?

Use it where you want to know **who** changed a row/column, **when** they changed it, **what** the changes were,
and **why** it was changed. (This is similar to inspecting a `git log` of commits, or a `git blame`). It can
also be used as the basis of some code to reconstitute the logged table(s) to any given point in time. (NB: code
not included)

This sample code was originally developed for a team that stored YAML/JSON config data in Git, and wanted to
migrate it to an RDBMS without sacrificing the "change history" and "git blame" features of Git.

## Solution strategies

This sample code covers 2 approaches:
- **Snapshot**: Logs a before/after snapshot of each affected row.
- **Delta**: Log only the changes to each row.

Each approach has various pros/cons:

### Snapshot

Pros:
- Easy to view the state of a given row at a given time.
- To reconstitute the state of the table (or specific rows) at a given point in time, it's *not* necessary to
  store a comprehensive complete history of the change logs. This means the snapshot strategy can
  be easily applied to existing populated tables where the prior change history is unknown.
- It is insensitive to schema changes. DDL changes (i.e. columns added/removed/renamed) do not affect
  logging or the algorithm to reconstitute a row.

Cons:
- Full row snapshots can potentially result in increased storage requirements compared to the Delta strategy.
- Requires (minor) code to identify which fields changed.

The ease of which rows can be reconstituted at a given point in time makes this approach useful for applications
that need to "roll back" changes to a prior version. It also suits applications that want to add auditing to tables
that already have data.


### Delta

Pros:
- Easy to directly view what fields changed.
- It only stores changes, so it is space-efficient. (NB: The sample code's implementation chooses to store a field's
  "after" state in addition to logging its "before" state. This is technically unnecessary and less space-efficient,
  but does make it trivial to compare before/after values).

Cons:
- Requires additional code to reconstitute a row's exact state at a particular moment in time.
- To accurately and consistently reconstitute a row at a given time, it requires the full history of the row from
  some known state (such as the initial or current state).
- Schema changes are not recorded which hinders reconstitututing the state of a row, since the "apply changes to
  previous state" algorithm must also take into account any schema changes.

This approach is useful for those who are mainly interested in viewing what changed and when (vs reconstituting the
state at a given time). It's also useful for applications concerned about efficient storage use.


## Usage overview

#### Install
1. Create history tables. One table stores metadata about a set of changes, and the other stores the changes
   themselves.
2. Create Postgresql stored procedures, to be used as triggers.
3. Configure the triggers on any tables as you want to log, using **either** the "snapshot" approach **or** the
   "delta" approach. In both cases, you specify which columns are logged vs ignored.

#### Application usage
1. The application begins a transaction.
2. The application calls a stored procedure to set the change metadata (the "git commit message"); i.e. **who** is
   making the change, **when** it's being made, and a 1-line summary of **what** the set of changes is about.
3. The application modifies logged tables (`INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`) in the usual way. The
   before/after state is automatically logged to the history table, and associated with the change metadata set up
   in step 2. The application can perform as many operations as it likes, each is logged similarly.
4. The application commits the transaction, which thusly commits the table modifications and the history logs.

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
      Summary: "Ticket #5555, promote Bob from Developer to Admin"
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
      Summary: "Ticket #5555, promote Bob from Developer to Admin"
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

- The application must be aware of this changeset system, in order to accurately set the change user & a
  human-readable change summary. The trigger fails with an exception if changes are attempted outside a
  transaction or if changeset metadata has not been specified. The intention is to prevent poorly-written app-code from
  accidentally modifying a logged table without first setting up a changeset.
- The triggers functions are generic, and any table-specific options are passed in as parameters. Therefore they can
  be re-used to log many different tables.
- Supports ignoring user-specified columns because (for example) they contain derived data, they're too noisy, they're too
  large to log, or cannot be expressed in JSONB (which stores the state of the fields).

### Caveats

- The code only supports data types that can be represented in JSONB. This means binary blobs and various exotic
  types either need to be ignored, or have explicit code to translate them to/from JSONB.
- While this code supports logging `TRUNCATE` changes, it's still possible for there to be race conditions when using
  `TRUNCATE` because in Postgres a `TRUNCATE` is "seen" outside its transaction.
- When using the "delta" strategy, primary keys are expected to be immutable so updates to them are **not logged**. E.g.
  `UPDATE foo SET id=2 WHERE id=1` will not log the old/new values. (Of course, the sample code can be easily
  modified to do this if desired)


## Install & Usage

See [INSTALL.md](./INSTALL.md).


## Potential improvements

The following is a list of various features that could be added:
* Sample code to reconstitute the logged table at a given point in time.
* For the "delta" approach, automatically determine the logged table's primary keys by introspecting Postgres internal
  tables.
* Support truncating the log at time _X_, which would remove/add enough data to the change history to support reconstituting
  it at any time after _X_, but prune changelog rows before _X_ to save space.
* Periodically vacuum the changeset table to remove any "null" changesets, i.e. those with no corresponding `change_history` rows.
  These occur when changes are made to the logged table but no changelog is stored, e.g. when only ignored columns are updated.
* Support a hybrid Snapshot / Delta approach to have the best of both worlds. Similar to how MPEG movies are compressed, store
  full snapshots periodically, and delta changelogs inbetween, for improved space efficiency and easier row reconstitution
  (at the cost of complexity).
* A minor space efficiency can be gained by optimizing how the change type (`UPDATE`, `DELETE`, etc) is stored in the table.


## Resources

* For information about Triggers, see https://www.postgresql.org/docs/13/plpgsql-trigger.html
* [Using `current_setting` vars in trigger functions](https://stackoverflow.com/questions/51880905/how-to-use-variable-settings-in-trigger-functions)
* A useful [blog post](https://supabase.com/blog/2022/03/08/audit) (and subsequent
  [Hacker News discussion](https://news.ycombinator.com/item?id=30615470)) covers the "snapshot" approach in-depth.
