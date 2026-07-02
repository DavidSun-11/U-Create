[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$UsbDrive,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path (Get-Location) ("USB_DEPLOY_DIAG_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))),

    [Parameter(Mandatory = $false)]
    [switch]$IncludeHash
)

$ErrorActionPreference = 'Continue'

$Report = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]
$ImageFilesFound = New-Object System.Collections.Generic.List[object]
$StatusPass = ('{0}{1}' -f [char]0x901A, [char]0x8FC7)
$StatusMissing = ('{0}{1}' -f [char]0x7F3A, [char]0x5931)
$StatusWarning = ('{0}{1}' -f [char]0x8B66, [char]0x544A)

function Add-Line {
    param([string]$Text = '')
    [void]$script:Report.Add($Text)
}

function Add-Section {
    param([string]$Name)
    Add-Line ''
    Add-Line ('=' * 78)
    Add-Line $Name
    Add-Line ('=' * 78)
}

function Add-WarningLine {
    param([string]$Text)
    [void]$script:Warnings.Add($Text)
}

function Format-ByteSize {
    param([Nullable[UInt64]]$Bytes)

    if ($null -eq $Bytes) {
        return 'Unknown'
    }
    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }
    if ($Bytes -ge 1MB) {
        return ('{0:N2} MB' -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB) {
        return ('{0:N2} KB' -f ($Bytes / 1KB))
    }
    return ('{0} bytes' -f $Bytes)
}

function Normalize-DriveRoot {
    param([string]$Drive)

    if ([string]::IsNullOrWhiteSpace($Drive)) {
        return $null
    }

    $value = $Drive.Trim()
    if ($value -match '^[A-Za-z]$') {
        $value = "$value`:"
    }
    if ($value -match '^[A-Za-z]:\\?$') {
        return (($value.Substring(0, 1).ToUpperInvariant()) + ':\')
    }

    try {
        return (Resolve-Path -LiteralPath $value -ErrorAction Stop).Path
    } catch {
        return $value
    }
}

function Join-RootPath {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    return (Join-Path -Path $Root -ChildPath $RelativePath)
}

function Test-DeployPath {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    return (Test-Path -LiteralPath (Join-RootPath -Root $Root -RelativePath $RelativePath))
}

function Get-FileReportLine {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    $path = Join-RootPath -Root $Root -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return "[$script:StatusMissing] $RelativePath | Path: $path"
    }

    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $line = "[$script:StatusPass] $RelativePath | Size: $(Format-ByteSize -Bytes $item.Length) | Modified: $($item.LastWriteTime) | Path: $($item.FullName)"

        if ($IncludeHash -and $item.Extension -match '^\.(wim|esd|swm)$') {
            try {
                $hash = Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop
                $line = "$line | SHA256: $($hash.Hash)"
            } catch {
                $line = "$line | SHA256: ERROR: $($_.Exception.Message)"
                Add-WarningLine "Failed to hash $($item.FullName): $($_.Exception.Message)"
            }
        }

        return $line
    } catch {
        Add-WarningLine "Failed to inspect ${path}: $($_.Exception.Message)"
        return "[$script:StatusWarning] $RelativePath | Path: $path | Error: $($_.Exception.Message)"
    }
}

function Get-TextFileContent {
    param([string]$Path)

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    } catch {
        try {
            return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        } catch {
            Add-WarningLine "Failed to read ${Path}: $($_.Exception.Message)"
            return $null
        }
    }
}

function Add-ContainsCheck {
    param(
        [string]$Label,
        [bool]$Passed,
        [bool]$WarningWhenFailed = $false
    )

    if ($Passed) {
        Add-Line "[$script:StatusPass] $Label"
    } elseif ($WarningWhenFailed) {
        Add-Line "[$script:StatusWarning] $Label"
        Add-WarningLine $Label
    } else {
        Add-Line "[$script:StatusMissing] $Label"
        Add-WarningLine $Label
    }
}

function Redact-XmlPasswordValues {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $pattern = '(?is)(<Password\b[^>]*>.*?<Value>)(.*?)(</Value>.*?</Password>)'
    return [regex]::Replace($Text, $pattern, {
        param($match)
        return $match.Groups[1].Value + '***REDACTED***' + $match.Groups[3].Value
    })
}

