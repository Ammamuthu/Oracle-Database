SET PAGESIZE 5000;
SET MARKUP HTML ON ENTMAP OFF SPOOL ON PREFORMAT OFF;
SET VERIFY OFF;

DEFINE v_schema = 'IMS_MM';
DEFINE v_table  = 'NACHA_BATCH_REP_DTLS';

SPOOL &&v_schema._&&v_table..html

SET TIMING ON;
SET SERVEROUTPUT ON;
SET LINES 999;


set timing on;
SET SERVEROUTPUT ON;

set lines 999;
col partition_name for a40;
col STATUS for a20;
col partition_index_status for a40;
col index_name for a40;
COL SUBPARTITION_NAME FOR A40;

select index_name,owner,status from dba_indexes where owner='&v_schema' and table_name='&v_table' and partitioned = 'NO';

select a.index_name, b.partition_name, a.status, b.status partition_index_status
from dba_indexes A, dba_ind_partitions B
where a.owner='&v_schema' and a.table_name='&v_table'
and a.owner=b.index_owner and a.index_name = b.index_name and a.index_type <> 'LOB' order by a.index_name, b.partition_name;


SELECT a.index_name, b.subpartition_name, a.status, b.status partition_index_status
FROM dba_indexes a, dba_ind_subpartitions b
WHERE a.owner = '&v_schema'
  AND a.table_name = '&v_table'
  AND a.owner = b.index_owner
  AND a.index_name = b.index_name
  AND a.index_type <> 'LOB'
ORDER BY a.index_name, b.subpartition_name;

 
select b.status,count(*) from  dba_indexes A, dba_ind_partitions B
where a.owner='&v_schema' and a.table_name='&v_table' and b.index_owner = '&v_schema' and a.index_name = b.index_name 
and partition_name not like 'SYS%'
group by b.status;
 

SELECT INDEX_NAME, STATUS, PARTITIONED
FROM DBA_INDEXES
WHERE TABLE_OWNER = '&v_schema'
  AND TABLE_NAME = '&v_table'
  AND INDEX_TYPE = 'LOB'
  AND partitioned = 'NO';

-- Step 3: LOB index partition status
SELECT INDEX_NAME, PARTITION_NAME, STATUS
FROM DBA_IND_PARTITIONS
WHERE INDEX_OWNER = '&v_schema'
  AND INDEX_NAME IN (
    SELECT INDEX_NAME
    FROM DBA_INDEXES
    WHERE TABLE_OWNER = '&v_schema'
      AND TABLE_NAME = '&v_table'
      AND INDEX_TYPE = 'LOB'
  );
 
SELECT
(SELECT NVL(SUM(S.bytes/1024/1024/1024),0)
FROM DBA_SEGMENTS S
WHERE S.OWNER = UPPER('&v_schema') AND
(S.SEGMENT_NAME = UPPER('&v_table'))) +
(SELECT NVL(SUM(S.bytes/1024/1024/1024),0)
FROM DBA_SEGMENTS S, DBA_LOBS L
WHERE S.OWNER = UPPER('&v_schema') AND
(L.SEGMENT_NAME = S.SEGMENT_NAME AND L.TABLE_NAME = UPPER('&v_table')
AND L.OWNER = UPPER('&v_schema'))) +
(SELECT NVL(SUM(S.bytes/1024/1024/1024),0)
FROM DBA_SEGMENTS S, DBA_INDEXES I
WHERE S.OWNER = UPPER('&v_schema') AND
(I.INDEX_NAME = S.SEGMENT_NAME AND I.TABLE_NAME = UPPER('&v_table') AND
INDEX_TYPE = 'LOB' AND I.OWNER = UPPER('&v_schema')))
"TOTAL TABLE SIZE"
FROM DUAL;
 
 
SELECT NM, SUM(DSIZE) FROM (
SELECT PARTITION_NAME AS NM,  NVL(SUM(S.BYTES/1024/1024/1024),0)  AS DSIZE
FROM DBA_SEGMENTS S
WHERE S.OWNER = UPPER('&v_schema') AND S.SEGMENT_TYPE = 'TABLE PARTITION' AND (S.SEGMENT_NAME = UPPER('&v_table'))
GROUP BY PARTITION_NAME
UNION ALL
SELECT L.PARTITION_NAME AS NM,  NVL(SUM(S.BYTES/1024/1024/1024),0) AS DSIZE
FROM DBA_SEGMENTS S, DBA_LOB_PARTITIONS L
WHERE S.PARTITION_NAME = L.LOB_PARTITION_NAME
    AND S.OWNER = '&v_schema'
    AND L.TABLE_OWNER = S.OWNER
    AND L.TABLE_NAME = '&v_table'
GROUP BY L.PARTITION_NAME
UNION ALL
SELECT 'INDEX_LOB' AS NM, NVL(SUM(S.BYTES/1024/1024/1024),0) AS DSIZE
FROM DBA_SEGMENTS S, DBA_INDEXES I
WHERE S.OWNER = UPPER('&v_schema') AND
(I.INDEX_NAME = S.SEGMENT_NAME AND I.TABLE_NAME = UPPER('&v_table') AND INDEX_TYPE = 'LOB' AND I.OWNER = UPPER('&v_schema'))
) GROUP BY NM;


