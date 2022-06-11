- [Overview](./README.md)
- [Installation, Configuration, & Usage](./INSTALL.md)
- [FAQ](./FAQ.md)
- **[Storage & Reconstitution](./STORAGE.md)**


# Storage & Reconstitution

In both approaches, the `changeset` table has 1 row per set of changes, and describes Who made the change, When it
was made, and an application-provided summary of What was changed.

For the `changeset_row_history_{snapshot,delta}` table, both "snapshot" and "delta" approaches share the following
metadata fields, used to describe a single change within the changeset:
- `id`: Unique ID on this table. Monotonically increasing, so can be used to order row changes within a change.
- `changeset_id`: Foreign key of the `changeset.changeset_id` setup in the previous step.
- `changetype`: the operation type, one of `INSERT`, `DELETE`, `UPDATE`, or `TRUNCATE`.
- `table_name`: the name of the modified table.


### "Snapshot" approach `change` format

The "snapshot" approach's changes are stored in `record` and `old_record` JSON columns of `changeset_row_history_snapshot`.


### "Delta" approach `change` format

The "delta" approach's change format is more complex. Broadly-speaking it only captures the differences, and any
columns marked to be 'always logged'.

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
SELECT changeset_new(
    'Some operation'                            -- operation
    , '{"some_param":"some value"}'::jsonb      -- operation params
    , 'some_user_id'                            -- user responsible for operation
);
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
NB: Column `wiz` is not included in the record because it was not modified.

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
