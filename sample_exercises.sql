/*
These exercises are run from delta_sample_usage.sql and snapshot_sample_usage.sql
*/


BEGIN;
SELECT changeset_new(
  'Change-001 insert some new test data. Expect 3 change_history log rows.'   -- operation
  , '{"some_param":"some_value","another_param":9876}'::jsonb                 -- arbitrary operation parameters / attributes
  , 'user_1234'                                                               -- ID of the user/bot making the change
);
-- Should log an INSERT with all the values, except for the ignored columns.
INSERT INTO sample_logged_table (text_col, int_col, float_col, col_to_ignore_updates, col_to_always_ignore, jsonb_col                           )
                         VALUES ('xxx',    123,     1.23,      999,                   888,                  '{"a":123,"medal":"bronze"}'::jsonb )
                              , ('yyy',    456,     4.56,      777,                   666,                  '{"b":456,"medal":"silver"}'::jsonb )
                              , ('zzz',    789,     7.89,      111,                   222,                  '{"c":789,"medal":"gold"}'::jsonb   )
;
COMMIT;


-- Should log no change_history rows, because no data actually changed. (Trigger should not be triggered)
-- NB: this will still create a changeset entry, but no actual changes will be logged against it.
BEGIN ;
SELECT changeset_new(
  'Change-002 UPDATE has no effect (data is updated to its current value). Expect no change_history logs.'
  , '{"some_param":"some_value","another_param":9876}'::jsonb
  , 'user_1234'
);
UPDATE sample_logged_table SET text_col='xxx'
 WHERE int_col = 123;  -- matches 1 row, but nothing updated
COMMIT;


-- Should log no change_history rows at all (because the only columns that the query changes are configured as "don't log changes")
-- NB: this will still create a changeset entry, but no actual changes will be logged against it.
BEGIN ;
SELECT changeset_new(
  'Change-003 UPDATE _only_ affects a column that is configured to be ignored. Expect no change_history logs.'
  , '{"some_param":"some_value","another_param":9876}'::jsonb
  , 'user_1234'
);
UPDATE sample_logged_table SET col_to_ignore_updates=1000
 WHERE int_col = 123;  -- matches 1 row, but only a non-logged column was updated
COMMIT;


-- Should log that row where text_col='xxx' was deleted
-- This should log all the fields, EXCEPT col_to_always_ignore
BEGIN;
SELECT changeset_new(
  'Change-004 DELETE a row. Expect 1 change_history log row.'
  , '{"some_param":"some_value","another_param":9876}'::jsonb
  , 'user_1234'
);
DELETE FROM sample_logged_table
 WHERE text_col = 'xxx';
COMMIT;


-- Should log that row where int_col = 456 had its text_col field updated from 'yyy' to 'updated'.
BEGIN;
SELECT changeset_new(
  'Change-005 UPDATE a column in a single row. Expect 1 change_history log row.'
  , '{"some_param":"some_value","another_param":9876}'::jsonb
  , 'user_1234'
);
UPDATE sample_logged_table SET text_col='updated'
 WHERE int_col = 456;
COMMIT;


-- Even though only part of the JSON was updated, the entire JSON blob is logged. (This is a limitation
-- of the comparison of the before/after column values)
BEGIN;
SELECT changeset_new(
  'Change-006 UPDATE multiple columns (int & float). Expect 1 change_history log row.'
  , '{"some_param":"some_value","another_param":9876}'::jsonb
  , 'user_1234'
);
UPDATE sample_logged_table SET int_col = 1000, float_col = 99.99
 WHERE text_col = 'zzz';
COMMIT;


-- Even though only part of the JSON was updated, the entire JSON blob is logged. (This is a limitation
-- of the comparison of the before/after column values)
BEGIN;
SELECT changeset_new(
  'Change-007 UPDATE a JSONB column. Expect 1 change_history log row.'
  , '{"some_param":"some_value","another_param":9876}'::jsonb
  , 'user_1234'
);
UPDATE sample_logged_table SET jsonb_col = '{"c":789,"medal":"platinum"}'::jsonb
 WHERE text_col = 'zzz';
COMMIT;


-- Should log that row where text_col='zzz' was updated so that field int_col changed from 789 to 12.
-- However the other 2 field changes should NOT be logged.
BEGIN;
SELECT changeset_new(
  'Change-008 UPDATE multiple columns in a single row. Some columns are configured to be ignored. Expect 1 change_history log row.'
  , '{"some_param":"some_value","another_param":9876}'::jsonb
  , 'user_1234'
);
UPDATE sample_logged_table SET int_col = 12, col_to_ignore_updates = -7, col_to_always_ignore = 45
 WHERE text_col = 'zzz';
COMMIT;


-- Should log multiple rows (effectively DELETEs) for each row remaining in the table.
BEGIN ;
SELECT changeset_new(
  'Change-009 truncating the whole table. Expect 2 change_history log rows.'
  , '{"some_param":"some_value","another_param":9876}'::jsonb
  , 'user_1234'
);
TRUNCATE sample_logged_table;
COMMIT;