SELECT
  (SELECT COUNT(*) FROM dba_tab_partitions
   WHERE table_owner = '&v_schema' AND table_name = '&v_table') AS PARTITION_COUNT,
  (SELECT COUNT(*) FROM dba_tab_subpartitions
   WHERE table_owner = '&v_schema' AND table_name = '&v_table') AS SUBPARTITION_COUNT,
  (SELECT COUNT(*) FROM dba_lob_partitions
   WHERE table_owner = '&v_schema' AND table_name = '&v_table') AS LOB_PARTITION_COUNT
FROM dual;


ALTER SESSION FORCE PARALLEL QUERY PARALLEL 16;
ALTER SESSION FORCE PARALLEL DDL PARALLEL 16;

-- Logging helper procedure
CREATE OR REPLACE PROCEDURE log_alert(p_msg IN VARCHAR2) AS
BEGIN
  EXECUTE IMMEDIATE 'BEGIN sys.DBMS_SYSTEM.ksdwrt(2, ''' || REPLACE(p_msg, '''', '''''') || '''); END;';
END;
/

-- Main Maintenance Block
DECLARE
  v_part_count    NUMBER := 0;
  v_subpart_count NUMBER := 0;
  v_lob_count     NUMBER := 0;
  v_lobpart_count NUMBER := 0;
  v_qry           VARCHAR2(1000);
  v_batch_size    CONSTANT PLS_INTEGER := 20;

  CURSOR cur_subparts IS
    SELECT table_owner, table_name, subpartition_name
    FROM dba_tab_subpartitions
    WHERE table_owner = '&v_schema'
      AND table_name = '&v_table';

  TYPE subpart_array IS TABLE OF cur_subparts%ROWTYPE INDEX BY PLS_INTEGER;
  subparts subpart_array;


