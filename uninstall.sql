/*
Uninstalls the changeset tables and trigger stored procedures.

NOTE! This does *not* delete the triggers installed onto each logged table. You'll need to run the following
for each installed trigger function first (substituting the appropriate table names):

  PERFORM disable_changeset_tracking_snapshot(some_table_name);

or

  PERFORM disable_changeset_tracking_delta(some_table_name);
*/

DROP FUNCTION IF EXISTS changeset_truncate_trigger_delta CASCADE;
DROP FUNCTION IF EXISTS changeset_truncate_trigger_snapshot CASCADE;
DROP FUNCTION IF EXISTS changeset_update_delete_trigger_delta CASCADE;
DROP FUNCTION IF EXISTS changeset_update_delete_trigger_snapshot CASCADE;
DROP FUNCTION IF EXISTS changeset_new(description text, user_id text) CASCADE;
DROP FUNCTION IF EXISTS enable_changeset_tracking_snapshot(regclass, text, text) CASCADE;
DROP FUNCTION IF EXISTS disable_changeset_tracking_snapshot(regclass) CASCADE;
DROP FUNCTION IF EXISTS enable_changeset_tracking_delta(regclass, text, text, text) CASCADE;
DROP FUNCTION IF EXISTS disable_changeset_tracking_delta(regclass) CASCADE;
DROP TABLE IF EXISTS sample_logged_table CASCADE;
DROP TABLE IF EXISTS changeset_row_history_delta CASCADE;
DROP TABLE IF EXISTS changeset_row_history_snapshot CASCADE;
DROP TABLE IF EXISTS changeset CASCADE;
