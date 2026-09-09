-- ==================================================================================
-- 1. Give Grant access of DBA tables to IMS_MM
-- ==================================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED;

GRANT SELECT ON DBA_INDEXES FROM IMS_MM;
GRANT SELECT ON DBA_IND_PARTITIONS FROM IMS_MM;
GRANT SELECT ON DBA_IND_SUBPARTITIONS FROM IMS_MM;



-- ==================================================================================
-- 3. USAGE
-- ==================================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED;
EXEC IMS_MM.rebuild_indexes(p_owner => 'IMS_MM', p_table => 'MYMT_OUT_REPOSITORY');




-- ==================================================================================
-- 3. Revoke the Grant access of DBA tables from IMS_MM
-- ==================================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED;

REVOKE SELECT ON DBA_INDEXES FROM IMS_MM;
REVOKE SELECT ON DBA_IND_PARTITIONS FROM IMS_MM;
REVOKE SELECT ON DBA_IND_SUBPARTITIONS FROM IMS_MM;


-- ==================================================================================
-- 4. EXPORT STATUS AS HTML (run manually, before and after; rename spool file yourself)
-- ==================================================================================
SET PAGESIZE 50000
SET LINESIZE 200
SET MARKUP HTML ON SPOOL ON ENTMAP ON
SPOOL index_status.html

SELECT
    COUNT(*) AS total_objects,
    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) AS completed,
    SUM(CASE WHEN status = 'FAILED'  THEN 1 ELSE 0 END) AS failed,
    SUM(CASE WHEN status = 'PENDING' THEN 1 ELSE 0 END) AS pending,
    ROUND(
        100 * SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*),0), 2
    ) AS percent_complete
FROM IMS_MM.index_rebuild_status
WHERE owner = 'IMS_MM'
  AND table_name = 'MYMT_OUT_REPOSITORY';

--Progess By index Type

  SELECT index_kind,
       status,
       COUNT(*) AS count
FROM IMS_MM.index_rebuild_status
WHERE owner = 'IMS_MM'
  AND table_name = 'MYMT_OUT_REPOSITORY'
GROUP BY index_kind, status
ORDER BY index_kind, status;

--failed Rebuilds

SELECT index_name,
       partition_name,
       subpartition_name,
       error_message,
       start_time,
       end_time
FROM IMS_MM.index_rebuild_status
WHERE owner = 'IMS_MM'
  AND table_name = 'MYMT_OUT_REPOSITORY'
  AND status = 'FAILED'
ORDER BY end_time;



SPOOL OFF
SET MARKUP HTML OFF