BEGIN
  -- Count object components
  SELECT COUNT(*) INTO v_part_count FROM dba_tab_partitions WHERE table_owner = '&v_schema' AND table_name = '&v_table';
  SELECT COUNT(*) INTO v_subpart_count FROM dba_tab_subpartitions WHERE table_owner = '&v_schema' AND table_name = '&v_table';
  SELECT COUNT(*) INTO v_lob_count FROM dba_lobs WHERE owner = '&v_schema' AND table_name = '&v_table';
  SELECT COUNT(*) INTO v_lobpart_count FROM dba_lob_partitions WHERE table_owner = '&v_schema' AND table_name = '&v_table';

  -- Move full table if not partitioned
  IF v_part_count = 0 THEN
    v_qry := 'ALTER TABLE &v_schema..&v_table MOVE PARALLEL 16';
    log_alert('Full_TABLE: ' || v_qry);
    EXECUTE IMMEDIATE v_qry;
    log_alert('Moving full table: ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF'));
  END IF;

  -- Move partitions if no subpartitions exist
  IF v_part_count > 0 AND v_subpart_count = 0 THEN
    FOR rec IN (
      SELECT 'ALTER TABLE ' || table_owner || '.' || table_name ||
             ' MOVE PARTITION ' || partition_name || ' PARALLEL 16' AS qry
      FROM dba_tab_partitions
      WHERE table_owner = '&v_schema' AND table_name = '&v_table') LOOP
      BEGIN
        v_qry := rec.qry;
        log_alert('PAR_Table: ' || v_qry);
        EXECUTE IMMEDIATE v_qry;
        log_alert('Moving partition: ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF'));
      EXCEPTION
        WHEN OTHERS THEN
          log_alert('Skipping composite partition move - ' || SQLERRM);
      END;
    END LOOP;
  END IF;

  -- Move subpartitions in batches and rebuild related indexes
  IF v_subpart_count > 0 THEN
  OPEN cur_subparts;
  LOOP
    FETCH cur_subparts BULK COLLECT INTO subparts LIMIT v_batch_size;
    EXIT WHEN subparts.COUNT = 0;

    -- Step 1: Move subpartitions in this batch
    FOR i IN 1 .. subparts.COUNT LOOP
      v_qry := 'ALTER TABLE ' || subparts(i).table_owner || '.' || subparts(i).table_name ||
               ' MOVE SUBPARTITION ' || subparts(i).subpartition_name;
      log_alert('SP_Table: ' || v_qry);
      EXECUTE IMMEDIATE v_qry;
      log_alert('Moved subpartition: ' || subparts(i).subpartition_name || ' at ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF'));
    END LOOP;

    -- Step 2: Rebuild *all* current unusable index subpartitions
    FOR idx IN (
      SELECT 'ALTER INDEX ' || index_owner || '.' || index_name ||
             ' REBUILD SUBPARTITION ' || subpartition_name || ' PARALLEL 16' AS qry
      FROM dba_ind_subpartitions
      WHERE status = 'UNUSABLE'
        AND index_owner = '&v_schema'
        AND index_name IN (
          SELECT index_name FROM dba_indexes
          WHERE table_owner = '&v_schema' 
          AND table_name = '&v_table'
        )
    ) LOOP
      log_alert('SP_INDX: ' || idx.qry);
      EXECUTE IMMEDIATE idx.qry;
      log_alert('Rebuilt subpartition index at: ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF'));
    END LOOP;

  END LOOP;
  CLOSE cur_subparts;
