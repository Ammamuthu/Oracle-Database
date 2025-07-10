SET PAGESIZE 5000;
SET MARKUP HTML ON ENTMAP OFF SPOOL ON PREFORMAT OFF;
SET VERIFY OFF;

DEFINE v_schema = 'IMS_MM';
DEFINE v_table  = 'NACHA_BATCH_REP_DTLS';

SPOOL &&v_schema._&&v_table..html

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



ALTER SESSION FORCE PARALLEL QUERY parallel 16;
ALTER SESSION FORCE PARALLEL DDL parallel 16;

-- =============================================
-- Core Maintenance Block
-- =============================================
DECLARE
  v_part_count    NUMBER := 0;
  v_subpart_count NUMBER := 0;
  v_lob_count     NUMBER := 0;
  v_lobpart_count NUMBER := 0;
  v_qry           VARCHAR2(1000);
BEGIN
  -- Detect table type
  SELECT COUNT(*) INTO v_part_count
  FROM dba_tab_partitions
  WHERE table_owner = '&v_schema' AND table_name = '&v_table';

  SELECT COUNT(*) INTO v_subpart_count
  FROM dba_tab_subpartitions
  WHERE table_owner = '&v_schema' AND table_name = '&v_table';

  SELECT COUNT(*) INTO v_lob_count
  FROM dba_lobs
  WHERE owner = '&v_schema' AND table_name = '&v_table';

  SELECT COUNT(*) INTO v_lobpart_count
  FROM dba_lob_partitions
  WHERE table_owner = '&v_schema' AND table_name = '&v_table';

  -- ========================
  -- Move Full Table (if not partitioned)
  -- ========================
  IF v_part_count = 0 THEN
    v_qry := 'ALTER TABLE &v_schema.&v_table MOVE PARALLEL 16';
    DBMS_OUTPUT.PUT_LINE('Full_TABLE: ' || v_qry);
    EXECUTE IMMEDIATE v_qry;
    DBMS_OUTPUT.PUT_LINE('Moving full table: ' || TO_CHAR(SYSTIMESTAMP, 'DD-MM-YYYY HH24:MI:SS'));
  END IF;

  -- ========================
  -- Move Table Partitions
  -- ========================
  IF v_part_count > 0 THEN
    FOR rec IN (
      SELECT 'ALTER TABLE ' || table_owner || '.' || table_name ||
             ' MOVE PARTITION ' || partition_name || ' PARALLEL 16' AS qry
      FROM dba_tab_partitions
      WHERE table_owner = '&v_schema' AND table_name = '&v_table'
    ) LOOP
      v_qry := rec.qry;
      DBMS_OUTPUT.PUT_LINE('PAR_Table: ' || v_qry);
      EXECUTE IMMEDIATE v_qry;
      DBMS_OUTPUT.PUT_LINE('Moving partition: ' || TO_CHAR(SYSTIMESTAMP, 'DD-MM-YYYY HH24:MI:SS'));
    END LOOP;
  END IF;

-- ========================
-- Move Subpartition and Rebuild Related Subpartition Indexes
-- ========================
IF v_subpart_count > 0 THEN
  FOR rec IN (
    SELECT table_owner,
           table_name,
           subpartition_name
    FROM dba_tab_subpartitions
    WHERE table_owner = '&v_schema'
      AND table_name = '&v_table'
  ) LOOP
    -- Move the subpartition
    v_qry := 'ALTER TABLE ' || rec.table_owner || '.' || rec.table_name ||
             ' MOVE SUBPARTITION ' || rec.subpartition_name ;
    DBMS_OUTPUT.PUT_LINE('SP_TABLE ' || v_qry);
    EXECUTE IMMEDIATE v_qry;
    DBMS_OUTPUT.PUT_LINE('Moving subpartition: ' || TO_CHAR(SYSTIMESTAMP, 'DD-MM-YYYY HH24:MI:SS'));
    -- Rebuild related unusable subpartition indexes
    FOR idx IN (
      SELECT 'ALTER INDEX ' || index_owner || '.' || index_name ||
             ' REBUILD SUBPARTITION ' || subpartition_name || ' PARALLEL 16' AS qry
      FROM dba_ind_subpartitions
      WHERE status = 'UNUSABLE'
        AND index_owner = '&v_schema'
        AND subpartition_name = rec.subpartition_name
    ) LOOP
      DBMS_OUTPUT.PUT_LINE('SP_INDX: ' || idx.qry);
      EXECUTE IMMEDIATE idx.qry;
      DBMS_OUTPUT.PUT_LINE('Rebuilding subpartition index: ' || TO_CHAR(SYSTIMESTAMP, 'DD-MM-YYYY HH24:MI:SS'));
    END LOOP;
  END LOOP;
