/*
Sample table & configuration
*/
DROP TABLE IF EXISTS test_data CASCADE;
CREATE TABLE test_data (
  test_id SERIAL PRIMARY KEY
  , aaa text
  , bbb int
  , col_to_ignore_updates int
  , col_to_always_ignore int
);
INSERT INTO test_data (aaa, bbb, col_to_ignore_updates, col_to_always_ignore)
   VALUES
    ('xxx', 123, 999, 888)
  , ('yyy', 456, 777, 666)
  , ('zzz', 789, 111, 222)
  ;


/*
Configure `test_data` changes to be automatically recorded.
*/
CREATE TRIGGER test_update_delete_trg
  AFTER INSERT OR UPDATE OR DELETE
  ON test_data
  FOR EACH ROW EXECUTE PROCEDURE changelog_update_delete_trigger(
    '{"test_id"}'                   -- primary key IDs (always logged)
    , '{"col_to_ignore_updates"}'   -- ignore these only when updating
    , '{"col_to_always_ignore"}'    -- ignore these always
  )
;

CREATE TRIGGER test_truncate_trg
  BEFORE TRUNCATE
  ON test_data
  FOR EACH STATEMENT EXECUTE PROCEDURE changelog_truncate_trigger(
    , '{"col_to_always_ignore"}'    -- ignore these always
  )
;
