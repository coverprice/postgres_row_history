/*
Worked examples of changes made to a sample `sample_logged_table` table, using the "delta" approach.
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
 Configure `sample_logged_table` changes to be automatically recorded using the "delta" approach.
*/
SELECT enable_changeset_tracking_delta
    ( 'sample_logged_table'::regclass                               -- table to enable
    , '{"id"}'                                                      -- primary key IDs (always logged)
    , '{"col_to_ignore_updates"}'                                   -- comma-separated list of cols to ignore (only when updating)
    , '{"col_to_always_ignore","another_col_to_always_ignore"}'     -- comma-separated list of cols to always ignore
  )
;


-- This is a psql directive to include + run the given file.
\i sample_exercises.sql



-- Display the logged changes so we can manually verify the output.
SELECT c.*, crh.id, crh.changetype, crh.table_name, crh.change
FROM changeset as c
  LEFT JOIN changeset_row_history_delta AS crh ON (c.id = crh.change_id)
ORDER BY c.time, crh.id;
