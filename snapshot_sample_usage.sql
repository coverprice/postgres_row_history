/*
Worked examples of changes made to a sample `sample_logged_table` table, using the "snapshot" approach.
*/


-- clear the changeset history
TRUNCATE changeset_row_history_delta CASCADE;
TRUNCATE changeset CASCADE;


/*
 Create a sample table used to illustrate the examples.
*/
DROP TABLE IF EXISTS sample_logged_table CASCADE;
CREATE TABLE sample_logged_table (
  id SERIAL PRIMARY KEY
  , text_col text
  , int_col int
  , float_col float
  , col_to_ignore_updates int
  , col_to_always_ignore int
  , another_col_to_always_ignore int
  , jsonb_col jsonb
);

/*
 Configure `sample_logged_table` changes to be automatically recorded using the "snapshot" approach.
*/
SELECT enable_changeset_tracking_snapshot
    ( 'snapshot_sample'::regclass                                   -- table to enable
    , '{"col_to_ignore_updates"}'                                   -- comma-separated list of cols to ignore (only when updating)
    , '{"col_to_always_ignore","another_col_to_always_ignore"}'     -- comma-separated list of cols to always ignore
  )
;


BEGIN;
SELECT changeset_new('Change-001 insert some new test data', 'user_1234');
-- Should log an INSERT with all the values, except for the ignored columns.
INSERT INTO snapshot_sample (text_col, int_col, float_col, col_to_ignore_updates, col_to_always_ignore, jsonb_col)
               VALUES ('xxx', 123, 1.23, 999, 888, '{"a":123,"medal":"bronze"}'::jsonb)
                    , ('yyy', 456, 4.56, 777, 666, '{"b":456,"medal":"silver"}'::jsonb)
                    , ('zzz', 789, 7.89, 111, 222, '{"c":789,"medal":"gold"}'::jsonb);
COMMIT;


-- Should log that row where text_col='xxx' was deleted
-- This should log all the fields, EXCEPT col_to_always_ignore
BEGIN;
SELECT changeset_new('Change-002 deleting a row', 'user_1234');
DELETE FROM snapshot_sample WHERE text_col = 'xxx';
COMMIT;


-- Should log that row where int_col = 456 had its text_col field updated from 'yyy' to 'updated'.
BEGIN;
SELECT changeset_new('Change-003 updating a row', 'user_1234');
UPDATE snapshot_sample SET text_col='updated'
 WHERE int_col = 456;
COMMIT;


-- Even though only part of the JSON was updated, the entire JSON blob is logged. (This is a limitation
-- of the comparison of the before/after column values)
BEGIN;
SELECT changeset_new('Change-004 updating int and float columns', 'user_1234');
UPDATE snapshot_sample SET int_col = 1000, float_col = 99.99
 WHERE text_col = 'zzz';
COMMIT;


-- Even though only part of the JSON was updated, the entire JSON blob is logged. (This is a limitation
-- of the comparison of the before/after column values)
BEGIN;
SELECT changeset_new('Change-005 updating a JSONB column', 'user_1234');
UPDATE snapshot_sample SET jsonb_col = '{"c":789,"medal":"platinum"}'::jsonb
 WHERE text_col = 'zzz';
COMMIT;


-- Should log that row where text_col='zzz' was updated so that field int_col changed from 789 to 12.
-- However the other 2 field changes should NOT be logged.
BEGIN;
SELECT changeset_new('Change-006 updating a row, some columns are ignored', 'user_1234');
UPDATE snapshot_sample SET int_col = 12, col_to_ignore_updates = -7, col_to_always_ignore = 45
 WHERE text_col = 'zzz';
COMMIT;


-- Should log multiple rows (effectively DELETEs) for each row remaining in the table.
BEGIN ;
SELECT changeset_new('Change-007 truncating the whole table', 'user_1234');
TRUNCATE snapshot_sample;
COMMIT;


-- Display the logged changes so we can manually verify the output.
SELECT c.*, crh.id, crh.changetype, crh.table_name, crh.record, crh.old_record
FROM changeset as c
  LEFT JOIN changeset_row_history_snapshot AS crh ON (c.id = crh.change_id)
ORDER BY c.time, crh.id;
