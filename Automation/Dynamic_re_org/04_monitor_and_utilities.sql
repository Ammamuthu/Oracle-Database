-- =============================================================================
-- FILE : 03_monitor_and_utilities.sql
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CHECK PROGRESS for one table
--    Run this anytime to see what is done / pending / failed
-- -----------------------------------------------------------------------------
SELECT
    step_seq                              AS seq,
    RPAD(step_type, 18)                   AS step_type,
    NVL(step_target,  '(full table)')     AS target,
    NVL(step_target2, '-')                AS detail,
    status,
    elapsed_secs                          AS secs,
    TO_CHAR(completed_at,'HH24:MI:SS')    AS completed,
    SUBSTRB(error_msg, 1, 60)             AS error
FROM SYS.REORG_TRACKER
WHERE schema_name = '&&v_schema'
  AND table_name  = '&&v_table'
ORDER BY step_seq;


-- -----------------------------------------------------------------------------
-- 2. SUMMARY across ALL tables you have seeded
-- -----------------------------------------------------------------------------
SELECT
    schema_name,
    table_name,
    SUM(CASE WHEN status='DONE'    THEN 1 ELSE 0 END)            AS done,
    SUM(CASE WHEN status='PENDING' THEN 1 ELSE 0 END)            AS pending,
    SUM(CASE WHEN status='FAILED'  THEN 1 ELSE 0 END)            AS failed,
    SUM(CASE WHEN status='RUNNING' THEN 1 ELSE 0 END)            AS stuck_running,
    COUNT(*)                                                      AS total,
    ROUND( SUM(CASE WHEN status='DONE' THEN 1 ELSE 0 END)
           / COUNT(*) * 100 ) || '%'                             AS pct_done
FROM SYS.REORG_TRACKER
GROUP BY schema_name, table_name
ORDER BY schema_name, table_name;


-- =============================================================================
-- UTILITIES  (uncomment and run as needed)
-- =============================================================================

-- Reset ALL failed steps for a table so they retry on next run
/*
UPDATE SYS.REORG_TRACKER
   SET status = 'PENDING', error_msg = NULL
 WHERE schema_name = '&&v_schema'
   AND table_name  = '&&v_table'
   AND status      = 'FAILED';
COMMIT;
*/

-- Fix a step stuck as RUNNING after a killed session
-- (the procedure does this automatically on next run, but you can do it manually)
/*
UPDATE SYS.REORG_TRACKER
   SET status = 'PENDING'
 WHERE schema_name = '&&v_schema'
   AND table_name  = '&&v_table'
   AND status      = 'RUNNING';
COMMIT;
*/

-- Skip a specific step (mark it DONE without running)
/*
UPDATE SYS.REORG_TRACKER
   SET status = 'SKIPPED'
 WHERE schema_name = '&&v_schema'
   AND table_name  = '&&v_table'
   AND step_seq    = &&step_seq;
COMMIT;
*/

-- Clean up tracker rows after a table is fully done and verified
/*
DELETE FROM SYS.REORG_TRACKER
 WHERE schema_name = '&&v_schema'
   AND table_name  = '&&v_table';
COMMIT;
*/