function Search-ImageFilesLimited {
    param(
        [string]$Directory,
        [int]$Depth,
        [int]$MaxDepth
    )

    if ($Depth -gt $MaxDepth) {
        return
    }

    try {
        Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction Stop |
            Where-Object { $_.Extension -match '^\.(wim|esd|swm)$' } |
            ForEach-Object {
                [void]$script:ImageFilesFound.Add([pscustomobject]@{
                    Path = $_.FullName
                    Name = $_.Name
                    Extension = $_.Extension
                    Length = $_.Length
                    LastWriteTime = $_.LastWriteTime
                    IsInstallImage = ($_.Name -ieq 'install.wim' -or $_.Name -ieq 'install.esd')
                })
            }
    } catch {
        Add-WarningLine "Image search skipped files in ${Directory}: $($_.Exception.Message)"
    }

    if ($Depth -ge $MaxDepth) {
        return
    }

    try {
        Get-ChildItem -LiteralPath $Directory -Directory -Force -ErrorAction Stop |
            Where-Object { -not (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) } |
            ForEach-Object {
                Search-ImageFilesLimited -Directory $_.FullName -Depth ($Depth + 1) -MaxDepth $MaxDepth
            }
    } catch {
        Add-WarningLine "Image search skipped directories in ${Directory}: $($_.Exception.Message)"
    }
}

function Invoke-DismGetWimInfo {
    param([string]$WimPath)

    Add-Line ''
    Add-Line "WIM: $WimPath"
    Add-Line "Command: dism /Get-WimInfo /WimFile:`"$WimPath`""

    try {
        $output = & dism.exe /Get-WimInfo "/WimFile:$WimPath" 2>&1
        $exitCode = $LASTEXITCODE
        Add-Line "ExitCode: $exitCode"
        foreach ($line in $output) {
            Add-Line ($line | Out-String).TrimEnd()
        }
        if ($exitCode -ne 0) {
            Add-WarningLine "DISM /Get-WimInfo failed for $WimPath with exit code $exitCode."
        }
    } catch {
        Add-Line "ERROR: $($_.Exception.Message)"
        Add-WarningLine "DISM /Get-WimInfo failed for ${WimPath}: $($_.Exception.Message)"
    }
}

$outputParent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputParent) -and -not (Test-Path -LiteralPath $outputParent)) {
    throw "OutputPath parent directory does not exist: $outputParent"
}

$specifiedRoot = Normalize-DriveRoot -Drive $UsbDrive

$driveTypeMap = @{
    0 = 'Unknown'
    1 = 'NoRootDirectory'
    2 = 'Removable'
    3 = 'LocalDisk'
    4 = 'Network'
    5 = 'CDROM'
    6 = 'RAMDisk'
}

$volumes = @()
try {
    $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
        Sort-Object DeviceID |
        ForEach-Object {
            [pscustomobject]@{
                DeviceID = $_.DeviceID
                Root = "$($_.DeviceID)\"
                VolumeName = $_.VolumeName
                FileSystem = $_.FileSystem
                Size = $_.Size
                FreeSpace = $_.FreeSpace
                DriveType = if ($driveTypeMap.ContainsKey([int]$_.DriveType)) { $driveTypeMap[[int]$_.DriveType] } else { $_.DriveType }
                Accessible = (Test-Path -LiteralPath "$($_.DeviceID)\")
            }
        }
} catch {
    Add-WarningLine "Failed to enumerate volumes: $($_.Exception.Message)"
}

$scanRoots = @()
if ($specifiedRoot) {
    $scanRoots = @($specifiedRoot)
    if (-not (Test-Path -LiteralPath $specifiedRoot)) {
        Add-WarningLine "Specified UsbDrive is not accessible: $specifiedRoot"
    }
} else {
    $scanRoots = $volumes |
        Where-Object { $_.Accessible } |
        ForEach-Object { $_.Root }
}

$allAccessibleRoots = $volumes |
    Where-Object { $_.Accessible } |
    ForEach-Object { $_.Root }

$windowsMarkers = @('setup.exe', 'boot', 'efi', 'sources\boot.wim')
$ulseeMarkers = @('Autounattend.xml', 'deploy.bat', 'diskpart-uefi.txt', 'unattend.xml', 'Images\install.wim')
$candidateRoots = New-Object System.Collections.Generic.List[object]

foreach ($root in $scanRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
        continue
    }

    $windowsHits = @($windowsMarkers | Where-Object { Test-DeployPath -Root $root -RelativePath $_ })
    $ulseeHits = @($ulseeMarkers | Where-Object { Test-DeployPath -Root $root -RelativePath $_ })

    if ($specifiedRoot -or $windowsHits.Count -gt 0 -or $ulseeHits.Count -gt 0) {
        [void]$candidateRoots.Add([pscustomobject]@{
            Root = $root
            WindowsHits = $windowsHits
            UlseeHits = $ulseeHits
            LooksLikeWindowsUsb = ($windowsHits.Count -eq $windowsMarkers.Count)
            LooksLikeUlseeDeploy = ($ulseeHits.Count -eq $ulseeMarkers.Count)
        })
    }
}

Add-Section 'Summary'
Add-Line "Report time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
Add-Line "Computer name: $env:COMPUTERNAME"
Add-Line "Current user: $env:USERDOMAIN\$env:USERNAME"
Add-Line "PowerShell version: $($PSVersionTable.PSVersion)"
Add-Line "UsbDrive parameter: $(if ($UsbDrive) { $UsbDrive } else { '<not specified; scanning all accessible drive letters>' })"
Add-Line "OutputPath: $OutputPath"
Add-Line "IncludeHash: $($IncludeHash.IsPresent)"
Add-Line 'Safety: this script is read-only except for writing this TXT report.'
Add-Line 'Safety: it does not run deploy.bat, diskpart, DISM Apply-Image, bcdboot, wpeutil, format, clean, or copy image files.'
Add-Line 'Safety: the only DISM command allowed by this script is dism /Get-WimInfo.'

Add-Section 'Volumes'
if ($volumes.Count -eq 0) {
    Add-Line "[$script:StatusWarning] No volumes were enumerated."
} else {
    foreach ($volume in $volumes) {
        Add-Line ("Drive: {0} | Label: {1} | FS: {2} | Size: {3} | Free: {4} | DriveType: {5} | Accessible: {6}" -f `
            $volume.DeviceID, $volume.VolumeName, $volume.FileSystem, (Format-ByteSize -Bytes $volume.Size), (Format-ByteSize -Bytes $volume.FreeSpace), $volume.DriveType, $volume.Accessible)
    }
}

