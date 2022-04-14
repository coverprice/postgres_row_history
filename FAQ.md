- [Overview](./README.md)
- [Installation, Configuration, & Usage](./INSTALL.md)
- **[FAQ](./FAQ.md)**
- [Storage & Reconstitution](./STORAGE.md)


# FAQ

### What is the recommended index to use for time deltas?

(Taken from an article linked to in the Resources section below): For time slices, we need an index on the timestamp column.
Since the table is append-only and the ts column is populated by insertion date, our values for timestamp are naturally in
ascending order. PostgreSQL's builtin [BRIN index](https://www.postgresql.org/docs/current/brin-intro.html) can leverage
that correlation between value and physical location to produce an index that, at scale, is many hundreds of times smaller
than the default (BTREE index) with faster lookup times.

For example:

    CREATE INDEX record_timestamp_idx ON changeset USING brin(time);


### Both approaches have trade-offs. Is there a hybrid approach?

Yes, you could conceivably mix "snapshot" and "delta" for the best of both worlds, at the price of increased complexity.
For example, if an app cared about space efficiency but did not care about logs older than 1 month, it could
periodically reconstitute the state of rows exactly 1 month ago and store them as snapshots, while using the "delta"
approach for the interim time period. This would allow the app to shed the delta logs before the snapshot point and
reap the benefits of the "delta" approach's more efficient storage usage, without sacrificing the ability to
reconstitute rows within the previous month.


### Do updates _need_ to be within a transaction?

No. If you wanted to remove the transaction, you could modify the code to use a `SESSION` variable instead so that the
changeset setup code could "communicate" with the triggers. However this opens the door for application bugs
that inadvertantly modify the logged tables; a `SESSION` variable means any changes will be logged against the
last `changeset` to be configured using `changeset_new()`, even if those changes have nothing to do with that
`changeset` entry.


### In the "delta" approach, is it strictly necessary to store both OLD & NEW values for UPDATEs?

No, you could just store OLD values for even more space efficiency. OLD & NEW are stored as a convenience, to make it
easy to see the contents of a specific changeset without having to reconstitute the before/after rows first.


### Are DDL changes (aka schema changes) logged?

No, DDL changes made to the table are not recorded. This does not affect the "snapshot" approach to reconstituting the
state of a row because it stores the complete state. But the "delta" approach's reconstitution algorithm is very sensitive
to DDL changes. They must be recorded elsewhere (perhaps manually). The reconstitution algorithm must take these schema
changes into account, especially column renames.


### In the "delta" approach, are primary key updates supported?

No. Primary keys are expected to be immutable, so the algorithm special-cases them.

With some minor changes, updates to primary keys could be supported; but updating primary keys at all seems like
a code smell.


### How do I use this with Django?

There is no Django-specific support, but [sample instructions](Django.md) are provided.