END IF;


  -- Move non-partitioned LOB segments
  IF v_lob_count > 0 THEN
    FOR rec IN (
      SELECT owner, table_name, column_name, tablespace_name
      FROM dba_lobs
      WHERE owner = '&v_schema' AND table_name = '&v_table' AND partitioned = 'NO') LOOP
      v_qry := 'ALTER TABLE ' || rec.owner || '.' || rec.table_name ||
               ' MOVE LOB (' || rec.column_name || ') STORE AS (TABLESPACE ' || rec.tablespace_name || ')';
      log_alert('LOB_Segment: ' || v_qry);
      EXECUTE IMMEDIATE v_qry;
      log_alert('Moving LOB segment: ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF'));
    END LOOP;
  END IF;

  -- Move LOB partitions
  IF v_lobpart_count > 0 THEN
    FOR rec IN (
      SELECT p.table_owner, p.table_name, p.partition_name,
             lob.column_name, lob.tablespace_name
      FROM dba_lob_partitions lob
      JOIN dba_tab_partitions p
        ON lob.table_owner = p.table_owner
       AND lob.table_name = p.table_name
       AND lob.partition_name = p.partition_name
      WHERE lob.table_owner = '&v_schema'
        AND lob.table_name = '&v_table'
        AND lob.tablespace_name IS NOT NULL) LOOP
      v_qry := 'ALTER TABLE ' || rec.table_owner || '.' || rec.table_name ||
               ' MOVE PARTITION ' || rec.partition_name ||
               ' LOB (' || rec.column_name || ') STORE AS (TABLESPACE ' || rec.tablespace_name || ')';
      log_alert('LOB_Par: ' || v_qry);
      EXECUTE IMMEDIATE v_qry;
      log_alert('Moving LOB partition: ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF'));
    END LOOP;
  END IF;

  -- Rebuild unusable index partitions
  FOR rec IN (
    SELECT 'ALTER INDEX ' || index_owner || '.' || index_name ||
           ' REBUILD PARTITION ' || partition_name || ' PARALLEL 16' AS qry
    FROM dba_ind_partitions
    WHERE status = 'UNUSABLE' AND index_owner = '&v_schema'
      AND index_name IN (
        SELECT index_name FROM dba_indexes
        WHERE table_owner = '&v_schema' AND table_name = '&v_table')) LOOP
    log_alert('PAR_INDX: ' || rec.qry);
    EXECUTE IMMEDIATE rec.qry;
    log_alert('Rebuilding index partition: ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF'));
  END LOOP;

  -- Rebuild unusable non-partitioned regular indexes
  FOR rec IN (
    SELECT 'ALTER INDEX ' || owner || '.' || index_name || ' REBUILD PARALLEL 16' AS qry
    FROM dba_indexes
    WHERE owner = '&v_schema' AND table_name = '&v_table'
      AND partitioned = 'NO' AND status <> 'VALID' AND index_type <> 'LOB') LOOP
    log_alert('GLB_INDX: ' || rec.qry);
    EXECUTE IMMEDIATE rec.qry;
    log_alert('Rebuilding non-partitioned index: ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF'));
  END LOOP;

  -- Rebuild unusable LOB index partitions
  FOR rec IN (
    SELECT 'ALTER INDEX ' || index_owner || '.' || index_name ||
           ' REBUILD PARTITION ' || partition_name AS qry
    FROM dba_ind_partitions
    WHERE status = 'UNUSABLE'
      AND index_owner = '&v_schema'
      AND index_name IN (
        SELECT index_name FROM dba_indexes
        WHERE table_owner = '&v_schema' AND table_name = '&v_table' AND index_type = 'LOB')) LOOP
    log_alert('P_LOB_INDX: ' || rec.qry);
    EXECUTE IMMEDIATE rec.qry;
    log_alert('Rebuilding LOB index partition: ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF'));
  END LOOP;

  -- Rebuild unusable non-partitioned LOB indexes
  FOR rec IN (
    SELECT 'ALTER INDEX ' || owner || '.' || index_name || ' REBUILD ' AS qry
    FROM dba_indexes
    WHERE table_owner = '&v_schema' AND table_name = '&v_table'
      AND index_type = 'LOB' AND status = 'UNUSABLE' AND partitioned = 'NO') LOOP
    log_alert('LOB_INDX: ' || rec.qry);
    EXECUTE IMMEDIATE rec.qry;
    log_alert('Rebuilding non-partitioned LOB index: ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF'));
  END LOOP;
EXCEPTION
  WHEN OTHERS THEN
    log_alert('Error - ' || SQLERRM);
END;
/

-- Drop helper after use
DROP PROCEDURE log_alert;


select a.index_name, b.partition_name, a.status, b.status partition_index_status
from dba_indexes A, dba_ind_partitions B
where a.owner='&v_schema' and a.table_name='&v_table'
and a.owner=b.index_owner and a.index_name = b.index_name and a.index_type <> 'LOB' order by a.index_name, b.partition_name;


SELECT a.index_name, b.subpartition_name, a.status, b.status partition_index_status
FROM dba_indexes a, dba_ind_subpartitions b
WHERE a.owner = '&v_schema'
  AND a.table_name = '&v_table'
  AND a.owner = b.index_owner
  AND a.index_name = b.index_name
  AND a.index_type <> 'LOB'
ORDER BY a.index_name, b.subpartition_name;


select index_name,owner,status from dba_indexes where owner='&v_schema' and table_name='&v_table' and partitioned = 'NO';
 
select b.status,count(*) from  dba_indexes A, dba_ind_partitions B
where a.owner='&v_schema' and a.table_name='&v_table' and b.index_owner = '&v_schema' and a.index_name = b.index_name 
and partition_name not like 'SYS%'
group by b.status;
 

