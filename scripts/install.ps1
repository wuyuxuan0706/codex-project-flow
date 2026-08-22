[CmdletBinding()]
param(
    [string]$Target = ".",
    [string]$ProjectName = "",
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateRoot = Split-Path -Parent $scriptRoot
$targetRoot = [System.IO.Path]::GetFullPath($Target)
$controlRootName = ".project-flow"
$manifestRelative = ".project-flow/manifest.json"
$backupRootName = ".project-flow-backup"
$validPolicies = @("seed_once", "merge_manual", "structured_manual", "replace_if_unmodified")
$validRenderModes = @("project_name", "project_name_json")

if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
    throw "Target directory does not exist: $targetRoot"
}
$targetItem = Get-Item -LiteralPath $targetRoot -Force
if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Target directory must not be a symbolic link, junction, or reparse point: $targetRoot"
}

function Test-SafeRelative([string]$RelativePath, [switch]$AllowControl) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        return $false
    }
    if ($RelativePath.Contains("\") -or $RelativePath -match "^[A-Za-z]:") {
        return $false
    }
    foreach ($character in $RelativePath.ToCharArray()) {
        if ([char]::IsControl($character)) { return $false }
    }
    $parts = $RelativePath.Split('/')
    if ($parts.Count -eq 0 -or @($parts | Where-Object { $_ -eq "" -or $_ -eq "." -or $_ -eq ".." }).Count -gt 0) {
        return $false
    }
    if (-not $AllowControl -and $parts[0] -in @($controlRootName, $backupRootName)) {
        return $false
    }
    return $true
}

