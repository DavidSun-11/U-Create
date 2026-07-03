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
$DismWimInfoResults = @{}
$StatusPass = ('{0}{1}' -f [char]0x901A, [char]0x8FC7)
$StatusMissing = ('{0}{1}' -f [char]0x7F3A, [char]0x5931)
$StatusWarning = ('{0}{1}' -f [char]0x8B66, [char]0x544A)
$LabelCurrentState = ('{0}{1}{2}{3}' -f [char]0x5F53, [char]0x524D, [char]0x72B6, [char]0x6001)
$LabelReason = ('{0}{1}' -f [char]0x539F, [char]0x56E0)
$LabelRecommendation = ('{0}{1}' -f [char]0x5EFA, [char]0x8BAE)

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

function Get-PathReportLine {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    $path = Join-RootPath -Root $Root -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        return "[$script:StatusMissing] $RelativePath | Path: $path"
    }

    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.PSIsContainer) {
            return "[$script:StatusPass] $RelativePath | Type: Directory | Modified: $($item.LastWriteTime) | Path: $($item.FullName)"
        }

        return "[$script:StatusPass] $RelativePath | Type: File | Size: $(Format-ByteSize -Bytes $item.Length) | Modified: $($item.LastWriteTime) | Path: $($item.FullName)"
    } catch {
        Add-WarningLine "Failed to inspect ${path}: $($_.Exception.Message)"
        return "[$script:StatusWarning] $RelativePath | Path: $path | Error: $($_.Exception.Message)"
    }
}

function Get-FileLengthOrNull {
    param([string]$Path)

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        }
    } catch {
        Add-WarningLine "Failed to get file length for ${Path}: $($_.Exception.Message)"
    }
    return $null
}

function Test-ValidImageFile {
    param([string]$Path)

    $length = Get-FileLengthOrNull -Path $Path
    return ($null -ne $length -and $length -gt 0)
}

