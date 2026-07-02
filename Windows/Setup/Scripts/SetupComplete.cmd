@echo off
setlocal EnableExtensions

set "LOG=C:\Windows\Temp\ULSEE-SetupComplete.log"

echo [%date% %time%] ULSEE SetupComplete started.>>"%LOG%"

echo [%date% %time%] Disabling hibernation.>>"%LOG%"
powercfg -h off >>"%LOG%" 2>&1

rem Optional post-install hook example:
rem if exist "C:\Deploy\Scripts\post-install.cmd" call "C:\Deploy\Scripts\post-install.cmd" >>"%LOG%" 2>&1

echo [%date% %time%] ULSEE SetupComplete finished.>>"%LOG%"
exit /b 0
