/*
Various examples of changes made to the sample `test_data` table.
*/


BEGIN;
SELECT changeset_new('Change-001 insert some new test data', 'user_1234');
-- Should log an INSERT with all the values, except for the ignored columns.
INSERT INTO test_data (text_col, int_col, float_col, col_to_ignore_updates, col_to_always_ignore, jsonb_col)
               VALUES ('xxx', 123, 1.23, 999, 888, '{"a":123,"medal":"bronze"}'::jsonb)
                    , ('yyy', 456, 4.56, 777, 666, '{"b":456,"medal":"silver"}'::jsonb)
                    , ('zzz', 789, 7.89, 111, 222, '{"c":789,"medal":"gold"}'::jsonb);
COMMIT;


-- Should log that row where text_col='xxx' was deleted
-- This should log all the fields, EXCEPT col_to_always_ignore
BEGIN;
SELECT changeset_new('Change-002 deleting a row', 'user_1234');
DELETE FROM test_data WHERE text_col = 'xxx';
COMMIT;


-- Should log that row where int_col = 456 had its text_col field updated from 'yyy' to 'updated'.
BEGIN;
SELECT changeset_new('Change-003 updating a row', 'user_1234');
UPDATE test_data SET text_col='updated'
 WHERE int_col = 456;
COMMIT;


-- Even though only part of the JSON was updated, the entire JSON blob is logged. (This is a limitation
-- of the comparison of the before/after column values)
BEGIN;
SELECT changeset_new('Change-004 updating int and float columns', 'user_1234');
UPDATE test_data SET int_col = 1000, float_col = 99.99
 WHERE text_col = 'zzz';
COMMIT;


-- Even though only part of the JSON was updated, the entire JSON blob is logged. (This is a limitation
-- of the comparison of the before/after column values)
BEGIN;
SELECT changeset_new('Change-005 updating a JSONB column', 'user_1234');
UPDATE test_data SET jsonb_col = '{"c":789,"medal":"platinum"}'::jsonb
 WHERE text_col = 'zzz';
COMMIT;


-- Should log that row where text_col='zzz' was updated so that field int_col changed from 789 to 12.
-- However the other 2 field changes should NOT be logged.
BEGIN;
SELECT changeset_new('Change-006 updating a row, some columns are ignored', 'user_1234');
UPDATE test_data SET int_col = 12, col_to_ignore_updates = -7, col_to_always_ignore = 45
 WHERE text_col = 'zzz';
COMMIT;


-- Should log multiple rows (effectively DELETEs) for each row remaining in the table.
BEGIN ;
SELECT changeset_new('Change-006 truncating the whole table', 'user_1234');
TRUNCATE test_data;
COMMIT;


-- Display the logged changes so we can manually verify the output.
SELECT c.*, crh.id, crh.changetype, crh.table_name, crh.change
FROM changeset as c
  LEFT JOIN changeset_row_history AS crh ON (c.id = crh.change_id)
ORDER BY c.time, crh.id;