Add-Section 'Windows USB Candidates'
if ($candidateRoots.Count -eq 0) {
    Add-Line "[$script:StatusWarning] No Windows USB or ULSEE deploy candidates were found."
    Add-WarningLine 'No Windows USB or ULSEE deploy candidates were found.'
} else {
    foreach ($candidate in $candidateRoots) {
        Add-Line ''
        Add-Line "Root: $($candidate.Root)"
        Add-Line "Looks like Windows install USB: $($candidate.LooksLikeWindowsUsb)"
        foreach ($marker in $windowsMarkers) {
            Add-ContainsCheck -Label "$($candidate.Root)$marker" -Passed (Test-DeployPath -Root $candidate.Root -RelativePath $marker) -WarningWhenFailed $true
        }
    }
}

Add-Section 'ULSEE Deploy Kit Check'
$deployCheckFiles = @(
    'Autounattend.xml',
    'deploy.bat',
    'diskpart-uefi.txt',
    'unattend.xml',
    'Images\install.wim',
    'Windows\Setup\Scripts\SetupComplete.cmd',
    'sources\boot.wim',
    'sources\install.wim',
    'sources\install.esd'
)

foreach ($candidate in $candidateRoots) {
    Add-Line ''
    Add-Line "Root: $($candidate.Root)"
    Add-Line "Looks like ULSEE deploy disk: $($candidate.LooksLikeUlseeDeploy)"
    foreach ($relativePath in $deployCheckFiles) {
        Add-Line (Get-FileReportLine -Root $candidate.Root -RelativePath $relativePath)
    }

    if ((Test-DeployPath -Root $candidate.Root -RelativePath 'sources\install.wim') -or (Test-DeployPath -Root $candidate.Root -RelativePath 'sources\install.esd')) {
        $message = "Notice for $($candidate.Root): this deployment kit does not rely on sources\install.wim or sources\install.esd; actual deployment uses Images\install.wim."
        Add-Line "[$script:StatusWarning] $message"
        Add-WarningLine $message
    }
}

Add-Section 'Image Files Found'
Add-Line 'Search scope: all accessible drive letters.'
Add-Line 'Search depth: root plus up to 4 directory levels per drive.'
foreach ($root in $allAccessibleRoots) {
    Search-ImageFilesLimited -Directory $root -Depth 0 -MaxDepth 4
}

