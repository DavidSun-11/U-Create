[CmdletBinding(DefaultParameterSetName = 'Patch')]
param(
    [Parameter(Mandatory = $true)]
    [string]$UsbDrive,

    [Parameter(Mandatory = $false, ParameterSetName = 'Patch')]
    [int]$Index = 2,

    [Parameter(Mandatory = $false, ParameterSetName = 'Patch')]
    [string]$MountDir,

    [Parameter(Mandatory = $false, ParameterSetName = 'Patch')]
    [switch]$Force,

    [Parameter(Mandatory = $false, ParameterSetName = 'Patch')]
    [switch]$KeepAutounattend,

    [Parameter(Mandatory = $false, ParameterSetName = 'Patch')]
    [switch]$PatchAllIndexes,

    [Parameter(Mandatory = $true, ParameterSetName = 'Restore')]
    [switch]$RestoreLatestBackup
)

$ErrorActionPreference = 'Stop'

function Resolve-UsbRoot {
    param([string]$Drive)

    $normalized = $Drive.Trim()
    if ($normalized -match '^[A-Za-z]$') {
        $normalized = "$normalized`:"
    }
    if ($normalized -match '^[A-Za-z]:$') {
        $normalized = "$normalized\"
    }
    return $normalized
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session.'
    }
}

function Assert-DismAvailable {
    $command = Get-Command dism.exe -ErrorAction SilentlyContinue
    if (-not $command) {
        throw 'dism.exe was not found in PATH.'
    }
}

function Test-NonEmptyFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    return ((Get-Item -LiteralPath $Path).Length -gt 0)
}

function Invoke-DismChecked {
    param(
        [string[]]$Arguments,
        [string]$FailureMessage
    )

    Write-Host "dism $($Arguments -join ' ')"
    $output = & dism.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        Write-Host $line
    }
    if ($exitCode -ne 0) {
        throw "$FailureMessage Exit code: $exitCode"
    }
    return $output
}

function Get-WimIndexes {
    param([string[]]$DismOutput)

    $indexes = New-Object System.Collections.Generic.List[int]
    foreach ($line in $DismOutput) {
        if ($line -match '^\s*(Index|索引)\s*:\s*(\d+)\s*$') {
            $indexValue = if ($Matches[2]) { $Matches[2] } else { $Matches[1] }
            [void]$indexes.Add([int]$indexValue)
        }
    }
    return @($indexes | Sort-Object -Unique)
}

function Write-LauncherFiles {
    param(
        [string]$MountPath,
        [int]$PatchedIndex
    )

    $system32 = Join-Path $MountPath 'Windows\System32'
    if (-not (Test-Path -LiteralPath $system32)) {
        throw "Mounted image does not contain Windows\System32: $system32"
    }

    $winpeshl = Join-Path $system32 'winpeshl.ini'
    $startnet = Join-Path $system32 'startnet.cmd'
    foreach ($file in @($winpeshl, $startnet)) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Copy-Item -LiteralPath $file -Destination "$file.ucreate.bak" -Force
        }
    }

    $launcher = Join-Path $system32 'ulsee-winpe-launch.cmd'
    $launcherContent = @'
@echo off
setlocal EnableExtensions

echo ============================================================
echo  ULSEE WinPE Direct Deploy Launcher
echo ============================================================

set "DEPLOYROOT="
set "LOGFILE="

echo [STEP] Initializing WinPE...
wpeinit

for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\deploy.bat" (
        set "DEPLOYROOT=%%D:"
        goto :found
    )
)

echo [ERROR] deploy.bat not found. Check USB content.
cmd /k
exit /b 1

:found
echo [OK] Found deploy root: %DEPLOYROOT%
if not exist "%DEPLOYROOT%\DeployLogs" mkdir "%DEPLOYROOT%\DeployLogs"
set "LOGFILE=%DEPLOYROOT%\DeployLogs\winpe-launch.log"
echo [%date% %time%] ULSEE WinPE Direct Deploy Launcher started.>>"%LOGFILE%"
echo [%date% %time%] Found deploy root: %DEPLOYROOT%>>"%LOGFILE%"