function Get-PreferredDeployImage {
    param([string]$Root)

    $imagesWimPath = Join-RootPath -Root $Root -RelativePath 'Images\install.wim'
    $sourcesWimPath = Join-RootPath -Root $Root -RelativePath 'sources\install.wim'

    if (Test-ValidImageFile -Path $imagesWimPath) {
        return [pscustomobject]@{
            RelativePath = 'Images\install.wim'
            Path = $imagesWimPath
            Source = 'Images'
            Exists = $true
        }
    }

    if (Test-Path -LiteralPath $imagesWimPath -PathType Leaf) {
        Add-WarningLine "Images\install.wim is 0 bytes and will be ignored by deploy.bat"
    }

    if (Test-ValidImageFile -Path $sourcesWimPath) {
        return [pscustomobject]@{
            RelativePath = 'sources\install.wim'
            Path = $sourcesWimPath
            Source = 'sources'
            Exists = $true
        }
    }

    return [pscustomobject]@{
        RelativePath = '<none>'
        Path = '<none>'
        Source = '<none>'
        Exists = $false
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

function Get-DeployScriptBehavior {
    param([string]$DeployPath)

    $content = $null
    if (Test-Path -LiteralPath $DeployPath -PathType Leaf) {
        $content = Get-TextFileContent -Path $DeployPath
    }

    $applyLine = $null
    $imageFileExpression = $null
    $imageFileUsesVariable = $false
    $imageFileUsesFixedDrive = $false
    if ($content) {
        $applyLine = ($content -split "`r?`n" | Where-Object { $_ -match '(?i)dism\s+/Apply-Image' } | Select-Object -First 1)
        if ($applyLine -and $applyLine -match '(?i)/ImageFile:"?([^"\s]+)') {
            $imageFileExpression = $Matches[1]
            $imageFileUsesVariable = ($imageFileExpression -match '%[^%]+%')
            $imageFileUsesFixedDrive = ($imageFileExpression -match '^[A-Za-z]:\\')
        }
    }

    $fixedDrivePattern = '(?i)(ImageFile:"?[A-Z]:\\|diskpart\s+/s\s+"?[A-Z]:\\|copy\s+/Y\s+"?[A-Z]:\\|xcopy\s+"?[A-Z]:\\)'

    return [pscustomobject]@{
        Exists = [bool]$content
        UsesScriptRoot = ($content -like '*%~dp0*')
        HasFixedDriveAssumption = ($content -match $fixedDrivePattern)
        ChecksImagesInstallWim = ($content -match '(?i)Images\\install\.wim')
        ChecksSourcesInstallWim = ($content -match '(?i)sources\\install\.wim')
        DismApplyLine = $applyLine
        ImageFileExpression = $imageFileExpression
        ImageFileUsesVariable = $imageFileUsesVariable
        ImageFileUsesFixedDrive = $imageFileUsesFixedDrive
        ApplyDirIsW = ($content -match '(?i)/ApplyDir:W:\\')
        BcdbootIsUefiWS = ($content -match '(?i)bcdboot\s+W:\\Windows\s+/s\s+S:\s+/f\s+UEFI')
        SupportsAutoMode = ($content -match '(?i)/auto')
        AutoModeAvoidsPause = (($content -match '(?i)if\s+not\s+"%AUTO%"\s*==\s*"1"\s+pause') -or ($content -match '(?i)if\s+"%AUTO%"\s*==\s*"1"'))
        UsesImagesInstallWim = ($content -match '(?i)Images\\install\.wim')
        UsesSourcesInstallWim = ($content -match '(?i)sources\\install\.wim')
        OnlyUsesImagesInstallWim = (($content -match '(?i)Images\\install\.wim') -and ($content -notmatch '(?i)sources\\install\.wim'))
        SupportsSourcesFallback = (($content -match '(?i)Images\\install\.wim') -and ($content -match '(?i)sources\\install\.wim') -and ($content -match '(?i)set\s+"WIM='))
    }
}

function Get-AutounattendState {
    param([string]$Root)

    $autounattendPath = Join-RootPath -Root $Root -RelativePath 'Autounattend.xml'
    $offPath = Join-RootPath -Root $Root -RelativePath 'Autounattend.off'
    $content = $null
    if (Test-Path -LiteralPath $autounattendPath -PathType Leaf) {
        $content = Get-TextFileContent -Path $autounattendPath
        $content = Redact-XmlPasswordValues -Text $content
    }

    return [pscustomobject]@{
        AutounattendExists = (Test-Path -LiteralPath $autounattendPath -PathType Leaf)
        AutounattendOffExists = (Test-Path -LiteralPath $offPath -PathType Leaf)
        Path = $autounattendPath
        OffPath = $offPath
        HasRunSynchronous = ($content -match '(?i)RunSynchronous')
        HasConfigSetRoot = ($content -match '(?i)%configsetroot%')
        HasDeployBat = ($content -match '(?i)deploy\.bat')
        HasAuto = ($content -match '(?i)/auto')
    }
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
    $result = [pscustomobject]@{
        Path = $WimPath
        Attempted = $true
        ExitCode = $null
        Success = $false
        Error = $null
    }

    try {
        $output = & dism.exe /Get-WimInfo "/WimFile:$WimPath" 2>&1
        $exitCode = $LASTEXITCODE
        $result.ExitCode = $exitCode
        $result.Success = ($exitCode -eq 0)
        Add-Line "ExitCode: $exitCode"
        foreach ($line in $output) {
            Add-Line ($line | Out-String).TrimEnd()
        }
        if ($exitCode -ne 0) {
            Add-WarningLine "DISM /Get-WimInfo failed for $WimPath with exit code $exitCode."
        }
    } catch {
        $result.Error = $_.Exception.Message
        Add-Line "ERROR: $($_.Exception.Message)"
        Add-WarningLine "DISM /Get-WimInfo failed for ${WimPath}: $($_.Exception.Message)"
    }

    $script:DismWimInfoResults[$WimPath.ToLowerInvariant()] = $result
    return $result
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
$ulseeToolMarkers = @('Autounattend.xml', 'deploy.bat', 'diskpart-uefi.txt', 'unattend.xml')
$candidateRoots = New-Object System.Collections.Generic.List[object]

foreach ($root in $scanRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
        continue
    }

    $windowsHits = @($windowsMarkers | Where-Object { Test-DeployPath -Root $root -RelativePath $_ })
    $ulseeHits = @($ulseeToolMarkers | Where-Object { Test-DeployPath -Root $root -RelativePath $_ })
    $preferredDeployImage = Get-PreferredDeployImage -Root $root

    if ($specifiedRoot -or $windowsHits.Count -gt 0 -or $ulseeHits.Count -gt 0 -or $preferredDeployImage.Exists) {
        [void]$candidateRoots.Add([pscustomobject]@{
            Root = $root
            WindowsHits = $windowsHits
            UlseeHits = $ulseeHits
            LooksLikeWindowsUsb = ($windowsHits.Count -eq $windowsMarkers.Count)
            HasDeployImage = $preferredDeployImage.Exists
            DeployImagePath = $preferredDeployImage.Path
            LooksLikeUlseeDeploy = (($ulseeHits.Count -eq $ulseeToolMarkers.Count) -and $preferredDeployImage.Exists)
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

Add-Section 'USB Root Tree'
$rootTreeItems = @(
    'boot',
    'efi',
    'sources',
    'sources\boot.wim',
    'sources\install.wim',
    'sources\install.esd',
    'Autounattend.xml',
    'deploy.bat',
    'diskpart-uefi.txt',
    'unattend.xml',
    'Images',
    'Images\install.wim',
    'Windows\Setup\Scripts\SetupComplete.cmd'
)

if ($candidateRoots.Count -eq 0) {
    Add-Line "[$script:StatusWarning] No candidate roots to inspect."
} else {
    foreach ($candidate in $candidateRoots) {
        Add-Line ''
        Add-Line "Root: $($candidate.Root)"
        foreach ($relativePath in $rootTreeItems) {
            Add-Line (Get-PathReportLine -Root $candidate.Root -RelativePath $relativePath)
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

    $imagesWimPath = Join-RootPath -Root $candidate.Root -RelativePath 'Images\install.wim'
    $imagesWimLength = Get-FileLengthOrNull -Path $imagesWimPath
    if ((Test-Path -LiteralPath $imagesWimPath -PathType Leaf) -and $imagesWimLength -eq 0) {
        Add-Line "[$script:StatusWarning] Images\install.wim is 0 bytes and will be ignored by deploy.bat"
    }
    Add-Line "Deploy image available by current priority: $($candidate.HasDeployImage)"
    Add-Line "Deploy image selected by current priority: $($candidate.DeployImagePath)"

    if ((Test-DeployPath -Root $candidate.Root -RelativePath 'sources\install.wim') -or (Test-DeployPath -Root $candidate.Root -RelativePath 'sources\install.esd')) {
        Add-Line "Notice for $($candidate.Root): deploy.bat priority is Images\install.wim first, then sources\install.wim."
    }
}

Add-Section 'Deploy Script Behavior'
if ($candidateRoots.Count -eq 0) {
    Add-Line "[$script:StatusWarning] No candidate roots to inspect."
} else {
    foreach ($candidate in $candidateRoots) {
        Add-Line ''
        Add-Line "Root: $($candidate.Root)"
        $deployPath = Join-RootPath -Root $candidate.Root -RelativePath 'deploy.bat'
        $behavior = Get-DeployScriptBehavior -DeployPath $deployPath
        if (-not $behavior.Exists) {
            Add-Line "[$script:StatusMissing] deploy.bat is missing; behavior cannot be analyzed."
            continue
        }

        Add-ContainsCheck -Label 'deploy.bat uses %~dp0 script root' -Passed $behavior.UsesScriptRoot
        Add-ContainsCheck -Label 'deploy.bat does not assume a fixed USB drive letter' -Passed (-not $behavior.HasFixedDriveAssumption) -WarningWhenFailed $true
        Add-ContainsCheck -Label 'deploy.bat checks Images\install.wim' -Passed $behavior.ChecksImagesInstallWim
        Add-ContainsCheck -Label 'deploy.bat checks sources\install.wim' -Passed $behavior.ChecksSourcesInstallWim -WarningWhenFailed $true
        Add-ContainsCheck -Label 'deploy.bat supports sources\install.wim fallback' -Passed $behavior.SupportsSourcesFallback -WarningWhenFailed $true
        Add-Line "DISM Apply-Image line: $(if ($behavior.DismApplyLine) { $behavior.DismApplyLine.Trim() } else { '<not found>' })"
        Add-Line "DISM ImageFile expression: $(if ($behavior.ImageFileExpression) { $behavior.ImageFileExpression } else { '<not found>' })"
        Add-Line "DISM ImageFile uses variable: $($behavior.ImageFileUsesVariable)"
        Add-Line "DISM ImageFile uses fixed drive path: $($behavior.ImageFileUsesFixedDrive)"
        Add-ContainsCheck -Label 'DISM ApplyDir is W:\' -Passed $behavior.ApplyDirIsW
        Add-ContainsCheck -Label 'bcdboot uses W:\Windows /s S: /f UEFI' -Passed $behavior.BcdbootIsUefiWS
        Add-ContainsCheck -Label 'deploy.bat supports /auto mode' -Passed $behavior.SupportsAutoMode
        Add-ContainsCheck -Label '/auto mode is designed to avoid pause prompts' -Passed $behavior.AutoModeAvoidsPause
        Add-Line "deploy.bat only recognizes Images\install.wim: $($behavior.OnlyUsesImagesInstallWim)"
    }
}

Add-Section 'Autounattend Risk State'
if ($candidateRoots.Count -eq 0) {
    Add-Line "[$script:StatusWarning] No candidate roots to inspect."
} else {
    foreach ($candidate in $candidateRoots) {
        Add-Line ''
        Add-Line "Root: $($candidate.Root)"
        $autoState = Get-AutounattendState -Root $candidate.Root
        Add-Line "Autounattend.xml exists: $($autoState.AutounattendExists)"
        Add-Line "Autounattend.off exists: $($autoState.AutounattendOffExists)"
        if ($autoState.AutounattendExists) {
            Add-Line "AUTO DEPLOY ENABLED: booting this USB may automatically erase Disk 0"
            Add-WarningLine "AUTO DEPLOY ENABLED on $($candidate.Root): booting this USB may automatically erase Disk 0."
        } elseif ($autoState.AutounattendOffExists) {
            Add-Line 'AUTO DEPLOY DISABLED'
        } else {
            Add-Line 'AUTO DEPLOY UNKNOWN: neither Autounattend.xml nor Autounattend.off was found.'
        }
        Add-ContainsCheck -Label 'Autounattend.xml contains RunSynchronous' -Passed $autoState.HasRunSynchronous -WarningWhenFailed $true
        Add-ContainsCheck -Label 'Autounattend.xml contains %configsetroot%' -Passed $autoState.HasConfigSetRoot -WarningWhenFailed $true
        Add-ContainsCheck -Label 'Autounattend.xml contains deploy.bat' -Passed $autoState.HasDeployBat -WarningWhenFailed $true
        Add-ContainsCheck -Label 'Autounattend.xml contains /auto' -Passed $autoState.HasAuto -WarningWhenFailed $true
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
    $candidateSourcesWim = Join-RootPath -Root $candidate.Root -RelativePath 'sources\install.wim'
    if (Test-Path -LiteralPath $candidateSourcesWim -PathType Leaf) {
        [void]$wimInfoTargets.Add((Get-Item -LiteralPath $candidateSourcesWim).FullName)
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
        [void](Invoke-DismGetWimInfo -WimPath $target)
    }
}

foreach ($candidate in $candidateRoots) {
    $candidateSourcesWim = Join-RootPath -Root $candidate.Root -RelativePath 'sources\install.wim'
    if (Test-Path -LiteralPath $candidateSourcesWim -PathType Leaf) {
        $sourcesWimFull = (Get-Item -LiteralPath $candidateSourcesWim).FullName
        $sourcesDism = $script:DismWimInfoResults[$sourcesWimFull.ToLowerInvariant()]
        if ($sourcesDism -and $sourcesDism.Success) {
            Add-Line "[$script:StatusPass] sources\install.wim can be used as deployment image: $sourcesWimFull"
        }
    }
}

Add-Section 'Deployment Decision Summary'
if ($candidateRoots.Count -eq 0) {
    Add-Line "$script:LabelCurrentState / Current state: NO USB CANDIDATE FOUND"
    Add-Line "$script:LabelReason / Reason: no accessible drive matched Windows USB or U-Create deploy markers."
    Add-Line "$script:LabelRecommendation / Recommendation: run again with -UsbDrive D: using the actual USB drive letter."
} else {
    foreach ($candidate in $candidateRoots) {
        Add-Line ''
        Add-Line "Root: $($candidate.Root)"

        $imagesWimPath = Join-RootPath -Root $candidate.Root -RelativePath 'Images\install.wim'
        $sourcesWimPath = Join-RootPath -Root $candidate.Root -RelativePath 'sources\install.wim'
        $sourcesEsdPath = Join-RootPath -Root $candidate.Root -RelativePath 'sources\install.esd'
        $deployPath = Join-RootPath -Root $candidate.Root -RelativePath 'deploy.bat'
        $behavior = Get-DeployScriptBehavior -DeployPath $deployPath
        $autoState = Get-AutounattendState -Root $candidate.Root

        $imagesWimExists = Test-Path -LiteralPath $imagesWimPath -PathType Leaf
        $imagesWimLength = Get-FileLengthOrNull -Path $imagesWimPath
        $imagesWimZeroBytes = ($imagesWimExists -and $imagesWimLength -eq 0)
        $imagesWimUsable = ($imagesWimExists -and $imagesWimLength -gt 0)
        $sourcesWimExists = Test-Path -LiteralPath $sourcesWimPath -PathType Leaf
        $sourcesWimUsable = Test-ValidImageFile -Path $sourcesWimPath
        $sourcesEsdExists = Test-Path -LiteralPath $sourcesEsdPath -PathType Leaf
        $preferredDeployImage = Get-PreferredDeployImage -Root $candidate.Root

        $sourcesDismStatus = 'not attempted or not present'
        if ($sourcesWimExists) {
            $sourcesWimFull = (Get-Item -LiteralPath $sourcesWimPath).FullName
            $sourcesDism = $script:DismWimInfoResults[$sourcesWimFull.ToLowerInvariant()]
            if ($sourcesDism) {
                $sourcesDismStatus = if ($sourcesDism.Success) { 'OK: DISM /Get-WimInfo recognized sources\install.wim' } else { "FAILED: DISM /Get-WimInfo exit code $($sourcesDism.ExitCode)" }
            }
        }

        $availableImages = New-Object System.Collections.Generic.List[string]
        if ($imagesWimExists) { [void]$availableImages.Add("Images\install.wim ($(Format-ByteSize -Bytes $imagesWimLength))") }
        if ($sourcesWimExists) { [void]$availableImages.Add('sources\install.wim') }
        if ($sourcesEsdExists) { [void]$availableImages.Add('sources\install.esd') }
        if ($availableImages.Count -eq 0) { [void]$availableImages.Add('<none found in expected USB locations>') }

        $resolvedDeployImage = $preferredDeployImage.Path
        if ($behavior.ImageFileExpression) {
            $imageFileExpressionResolved = $behavior.ImageFileExpression.Replace('%ROOT%', $candidate.Root)
        } else {
            $imageFileExpressionResolved = '<not found>'
        }

        $toolsCopied = (
            (Test-DeployPath -Root $candidate.Root -RelativePath 'Autounattend.xml') -and
            (Test-DeployPath -Root $candidate.Root -RelativePath 'deploy.bat') -and
            (Test-DeployPath -Root $candidate.Root -RelativePath 'diskpart-uefi.txt') -and
            (Test-DeployPath -Root $candidate.Root -RelativePath 'unattend.xml')
        )

        $pathMatchesDeployBat = (($behavior.SupportsSourcesFallback -and $preferredDeployImage.Exists) -or ($behavior.OnlyUsesImagesInstallWim -and $imagesWimUsable))
        $autoReady = ($autoState.AutounattendExists -and $autoState.HasRunSynchronous -and $autoState.HasConfigSetRoot -and $autoState.HasDeployBat -and $autoState.HasAuto)
        $deployReady = ($candidate.LooksLikeWindowsUsb -and $toolsCopied -and $pathMatchesDeployBat -and $behavior.ApplyDirIsW -and $behavior.BcdbootIsUefiWS)

        Add-Line "Windows boot USB: $($candidate.LooksLikeWindowsUsb)"
        Add-Line "U-Create deploy tools copied: $toolsCopied"
        Add-Line "Available image location(s): $($availableImages -join '; ')"
        Add-Line "Images\install.wim exists: $imagesWimExists"
        Add-Line "Images\install.wim is 0 bytes: $imagesWimZeroBytes"
        Add-Line "sources\install.wim exists: $sourcesWimExists"
        Add-Line "sources\install.wim is non-empty: $sourcesWimUsable"
        Add-Line "sources\install.wim DISM /Get-WimInfo: $sourcesDismStatus"
        Add-Line "sources\install.esd exists: $sourcesEsdExists"
        Add-Line "deploy.bat actual ImageFile expression: $(if ($behavior.ImageFileExpression) { $behavior.ImageFileExpression } else { '<not found>' })"
        Add-Line "deploy.bat ImageFile expression resolved literally: $imageFileExpressionResolved"
        Add-Line "deploy.bat final selected image path by priority: $resolvedDeployImage"
        Add-Line "deploy.bat only recognizes Images\install.wim: $($behavior.OnlyUsesImagesInstallWim)"
        Add-Line "deploy.bat supports sources\install.wim fallback: $($behavior.SupportsSourcesFallback)"
        Add-Line "USB image location matches deploy.bat: $pathMatchesDeployBat"
        Add-Line "Autounattend auto deploy ready: $autoReady"

        if ($deployReady -and $autoReady) {
            Add-Line "$script:LabelCurrentState / Current state: CAN ENTER TEST DEPLOYMENT"
            Add-Line "$script:LabelReason / Reason: Autounattend.xml, deploy.bat, diskpart script, unattend.xml, Windows USB files, and a valid install.wim are present and match current deploy.bat behavior."
            Add-Line "$script:LabelRecommendation / Recommended next action: if this is the intended target workflow, boot a test machine only after confirming Disk 0 can be erased."
        } elseif ($autoState.AutounattendExists -and -not $pathMatchesDeployBat) {
            Add-Line "$script:LabelCurrentState / Current state: DO NOT BOOT FOR AUTO DEPLOY"
            Add-Line "$script:LabelReason / Reason: AUTO DEPLOY ENABLED but current image location does not match deploy.bat behavior."
            if ($sourcesWimExists -and -not $imagesWimUsable) {
                Add-Line "$script:LabelRecommendation / Recommended next action: verify deploy.bat on the USB includes sources\install.wim fallback and confirm sources\install.wim is non-empty and readable."
            } else {
                Add-Line "$script:LabelRecommendation / Recommended next action: disable Autounattend.xml before booting, then fix missing or zero-byte install.wim."
            }
        } elseif (-not $autoState.AutounattendExists) {
            Add-Line "$script:LabelCurrentState / Current state: AUTO DEPLOY NOT ENABLED"
            Add-Line "$script:LabelReason / Reason: Autounattend.xml is not present at USB root."
            Add-Line "$script:LabelRecommendation / Recommended next action: keep auto deploy disabled until ChatGPT confirms the USB image path and deploy.bat behavior match."
        } elseif (-not $candidate.LooksLikeWindowsUsb) {
            Add-Line "$script:LabelCurrentState / Current state: NOT READY"
            Add-Line "$script:LabelReason / Reason: this drive does not look like a complete Windows installation USB."
            Add-Line "$script:LabelRecommendation / Recommended next action: rebuild or verify the Windows 11 boot USB structure before deployment."
        } elseif (-not $toolsCopied) {
            Add-Line "$script:LabelCurrentState / Current state: NOT READY"
            Add-Line "$script:LabelReason / Reason: U-Create deployment files are missing from the USB root."
            Add-Line "$script:LabelRecommendation / Recommended next action: run copy-to-usb.ps1 or manually place the missing U-Create files."
        } elseif (-not $preferredDeployImage.Exists -and $sourcesWimExists) {
            Add-Line "$script:LabelCurrentState / Current state: NOT READY"
            Add-Line "$script:LabelReason / Reason: sources\install.wim exists but is empty or not readable as a non-empty file."
            Add-Line "$script:LabelRecommendation / Recommended next action: fix the install.wim file before enabling auto deployment."
        } else {
            Add-Line "$script:LabelCurrentState / Current state: NOT READY"
            Add-Line "$script:LabelReason / Reason: one or more required deployment conditions are missing or ambiguous."
            Add-Line "$script:LabelRecommendation / Recommended next action: review missing/warning lines in this report before enabling auto deployment."
        }
    }
}

Add-Section 'Recommended Next Action For ChatGPT'
if ($candidateRoots.Count -eq 0) {
    Add-Line "$script:LabelCurrentState / Current state: not enough USB evidence."
    Add-Line "$script:LabelRecommendation / Recommendation: run the script again with -UsbDrive <letter>: and send the new report."
} else {
    foreach ($candidate in $candidateRoots) {
        Add-Line ''
        Add-Line "Root: $($candidate.Root)"

        $imagesWimPath = Join-RootPath -Root $candidate.Root -RelativePath 'Images\install.wim'
        $sourcesWimPath = Join-RootPath -Root $candidate.Root -RelativePath 'sources\install.wim'
        $deployPath = Join-RootPath -Root $candidate.Root -RelativePath 'deploy.bat'
        $behavior = Get-DeployScriptBehavior -DeployPath $deployPath
        $autoState = Get-AutounattendState -Root $candidate.Root
        $imagesWimLength = Get-FileLengthOrNull -Path $imagesWimPath
        $imagesWimUsable = ((Test-Path -LiteralPath $imagesWimPath -PathType Leaf) -and $imagesWimLength -gt 0)
        $preferredDeployImage = Get-PreferredDeployImage -Root $candidate.Root
        $sourcesWimExists = Test-Path -LiteralPath $sourcesWimPath -PathType Leaf
        $toolsCopied = (
            (Test-DeployPath -Root $candidate.Root -RelativePath 'Autounattend.xml') -and
            (Test-DeployPath -Root $candidate.Root -RelativePath 'deploy.bat') -and
            (Test-DeployPath -Root $candidate.Root -RelativePath 'diskpart-uefi.txt') -and
            (Test-DeployPath -Root $candidate.Root -RelativePath 'unattend.xml')
        )
        $pathMatchesDeployBat = (($behavior.SupportsSourcesFallback -and $preferredDeployImage.Exists) -or ($behavior.OnlyUsesImagesInstallWim -and $imagesWimUsable))
        $autoReady = ($autoState.AutounattendExists -and $autoState.HasRunSynchronous -and $autoState.HasConfigSetRoot -and $autoState.HasDeployBat -and $autoState.HasAuto)

        if ($candidate.LooksLikeWindowsUsb -and $toolsCopied -and $pathMatchesDeployBat -and $autoReady) {
            Add-Line "$script:LabelCurrentState / Current state: can enter test deployment."
            Add-Line "$script:LabelReason / Reason: Autounattend.xml, deploy.bat, diskpart, unattend, and valid install.wim are present and matched."
            Add-Line "Selected deployment image: $($preferredDeployImage.Path)"
            Add-Line "$script:LabelRecommendation / Ask ChatGPT: confirm final safety checklist before booting a test machine."
        } elseif ($autoState.AutounattendExists -and $sourcesWimExists -and -not $preferredDeployImage.Exists) {
            Add-Line "$script:LabelCurrentState / Current state: do not start deployment."
            Add-Line "$script:LabelReason / Reason: an install.wim path exists but no valid non-empty deployment image was selected."
            Add-Line "$script:LabelRecommendation / Ask ChatGPT: inspect WIM validity and fix image placement before booting."
        } elseif ($autoState.AutounattendExists -and -not $pathMatchesDeployBat) {
            Add-Line "$script:LabelCurrentState / Current state: disable Autounattend.xml before booting."
            Add-Line "$script:LabelReason / Reason: automatic deployment is enabled but script/image matching is not confirmed."
            Add-Line "$script:LabelRecommendation / Ask ChatGPT: identify which missing item must be fixed before auto deployment."
        } elseif (-not $autoState.AutounattendExists) {
            Add-Line "$script:LabelCurrentState / Current state: auto deployment is disabled or not configured."
            Add-Line "$script:LabelReason / Reason: Autounattend.xml is missing from the USB root."
            Add-Line "$script:LabelRecommendation / Ask ChatGPT: confirm whether it is safe to enable Autounattend.xml after fixing image placement."
        } else {
            Add-Line "$script:LabelCurrentState / Current state: needs review before deployment."
            Add-Line "$script:LabelReason / Reason: this report found missing, ambiguous, or mismatched deployment evidence."
            Add-Line "$script:LabelRecommendation / Ask ChatGPT: read Deployment Decision Summary and recommend the next file operation. Do not boot target hardware yet."
        }
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
        Add-ContainsCheck -Label 'deploy.bat contains sources\install.wim' -Passed ($content -match '(?i)sources\\install\.wim')
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
Add-Line '2. Confirm the intended ULSEE deploy disk has Autounattend.xml, deploy.bat, diskpart-uefi.txt, unattend.xml, and a valid install.wim.'
Add-Line '3. Image priority is Images\install.wim first, then sources\install.wim.'
Add-Line '4. Review DISM /Get-WimInfo output for the expected Windows image index and edition.'
Add-Line "5. If anything is marked $script:StatusMissing or $script:StatusWarning, fix the USB content before booting a target computer."
Add-Line '6. Send this USB_DEPLOY_DIAG_*.txt report to ChatGPT for analysis if you want a second check.'

Set-Content -LiteralPath $OutputPath -Value $Report -Encoding UTF8
Write-Host "Report written to: $OutputPath"
