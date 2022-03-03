/*
Various examples of changes made to the sample `test_data` table.
*/
BEGIN;
SELECT changeset_new('Change-001 insert some new test data', 'user_1234');

-- Shouldn't log anything
INSERT INTO test_data (aaa, bbb, col_to_ignore_updates, col_to_always_ignore)
               VALUES ('denver', 9999, 1, 2);
COMMIT;


-- Should log that row where aaa='xxx' was deleted
-- This should log all the fields, EXCEPT col_to_always_ignore
BEGIN;
SELECT changeset_new('Change-002 deleting a row', 'user_1234');
DELETE FROM test_data WHERE aaa = 'xxx';
COMMIT;


-- Should log that row where bbb = 456 had its aaa field updated from 'yyy' to 'updated'.
BEGIN;
SELECT changeset_new('Change-003 updating a row', 'user_1234');
UPDATE test_data SET aaa='updated'
 WHERE bbb = 456;
COMMIT;


-- Should log that row where aaa='zzz' was updated so that field bbb changed from 789 to 12.
-- However the other 2 field changes should NOT be logged.
BEGIN;
SELECT changeset_new('Change-004 updating a row, seeing if columns are ignored', 'user_1234');
UPDATE test_data SET bbb = 12, col_to_ignore_updates = -7, col_to_always_ignore = 45
 WHERE aaa = 'zzz';
COMMIT;


-- Should log multiple rows (effectively DELETEs) for each row remaining in the table.
BEGIN ;
SELECT changeset_new('Change-005 truncating the whole table', 'user_1234');
TRUNCATE test_data;
COMMIT;


-- Display the logged changes so we can manually verify the output.
SELECT c.*, crh.id, crh.changetype, crh.table_name, crh.change
FROM changeset as c
  LEFT JOIN changeset_row_history AS crh ON (c.id = crh.change_id)
ORDER BY c.time, crh.id;
