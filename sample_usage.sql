/*
Various examples of changes made to the sample `test_data` table.
*/
BEGIN;
SELECT changelog_new('Change-001 insert some new test data', 'rthrashe');

-- Shouldn't log anything
INSERT INTO test_data (aaa, bbb, col_to_ignore_updates, col_to_always_ignore)
               VALUES ('denver', 9999, 1, 2);
COMMIT;


-- Should log that row where aaa='xxx' was deleted
-- This should log all the fields, EXCEPT col_to_always_ignore
BEGIN;
SELECT changelog_new('Change-002 deleting a row', 'rthrashe');
DELETE FROM test_data WHERE aaa = 'xxx';
COMMIT;


-- Should log that row where bbb = 456 had its aaa field updated from 'yyy' to 'updated'.
BEGIN;
SELECT changelog_new('Change-003 updating a row', 'rthrashe');
UPDATE test_data SET aaa='updated' WHERE bbb = 456;
COMMIT;


-- Should log that row where aaa='zzz' was updated so that field bbb changed from 789 to 12.
-- However the other 2 field changes should NOT be logged.
BEGIN;
SELECT changelog_new('Change-003 updating a row, seeing if columns are ignored', 'rthrashe');
UPDATE test_data SET bbb = 12, col_to_ignore_updates = -7, col_to_always_ignore = 45  WHERE aaa = 'zzz';
COMMIT;


-- Should log multiple rows (effectively DELETEs) for each row remaining in the table.
BEGIN ;
SELECT changelog_new('DPP-4444 did some things', 'rthrashe');
TRUNCATE test_data;
COMMIT;


-- Display the logged changes so we can manually verify the output.
SELECT c.*, crh.id, crh.changetype, crh.table_name, crh.change
FROM changelog as c
  LEFT JOIN changelog_row_history AS crh ON (c.id = crh.change_id)
ORDER BY c.time, crh.id;
