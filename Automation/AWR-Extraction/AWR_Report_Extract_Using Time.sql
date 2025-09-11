--Run it in a Terminal
sqlplus / as sysdba @AWR_ano.sql "2025-08-17 17:00" "2025-08-17 18:00"

---------------------------------------------------------------------------------
-- Prompt user for start and end time
DEFINE start_time_str = '&1'
DEFINE end_time_str   = '&2'

COLUMN dbid_val NEW_VALUE dbid_val
COLUMN inst_val NEW_VALUE inst_val
COLUMN db_name NEW_VALUE db_name

SELECT dbid AS dbid_val, instance_number AS inst_val, name AS db_name
FROM v$database, v$instance;

COLUMN begin_snap_id NEW_VALUE begin_snap_id
COLUMN end_snap_id NEW_VALUE end_snap_id

SELECT snap_id AS begin_snap_id
FROM dba_hist_snapshot
WHERE begin_interval_time <= TO_TIMESTAMP('&start_time_str', 'YYYY-MM-DD HH24:MI')
ORDER BY begin_interval_time DESC
FETCH FIRST 1 ROWS ONLY;

SELECT snap_id AS end_snap_id
FROM dba_hist_snapshot
WHERE begin_interval_time <= TO_TIMESTAMP('&end_time_str', 'YYYY-MM-DD HH24:MI')
ORDER BY begin_interval_time DESC
FETCH FIRST 1 ROWS ONLY;

-- Build the report filename using DB name and snapshot IDs
COLUMN report_file_name NEW_VALUE report_file_name

SELECT LOWER('&db_name') || '_awr_' || &begin_snap_id || '_to_' || &end_snap_id || '.html' AS report_file_name FROM dual;

-- Set formatting options
SET LONG 1000000
SET PAGESIZE 0
SET LINESIZE 200
SET LONGCHUNKSIZE 1000000
SET TRIMSPOOL ON

PROMPT Generating AWR report: &&report_file_name

-- Generate the AWR report HTML and spool it
SPOOL &&report_file_name

SELECT output
FROM TABLE(
  DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML(
    &&dbid_val, &&inst_val, &&begin_snap_id, &&end_snap_id
  )
);

SPOOL OFF

PROMPT Report saved as &&report_file_name