SELECT INDEX_NAME, STATUS, PARTITIONED
FROM DBA_INDEXES
WHERE TABLE_OWNER = '&v_schema'
  AND TABLE_NAME = '&v_table'
  AND INDEX_TYPE = 'LOB';

-- Step 3: LOB index partition status
SELECT INDEX_NAME, PARTITION_NAME, STATUS
FROM DBA_IND_PARTITIONS
WHERE INDEX_OWNER = '&v_schema'
  AND INDEX_NAME IN (
    SELECT INDEX_NAME
    FROM DBA_INDEXES
    WHERE TABLE_OWNER = '&v_schema'
      AND TABLE_NAME = '&v_table'
      AND INDEX_TYPE = 'LOB'
  );
 
SELECT
(SELECT NVL(SUM(S.bytes/1024/1024/1024),0)
FROM DBA_SEGMENTS S
WHERE S.OWNER = UPPER('&v_schema') AND
(S.SEGMENT_NAME = UPPER('&v_table'))) +
(SELECT NVL(SUM(S.bytes/1024/1024/1024),0)
FROM DBA_SEGMENTS S, DBA_LOBS L
WHERE S.OWNER = UPPER('&v_schema') AND
(L.SEGMENT_NAME = S.SEGMENT_NAME AND L.TABLE_NAME = UPPER('&v_table')
AND L.OWNER = UPPER('&v_schema'))) +
(SELECT NVL(SUM(S.bytes/1024/1024/1024),0)
FROM DBA_SEGMENTS S, DBA_INDEXES I
WHERE S.OWNER = UPPER('&v_schema') AND
(I.INDEX_NAME = S.SEGMENT_NAME AND I.TABLE_NAME = UPPER('&v_table') AND
INDEX_TYPE = 'LOB' AND I.OWNER = UPPER('&v_schema')))
"TOTAL TABLE SIZE"
FROM DUAL;
 
SELECT NM, SUM(DSIZE) FROM (
SELECT PARTITION_NAME AS NM,  NVL(SUM(S.BYTES/1024/1024/1024),0)  AS DSIZE
FROM DBA_SEGMENTS S
WHERE S.OWNER = UPPER('&v_schema') AND S.SEGMENT_TYPE = 'TABLE PARTITION' AND (S.SEGMENT_NAME = UPPER('&v_table'))
GROUP BY PARTITION_NAME
UNION ALL
SELECT L.PARTITION_NAME AS NM,  NVL(SUM(S.BYTES/1024/1024/1024),0) AS DSIZE
FROM DBA_SEGMENTS S, DBA_LOB_PARTITIONS L
WHERE S.PARTITION_NAME = L.LOB_PARTITION_NAME
    AND S.OWNER = '&v_schema'
    AND L.TABLE_OWNER = S.OWNER
    AND L.TABLE_NAME = '&v_table'
GROUP BY L.PARTITION_NAME
UNION ALL
SELECT 'INDEX_LOB' AS NM, NVL(SUM(S.BYTES/1024/1024/1024),0) AS DSIZE
FROM DBA_SEGMENTS S, DBA_INDEXES I
WHERE S.OWNER = UPPER('&v_schema') AND
(I.INDEX_NAME = S.SEGMENT_NAME AND I.TABLE_NAME = UPPER('&v_table') AND INDEX_TYPE = 'LOB' AND I.OWNER = UPPER('&v_schema'))
) GROUP BY NM;

SELECT
  (SELECT COUNT(*) FROM dba_tab_partitions
   WHERE table_owner = '&v_schema' AND table_name = '&v_table') AS PARTITION_COUNT,
  (SELECT COUNT(*) FROM dba_tab_subpartitions
   WHERE table_owner = '&v_schema' AND table_name = '&v_table') AS SUBPARTITION_COUNT,
  (SELECT COUNT(*) FROM dba_lob_partitions
   WHERE table_owner = '&v_schema' AND table_name = '&v_table') AS LOB_PARTITION_COUNT
FROM dual;

SET TIMING off;
SPOOL OFF;
EXIT;
