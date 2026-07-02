@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
set "AUTO=0"

if /I "%~1"=="/auto" set "AUTO=1"

echo ============================================================
echo  ULSEE Windows 11 WinPE Deployment
echo ============================================================
echo Script root: "%ROOT%"
echo.

if not exist "%ROOT%Images\install.wim" (
    echo [ERROR] Missing image file: "%ROOT%Images\install.wim"
    goto :fail
)
echo [OK] Found image file: "%ROOT%Images\install.wim"

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

echo [STEP] Initializing WinPE networking and Plug and Play...
wpeinit
if errorlevel 1 (
    echo [ERROR] wpeinit failed.
    goto :fail
)
echo [OK] WinPE initialization completed.
echo.

echo [STEP] Partitioning Disk 0 as UEFI/GPT...
diskpart /s "%ROOT%diskpart-uefi.txt"
if errorlevel 1 (
    echo [ERROR] diskpart failed.
    goto :fail
)
echo [OK] Disk partitioning completed.
echo.

echo [STEP] Applying Windows image to W:\ ...
dism /Apply-Image /ImageFile:"%ROOT%Images\install.wim" /Index:1 /ApplyDir:W:\ /CheckIntegrity
if errorlevel 1 (
    echo [ERROR] DISM Apply-Image failed.
    goto :fail
)
echo [OK] Windows image applied.
echo.

echo [STEP] Copying target system unattend.xml...
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

echo [STEP] Copying optional SetupComplete scripts...
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

echo [STEP] Writing UEFI boot files...
bcdboot W:\Windows /s S: /f UEFI
if errorlevel 1 (
    echo [ERROR] bcdboot failed.
    goto :fail
)
echo [OK] UEFI boot files written.
echo.

echo [SUCCESS] Deployment completed. Rebooting into Windows...
wpeutil reboot
if errorlevel 1 (
    echo [ERROR] Failed to reboot automatically.
    goto :fail
)

exit /b 0

:fail
echo.
echo [FAILED] Deployment did not complete successfully.
if not "%AUTO%"=="1" pause
exit /b 1
