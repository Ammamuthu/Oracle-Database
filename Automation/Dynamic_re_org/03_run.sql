-- =============================================================================
-- FILE : 03_run.sql
-- EDIT only the 2 lines marked EDIT HERE
-- Run: sqlplus user/pass @03_run.sql
-- =============================================================================

-- EDIT HERE
DEFINE v_schema = 'IMS_MM'
DEFINE v_table  = 'IBG_FILE_GEN_IDS'

SET PAGESIZE  5000
SET LINESIZE  999
SET TRIMSPOOL ON
SET ECHO      OFF
SET FEEDBACK  ON
SET VERIFY    OFF
SET TIMING    ON

-- Default SQL*Plus HTML - no custom CSS, exactly like your existing output
SET MARKUP HTML ON ENTMAP OFF SPOOL ON PREFORMAT OFF

-- EDIT HERE : filename
-- SPOOL IMS_MM_IBG_FILE_GEN_IDS.html

SPOOL &&v_schema._&&v_table..html

-- =============================================================================
-- PRE-REORG : OBJECT COUNTS
-- =============================================================================
SELECT
    (SELECT COUNT(*) FROM dba_tab_partitions
     WHERE table_owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table')) AS PARTITION_COUNT,
    (SELECT COUNT(*) FROM dba_tab_subpartitions
     WHERE table_owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table')) AS SUBPARTITION_COUNT,
    (SELECT COUNT(*) FROM dba_lob_partitions
     WHERE table_owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table')) AS LOB_PARTITION_COUNT
FROM DUAL;

-- =============================================================================
-- PRE-REORG : TOTAL TABLE SIZE (GB)
-- =============================================================================
SELECT
    NVL((SELECT SUM(S.bytes/1024/1024/1024) FROM DBA_SEGMENTS S
         WHERE S.OWNER=UPPER('&&v_schema') AND S.SEGMENT_NAME=UPPER('&&v_table')),0)
  + NVL((SELECT SUM(S.bytes/1024/1024/1024) FROM DBA_SEGMENTS S, DBA_LOBS L
         WHERE S.OWNER=UPPER('&&v_schema') AND L.SEGMENT_NAME=S.SEGMENT_NAME
           AND L.TABLE_NAME=UPPER('&&v_table') AND L.OWNER=UPPER('&&v_schema')),0)
  + NVL((SELECT SUM(S.bytes/1024/1024/1024) FROM DBA_SEGMENTS S, DBA_INDEXES I
         WHERE S.OWNER=UPPER('&&v_schema') AND I.INDEX_NAME=S.SEGMENT_NAME
           AND I.TABLE_NAME=UPPER('&&v_table') AND I.INDEX_TYPE='LOB'
           AND I.OWNER=UPPER('&&v_schema')),0)
    AS "TOTAL TABLE SIZE GB"
FROM DUAL;

-- =============================================================================
-- PRE-REORG : PARTITION-WISE SIZE (GB)
-- =============================================================================
SELECT NM, ROUND(SUM(DSIZE),4) AS SIZE_GB FROM (
    SELECT PARTITION_NAME AS NM, NVL(SUM(S.BYTES/1024/1024/1024),0) DSIZE
    FROM DBA_SEGMENTS S WHERE S.OWNER=UPPER('&&v_schema')
      AND S.SEGMENT_TYPE='TABLE PARTITION' AND S.SEGMENT_NAME=UPPER('&&v_table')
    GROUP BY PARTITION_NAME
    UNION ALL
    SELECT L.PARTITION_NAME, NVL(SUM(S.BYTES/1024/1024/1024),0)
    FROM DBA_SEGMENTS S, DBA_LOB_PARTITIONS L
    WHERE S.PARTITION_NAME=L.LOB_PARTITION_NAME AND S.OWNER=UPPER('&&v_schema')
      AND L.TABLE_OWNER=S.OWNER AND L.TABLE_NAME=UPPER('&&v_table')
    GROUP BY L.PARTITION_NAME
    UNION ALL
    SELECT 'INDEX_LOB', NVL(SUM(S.BYTES/1024/1024/1024),0)
    FROM DBA_SEGMENTS S, DBA_INDEXES I WHERE S.OWNER=UPPER('&&v_schema')
      AND I.INDEX_NAME=S.SEGMENT_NAME AND I.TABLE_NAME=UPPER('&&v_table')
      AND I.INDEX_TYPE='LOB' AND I.OWNER=UPPER('&&v_schema')
) GROUP BY NM ORDER BY SIZE_GB DESC;

-- =============================================================================
-- PRE-REORG : NON-PARTITIONED INDEX STATUS
-- =============================================================================
SELECT index_name, owner, status
FROM dba_indexes
WHERE owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table') AND partitioned='NO'
ORDER BY index_name;

-- =============================================================================
-- PRE-REORG : INDEX PARTITION STATUS
-- =============================================================================
SELECT a.index_name, b.partition_name, a.status, b.status AS partition_index_status
FROM dba_indexes a, dba_ind_partitions b
WHERE a.owner=UPPER('&&v_schema') AND a.table_name=UPPER('&&v_table')
  AND a.owner=b.index_owner AND a.index_name=b.index_name AND a.index_type<>'LOB'
ORDER BY a.index_name, b.partition_name;

-- =============================================================================
-- PRE-REORG : INDEX SUBPARTITION STATUS
-- =============================================================================
SELECT a.index_name, b.subpartition_name, a.status, b.status AS partition_index_status
FROM dba_indexes a, dba_ind_subpartitions b
WHERE a.owner=UPPER('&&v_schema') AND a.table_name=UPPER('&&v_table')
  AND a.owner=b.index_owner AND a.index_name=b.index_name AND a.index_type<>'LOB'
ORDER BY a.index_name, b.subpartition_name;

-- =============================================================================
-- PRE-REORG : INDEX PARTITION USABILITY SUMMARY
-- =============================================================================
SELECT b.status, COUNT(*) AS CNT
FROM dba_indexes a, dba_ind_partitions b
WHERE a.owner=UPPER('&&v_schema') AND a.table_name=UPPER('&&v_table')
  AND b.index_owner=UPPER('&&v_schema') AND a.index_name=b.index_name
  AND b.partition_name NOT LIKE 'SYS%'
GROUP BY b.status ORDER BY b.status;

-- =============================================================================
-- PRE-REORG : LOB INDEX STATUS (NON-PARTITIONED)
-- =============================================================================
SELECT index_name, status, partitioned
FROM dba_indexes
WHERE table_owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table')
  AND index_type='LOB' AND partitioned='NO'
ORDER BY index_name;

-- =============================================================================
-- PRE-REORG : LOB INDEX PARTITION STATUS
-- =============================================================================
SELECT index_name, partition_name, status
FROM dba_ind_partitions
WHERE index_owner=UPPER('&&v_schema')
  AND index_name IN (
      SELECT index_name FROM dba_indexes
      WHERE table_owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table') AND index_type='LOB'
  )
ORDER BY index_name, partition_name;

-- =============================================================================
-- EXECUTE REORG
-- Turn markup OFF during exec so procedure output doesn't go into HTML as text
-- Alert log shows live progress while this runs
-- =============================================================================
SET MARKUP HTML OFF
SET SERVEROUTPUT OFF
SET TIMING ON

EXEC SYS.REORG_TABLE('&&v_schema', '&&v_table');

SET TIMING OFF
SET MARKUP HTML ON ENTMAP OFF SPOOL ON PREFORMAT OFF

-- =============================================================================
-- REORG TRACKER : STEP RESULTS
-- =============================================================================
SELECT
    step_seq                           AS SEQ,
    step_type                          AS TYPE,
    NVL(step_target,'(full table)')    AS TARGET,
    status,
    elapsed_secs                       AS SECS,
    TO_CHAR(started_at,  'HH24:MI:SS') AS STARTED,
    TO_CHAR(completed_at,'HH24:MI:SS') AS COMPLETED,
    SUBSTRB(error_msg,1,80)            AS ERROR
FROM SYS.REORG_TRACKER
WHERE schema_name=UPPER('&&v_schema') AND table_name=UPPER('&&v_table')
ORDER BY step_seq;

-- =============================================================================
-- REORG TRACKER : SUMMARY
-- =============================================================================
SELECT
    SUM(CASE WHEN status='DONE'    THEN 1 ELSE 0 END) AS DONE,
    SUM(CASE WHEN status='PENDING' THEN 1 ELSE 0 END) AS PENDING,
    SUM(CASE WHEN status='FAILED'  THEN 1 ELSE 0 END) AS FAILED,
    SUM(CASE WHEN status='RUNNING' THEN 1 ELSE 0 END) AS STUCK_RUNNING,
    COUNT(*)                                           AS TOTAL
FROM SYS.REORG_TRACKER
WHERE schema_name=UPPER('&&v_schema') AND table_name=UPPER('&&v_table');

-- =============================================================================
-- POST-REORG : OBJECT COUNTS
-- =============================================================================
SELECT
    (SELECT COUNT(*) FROM dba_tab_partitions
     WHERE table_owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table')) AS PARTITION_COUNT,
    (SELECT COUNT(*) FROM dba_tab_subpartitions
     WHERE table_owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table')) AS SUBPARTITION_COUNT,
    (SELECT COUNT(*) FROM dba_lob_partitions
     WHERE table_owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table')) AS LOB_PARTITION_COUNT
FROM DUAL;

-- =============================================================================
-- POST-REORG : TOTAL TABLE SIZE (GB)
-- =============================================================================
SELECT
    NVL((SELECT SUM(S.bytes/1024/1024/1024) FROM DBA_SEGMENTS S
         WHERE S.OWNER=UPPER('&&v_schema') AND S.SEGMENT_NAME=UPPER('&&v_table')),0)
  + NVL((SELECT SUM(S.bytes/1024/1024/1024) FROM DBA_SEGMENTS S, DBA_LOBS L
         WHERE S.OWNER=UPPER('&&v_schema') AND L.SEGMENT_NAME=S.SEGMENT_NAME
           AND L.TABLE_NAME=UPPER('&&v_table') AND L.OWNER=UPPER('&&v_schema')),0)
  + NVL((SELECT SUM(S.bytes/1024/1024/1024) FROM DBA_SEGMENTS S, DBA_INDEXES I
         WHERE S.OWNER=UPPER('&&v_schema') AND I.INDEX_NAME=S.SEGMENT_NAME
           AND I.TABLE_NAME=UPPER('&&v_table') AND I.INDEX_TYPE='LOB'
           AND I.OWNER=UPPER('&&v_schema')),0)
    AS "TOTAL TABLE SIZE GB"
FROM DUAL;

-- =============================================================================
-- POST-REORG : NON-PARTITIONED INDEX STATUS
-- =============================================================================
SELECT index_name, owner, status
FROM dba_indexes
WHERE owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table') AND partitioned='NO'
ORDER BY index_name;

-- =============================================================================
-- POST-REORG : INDEX PARTITION STATUS
-- =============================================================================
SELECT a.index_name, b.partition_name, a.status, b.status AS partition_index_status
FROM dba_indexes a, dba_ind_partitions b
WHERE a.owner=UPPER('&&v_schema') AND a.table_name=UPPER('&&v_table')
  AND a.owner=b.index_owner AND a.index_name=b.index_name AND a.index_type<>'LOB'
ORDER BY a.index_name, b.partition_name;

-- =============================================================================
-- POST-REORG : INDEX SUBPARTITION STATUS
-- =============================================================================
SELECT a.index_name, b.subpartition_name, a.status, b.status AS partition_index_status
FROM dba_indexes a, dba_ind_subpartitions b
WHERE a.owner=UPPER('&&v_schema') AND a.table_name=UPPER('&&v_table')
  AND a.owner=b.index_owner AND a.index_name=b.index_name AND a.index_type<>'LOB'
ORDER BY a.index_name, b.subpartition_name;

-- =============================================================================
-- POST-REORG : INDEX PARTITION USABILITY SUMMARY
-- =============================================================================
SELECT b.status, COUNT(*) AS CNT
FROM dba_indexes a, dba_ind_partitions b
WHERE a.owner=UPPER('&&v_schema') AND a.table_name=UPPER('&&v_table')
  AND b.index_owner=UPPER('&&v_schema') AND a.index_name=b.index_name
  AND b.partition_name NOT LIKE 'SYS%'
GROUP BY b.status ORDER BY b.status;

-- =============================================================================
-- POST-REORG : LOB INDEX STATUS (NON-PARTITIONED)
-- =============================================================================
SELECT index_name, status, partitioned
FROM dba_indexes
WHERE table_owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table')
  AND index_type='LOB' AND partitioned='NO'
ORDER BY index_name;

-- =============================================================================
-- POST-REORG : LOB INDEX PARTITION STATUS
-- =============================================================================
SELECT index_name, partition_name, status
FROM dba_ind_partitions
WHERE index_owner=UPPER('&&v_schema')
  AND index_name IN (
      SELECT index_name FROM dba_indexes
      WHERE table_owner=UPPER('&&v_schema') AND table_name=UPPER('&&v_table') AND index_type='LOB'
  )
ORDER BY index_name, partition_name;

-- =============================================================================
-- POST-REORG : PARTITION-WISE SIZE (GB)
-- =============================================================================
SELECT NM, ROUND(SUM(DSIZE),4) AS SIZE_GB FROM (
    SELECT PARTITION_NAME AS NM, NVL(SUM(S.BYTES/1024/1024/1024),0) DSIZE
    FROM DBA_SEGMENTS S WHERE S.OWNER=UPPER('&&v_schema')
      AND S.SEGMENT_TYPE='TABLE PARTITION' AND S.SEGMENT_NAME=UPPER('&&v_table')
    GROUP BY PARTITION_NAME
    UNION ALL
    SELECT L.PARTITION_NAME, NVL(SUM(S.BYTES/1024/1024/1024),0)
    FROM DBA_SEGMENTS S, DBA_LOB_PARTITIONS L
    WHERE S.PARTITION_NAME=L.LOB_PARTITION_NAME AND S.OWNER=UPPER('&&v_schema')
      AND L.TABLE_OWNER=S.OWNER AND L.TABLE_NAME=UPPER('&&v_table')
    GROUP BY L.PARTITION_NAME
    UNION ALL
    SELECT 'INDEX_LOB', NVL(SUM(S.BYTES/1024/1024/1024),0)
    FROM DBA_SEGMENTS S, DBA_INDEXES I WHERE S.OWNER=UPPER('&&v_schema')
      AND I.INDEX_NAME=S.SEGMENT_NAME AND I.TABLE_NAME=UPPER('&&v_table')
      AND I.INDEX_TYPE='LOB' AND I.OWNER=UPPER('&&v_schema')
) GROUP BY NM ORDER BY SIZE_GB DESC;

SPOOL OFF
SET MARKUP HTML OFF
SET FEEDBACK ON
SET ECHO ON
SET TIMING OFF
