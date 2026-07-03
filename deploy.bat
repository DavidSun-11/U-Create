@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
set "AUTO=0"
set "WIM="
set "LOGDIR=%ROOT%DeployLogs"
set "DISKPART_LOG=%LOGDIR%\diskpart.log"
set "DISM_LOG=%LOGDIR%\dism-apply.log"
set "BCDBOOT_LOG=%LOGDIR%\bcdboot.log"
set "BCDEDIT_LOG=%LOGDIR%\bcdedit-firmware.log"
set "FWBOOTMGR_LOG=%LOGDIR%\fwbootmgr-displayorder.log"
set "SUCCESS_FLAG=%LOGDIR%\deploy-success.flag"

if /I "%~1"=="/auto" set "AUTO=1"

echo ============================================================
echo  ULSEE Windows 11 WinPE Deployment
echo ============================================================
echo Script root: "%ROOT%"
echo.

if not exist "%LOGDIR%" mkdir "%LOGDIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create log directory: "%LOGDIR%"
    goto :fail
)
echo [OK] Log directory: "%LOGDIR%"
echo.

echo [STEP] Selecting Windows image file...
if exist "%ROOT%Images\install.wim" (
    for %%I in ("%ROOT%Images\install.wim") do (
        if not "%%~zI"=="0" set "WIM=%%~fI"
    )
    if not defined WIM echo [WARNING] Ignoring zero-byte image file: "%ROOT%Images\install.wim"
)

if not defined WIM (
    if exist "%ROOT%sources\install.wim" (
        for %%I in ("%ROOT%sources\install.wim") do (
            if not "%%~zI"=="0" set "WIM=%%~fI"
        )
        if not defined WIM echo [WARNING] Ignoring zero-byte image file: "%ROOT%sources\install.wim"
    )
)

if not defined WIM (
    echo [ERROR] No valid Windows image found.
    echo [ERROR] Expected a non-empty file at one of:
    echo [ERROR]   "%ROOT%Images\install.wim"
    echo [ERROR]   "%ROOT%sources\install.wim"
    goto :fail
)
echo [OK] Using image file: "%WIM%"

if not exist "%ROOT%diskpart-uefi.txt" (
    echo [ERROR] Missing diskpart script: "%ROOT%diskpart-uefi.txt"
    goto :fail
)
echo [OK] Found diskpart script: "%ROOT%diskpart-uefi.txt"
echo.

if "%AUTO%"=="1" (
    echo [AUTO] Automatic mode enabled. Disk 0 will be erased without prompt.
) else (
    echo [WARNING] This deployment will erase all data on Disk 0.
    echo [WARNING] Continue only on the target computer.
    pause
)
echo.

echo [STEP] wpeinit - Initializing WinPE networking and Plug and Play...
wpeinit
if errorlevel 1 (
    echo [ERROR] wpeinit failed.
    goto :fail
)
echo [OK] WinPE initialization completed.
echo.

echo [STEP] diskpart - Partitioning Disk 0 as UEFI/GPT...
diskpart /s "%ROOT%diskpart-uefi.txt" > "%DISKPART_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] diskpart failed.
    echo [ERROR] See log: "%DISKPART_LOG%"
    goto :fail
)
echo [OK] Disk partitioning completed.
echo.

echo [STEP] applying image - Applying Windows image to W:\ ...
dism /Apply-Image /ImageFile:"%WIM%" /Index:1 /ApplyDir:W:\ /CheckIntegrity /LogPath:"%DISM_LOG%"
if errorlevel 1 (
    echo [ERROR] DISM Apply-Image failed.
    echo [ERROR] See log: "%DISM_LOG%"
    goto :fail
)
echo [OK] Windows image applied.
echo.

echo [STEP] verifying applied Windows...
if not exist "W:\Windows\System32\config\SYSTEM" (
    echo [ERROR] Applied Windows SYSTEM registry hive not found:
    echo [ERROR]   W:\Windows\System32\config\SYSTEM
    echo [ERROR] See DISM log: "%DISM_LOG%"
    goto :fail
)
echo [OK] Applied Windows verification passed.
echo.

echo [STEP] copying unattend - Copying target system unattend.xml...
if not exist "W:\Windows\Panther" (
    mkdir "W:\Windows\Panther"
    if errorlevel 1 (
        echo [ERROR] Failed to create W:\Windows\Panther.
        goto :fail
    )
)
copy /Y "%ROOT%unattend.xml" "W:\Windows\Panther\Unattend.xml"
if errorlevel 1 (
    echo [ERROR] Failed to copy unattend.xml.
    goto :fail
)
echo [OK] Copied unattend.xml to W:\Windows\Panther\Unattend.xml.
echo.

echo [STEP] copying SetupComplete scripts...
if exist "%ROOT%Windows\Setup\Scripts" (
    if not exist "W:\Windows\Setup\Scripts" (
        mkdir "W:\Windows\Setup\Scripts"
        if errorlevel 1 (
            echo [ERROR] Failed to create W:\Windows\Setup\Scripts.
            goto :fail
        )
    )
    xcopy "%ROOT%Windows\Setup\Scripts" "W:\Windows\Setup\Scripts\" /E /I /H /Y
    if errorlevel 1 (
        echo [ERROR] Failed to copy SetupComplete scripts.
        goto :fail
    )
    echo [OK] Copied SetupComplete scripts.
) else (
    echo [INFO] Optional scripts directory not found; skipping.
)
echo.

echo [STEP] bcdboot - Writing UEFI boot files...
bcdboot W:\Windows /l en-US /s S: /f UEFI /v > "%BCDBOOT_LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] bcdboot failed. System image may be applied but EFI boot files were not created.
    echo [ERROR] See log: "%BCDBOOT_LOG%"
    goto :fail
)
echo [OK] UEFI boot files written.
echo.

echo [STEP] writing deployment success flag...
echo Deployment completed at %date% %time%>"%SUCCESS_FLAG%"
echo Image: "%WIM%">>"%SUCCESS_FLAG%"
echo [OK] Success flag written: "%SUCCESS_FLAG%"
echo.

echo [STEP] firmware boot diagnostics...
bcdedit /enum firmware > "%BCDEDIT_LOG%" 2>&1
if errorlevel 1 (
    echo [WARNING] bcdedit /enum firmware failed. Continuing.
    echo [WARNING] See log: "%BCDEDIT_LOG%"
)

bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst > "%FWBOOTMGR_LOG%" 2>&1
if errorlevel 1 (
    echo [WARNING] Failed to prioritize Windows Boot Manager. Continuing.
    echo [WARNING] See log: "%FWBOOTMGR_LOG%"
)
echo.

echo [STEP] reboot
echo [OK] Deployment completed. Rebooting to Windows Boot Manager.
wpeutil reboot
if errorlevel 1 (
    echo [ERROR] Failed to reboot automatically.
    goto :fail
)

exit /b 0

:fail
echo.
echo [FAILED] Deployment did not complete successfully.
echo [FAILED] Log directory: "%LOGDIR%"
if "%AUTO%"=="1" (
    echo [STOP] Automatic mode stopped for inspection.
    cmd /k
) else (
    pause
)
exit /b 1
