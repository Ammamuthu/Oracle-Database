BEGIN
	DBMS_SYSTEM.KSDWRT(2,'=======Rman Backup Summery=========')			;	
end;
/

				
DECLARE
BEGIN
    FOR r IN (
		SELECT *
		from (
			SELECT SESSION_KEY,
					INPUT_TYPE,
					STATUS,
					TO_CHAR(START_TIME,'mm/dd/yy hh24:mi') start_time,
					TO_CHAR(END_TIME,'mm/dd/yy hh24:mi') end_time,
					ROUND(elapsed_seconds/3600,2) hrs
			FROM V$RMAN_BACKUP_JOB_DETAILS
			ORDER BY START_TIME DESC
		)
		WHERE ROWNUM = 1												
    ) LOOP
        DBMS_SYSTEM.KSDWRT(2, '-----------------------------');
        DBMS_SYSTEM.KSDWRT(2, 'SESSION_KEY : ' || r.session_key);
        DBMS_SYSTEM.KSDWRT(2, 'INPUT_TYPE  : ' || r.input_type);
        DBMS_SYSTEM.KSDWRT(2, 'STATUS      : ' || r.status);
        DBMS_SYSTEM.KSDWRT(2, 'START       : ' || r.start_time);
        DBMS_SYSTEM.KSDWRT(2, 'END         : ' || r.end_time);
        DBMS_SYSTEM.KSDWRT(2, 'HOURS       : ' || r.hrs);
    END LOOP;
END;
/
BEGIN
	DBMS_SYSTEM.KSDWRT(2,'=======Rman Backup Summery Ended =========')			;	
end;
/

Exit;