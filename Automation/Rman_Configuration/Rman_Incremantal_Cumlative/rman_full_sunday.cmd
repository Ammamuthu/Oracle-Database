@echo off
rman target / cmdfile=D:\ims_ecs\scripts\Level_0\rman_full_sunday.rcv log=D:\ims_ecs\scripts\Level_0\logs\full_backup_%date:~-4%%date:~4,2%%date:~7,2%.log

:: --- Delete .bak files older than 14 days ---
forfiles /p "D:\ims_ecs\Backup\IMS\Level_0" /s /m *.bak /d -14 /c "cmd /c del @path"

:: --- Delete log files older than 30 days ---
forfiles /p "D:\ims_ecs\scripts\Level_0\logs" /s /m *.log /d -30 /c "cmd /c del @path"