function Assert-InTarget([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $prefix = $targetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (($full -ne $targetRoot) -and (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Refusing path outside target: $full"
    }
}

function Resolve-SafeTargetPath([string]$RelativePath, [switch]$AllowControl) {
    if (-not (Test-SafeRelative $RelativePath -AllowControl:$AllowControl)) {
        throw "Unsafe relative target path: $RelativePath"
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $targetRoot ($RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
    Assert-InTarget $full
    $current = $targetRoot
    foreach ($part in $RelativePath.Split('/')) {
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { break }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing target path through a symbolic link, junction, or reparse point: $current"
        }
    }
    return $full
}

function Ensure-SafeDirectory([string]$Directory) {
    $full = [System.IO.Path]::GetFullPath($Directory)
    Assert-InTarget $full
    if ($full -eq $targetRoot) { return }
    $prefix = $targetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $relative = $full.Substring($prefix.Length)
    $current = $targetRoot
    foreach ($part in $relative.Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            [System.IO.Directory]::CreateDirectory($current) | Out-Null
            continue
        }
        if (-not $item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Directory path is not a real directory: $current"
        }
    }
}

function Get-SafeFileState([string]$Path, [string]$Label) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if ($item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "$Label exists and is not a safe regular file: $Path"
    }
    return $true
}

function Resolve-SafeSource([string]$RelativePath) {
    if (-not (Test-SafeRelative $RelativePath -AllowControl)) {
        throw "Unsafe managed source path: $RelativePath"
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $templateRoot ($RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
    $prefix = $templateRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed source escapes plugin root: $RelativePath"
    }
    $current = $templateRoot
    foreach ($part in $RelativePath.Split('/')) {
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { throw "Managed source is missing: $RelativePath" }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Managed source path uses a symbolic link or reparse point: $RelativePath"
        }
    }
    $sourceItem = Get-Item -LiteralPath $full -Force
    if ($sourceItem.PSIsContainer) { throw "Managed source is not a regular file: $RelativePath" }
    return $full
}

function Read-NormalizedText([string]$Path, [string]$Label) {
    if (-not (Get-SafeFileState $Path $Label)) { throw "$Label is missing: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $offset = 3
    }
    try {
        $text = $utf8Strict.GetString($bytes, $offset, $bytes.Length - $offset)
    } catch {
        throw "$Label is not UTF-8 text: $($_.Exception.Message)"
    }
    return $text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Read-JsonFile([string]$Path, [string]$Label) {
    try {
        return (Read-NormalizedText $Path $Label) | ConvertFrom-Json
    } catch {
        throw "$Label is invalid JSON: $($_.Exception.Message)"
    }
}

function Get-TextHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $utf8NoBom.GetBytes($Text)
        return "sha256:" + ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Write-AtomicText([string]$Path, [string]$Text) {
    Assert-InTarget $Path
    Ensure-SafeDirectory (Split-Path -Parent $Path)
    $exists = Get-SafeFileState $Path "Destination"
    $temporary = "$Path.project-flow-tmp-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $utf8NoBom)
        if ($exists) {
            [System.IO.File]::Replace($temporary, $Path, $null)
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Render-Template([string]$Text, [string]$Mode) {
    if ($Mode -eq "project_name_json") {
        $jsonName = ConvertTo-Json -InputObject $ProjectName -Compress
        return $Text.Replace('"<PROJECT_NAME>"', $jsonName)
    }
    return $Text.Replace("<PROJECT_NAME>", $ProjectName)
}

if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    $ProjectName = Split-Path -Leaf $targetRoot
}
foreach ($character in $ProjectName.ToCharArray()) {
    if ([char]::IsControl($character)) {
        throw "ProjectName must not contain control characters."
    }
}

$versionPath = Join-Path $templateRoot "VERSION"
$workflowVersion = (Read-NormalizedText $versionPath "VERSION").Trim()
if ([string]::IsNullOrWhiteSpace($workflowVersion)) { throw "VERSION must contain one non-empty version." }
foreach ($character in $workflowVersion.ToCharArray()) {
    if ([char]::IsControl($character)) { throw "VERSION must not contain control characters." }
}

$managedPath = Join-Path $templateRoot "managed-files.json"
$managed = Read-JsonFile $managedPath "managed-files.json"
if ($managed.schema_version -ne 1 -or [string]$managed.workflow_version -ne $workflowVersion) {
    throw "managed-files.json schema or workflow_version does not match VERSION."
}
$rawEntries = @($managed.files)
if ($rawEntries.Count -eq 0) { throw "managed-files.json files must be a non-empty array." }

$entries = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($raw in $rawEntries) {
    $relative = [string]$raw.path
    $sourceRelative = [string]$raw.source
    if (-not (Test-SafeRelative $relative) -or -not (Test-SafeRelative $sourceRelative -AllowControl)) {
        throw "Unsafe managed path or source: $relative"
    }
    if ($seen.ContainsKey($relative)) { throw "Duplicate managed path: $relative" }
    $seen[$relative] = $true
    $policy = [string]$raw.policy
    $renderMode = [string]$raw.render
    if ($validPolicies -notcontains $policy) { throw "Unsupported policy for $relative" }
    if ($validRenderModes -notcontains $renderMode) { throw "Unsupported render mode for $relative" }
    $source = Resolve-SafeSource $sourceRelative
    $sourceText = Read-NormalizedText $source $sourceRelative
    $entries.Add([pscustomobject]@{
        Path = $relative
        Source = $sourceRelative
        Policy = $policy
        Render = $renderMode
        SourcePath = $source
        Rendered = (Render-Template $sourceText $renderMode)
    })
}
if (-not $seen.ContainsKey("docs/PROJECT_STATE.md")) { throw "docs/PROJECT_STATE.md must be managed." }
$stateEntry = @($entries | Where-Object { $_.Path -eq "docs/PROJECT_STATE.md" })[0]
if ($stateEntry.Policy -ne "seed_once") { throw "docs/PROJECT_STATE.md must use seed_once." }

$manifestPath = Resolve-SafeTargetPath $manifestRelative -AllowControl
$manifestExisted = Get-SafeFileState $manifestPath "Manifest"
$hadExistingManaged = $false
foreach ($entry in $entries) {
    $destination = Resolve-SafeTargetPath $entry.Path
    if (Get-SafeFileState $destination "Destination") { $hadExistingManaged = $true }
}

$legacyWithoutManifest = -not $Force -and -not $manifestExisted -and $hadExistingManaged
if ($legacyWithoutManifest -and -not $DryRun) {
    Write-Host "NOTICE Existing managed files were found without a manifest."
    Write-Host "NOTICE The files will keep normal non-force skip behavior, but the manifest will not be initialized."
    Write-Host "NOTICE Run the explicit upgrade with -AdoptFrom 0.2.0 to adopt this legacy installation."
}

$backupStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRelative = "$backupRootName/$backupStamp"
$backupRoot = Resolve-SafeTargetPath $backupRelative -AllowControl
$backupSuffix = 0
while (Test-Path -LiteralPath $backupRoot) {
    $backupSuffix++
    $backupRelative = "$backupRootName/$backupStamp-$backupSuffix"
    $backupRoot = Resolve-SafeTargetPath $backupRelative -AllowControl
}

$created = 0
$replaced = 0
$skipped = 0
$written = 0
$manifestBackedUp = $false
$manifestChanged = $false
$writeRecords = New-Object System.Collections.Generic.List[object]

function Backup-File([string]$Source, [string]$RelativePath) {
    $backup = Resolve-SafeTargetPath "$backupRelative/$RelativePath" -AllowControl
    Ensure-SafeDirectory (Split-Path -Parent $backup)
    [System.IO.File]::WriteAllBytes($backup, [System.IO.File]::ReadAllBytes($Source))
}

function Restore-InstallChanges {
    for ($index = $writeRecords.Count - 1; $index -ge 0; $index--) {
        $record = $writeRecords[$index]
        $destination = Resolve-SafeTargetPath $record.Path
        if ($record.Existed) {
            $backup = Resolve-SafeTargetPath "$backupRelative/$($record.Path)" -AllowControl
            [System.IO.File]::WriteAllBytes($destination, [System.IO.File]::ReadAllBytes($backup))
        } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            [System.IO.File]::Delete($destination)
        }
    }
    if ($script:manifestChanged) {
        if ($manifestExisted) {
            $backupManifest = Resolve-SafeTargetPath "$backupRelative/$manifestRelative" -AllowControl
            [System.IO.File]::WriteAllBytes($manifestPath, [System.IO.File]::ReadAllBytes($backupManifest))
        } elseif (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            [System.IO.File]::Delete($manifestPath)
        }
        $script:manifestChanged = $false
    }
    Write-Warning "Restored install changes after validation failure."
}

if ($Force -and $manifestExisted -and -not $DryRun) {
    Backup-File $manifestPath $manifestRelative
    $manifestBackedUp = $true
}

try {
    foreach ($entry in $entries) {
        $destination = Resolve-SafeTargetPath $entry.Path
        $exists = Get-SafeFileState $destination "Destination"
        if ($exists -and -not $Force) {
            Write-Host "SKIP  $($entry.Path) (already exists)"
            $skipped++
            continue
        }
        if ($DryRun) {
            $verb = if ($exists) { "REPLACE" } else { "CREATE " }
            Write-Host "$verb $($entry.Path)"
            continue
        }
        if ($exists) {
            Backup-File $destination $entry.Path
            $replaced++
        } else {
            $created++
        }
        $writeRecords.Add([pscustomobject]@{ Path = $entry.Path; Existed = $exists })
        Write-AtomicText $destination $entry.Rendered
        $written++
        Write-Host "WRITE $($entry.Path)"
    }
} catch {
    if (-not $DryRun) { Restore-InstallChanges }
    throw
}

if ($DryRun) {
    if ($Force) {
        Write-Host "DRY RUN manifest reset was not performed."
    } elseif ($manifestExisted) {
        Write-Host "PRESERVE $manifestRelative (already exists; dry run)"
    } elseif ($legacyWithoutManifest) {
        Write-Host "MANIFEST NOT INITIALIZED; explicit upgrade with -AdoptFrom 0.2.0 is required."
    } else {
        Write-Host "DRY RUN manifest initialization was not performed."
    }
    Write-Host "Dry run complete; no files changed and the manifest was not created or replaced."
    exit 0
}

Write-Host "Installed: created=$created replaced=$replaced skipped=$skipped"
if (Test-Path -LiteralPath $backupRoot -PathType Container) {
    Write-Host "Backups: $backupRoot"
}

$powerShellExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if (-not $Force) {
    & $powerShellExecutable -NoLogo -NoProfile -NonInteractive -File (Join-Path $scriptRoot "validate.ps1") -Target $targetRoot
    if ($LASTEXITCODE -ne 0) {
        Restore-InstallChanges
        throw "Post-install validation exited with $LASTEXITCODE"
    }
}

$initializeManifest = $false
$replaceManifest = $false
if ($Force) {
    if ($written -ne $entries.Count) {
        Restore-InstallChanges
        throw "Force reset did not render every managed file; manifest was preserved."
    }
    $initializeManifest = $true
    $replaceManifest = $manifestExisted
} elseif ($manifestExisted) {
    Write-Host "PRESERVE $manifestRelative (already exists)"
} elseif ($legacyWithoutManifest) {
    Write-Host "MANIFEST NOT INITIALIZED; run the explicit upgrade with -AdoptFrom 0.2.0."
} else {
    if ($written -ne $entries.Count) {
        Restore-InstallChanges
        throw "Clean install did not render every managed file; manifest was not initialized."
    }
    $initializeManifest = $true
}

if ($initializeManifest) {
    $manifestFiles = @($entries | ForEach-Object {
        $destination = Resolve-SafeTargetPath $_.Path
        $liveText = Read-NormalizedText $destination $_.Path
        $baselineHash = Get-TextHash $_.Rendered
        if ((Get-TextHash $liveText) -ne $baselineHash) {
            Restore-InstallChanges
            throw "Installed file does not match its rendered baseline: $($_.Path)"
        }
        [ordered]@{
            path = $_.Path
            source = $_.Source
            policy = $_.Policy
            baseline_hash = $baselineHash
        }
    })
    if ($replaceManifest -and -not $manifestBackedUp) {
        Restore-InstallChanges
        throw "Refusing to replace a manifest that was not backed up."
    }
    $manifest = [ordered]@{
        schema_version = 1
        workflow_version = $workflowVersion
        project_name = $ProjectName
        installed_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        last_transaction = $null
        files = $manifestFiles
    }
    try {
        Write-AtomicText $manifestPath (($manifest | ConvertTo-Json -Depth 20) + "`n")
        $manifestChanged = $true
    } catch {
        Restore-InstallChanges
        throw
    }
    Write-Host "$(if ($replaceManifest) { 'RESET' } else { 'WRITE' }) $manifestRelative"
    & $powerShellExecutable -NoLogo -NoProfile -NonInteractive -File (Join-Path $scriptRoot "validate.ps1") -Target $targetRoot
    if ($LASTEXITCODE -ne 0) {
        Restore-InstallChanges
        throw "Post-manifest validation exited with $LASTEXITCODE"
    }
}
