/*
Uninstalls the changeset tables and trigger stored procedures.

NOTE! This does *not* delete the triggers installed onto each logged table. You'll need to run the following
for each installed trigger function (substituting the appropriate trigger & table names):

  DROP TRIGGER IF EXISTS some_trigger_name ON some_table_name CASCADE;
*/

DROP FUNCTION IF EXISTS changeset_truncate_trigger CASCADE;
DROP FUNCTION IF EXISTS changeset_update_delete_trigger CASCADE;
DROP FUNCTION IF EXISTS changeset_new
    ( description text
    , user_id text
    ) RETURNS int
  CASCADE;
DROP TABLE IF EXISTS changeset_row_history CASCADE;
DROP TABLE IF EXISTS changeset CASCADE;