END IF;

  -- ========================
  -- Move LOB Segments
  -- ========================
  IF v_lob_count > 0 THEN
    FOR rec IN (
      SELECT owner, table_name, column_name, tablespace_name
      FROM dba_lobs
      WHERE owner = '&v_schema' AND table_name = '&v_table'
    ) LOOP
      v_qry := 'ALTER TABLE ' || rec.owner || '.' || rec.table_name ||
               ' MOVE LOB (' || rec.column_name || ') STORE AS (TABLESPACE ' || rec.tablespace_name || ')';
      DBMS_OUTPUT.PUT_LINE('LOB_Segment ' || v_qry);
      EXECUTE IMMEDIATE v_qry;
      DBMS_OUTPUT.PUT_LINE('Moving LOB segment: ' || TO_CHAR(SYSTIMESTAMP, 'DD-MM-YYYY HH24:MI:SS'));
    END LOOP;
  END IF;

  -- ========================
  -- Move LOB Partitions
  -- ========================
  IF v_lobpart_count > 0 THEN
    FOR rec IN (
      SELECT p.table_owner,
             p.table_name,
             p.partition_name,
             lob.column_name,
             lob.tablespace_name
      FROM dba_lob_partitions lob
      JOIN dba_tab_partitions p
        ON lob.table_owner = p.table_owner
       AND lob.table_name  = p.table_name
       AND lob.partition_name = p.partition_name
      WHERE lob.table_owner = '&v_schema'
        AND lob.table_name  = '&v_table'
    ) LOOP
      v_qry := 'ALTER TABLE ' || rec.table_owner || '.' || rec.table_name ||
               ' MOVE PARTITION ' || rec.partition_name ||
               ' LOB (' || rec.column_name || ') STORE AS (TABLESPACE ' || rec.tablespace_name || ')';
      DBMS_OUTPUT.PUT_LINE('LOB_Par: ' || v_qry);
      EXECUTE IMMEDIATE v_qry;
      DBMS_OUTPUT.PUT_LINE('Moving LOB partition: ' || TO_CHAR(SYSTIMESTAMP, 'DD-MM-YYYY HH24:MI:SS'));
    END LOOP;
  END IF;

  -- ========================
  -- Rebuild UNUSABLE Index Partitions
  -- ========================
  FOR rec IN (
    SELECT 'ALTER INDEX ' || index_owner || '.' || index_name ||
           ' REBUILD PARTITION ' || partition_name || ' PARALLEL 16' AS qry
    FROM dba_ind_partitions
    WHERE status = 'UNUSABLE' AND index_owner = '&v_schema'
      AND index_name IN (
        SELECT index_name FROM dba_indexes
        WHERE table_owner = '&v_schema' AND table_name = '&v_table'
      )
  ) LOOP
    v_qry := rec.qry;
    DBMS_OUTPUT.PUT_LINE('PAR_INDX: ' || v_qry);
    EXECUTE IMMEDIATE v_qry;
    DBMS_OUTPUT.PUT_LINE('Rebuilding index partition: ' || TO_CHAR(SYSTIMESTAMP, 'DD-MM-YYYY HH24:MI:SS'));
  END LOOP;

-- ========================
  -- Rebuild UNUSABLE Non-partitioned Regular Indexes
  -- ========================
  FOR rec IN (
    SELECT 'ALTER INDEX ' || owner || '.' || index_name || ' REBUILD PARALLEL 16' AS qry
    FROM dba_indexes
    WHERE owner = '&v_schema' AND table_name = '&v_table'
      AND partitioned = 'NO' AND status <> 'VALID' AND index_type <> 'LOB'
  ) LOOP
    v_qry := rec.qry;
    DBMS_OUTPUT.PUT_LINE('GLB_INDX: ' || v_qry);
    EXECUTE IMMEDIATE v_qry;
    DBMS_OUTPUT.PUT_LINE('Rebuilding non-partitioned index: ' || TO_CHAR(SYSTIMESTAMP, 'DD-MM-YYYY HH24:MI:SS'));
  END LOOP;

  -- ========================
  -- Rebuild UNUSABLE LOB Index Partitions
  -- ========================
  FOR rec IN (
    SELECT 'ALTER INDEX ' || index_owner || '.' || index_name ||
           ' REBUILD PARTITION ' || partition_name AS qry
    FROM dba_ind_partitions
    WHERE status = 'UNUSABLE'
      AND index_owner = '&v_schema'
      AND index_name IN (
        SELECT index_name
        FROM dba_indexes
        WHERE table_owner = '&v_schema'
          AND table_name = '&v_table'
          AND index_type = 'LOB'
      )
  ) LOOP
    DBMS_OUTPUT.PUT_LINE('P_LOB_INDX: ' || rec.qry);
    EXECUTE IMMEDIATE rec.qry;
    DBMS_OUTPUT.PUT_LINE('Rebuilding LOB index partition: ' || TO_CHAR(SYSTIMESTAMP, 'DD-MM-YYYY HH24:MI:SS'));
  END LOOP;

  -- ========================
  -- Rebuild UNUSABLE Non-partitioned LOB Indexes
  -- ========================
  FOR rec IN (
    SELECT 'ALTER INDEX ' || owner || '.' || index_name || ' REBUILD ' AS qry
    FROM dba_indexes
    WHERE table_owner = '&v_schema'
      AND table_name = '&v_table'
      AND index_type = 'LOB'
      AND status = 'UNUSABLE'
      AND partitioned = 'NO'
  ) LOOP
    DBMS_OUTPUT.PUT_LINE('LOB_INDX: ' || rec.qry);
    EXECUTE IMMEDIATE rec.qry;
    DBMS_OUTPUT.PUT_LINE('Rebuilding LOB index: ' || TO_CHAR(SYSTIMESTAMP, 'DD-MM-YYYY HH24:MI:SS'));
  END LOOP;

EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Error - ' || SQLERRM);
END;
/


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


SET TIMING OFF;
SPOOL OFF;