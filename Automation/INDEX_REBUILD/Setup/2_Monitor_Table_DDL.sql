CREATE TABLE IMS_MM.index_rebuild_status (
  id                 NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  owner              VARCHAR2(128)  NOT NULL,
  table_name         VARCHAR2(128)  NOT NULL,
  index_name         VARCHAR2(128)  NOT NULL,
  index_kind         VARCHAR2(10)   NOT NULL,               -- NORMAL / LOB
  partition_name     VARCHAR2(128),
  subpartition_name  VARCHAR2(128),
  status             VARCHAR2(10)   DEFAULT 'PENDING',      -- SUCCESS / FAILED
  start_time         TIMESTAMP,
  end_time           TIMESTAMP,
  error_message      VARCHAR2(4000)
);

-- CREATE UNIQUE INDEX IMS_MM.uk_index_rebuild_status
--  ON IMS_MM.index_rebuild_status (
--    owner, index_name, NVL(partition_name, '~'), NVL(subpartition_name, '~')
--  );