$uniqueImages = $ImageFilesFound |
    Sort-Object Path -Unique

if (-not $uniqueImages -or @($uniqueImages).Count -eq 0) {
    Add-Line "[$script:StatusWarning] No WIM/ESD/SWM image files found within the search depth."
} else {
    foreach ($image in $uniqueImages) {
        $mark = if ($image.IsInstallImage) { ' [IMPORTANT: install image filename]' } else { '' }
        $line = "{0}{1} | Size: {2} | Modified: {3}" -f $image.Path, $mark, (Format-ByteSize -Bytes $image.Length), $image.LastWriteTime
        if ($IncludeHash) {
            try {
                $hash = Get-FileHash -LiteralPath $image.Path -Algorithm SHA256 -ErrorAction Stop
                $line = "$line | SHA256: $($hash.Hash)"
            } catch {
                $line = "$line | SHA256: ERROR: $($_.Exception.Message)"
                Add-WarningLine "Failed to hash $($image.Path): $($_.Exception.Message)"
            }
        }
        Add-Line $line
    }
}

Add-Section 'DISM WimInfo'
$wimInfoTargets = New-Object System.Collections.Generic.HashSet[string]
foreach ($candidate in $candidateRoots) {
    $candidateWim = Join-RootPath -Root $candidate.Root -RelativePath 'Images\install.wim'
    if (Test-Path -LiteralPath $candidateWim -PathType Leaf) {
        [void]$wimInfoTargets.Add((Get-Item -LiteralPath $candidateWim).FullName)
    }
}
foreach ($image in $uniqueImages) {
    if ($image.Name -ieq 'install.wim') {
        [void]$wimInfoTargets.Add($image.Path)
    }
}

if ($wimInfoTargets.Count -eq 0) {
    Add-Line "[$script:StatusWarning] No install.wim targets found for DISM /Get-WimInfo."
} else {
    foreach ($target in $wimInfoTargets) {
        Invoke-DismGetWimInfo -WimPath $target
    }
}

