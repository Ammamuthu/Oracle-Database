SET PAGESIZE 50000
SET LINESIZE 200
SET MARKUP HTML ON SPOOL ON ENTMAP ON
SET TIMING ON;
SET SERVEROUTPUT ON;
SET LINES 999;
set timing on;
SET SERVEROUTPUT ON;
SET VERIFY OFF;


col partition_name for a40;
col STATUS for a20;
col partition_index_status for a40;
col index_name for a40;
COL SUBPARTITION_NAME FOR A40;

DEFINE v_schema = 'IMS_MM';
DEFINE v_table  = 'MYMT_OUT_REPOSITORY';

SPOOL &&v_schema._&&v_table._INDEX_STATUS.html

-- ==========================================================
-- 0. OVERALL USABLE vs UNUSABLE COUNT (all objects combined)
-- ==========================================================
SELECT
  ( (SELECT COUNT(*)
       FROM dba_indexes
      WHERE owner = '&v_schema'
        AND table_name = '&v_table'
        AND partitioned = 'NO'
        AND status = 'VALID')
  + (SELECT COUNT(*)
       FROM dba_ind_partitions b, dba_indexes a
      WHERE a.owner = '&v_schema'
        AND a.owner = b.index_owner
        AND a.table_name = '&v_table'
        AND a.index_name = b.index_name
        AND b.status = 'USABLE')
  + (SELECT COUNT(*)
       FROM dba_ind_subpartitions b, dba_indexes a
      WHERE a.owner = '&v_schema'
        AND a.owner = b.index_owner
        AND a.table_name = '&v_table'
        AND a.index_name = b.index_name
        AND b.status = 'USABLE')
  ) AS OVERALL_USABLE_COUNT_IDX,
  ( (SELECT COUNT(*)
       FROM dba_indexes
      WHERE owner = '&v_schema'
        AND table_name = '&v_table'
        AND partitioned = 'NO'
        AND status = 'UNUSABLE')
  + (SELECT COUNT(*)
       FROM dba_ind_partitions b, dba_indexes a
      WHERE a.owner = '&v_schema'
        AND a.owner = b.index_owner
        AND a.table_name = '&v_table'
        AND a.index_name = b.index_name
        AND b.status = 'UNUSABLE')
  + (SELECT COUNT(*)
       FROM dba_ind_subpartitions b, dba_indexes a
      WHERE a.owner = '&v_schema'
        AND a.owner = b.index_owner
        AND a.table_name = '&v_table'
        AND a.index_name = b.index_name
        AND b.status = 'UNUSABLE')
  ) AS OVERALL_UNUSABLE_COUNT_IDX
FROM dual;

-- ==========================================================
-- 1. INDEX (regular, non-partitioned)
-- ==========================================================
SELECT status, COUNT(*) Regular_Index
FROM dba_indexes
WHERE owner = '&v_schema'
  AND table_name = '&v_table'
  AND partitioned = 'NO'
  AND index_type <> 'LOB'
GROUP BY status;

SELECT index_name, status
FROM dba_indexes
WHERE owner = '&v_schema'
  AND table_name = '&v_table'
  AND partitioned = 'NO'
  AND index_type <> 'LOB'
ORDER BY status, index_name;

-- ==========================================================
-- 2. PART INDEX (regular index partitions)
-- ==========================================================
SELECT b.status, COUNT(*) PARTITION_Index
FROM dba_indexes a, dba_ind_partitions b
WHERE a.owner = '&v_schema'
  AND a.owner = b.index_owner
  AND a.table_name = '&v_table'
  AND a.index_name = b.index_name
  AND a.index_type <> 'LOB'
GROUP BY b.status;

SELECT b.index_name, b.partition_name, b.status
FROM dba_indexes a, dba_ind_partitions b
WHERE a.owner = '&v_schema'
  AND a.owner = b.index_owner
  AND a.table_name = '&v_table'
  AND a.index_name = b.index_name
  AND a.index_type <> 'LOB'
ORDER BY b.status, b.index_name, b.partition_name;

-- ==========================================================
-- 3. SUB PART (regular index subpartitions)
-- ==========================================================
SELECT b.status, COUNT(*) SUBPARTITION_Index
FROM dba_indexes a, dba_ind_subpartitions b
WHERE a.owner = '&v_schema'
  AND a.owner = b.index_owner
  AND a.table_name = '&v_table'
  AND a.index_name = b.index_name
  AND a.index_type <> 'LOB'
GROUP BY b.status;

SELECT b.index_name, b.subpartition_name, b.status
FROM dba_indexes a, dba_ind_subpartitions b
WHERE a.owner = '&v_schema'
  AND a.owner = b.index_owner
  AND a.table_name = '&v_table'
  AND a.index_name = b.index_name
  AND a.index_type <> 'LOB'
ORDER BY b.status, b.index_name, b.subpartition_name;

-- ==========================================================
-- 4. LOB (LOB index, non-partitioned)
-- ==========================================================
SELECT status, COUNT(*) LOB_Regular_IDX
FROM dba_indexes
WHERE owner = '&v_schema'
  AND table_name = '&v_table'
  AND partitioned = 'NO'
  AND index_type = 'LOB'
GROUP BY status;

SELECT index_name, status
FROM dba_indexes
WHERE owner = '&v_schema'
  AND table_name = '&v_table'
  AND partitioned = 'NO'
  AND index_type = 'LOB'
ORDER BY status, index_name;

-- ==========================================================
-- 5. LOB INDEX PARTITION
-- ==========================================================
SELECT b.status, COUNT(*) LOB_PARTITION_IDX
FROM dba_indexes a, dba_ind_partitions b
WHERE a.owner = '&v_schema'
  AND a.owner = b.index_owner
  AND a.table_name = '&v_table'
  AND a.index_name = b.index_name
  AND a.index_type = 'LOB'
GROUP BY b.status;

SELECT b.index_name, b.partition_name, b.status
FROM dba_indexes a, dba_ind_partitions b
WHERE a.owner = '&v_schema'
  AND a.owner = b.index_owner
  AND a.table_name = '&v_table'
  AND a.index_name = b.index_name
  AND a.index_type = 'LOB'
ORDER BY b.status, b.index_name, b.partition_name;

-- ==========================================================
-- 6. LOB INDEX SUBPARTITION
-- ==========================================================
SELECT b.status, COUNT(*) LOB_SUBPARTITION_IDX
FROM dba_indexes a, dba_ind_subpartitions b
WHERE a.owner = '&v_schema'
  AND a.owner = b.index_owner
  AND a.table_name = '&v_table'
  AND a.index_name = b.index_name
  AND a.index_type = 'LOB'
GROUP BY b.status;

SELECT b.index_name, b.subpartition_name, b.status
FROM dba_indexes a, dba_ind_subpartitions b
WHERE a.owner = '&v_schema'
  AND a.owner = b.index_owner
  AND a.table_name = '&v_table'
  AND a.index_name = b.index_name
  AND a.index_type = 'LOB'
ORDER BY b.status, b.index_name, b.subpartition_name;


SPOOL OFF
SET MARKUP HTML OFF