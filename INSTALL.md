- [Overview](./README.md)
- **[Installation, Configuration, & Usage](./INSTALL.md)**
- [FAQ](./FAQ.md)
- [Storage & Reconstitution](./STORAGE.md)


# Installation, Configuration, & Usage

## Installation

Both the "Snapshot" and "Delta" approaches (refer to the [README.md](./README.md) for a description) use a shared
[`install.sql`](./install.sql) SQL script that adds the necessary tables and stored procedures. Running this script creates:
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


## Configuration

To enable logging on a table, call the `enable_changeset_tracking_snapshot` or
`enable_changeset_tracking_delta` stored procs, depending on which approach you want to use. This will
add the triggers to the given table.

See the [`snapshot_sample_usage.sql`](./snapshot_sample_usage.sql) and [`delta_sample_usage.sql`](./delta_sample_usage.sql)
files for worked examples.

Notes on parameters:
- Some parameters are comma-separated lists of columns. Because of the way triggers accept parameters, these must be
  specifed in the format `'{"item1","item2","..."}'`. (i.e everything inside the single quotes is required, including
  the braces.) Examples: `'{}'` is the empty list, `'{"foo"}'` is 1 list element, and `'{"foo","bar","baz"}'` is multiple list elements.
- `pkey_cols`: ("delta" approach only) a list of primary key columns (at least 1). These column names/values are always logged.
- `ignore_update_cols`: list of columns (0-many) to ignore durung UPDATE operations. These might be ignored because they are
   noisy (e.g. a `last_updated_time` column), or contain derived information (e.g. search index tokens).
- `ignore_cols`: list of columns (0-many) to always ignore, regardless of whether the operation is INSERT, DELETE, UPDATE,
  or TRUNCATE. The application might choose to ignore these because (for example) they have a data type that cannot be
  represented in JSONB, or are too large to log.


### Logging a change

See the [`snapshot_sample_usage.sql`](./snapshot_sample_usage.sql) and [`delta_sample_usage.sql`](./delta_sample_usage.sql)
files for worked examples.

1) In your app, begin a transaction.

2) Call `changeset_new(<operation summary>, <params>, <user id>)`. This will insert a new `changeset` row that contains:

   - a human readable summary of the changeset (ex. "Granting user access")
   - a JSONB set of relevant dynamic attributes about the changeset (ex. `"for_user": "jsmith", "account_id": 1234, "support_ticket: 93747`)
   - The user ID of the person/bot responsible for the change.
   - the current time

It will also configure a local session var so that subsequent changes to the configured tables will be associated with this
new changeset row.

Example:
```
SELECT changeset_new(
	'Grant administrator access',							-- Change summary
	, '{"ticket": "1234", "for_user": "jsmith"}'::jsonb		-- Dynamic vars about the change
	, 'alice.simpson'										-- Person responsible for this change
);
```

3) Proceed with your changes. Call `INSERT`, `DELETE`, `UPDATE` and/or `TRUNCATE` operations that involve the configured
table. For each modified row, a corresponding entry will be logged in the `changeset_row_history` table. See
"What is stored" below for details.

4) Commit the transaction. **NB**: if you rollback the transaction, the `changeset` and any
   `changeset_row_history_{snapshot,delta}` entries will also be rolled back.

Committing the transaction will also clear the var used by the trigger to connect changes with a `changeset` entry.
This prevents the app from inadvertently modifying the table outside of a transaction. (Modifying a logged
table outside of a transactions will throw a DB exception.)