if exist "%DEPLOYROOT%\DeployLogs\deploy-success.flag" (
    echo [STOP] Previous deployment completed. Remove USB or delete DeployLogs\deploy-success.flag to deploy again.
    echo [%date% %time%] STOP: deploy-success.flag exists.>>"%LOGFILE%"
    cmd /k
    exit /b 2
)

echo [STEP] Starting deploy.bat /auto...
echo [%date% %time%] Calling deploy.bat /auto.>>"%LOGFILE%"
call "%DEPLOYROOT%\deploy.bat" /auto
set "DEPLOYEXIT=%ERRORLEVEL%"

if not "%DEPLOYEXIT%"=="0" (
    echo [ERROR] deploy.bat returned exit code %DEPLOYEXIT%.
    echo [%date% %time%] ERROR: deploy.bat returned exit code %DEPLOYEXIT%.>>"%LOGFILE%"
    cmd /k
    exit /b %DEPLOYEXIT%
)

echo [%date% %time%] deploy.bat returned success.>>"%LOGFILE%"
exit /b 0
'@

    Set-Content -LiteralPath $launcher -Value $launcherContent -Encoding ASCII

    $winpeshlContent = @'
[LaunchApps]
X:\Windows\System32\cmd.exe, /c X:\Windows\System32\ulsee-winpe-launch.cmd
'@
    Set-Content -LiteralPath $winpeshl -Value $winpeshlContent -Encoding ASCII

    $stamp = Join-Path $system32 'UCreate-BootWim-DirectDeploy.txt'
    Set-Content -LiteralPath $stamp -Value @(
        "mode=boot.wim direct deploy"
        "patchedIndex=$PatchedIndex"
        "patchedAt=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        'launcher=Windows\System32\ulsee-winpe-launch.cmd'
    ) -Encoding ASCII
}

function Restore-LatestBackup {
    param(
        [string]$BootWimPath,
        [string]$SourcesDir
    )

    $latestBackup = Get-ChildItem -LiteralPath $SourcesDir -Filter 'boot.wim.bak-*' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latestBackup) {
        throw "No boot.wim backup found in $SourcesDir"
    }

    Copy-Item -LiteralPath $latestBackup.FullName -Destination $BootWimPath -Force
    $markerPath = Join-Path (Split-Path -Parent $SourcesDir) 'U-Create-BootWim-Patched.txt'
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        Remove-Item -LiteralPath $markerPath -Force
    }
    Write-Host "[OK] Restored boot.wim from: $($latestBackup.FullName)"
}

$usbRoot = Resolve-UsbRoot -Drive $UsbDrive
$sourcesDir = Join-Path $usbRoot 'sources'
$bootWim = Join-Path $sourcesDir 'boot.wim'
$markerPath = Join-Path $usbRoot 'U-Create-BootWim-Patched.txt'

Assert-Administrator
Assert-DismAvailable

if (-not (Test-Path -LiteralPath $usbRoot)) {
    throw "USB drive does not exist: $usbRoot"
}
if (-not (Test-Path -LiteralPath $bootWim -PathType Leaf)) {
    throw "Missing boot.wim: $bootWim"
}

if ($RestoreLatestBackup) {
    Restore-LatestBackup -BootWimPath $bootWim -SourcesDir $sourcesDir
    return
}

if ((Test-Path -LiteralPath $markerPath -PathType Leaf) -and -not $Force) {
    throw "This USB already appears patched: $markerPath. Use -Force to patch again."
}

$requiredFiles = @(
    'deploy.bat',
    'diskpart-uefi.txt',
    'unattend.xml'
)

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $usbRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required deployment file: $path"
    }
}

$imagesWim = Join-Path $usbRoot 'Images\install.wim'
$sourcesInstallWim = Join-Path $usbRoot 'sources\install.wim'
if (-not ((Test-NonEmptyFile -Path $imagesWim) -or (Test-NonEmptyFile -Path $sourcesInstallWim))) {
    throw 'No valid deployment image found. Expected non-empty Images\install.wim or sources\install.wim.'
}

