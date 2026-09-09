CREATE OR REPLACE PROCEDURE IMS_MM.rebuild_indexes (
  p_owner        IN VARCHAR2,
  p_table        IN VARCHAR2,
  p_parallel     IN NUMBER DEFAULT 16,
  p_parallel_lob IN NUMBER DEFAULT NULL
) IS
  v_owner      VARCHAR2(128) := UPPER(p_owner);
  v_table      VARCHAR2(128) := UPPER(p_table);
  v_par        VARCHAR2(30)  := CASE WHEN p_parallel IS NOT NULL THEN ' PARALLEL ' || p_parallel ELSE '' END;
  v_par_lob    VARCHAR2(30)  := CASE WHEN p_parallel_lob IS NOT NULL THEN ' PARALLEL ' || p_parallel_lob ELSE '' END;
  v_cnt        NUMBER;
  v_start      TIMESTAMP;

  
  PROCEDURE run_and_log(p_index VARCHAR2, p_kind VARCHAR2, p_part VARCHAR2, p_subpart VARCHAR2, p_sql VARCHAR2) IS
    v_err VARCHAR2(4000);   -- SQLERRM can't be used directly inside a SQL statement, capture it first
  BEGIN
    SELECT COUNT(*) INTO v_cnt
    FROM IMS_MM.index_rebuild_status
    WHERE owner = v_owner AND index_name = p_index
      AND NVL(partition_name,'~') = NVL(p_part,'~')
      AND NVL(subpartition_name,'~') = NVL(p_subpart,'~')
      AND status = 'SUCCESS';

    IF v_cnt > 0 THEN
      DBMS_OUTPUT.PUT_LINE('SKIP: ' || p_index || ' ' || NVL(p_part, NVL(p_subpart,'')));
      RETURN;
    END IF;

    v_start := SYSTIMESTAMP;
    BEGIN
      DBMS_OUTPUT.PUT_LINE('RUN : ' || p_sql);
      EXECUTE IMMEDIATE p_sql;
      MERGE INTO IMS_MM.index_rebuild_status t
      USING (SELECT v_owner o, v_table tn, p_index idx, p_kind k, p_part pt, p_subpart sp FROM dual) s
      ON (t.owner=s.o AND t.index_name=s.idx AND NVL(t.partition_name,'~')=NVL(s.pt,'~') AND NVL(t.subpartition_name,'~')=NVL(s.sp,'~'))
      WHEN MATCHED THEN UPDATE SET status='SUCCESS', start_time=v_start, end_time=SYSTIMESTAMP, error_message=NULL
      WHEN NOT MATCHED THEN INSERT (owner, table_name, index_name, index_kind, partition_name, subpartition_name, status, start_time, end_time)
        VALUES (s.o, s.tn, s.idx, s.k, s.pt, s.sp, 'SUCCESS', v_start, SYSTIMESTAMP);
      DBMS_OUTPUT.PUT_LINE('OK  : ' || p_index);
    EXCEPTION
      WHEN OTHERS THEN
        v_err := SQLERRM;
        MERGE INTO IMS_MM.index_rebuild_status t
        USING (SELECT v_owner o, v_table tn, p_index idx, p_kind k, p_part pt, p_subpart sp FROM dual) s
        ON (t.owner=s.o AND t.index_name=s.idx AND NVL(t.partition_name,'~')=NVL(s.pt,'~') AND NVL(t.subpartition_name,'~')=NVL(s.sp,'~'))
        WHEN MATCHED THEN UPDATE SET status='FAILED', start_time=v_start, end_time=SYSTIMESTAMP, error_message=v_err
        WHEN NOT MATCHED THEN INSERT (owner, table_name, index_name, index_kind, partition_name, subpartition_name, status, start_time, end_time, error_message)
          VALUES (s.o, s.tn, s.idx, s.k, s.pt, s.sp, 'FAILED', v_start, SYSTIMESTAMP, v_err);
        DBMS_OUTPUT.PUT_LINE('FAIL: ' || p_index || ' - ' || v_err);
        -- not re-raised, so the loop keeps going
    END;
    COMMIT;
  END run_and_log;

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== Rebuilding indexes for ' || v_owner || '.' || v_table || ' ===');

  -- non-partitioned regular indexes
  FOR r IN (SELECT index_name FROM dba_indexes
            WHERE table_name = v_table
              AND partitioned = 'NO' AND index_type <> 'LOB' AND status = 'UNUSABLE')
  LOOP
    run_and_log(r.index_name, 'NORMAL', NULL, NULL,
      'ALTER INDEX ' || v_owner || '.' || r.index_name || ' REBUILD' || v_par);
  END LOOP;

  -- non-partitioned LOB indexes
  FOR r IN (SELECT index_name FROM dba_indexes
            WHERE table_name = v_table
              AND index_type = 'LOB' AND partitioned = 'NO' AND status = 'UNUSABLE')
  LOOP
    run_and_log(r.index_name, 'LOB', NULL, NULL,
      'ALTER INDEX ' || v_owner || '.' || r.index_name || ' REBUILD' || v_par_lob);
  END LOOP;

  -- regular index partitions
  FOR r IN (SELECT b.index_name, b.partition_name FROM dba_indexes a, dba_ind_partitions b
            WHERE a.table_name = v_table
              AND a.index_name = b.index_name
              AND a.index_type <> 'LOB' AND b.status = 'UNUSABLE')
  LOOP
    run_and_log(r.index_name, 'NORMAL', r.partition_name, NULL,
      'ALTER INDEX ' || v_owner || '.' || r.index_name || ' REBUILD PARTITION ' || r.partition_name || v_par);
  END LOOP;

  -- regular index subpartitions
  FOR r IN (SELECT b.index_name, b.subpartition_name FROM dba_indexes a, dba_ind_subpartitions b
            WHERE a.table_name = v_table
              AND a.index_name = b.index_name
              AND a.index_type <> 'LOB' AND b.status = 'UNUSABLE')
  LOOP
    run_and_log(r.index_name, 'NORMAL', NULL, r.subpartition_name,
      'ALTER INDEX ' || v_owner || '.' || r.index_name || ' REBUILD SUBPARTITION ' || r.subpartition_name || v_par);
  END LOOP;

  -- LOB index partitions
  FOR r IN (SELECT b.index_name, b.partition_name FROM dba_indexes a, dba_ind_partitions b
            WHERE a.table_name = v_table
              AND a.index_name = b.index_name
              AND a.index_type = 'LOB' AND b.status = 'UNUSABLE')
  LOOP
    run_and_log(r.index_name, 'LOB', r.partition_name, NULL,
      'ALTER INDEX ' || v_owner || '.' || r.index_name || ' REBUILD PARTITION ' || r.partition_name || v_par_lob);
  END LOOP;

  -- LOB index subpartitions
  FOR r IN (SELECT b.index_name, b.subpartition_name FROM dba_indexes a, dba_ind_subpartitions b
            WHERE a.table_name = v_table
              AND a.index_name = b.index_name
              AND a.index_type = 'LOB' AND b.status = 'UNUSABLE')
  LOOP
    run_and_log(r.index_name, 'LOB', NULL, r.subpartition_name,
      'ALTER INDEX ' || v_owner || '.' || r.index_name || ' REBUILD SUBPARTITION ' || r.subpartition_name || v_par_lob);
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('=== Done. See IMS_MM.index_rebuild_status ===');
END rebuild_indexes;
/

