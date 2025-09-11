import oracledb

hostname = "192.168.76.210"
port = 1521
service_name = "rtp"
username = "sys"
password = "Ebslabs123"

start_time_str = "2025-08-27 17:00"
end_time_str = "2025-08-27 19:00"

dsn = f"{hostname}:{port}/{service_name}"

connection = oracledb.connect(
    user=username,
    password=password,
    dsn=dsn,
    mode=oracledb.AUTH_MODE_SYSDBA
)

try:
    cursor = connection.cursor()

    cursor.execute("SELECT dbid, instance_number, name FROM v$database, v$instance")
    row = cursor.fetchone()
    if row is None:
        raise Exception("Cannot fetch DB info")
    dbid, inst_num, db_name = row

    # Helper to fetch snapshot id safely
    def get_snap_id(time_str):
        cursor.execute("""
            SELECT snap_id
            FROM dba_hist_snapshot
            WHERE begin_interval_time <= TO_TIMESTAMP(:time_str, 'YYYY-MM-DD HH24:MI')
            ORDER BY begin_interval_time DESC
            FETCH FIRST 1 ROWS ONLY
        """, time_str=time_str)
        snap_row = cursor.fetchone()
        
        if snap_row is None:
            raise Exception(f"No snapshot found before {time_str}")
        return snap_row[0]

    begin_snap_id = get_snap_id(start_time_str)
    end_snap_id = get_snap_id(end_time_str)

    filename = f"{db_name.lower()}_awr_{begin_snap_id}_to_{end_snap_id}.html"

    cursor.execute("""
        SELECT output
        FROM TABLE(
            DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML(:dbid, :inst_num, :begin_snap, :end_snap)
        )
    """, dbid=dbid, inst_num=inst_num, begin_snap=begin_snap_id, end_snap=end_snap_id)
    
    AWRResult = cursor.fetchall()
    
    lines = []
    for row in AWRResult:
        lines.append((row[0] or '') + "\n")

    report_html = "".join(lines)

    with open(filename, "w", encoding="utf-8") as f:
        f.write(report_html)

    print(f"AWR report saved as: {filename}")

finally:
    cursor.close()
    connection.close()
