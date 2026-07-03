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

if ($PSBoundParameters.ContainsKey('WimPath')) {
    if (-not (Test-Path -LiteralPath $WimPath)) {
        throw "WIM file does not exist: $WimPath"
    }
    $wimItem = Get-Item -LiteralPath $WimPath
    if ($wimItem.Length -eq 0) {
        throw "WIM file is 0 bytes and will not be copied: $WimPath"
    }
    $imagesDestination = Join-Path $usbRoot 'Images'
    New-Item -ItemType Directory -Path $imagesDestination -Force | Out-Null
    Write-Host "Ensured Images directory exists"
    Copy-Item -LiteralPath $WimPath -Destination (Join-Path $imagesDestination 'install.wim') -Force
    Write-Host "Copied install.wim to Images\install.wim"
} else {
    Write-Host "No -WimPath provided; Images\install.wim was not created."
    $existingSourcesWim = Join-Path $usbRoot 'sources\install.wim'
    if (Test-Path -LiteralPath $existingSourcesWim) {
        $sourcesWimItem = Get-Item -LiteralPath $existingSourcesWim
        if ($sourcesWimItem.Length -gt 0) {
            Write-Host "[OK] Found existing sources\install.wim. deploy.bat can use it."
        } else {
            Write-Warning "Found sources\install.wim, but it is 0 bytes. deploy.bat will ignore it."
        }
    } else {
        Write-Warning "No -WimPath provided and sources\install.wim was not found. deploy.bat will not have a valid image unless Images\install.wim already exists."
    }
}

Write-Host ''
Write-Host 'Final USB deployment file check:'
$checkPaths = @(
    'Autounattend.xml',
    'deploy.bat',
    'diskpart-uefi.txt',
    'unattend.xml',
    'Windows\Setup\Scripts\SetupComplete.cmd',
    'Images\install.wim',
    'sources\install.wim'
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
$imagesWim = Join-Path $usbRoot 'Images\install.wim'
$sourcesWim = Join-Path $usbRoot 'sources\install.wim'
$hasValidImagesWim = (Test-Path -LiteralPath $imagesWim) -and ((Get-Item -LiteralPath $imagesWim).Length -gt 0)
$hasValidSourcesWim = (Test-Path -LiteralPath $sourcesWim) -and ((Get-Item -LiteralPath $sourcesWim).Length -gt 0)
if ($hasValidImagesWim -or $hasValidSourcesWim) {
    Write-Host '[OK]      At least one valid deployment image path exists.'
} else {
    Write-Warning 'No valid deployment image found at Images\install.wim or sources\install.wim.'
}

Write-Host ''
Write-Host 'Image selection priority used by deploy.bat:'
Write-Host '  1. Images\install.wim'
Write-Host '  2. sources\install.wim'
Write-Host ''
Write-Warning 'When this USB boots, Autounattend.xml will automatically run deployment and erase Disk 0 on the target computer.'