Add-Section 'Script/XML Validation'
foreach ($candidate in $candidateRoots) {
    Add-Line ''
    Add-Line "Root: $($candidate.Root)"

    $autounattendPath = Join-RootPath -Root $candidate.Root -RelativePath 'Autounattend.xml'
    if (Test-Path -LiteralPath $autounattendPath -PathType Leaf) {
        $content = Get-TextFileContent -Path $autounattendPath
        $safeContent = Redact-XmlPasswordValues -Text $content
        Add-ContainsCheck -Label 'Autounattend.xml contains RunSynchronous' -Passed ($safeContent -match '(?i)RunSynchronous')
        Add-ContainsCheck -Label 'Autounattend.xml contains deploy.bat' -Passed ($safeContent -match '(?i)deploy\.bat')
        Add-ContainsCheck -Label 'Autounattend.xml contains /auto' -Passed ($safeContent -match '(?i)/auto')
        Add-ContainsCheck -Label 'Autounattend.xml contains %configsetroot%' -Passed ($safeContent -match '(?i)%configsetroot%')
    } else {
        Add-Line "[$script:StatusMissing] Autounattend.xml validation skipped because file is missing."
    }

    $deployPath = Join-RootPath -Root $candidate.Root -RelativePath 'deploy.bat'
    if (Test-Path -LiteralPath $deployPath -PathType Leaf) {
        $content = Get-TextFileContent -Path $deployPath
        Add-ContainsCheck -Label 'deploy.bat contains %~dp0' -Passed ($content -like '*%~dp0*')
        Add-ContainsCheck -Label 'deploy.bat contains Images\install.wim' -Passed ($content -match '(?i)Images\\install\.wim')
        Add-ContainsCheck -Label 'deploy.bat contains diskpart-uefi.txt' -Passed ($content -match '(?i)diskpart-uefi\.txt')
        Add-ContainsCheck -Label 'deploy.bat contains /Apply-Image' -Passed ($content -match '(?i)/Apply-Image')
        Add-ContainsCheck -Label 'deploy.bat contains /ApplyDir:W:' -Passed ($content -match '(?i)/ApplyDir:W:\\')
        Add-ContainsCheck -Label 'deploy.bat contains bcdboot W:\Windows /s S: /f UEFI' -Passed ($content -match '(?i)bcdboot\s+W:\\Windows\s+/s\s+S:\s+/f\s+UEFI')
    } else {
        Add-Line "[$script:StatusMissing] deploy.bat validation skipped because file is missing."
    }

    $diskpartPath = Join-RootPath -Root $candidate.Root -RelativePath 'diskpart-uefi.txt'
    if (Test-Path -LiteralPath $diskpartPath -PathType Leaf) {
        $content = Get-TextFileContent -Path $diskpartPath
        Add-ContainsCheck -Label 'diskpart-uefi.txt contains select disk 0' -Passed ($content -match '(?im)^\s*select\s+disk\s+0\s*$')
        Add-ContainsCheck -Label 'diskpart-uefi.txt contains clean' -Passed ($content -match '(?im)^\s*clean\s*$')
        Add-ContainsCheck -Label 'diskpart-uefi.txt contains convert gpt' -Passed ($content -match '(?im)^\s*convert\s+gpt\s*$')
        Add-ContainsCheck -Label 'diskpart-uefi.txt contains assign letter=S' -Passed ($content -match '(?im)^\s*assign\s+letter=S\s*$')
        Add-ContainsCheck -Label 'diskpart-uefi.txt contains assign letter=W' -Passed ($content -match '(?im)^\s*assign\s+letter=W\s*$')
    } else {
        Add-Line "[$script:StatusMissing] diskpart-uefi.txt validation skipped because file is missing."
    }

    $unattendPath = Join-RootPath -Root $candidate.Root -RelativePath 'unattend.xml'
    if (Test-Path -LiteralPath $unattendPath -PathType Leaf) {
        $content = Get-TextFileContent -Path $unattendPath
        $safeContent = Redact-XmlPasswordValues -Text $content
        Add-ContainsCheck -Label 'unattend.xml contains AutoLogon' -Passed ($safeContent -match '(?i)AutoLogon')
        Add-ContainsCheck -Label 'unattend.xml Username is ulsee' -Passed ($safeContent -match '(?is)<Username>\s*ulsee\s*</Username>')
        Add-ContainsCheck -Label 'unattend.xml contains SkipMachineOOBE' -Passed ($safeContent -match '(?i)SkipMachineOOBE')
        Add-ContainsCheck -Label 'unattend.xml contains SkipUserOOBE' -Passed ($safeContent -match '(?i)SkipUserOOBE')
        Add-ContainsCheck -Label 'unattend.xml does not contain LocalAccounts' -Passed ($safeContent -notmatch '(?i)LocalAccounts') -WarningWhenFailed $true
        Add-ContainsCheck -Label 'unattend.xml does not contain Microsoft-Windows-UnattendedJoin' -Passed ($safeContent -notmatch '(?i)Microsoft-Windows-UnattendedJoin') -WarningWhenFailed $true
        if ($safeContent -match '(?is)<Password\b[^>]*>.*?<Value>\*\*\*REDACTED\*\*\*</Value>.*?</Password>') {
            Add-Line 'Sensitive XML password display: <Value>***REDACTED***</Value>'
        }
    } else {
        Add-Line "[$script:StatusMissing] unattend.xml validation skipped because file is missing."
    }
}

Add-Section 'Warnings'
if ($Warnings.Count -eq 0) {
    Add-Line 'No warnings collected.'
} else {
    foreach ($warning in ($Warnings | Sort-Object -Unique)) {
        Add-Line "[$script:StatusWarning] $warning"
    }
}

Add-Section 'Recommended Next Steps'
Add-Line '1. Confirm the intended Windows installation USB is listed as a Windows USB candidate.'
Add-Line '2. Confirm the intended ULSEE deploy disk has Autounattend.xml, deploy.bat, diskpart-uefi.txt, unattend.xml, and Images\install.wim.'
Add-Line '3. If sources\install.wim or sources\install.esd exists, remember this kit does not rely on it; deployment uses Images\install.wim.'
Add-Line '4. Review DISM /Get-WimInfo output for the expected Windows image index and edition.'
Add-Line "5. If anything is marked $script:StatusMissing or $script:StatusWarning, fix the USB content before booting a target computer."
Add-Line '6. Send this USB_DEPLOY_DIAG_*.txt report to ChatGPT for analysis if you want a second check.'

Set-Content -LiteralPath $OutputPath -Value $Report -Encoding UTF8
Write-Host "Report written to: $OutputPath"
