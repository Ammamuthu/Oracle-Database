-- =============================================================================
-- FILE : 02_reorg_procedure.sql
-- Compile once. Run via 03_run.sql each downtime.
-- Author : Ammamuthu.M
-- =============================================================================
SET DEFINE OFF

CREATE OR REPLACE PROCEDURE SYS.REORG_TABLE (
    p_schema  IN VARCHAR2,
    p_table   IN VARCHAR2
)
AS
    v_schema      VARCHAR2(30)   := UPPER(TRIM(p_schema));
    v_table       VARCHAR2(128)  := UPPER(TRIM(p_table));
    v_seq         NUMBER         := 0;
    v_step_start  TIMESTAMP;
    v_elapsed     NUMBER;
    v_part_count  NUMBER;
    v_sub_count   NUMBER;
    v_lob_count   NUMBER;
    v_lobp_count  NUMBER;
    v_err         VARCHAR2(4000);

    -- Batch size matches original script LIMIT 20
    v_batch_size  CONSTANT PLS_INTEGER := 20;
    v_batch_count NUMBER := 0;

    -- Holds the subpartition names moved in the current batch of 20
    -- Used to rebuild ONLY the index subpartitions for those exact names
    TYPE t_name_list IS TABLE OF VARCHAR2(128) INDEX BY PLS_INTEGER;
    v_batch_names t_name_list;

    -- =========================================================================
    -- log_alert
    -- =========================================================================
    PROCEDURE log_alert (p_msg IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'BEGIN sys.DBMS_SYSTEM.ksdwrt(2,:m); END;'
        USING SUBSTRB('[REORG]['||v_schema||'.'||v_table||'] '||p_msg, 1, 2000);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- =========================================================================
    -- add_step
    -- =========================================================================
    PROCEDURE add_step (
        p_seq  IN NUMBER,   p_type IN VARCHAR2,
        p_tgt1 IN VARCHAR2, p_tgt2 IN VARCHAR2,
        p_tbs  IN VARCHAR2, p_ddl  IN VARCHAR2
    ) IS
    BEGIN
        INSERT INTO SYS.REORG_TRACKER
            (schema_name, table_name, step_seq, step_type,
             step_target, step_target2, tablespace_name, ddl_statement, status)
        SELECT v_schema, v_table, p_seq, p_type,
               p_tgt1, p_tgt2, p_tbs, p_ddl, 'PENDING'
        FROM DUAL
        WHERE NOT EXISTS (
            SELECT 1 FROM SYS.REORG_TRACKER
            WHERE schema_name = v_schema
              AND table_name  = v_table
              AND step_seq    = p_seq
        );
    END;

    -- =========================================================================
    -- rebuild_batch_subpart_indexes
    --
    -- Rebuilds UNUSABLE index subpartitions ONLY for the subpartition names
    -- in the current batch (v_batch_names).
    --
    -- Original script Step 2:
    --   After moving 20 subpartitions, rebuild all UNUSABLE index subpartitions
    --   that correspond to those exact table subpartition names.
    --
    -- Why filter by name?
    --   When you MOVE SUBPARTITION X, the index subpartition named X becomes
    --   UNUSABLE. So we rebuild only those matching names - not the entire table.
    -- =========================================================================
    PROCEDURE rebuild_batch_subpart_indexes IS
        v_qry  VARCHAR2(4000);
    BEGIN
        IF v_batch_names.COUNT = 0 THEN RETURN; END IF;

        -- Loop through each subpartition name in this batch
        -- For each name, find its UNUSABLE index subpartitions and rebuild them
        -- Mirrors original script cursor loop - no CAST or collection types needed
        FOR i IN 1 .. v_batch_names.COUNT LOOP
            FOR ix IN (
                SELECT isp.index_owner,
                       isp.index_name,
                       isp.subpartition_name
                FROM dba_ind_subpartitions isp
                WHERE isp.status           = 'UNUSABLE'
                  AND isp.subpartition_name = v_batch_names(i)
                  AND isp.index_owner IN (
                      SELECT owner FROM dba_indexes
                      WHERE table_owner = v_schema
                        AND table_name  = v_table
                        AND index_type <> 'LOB'
                  )
            ) LOOP
                BEGIN
                    v_qry := 'ALTER INDEX '||ix.index_owner||'.'||ix.index_name||
                             ' REBUILD SUBPARTITION '||ix.subpartition_name||' PARALLEL 16';
                    EXECUTE IMMEDIATE v_qry;
                    log_alert('SP_INDX: '||ix.index_name||'/'||ix.subpartition_name);
                EXCEPTION WHEN OTHERS THEN
                    log_alert('SP_INDX WARN: '||ix.index_name||'/'||ix.subpartition_name||' '||SQLERRM);
                END;
            END LOOP;
        END LOOP;

        -- Clear batch for next set of 20
        v_batch_names.DELETE;
        v_batch_count := 0;
    END;

BEGIN
    -- =========================================================================
    -- PHASE 0 : SESSION SETTINGS
    -- =========================================================================
    EXECUTE IMMEDIATE 'ALTER SESSION FORCE PARALLEL QUERY PARALLEL 16';
    EXECUTE IMMEDIATE 'ALTER SESSION FORCE PARALLEL DDL   PARALLEL 16';

    log_alert('START');

    -- =========================================================================
    -- PHASE 1 : SEED
    -- Register every DDL step in execution order.
    -- On resume, existing rows skipped. DONE rows never overwritten.
    -- =========================================================================
    SELECT COUNT(*) INTO v_part_count  FROM dba_tab_partitions   WHERE table_owner=v_schema AND table_name=v_table;
    SELECT COUNT(*) INTO v_sub_count   FROM dba_tab_subpartitions WHERE table_owner=v_schema AND table_name=v_table;
    SELECT COUNT(*) INTO v_lob_count   FROM dba_lobs              WHERE owner=v_schema AND table_name=v_table AND partitioned='NO';
    SELECT COUNT(*) INTO v_lobp_count  FROM dba_lob_partitions    WHERE table_owner=v_schema AND table_name=v_table;

    log_alert('Structure: parts='||v_part_count||' subparts='||v_sub_count
              ||' lobs='||v_lob_count||' lob_parts='||v_lobp_count);

    v_seq := 1;

    -- 1A. Non-partitioned full table
    IF v_part_count = 0 THEN
        add_step(v_seq, 'MOVE_TABLE', NULL, NULL, NULL,
            'ALTER TABLE '||v_schema||'.'||v_table||' MOVE PARALLEL 16');
        v_seq := v_seq + 1;
    END IF;

    -- 1B. Partitions (no subpartitions)
    IF v_part_count > 0 AND v_sub_count = 0 THEN
        FOR r IN (
            SELECT partition_name FROM dba_tab_partitions
            WHERE table_owner=v_schema AND table_name=v_table
            ORDER BY partition_position
        ) LOOP
            add_step(v_seq, 'MOVE_PARTITION', r.partition_name, NULL, NULL,
                'ALTER TABLE '||v_schema||'.'||v_table||
                ' MOVE PARTITION '||r.partition_name||' PARALLEL 16');
            v_seq := v_seq + 1;
        END LOOP;
    END IF;

    -- 1C. Subpartitions (composite partitioned)
    IF v_sub_count > 0 THEN
        FOR r IN (
            SELECT subpartition_name, partition_name, subpartition_position
            FROM dba_tab_subpartitions
            WHERE table_owner=v_schema AND table_name=v_table
            ORDER BY partition_name, subpartition_position
        ) LOOP
            add_step(v_seq, 'MOVE_SUBPART', r.subpartition_name, r.partition_name, NULL,
                'ALTER TABLE '||v_schema||'.'||v_table||
                ' MOVE SUBPARTITION '||r.subpartition_name);
            v_seq := v_seq + 1;
        END LOOP;
    END IF;

    -- 2A. Non-partitioned LOBs
    IF v_lob_count > 0 THEN
        FOR r IN (
            SELECT column_name, tablespace_name FROM dba_lobs
            WHERE owner=v_schema AND table_name=v_table AND partitioned='NO'
            ORDER BY column_name
        ) LOOP
            add_step(v_seq, 'MOVE_LOB', NULL, r.column_name, r.tablespace_name,
                'ALTER TABLE '||v_schema||'.'||v_table||
                ' MOVE LOB ('||r.column_name||') STORE AS (TABLESPACE '||r.tablespace_name||')');
            v_seq := v_seq + 1;
        END LOOP;
    END IF;

    -- 2B. LOB partitions
    IF v_lobp_count > 0 THEN
        FOR r IN (
            SELECT p.partition_name, l.column_name, l.tablespace_name
            FROM dba_lob_partitions l
            JOIN dba_tab_partitions p
              ON l.table_owner=p.table_owner AND l.table_name=p.table_name
             AND l.partition_name=p.partition_name
            WHERE l.table_owner=v_schema AND l.table_name=v_table
              AND l.tablespace_name IS NOT NULL
            ORDER BY p.partition_position, l.column_name
        ) LOOP
            add_step(v_seq, 'MOVE_LOB_PART', r.partition_name, r.column_name, r.tablespace_name,
                'ALTER TABLE '||v_schema||'.'||v_table||
                ' MOVE PARTITION '||r.partition_name||
                ' LOB ('||r.column_name||') STORE AS (TABLESPACE '||r.tablespace_name||')');
            v_seq := v_seq + 1;
        END LOOP;
    END IF;

    -- 3. Rebuild index PARTITIONS
    --    Only single-level partitioned indexes (subpartitioning_type='NONE')
    --    Composite partitioned indexes (ORA-14287 fix) are excluded here
    --    and handled below at subpartition level
    FOR r IN (
        SELECT b.index_owner, b.index_name, b.partition_name
        FROM dba_indexes a
        JOIN dba_ind_partitions b  ON a.owner=b.index_owner AND a.index_name=b.index_name
        JOIN dba_part_indexes   pi ON pi.owner=a.owner AND pi.index_name=a.index_name
        WHERE a.owner=v_schema AND a.table_name=v_table
          AND a.index_type<>'LOB'
          AND pi.subpartitioning_type = 'NONE'
        ORDER BY b.index_name, b.partition_position
    ) LOOP
        add_step(v_seq, 'REBUILD_IDX_PART', r.index_name, r.partition_name, NULL,
            'ALTER INDEX '||r.index_owner||'.'||r.index_name||
            ' REBUILD PARTITION '||r.partition_name||' PARALLEL 16');
        v_seq := v_seq + 1;
    END LOOP;

    -- 4. Rebuild non-partitioned regular indexes
    FOR r IN (
        SELECT owner, index_name FROM dba_indexes
        WHERE owner=v_schema AND table_name=v_table
          AND partitioned='NO' AND index_type<>'LOB'
        ORDER BY index_name
    ) LOOP
        add_step(v_seq, 'REBUILD_IDX', r.index_name, NULL, NULL,
            'ALTER INDEX '||r.owner||'.'||r.index_name||' REBUILD PARALLEL 16');
        v_seq := v_seq + 1;
    END LOOP;

    -- 5. Rebuild index SUBPARTITIONS (composite partitioned indexes)
    FOR r IN (
        SELECT b.index_owner, b.index_name, b.subpartition_name
        FROM dba_indexes a
        JOIN dba_ind_subpartitions b ON a.owner=b.index_owner AND a.index_name=b.index_name
        WHERE a.owner=v_schema AND a.table_name=v_table AND a.index_type<>'LOB'
        ORDER BY b.index_name, b.subpartition_name
    ) LOOP
        add_step(v_seq, 'REBUILD_IDX_SP', r.index_name, r.subpartition_name, NULL,
            'ALTER INDEX '||r.index_owner||'.'||r.index_name||
            ' REBUILD SUBPARTITION '||r.subpartition_name||' PARALLEL 16');
        v_seq := v_seq + 1;
    END LOOP;

    -- 6. Rebuild LOB index PARTITIONS (non-composite only)
    FOR r IN (
        SELECT b.index_owner, b.index_name, b.partition_name
        FROM dba_indexes a
        JOIN dba_ind_partitions b  ON a.owner=b.index_owner AND a.index_name=b.index_name
        JOIN dba_part_indexes   pi ON pi.owner=a.owner AND pi.index_name=a.index_name
        WHERE a.table_owner=v_schema AND a.table_name=v_table
          AND a.index_type='LOB'
          AND pi.subpartitioning_type = 'NONE'
        ORDER BY b.index_name, b.partition_position
    ) LOOP
        add_step(v_seq, 'REBUILD_LOB_PART', r.index_name, r.partition_name, NULL,
            'ALTER INDEX '||r.index_owner||'.'||r.index_name||
            ' REBUILD PARTITION '||r.partition_name);
        v_seq := v_seq + 1;
    END LOOP;

    -- 7. Rebuild non-partitioned LOB indexes
    FOR r IN (
        SELECT owner, index_name FROM dba_indexes
        WHERE table_owner=v_schema AND table_name=v_table
          AND index_type='LOB' AND partitioned='NO'
        ORDER BY index_name
    ) LOOP
        add_step(v_seq, 'REBUILD_LOB_IDX', r.index_name, NULL, NULL,
            'ALTER INDEX '||r.owner||'.'||r.index_name||' REBUILD');
        v_seq := v_seq + 1;
    END LOOP;

    COMMIT;
    log_alert('SEED DONE - '||v_seq||' steps registered');

    -- =========================================================================
    -- PHASE 2 : RECOVER
    -- =========================================================================
    UPDATE SYS.REORG_TRACKER
       SET status    = 'PENDING',
           error_msg = 'Reset from RUNNING - prev session killed '||TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS')
     WHERE schema_name = v_schema
       AND table_name  = v_table
       AND status      = 'RUNNING';

    IF SQL%ROWCOUNT > 0 THEN
        log_alert('RECOVERED '||SQL%ROWCOUNT||' RUNNING steps -> PENDING');
    END IF;
    COMMIT;

    -- =========================================================================
    -- PHASE 3 : EXECUTE
    --
    -- SUBPARTITION BATCH LOGIC:
    --   Move subpart 1..20  -> collect names -> rebuild index subparts for those 20 names
    --   Move subpart 21..40 -> collect names -> rebuild index subparts for those 20 names
    --   Move subpart 41..N  -> collect names -> rebuild index subparts for remainder
    --   (exact mirror of original BULK COLLECT LIMIT 20 batch approach)
    -- =========================================================================
    FOR step IN (
        SELECT step_seq, step_type, step_target, step_target2, ddl_statement
        FROM SYS.REORG_TRACKER
        WHERE schema_name = v_schema
          AND table_name  = v_table
          AND status NOT IN ('DONE','SKIPPED')
        ORDER BY step_seq
    ) LOOP

        -- -------------------------------------------------------------------
        -- Flush partial batch when we exit the subpartition move phase
        -- i.e. the first non-subpart step after some subparts were moved
        -- -------------------------------------------------------------------
        IF step.step_type NOT IN ('MOVE_TABLE','MOVE_PARTITION','MOVE_SUBPART')
           AND v_batch_count > 0 THEN
            log_alert('Flush final batch ('||v_batch_count||' subparts) -> rebuild their index subparts');
            rebuild_batch_subpart_indexes;
        END IF;

        v_step_start := SYSTIMESTAMP;
        log_alert('RUN ['||step.step_seq||'] '||step.step_type||
                  ' -> '||NVL(step.step_target, v_table));

        UPDATE SYS.REORG_TRACKER
           SET status     = 'RUNNING',
               started_at = v_step_start,
               error_msg  = NULL
         WHERE schema_name = v_schema
           AND table_name  = v_table
           AND step_seq    = step.step_seq;
        COMMIT;

        BEGIN
            EXECUTE IMMEDIATE step.ddl_statement;

            v_elapsed := ROUND(
                EXTRACT(HOUR   FROM (SYSTIMESTAMP-v_step_start))*3600 +
                EXTRACT(MINUTE FROM (SYSTIMESTAMP-v_step_start))*60   +
                EXTRACT(SECOND FROM (SYSTIMESTAMP-v_step_start)), 1);

            UPDATE SYS.REORG_TRACKER
               SET status       = 'DONE',
                   completed_at = SYSTIMESTAMP,
                   elapsed_secs = v_elapsed
             WHERE schema_name = v_schema
               AND table_name  = v_table
               AND step_seq    = step.step_seq;
            COMMIT;

            log_alert('DONE ['||step.step_seq||'] '||v_elapsed||'s');

            -- -------------------------------------------------------------------
            -- After each successful MOVE_SUBPART:
            --   1. Add this subpartition name to the batch list
            --   2. When batch reaches 20 -> rebuild index subparts for those 20 names
            -- -------------------------------------------------------------------
            IF step.step_type = 'MOVE_SUBPART' THEN
                v_batch_count := v_batch_count + 1;
                v_batch_names(v_batch_count) := step.step_target;

                IF v_batch_count >= v_batch_size THEN
                    log_alert('Batch of '||v_batch_size||' done -> rebuild index subparts for this batch');
                    rebuild_batch_subpart_indexes;
                    -- v_batch_names and v_batch_count reset inside the procedure
                END IF;
            END IF;

        EXCEPTION
            WHEN OTHERS THEN
                v_err := SUBSTRB(SQLERRM, 1, 4000);
                v_elapsed := ROUND(
                    EXTRACT(HOUR   FROM (SYSTIMESTAMP-v_step_start))*3600 +
                    EXTRACT(MINUTE FROM (SYSTIMESTAMP-v_step_start))*60   +
                    EXTRACT(SECOND FROM (SYSTIMESTAMP-v_step_start)), 1);
                UPDATE SYS.REORG_TRACKER
                   SET status       = 'FAILED',
                       completed_at = SYSTIMESTAMP,
                       elapsed_secs = v_elapsed,
                       error_msg    = v_err
                 WHERE schema_name = v_schema
                   AND table_name  = v_table
                   AND step_seq    = step.step_seq;
                COMMIT;
                log_alert('FAILED ['||step.step_seq||'] '||v_err);
                -- Do NOT raise - continue to next step
        END;

    END LOOP;

    -- Final flush - handles tables that have ONLY subpartitions and nothing after
    IF v_batch_count > 0 THEN
        log_alert('End-of-run flush ('||v_batch_count||' subparts) -> rebuild their index subparts');
        rebuild_batch_subpart_indexes;
    END IF;

    log_alert('ALL STEPS PROCESSED for '||v_schema||'.'||v_table);

EXCEPTION
    WHEN OTHERS THEN
        v_err := SUBSTRB(SQLERRM, 1, 4000);
        log_alert('FATAL ERROR: '||v_err);
        RAISE;
END REORG_TABLE;
/
SET DEFINE ON