Write-Host "[STEP] Reading boot.wim image information..."
$wimInfo = Invoke-DismChecked -Arguments @('/Get-WimInfo', "/WimFile:$bootWim") -FailureMessage 'Failed to read boot.wim image information.'
$availableIndexes = @(Get-WimIndexes -DismOutput $wimInfo)
if ($availableIndexes.Count -eq 0) {
    throw 'Could not detect any boot.wim indexes from DISM output.'
}

if ($PatchAllIndexes) {
    $indexesToPatch = $availableIndexes
} else {
    if ($availableIndexes -notcontains $Index) {
        throw "Index $Index does not exist in boot.wim. Available indexes: $($availableIndexes -join ', ')"
    }
    $indexesToPatch = @($Index)
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = Join-Path $sourcesDir "boot.wim.bak-$timestamp"
Copy-Item -LiteralPath $bootWim -Destination $backupPath -Force
Write-Host "[OK] Backed up boot.wim to: $backupPath"

$createdTempMount = $false
if ([string]::IsNullOrWhiteSpace($MountDir)) {
    $MountDir = Join-Path ([IO.Path]::GetTempPath()) "UCreate-BootWim-Mount-$timestamp"
    $createdTempMount = $true
}

$mounted = $false
try {
    foreach ($targetIndex in $indexesToPatch) {
        if (Test-Path -LiteralPath $MountDir) {
            $children = @(Get-ChildItem -LiteralPath $MountDir -Force -ErrorAction SilentlyContinue)
            if ($children.Count -gt 0) {
                throw "MountDir is not empty: $MountDir"
            }
        } else {
            New-Item -ItemType Directory -Path $MountDir -Force | Out-Null
        }

        Write-Host "[STEP] Mounting boot.wim index $targetIndex..."
        Invoke-DismChecked -Arguments @('/Mount-Wim', "/WimFile:$bootWim", "/Index:$targetIndex", "/MountDir:$MountDir") -FailureMessage "Failed to mount boot.wim index $targetIndex."
        $mounted = $true

        Write-Host "[STEP] Writing U-Create launcher into mounted image..."
        Write-LauncherFiles -MountPath $MountDir -PatchedIndex $targetIndex

        Write-Host "[STEP] Committing boot.wim index $targetIndex..."
        Invoke-DismChecked -Arguments @('/Unmount-Wim', "/MountDir:$MountDir", '/Commit') -FailureMessage "Failed to commit boot.wim index $targetIndex. Run DISM /Cleanup-Wim if DISM reports a stale mount."
        $mounted = $false
    }
} catch {
    Write-Error $_.Exception.Message
    if ($mounted) {
        Write-Warning "Discarding mounted image: $MountDir"
        & dism.exe /Unmount-Wim "/MountDir:$MountDir" /Discard | Out-Host
    }
    Write-Warning 'If DISM reports stale mounted images, run: DISM /Cleanup-Wim'
    throw
} finally {
    if ($createdTempMount -and (Test-Path -LiteralPath $MountDir)) {
        Remove-Item -LiteralPath $MountDir -Force -Recurse -ErrorAction SilentlyContinue
    }
}

$autounattend = Join-Path $usbRoot 'Autounattend.xml'
$setupModeAutounattend = Join-Path $usbRoot 'Autounattend.setup-mode.xml'
if ((Test-Path -LiteralPath $autounattend -PathType Leaf) -and -not $KeepAutounattend) {
    Move-Item -LiteralPath $autounattend -Destination $setupModeAutounattend -Force
    Write-Host "[OK] Renamed Autounattend.xml to Autounattend.setup-mode.xml"
}

$marker = @(
    "patch time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "boot.wim path: $bootWim"
    "index: $(if ($PatchAllIndexes) { 'all: ' + ($indexesToPatch -join ', ') } else { $Index })"
    "backup path: $backupPath"
    'launcher path: Windows\System32\ulsee-winpe-launch.cmd'
    'mode: boot.wim direct deploy'
)
Set-Content -LiteralPath $markerPath -Value $marker -Encoding UTF8

Write-Host ''
Write-Host '[SUCCESS] boot.wim direct deploy patch completed.'
Write-Host 'Next diagnostic command:'
Write-Host "powershell -ExecutionPolicy Bypass -File .\tools\collect-usb-deploy-info.ps1 -UsbDrive $UsbDrive"
