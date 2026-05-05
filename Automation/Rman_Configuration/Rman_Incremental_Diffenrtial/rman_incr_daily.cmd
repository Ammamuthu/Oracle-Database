@echo off
rman target / cmdfile=D:\ims_ecs\scripts\Level_1\rman_incr_daily.rcv log=D:\ims_ecs\scripts\Level_1\logs\incr_backup_%date:~-4%%date:~4,2%%date:~7,2%.log

:: --- Delete any .bak files older than 14 days that RMAN may have missed ---
forfiles /p "D:\ims_ecs\Backup\IMS\Level_1" /s /m *.bak /d -14 /c "cmd /c del @path"

:: --- Delete log files older than 30 days ---
forfiles /p "D:\ims_ecs\scripts\Level_1\logs" /s /m *.log /d -30 /c "cmd /c del @path"