-- =============================================================================
-- FILE : 01_create_tracker_table.sql
-- RUN  : Once only, as DBA
-- =============================================================================

CREATE TABLE SYS.REORG_TRACKER (
    schema_name     VARCHAR2(30)   NOT NULL,
    table_name      VARCHAR2(128)  NOT NULL,
    step_seq        NUMBER         NOT NULL,
    step_type       VARCHAR2(30)   NOT NULL,
    step_target     VARCHAR2(128),            -- partition / index name
    step_target2    VARCHAR2(128),            -- lob column name (if applicable)
    tablespace_name VARCHAR2(30),
    ddl_statement   VARCHAR2(4000) NOT NULL,
    status          VARCHAR2(10)   DEFAULT 'PENDING' NOT NULL,
    -- PENDING  -> not yet run
    -- RUNNING  -> started (if session killed, stays here; auto-reset next run)
    -- DONE     -> completed successfully, NEVER re-runs
    -- FAILED   -> errored, retried next run
    started_at      TIMESTAMP,
    completed_at    TIMESTAMP,
    elapsed_secs    NUMBER,
    error_msg       VARCHAR2(4000),
    CONSTRAINT pk_reorg_tracker PRIMARY KEY (schema_name, table_name, step_seq)
);
