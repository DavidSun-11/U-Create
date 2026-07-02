param(
    [Parameter(Mandatory = $true)]
    [string]$UsbDrive,

    [Parameter(Mandatory = $false)]
    [string]$WimPath
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

$kitRoot = Split-Path -Parent $PSScriptRoot
$usbRoot = Resolve-UsbRoot -Drive $UsbDrive

Write-Host "ULSEE USB copy tool"
Write-Host "Kit root: $kitRoot"
Write-Host "USB root: $usbRoot"
Write-Host ''

if (-not (Test-Path -LiteralPath $usbRoot)) {
    throw "USB drive does not exist: $usbRoot"
}

$looksLikeWindowsUsb = (Test-Path -LiteralPath (Join-Path $usbRoot 'sources')) -or (Test-Path -LiteralPath (Join-Path $usbRoot 'setup.exe'))
if (-not $looksLikeWindowsUsb) {
    Write-Warning "The USB root does not look like a Windows installation USB. Expected 'sources' or 'setup.exe'. Continuing anyway."
}

$filesToCopy = @(
    'Autounattend.xml',
    'deploy.bat',
    'diskpart-uefi.txt',
    'unattend.xml'
)

foreach ($file in $filesToCopy) {
    $source = Join-Path $kitRoot $file
    $destination = Join-Path $usbRoot $file
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Missing source file: $source"
    }
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Write-Host "Copied $file"
}

$windowsSource = Join-Path $kitRoot 'Windows'
$windowsDestination = Join-Path $usbRoot 'Windows'
if (Test-Path -LiteralPath $windowsSource) {
    Copy-Item -LiteralPath $windowsSource -Destination $usbRoot -Recurse -Force
    Write-Host "Copied Windows directory"
} else {
    Write-Warning "Windows directory not found in kit root: $windowsSource"
}

$imagesDestination = Join-Path $usbRoot 'Images'
New-Item -ItemType Directory -Path $imagesDestination -Force | Out-Null
Write-Host "Ensured Images directory exists"

if ($PSBoundParameters.ContainsKey('WimPath')) {
    if (-not (Test-Path -LiteralPath $WimPath)) {
        throw "WIM file does not exist: $WimPath"
    }
    Copy-Item -LiteralPath $WimPath -Destination (Join-Path $imagesDestination 'install.wim') -Force
    Write-Host "Copied install.wim"
} else {
    Write-Host "No -WimPath provided; install.wim was not copied."
}

Write-Host ''
Write-Host 'Final USB deployment file check:'
$checkPaths = @(
    'Autounattend.xml',
    'deploy.bat',
    'diskpart-uefi.txt',
    'unattend.xml',
    'Windows\Setup\Scripts\SetupComplete.cmd',
    'Images\install.wim'
)

foreach ($relativePath in $checkPaths) {
    $path = Join-Path $usbRoot $relativePath
    if (Test-Path -LiteralPath $path) {
        Write-Host "[OK]      $relativePath"
    } else {
        Write-Host "[MISSING] $relativePath"
    }
}

Write-Host ''
Write-Warning 'When this USB boots, Autounattend.xml will automatically run deployment and erase Disk 0 on the target computer.'
