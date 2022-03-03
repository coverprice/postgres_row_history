/*
This sample shows the creation of a table to be logged, and configuring triggers
on the table to perform the logging.

See the `sample_usage.sql` file for examples of logging changes to this sample table.
*/

/*
1. Create a sample table.
*/
DROP TABLE IF EXISTS test_data CASCADE;
CREATE TABLE test_data (
  test_id SERIAL PRIMARY KEY
  , text_col text
  , int_col int
  , float_col float
  , col_to_ignore_updates int
  , col_to_always_ignore int
  , jsonb_col jsonb
);


/*
2. Configure `test_data` changes to be automatically recorded.
*/
CREATE TRIGGER test_update_delete_trg
  AFTER INSERT OR UPDATE OR DELETE
  ON test_data
  FOR EACH ROW EXECUTE PROCEDURE changeset_update_delete_trigger(
    '{"test_id"}'                   -- primary key IDs (always logged)
    , '{"col_to_ignore_updates"}'   -- ignore these only when updating
    , '{"col_to_always_ignore"}'    -- ignore these always
  )
;

CREATE TRIGGER test_truncate_trg
  BEFORE TRUNCATE
  ON test_data
  FOR EACH STATEMENT EXECUTE PROCEDURE changeset_truncate_trigger(
    , '{"col_to_always_ignore"}'    -- ignore these always
  )
;
