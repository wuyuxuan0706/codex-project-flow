[CmdletBinding()]
param(
    [string]$Target = ".",
    [switch]$Plan,
    [switch]$Apply,
    [string]$Rollback = "",
    [string]$AdoptFrom = "",
    [string]$ProjectName = "",
    [string[]]$AcceptLocal = @()
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pluginRoot = Split-Path -Parent $scriptRoot
$targetRoot = [System.IO.Path]::GetFullPath($Target)
$controlRootName = ".project-flow"
$manifestRelative = ".project-flow/manifest.json"
$validPolicies = @("seed_once", "merge_manual", "structured_manual", "replace_if_unmodified")

if ($Apply -and $Plan) { throw "-Apply and -Plan are mutually exclusive." }
if ($Rollback -and ($Apply -or $Plan)) { throw "-Rollback is mutually exclusive with -Apply and -Plan." }
if ($AcceptLocal.Count -gt 0 -and -not $Apply) { throw "-AcceptLocal requires -Apply." }
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
    if ($RelativePath.Contains("\") -or $RelativePath.Contains("`0") -or $RelativePath -match "^[A-Za-z]:") {
        return $false
    }
    $parts = $RelativePath.Split('/')
    if ($parts.Count -eq 0 -or @($parts | Where-Object { $_ -eq "" -or $_ -eq "." -or $_ -eq ".." }).Count -gt 0) {
        return $false
    }
    if (-not $AllowControl -and $parts[0] -eq $controlRootName) {
        return $false
    }
    return $true
}

function Resolve-SafePath([string]$RelativePath, [switch]$AllowControl) {
    if (-not (Test-SafeRelative $RelativePath -AllowControl:$AllowControl)) {
        throw "Unsafe relative path: $RelativePath"
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $targetRoot ($RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
    $prefix = $targetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes target: $RelativePath"
    }
    $current = $targetRoot
    foreach ($part in $RelativePath.Split('/')) {
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { break }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing path through a symbolic link, junction, or reparse point: $current"
        }
    }
    return $full
}

function Resolve-SafePluginInput([string]$RelativePath, [string]$Label, [switch]$AllowMissingTail) {
    if (-not (Test-SafeRelative $RelativePath)) {
        throw "Unsafe plugin input path: $RelativePath"
    }
    $current = $pluginRoot
    $missing = $false
    foreach ($part in $RelativePath.Split('/')) {
        $current = Join-Path $current $part
        if ($missing) { continue }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            if ($AllowMissingTail) {
                $missing = $true
                continue
            }
            throw "$Label is missing or unsafe: $RelativePath"
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label path uses a symbolic link, junction, or reparse point: $RelativePath"
        }
    }
    $full = Join-Path $pluginRoot ($RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not $missing) {
        $finalItem = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($null -eq $finalItem -or $finalItem.PSIsContainer) {
            throw "$Label is not a regular file: $RelativePath"
        }
    }
    return $full
}

function Ensure-SafeDirectory([string]$Directory) {
    $full = [System.IO.Path]::GetFullPath($Directory)
    $prefix = $targetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($full -ne $targetRoot -and -not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing directory outside target: $full"
    }
    if ($full -eq $targetRoot) { return }
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

function Read-NormalizedText([string]$Path, [string]$Label) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "$Label is missing or is not a safe regular file."
    }
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

function Get-TextHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $utf8NoBom.GetBytes($Text)
        return "sha256:" + ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileHashNormalized([string]$Path, [string]$Label) {
    return Get-TextHash (Read-NormalizedText $Path $Label)
}

function Write-AtomicBytes([string]$Path, [byte[]]$Bytes) {
    Ensure-SafeDirectory (Split-Path -Parent $Path)
    $existing = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($existing -and ($existing.PSIsContainer -or (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
        throw "Refusing to replace a non-file or reparse point: $Path"
    }
    $temporary = "$Path.project-flow-tmp-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        [System.IO.File]::WriteAllBytes($temporary, $Bytes)
        if ($existing) {
            [System.IO.File]::Replace($temporary, $Path, $null)
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-AtomicText([string]$Path, [string]$Text) {
    Write-AtomicBytes $Path ($utf8NoBom.GetBytes($Text))
}

function Read-JsonFile([string]$Path, [string]$Label) {
    try {
        return (Read-NormalizedText $Path $Label) | ConvertFrom-Json
    } catch {
        throw "$Label is invalid JSON: $($_.Exception.Message)"
    }
}

function Test-Property([object]$Object, [string]$Name) {
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Render-Template([string]$Text, [string]$Mode, [string]$Name) {
    if ($Mode -eq "project_name_json") {
        $jsonName = ConvertTo-Json -InputObject $Name -Compress
        return $Text.Replace('"<PROJECT_NAME>"', $jsonName)
    }
    return $Text.Replace("<PROJECT_NAME>", $Name)
}

function Confirm-ProjectName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Project name must not be empty." }
    foreach ($character in $Name.ToCharArray()) {
        if ([char]::IsControl($character)) { throw "Project name must not contain control characters." }
    }
    return $Name
}

function New-TransactionId {
    return (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + "-$PID-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Resolve-TransactionRoot([string]$Identifier) {
    if ($Identifier -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw "Invalid transaction identifier." }
    return Resolve-SafePath "$controlRootName/transactions/$Identifier" -AllowControl
}

$managedPath = Resolve-SafePluginInput "managed-files.json" "managed-files.json"
$managed = Read-JsonFile $managedPath "managed-files.json"
if ($managed.schema_version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$managed.workflow_version)) {
    throw "Unsupported managed-files.json schema."
}
$newVersion = [string]$managed.workflow_version
$entries = @($managed.files)
if ($entries.Count -eq 0) { throw "managed-files.json files must be a non-empty array." }
$seen = @{}
foreach ($entry in $entries) {
    $relative = [string]$entry.path
    $sourceRelative = [string]$entry.source
    if (-not (Test-SafeRelative $relative) -or -not (Test-SafeRelative $sourceRelative)) {
        throw "Unsafe managed path or source: $relative"
    }
    if ($seen.ContainsKey($relative)) { throw "Duplicate managed path: $relative" }
    $seen[$relative] = $true
    if ($validPolicies -notcontains [string]$entry.policy) { throw "Unsupported policy for $relative" }
    if (@("project_name", "project_name_json") -notcontains [string]$entry.render) { throw "Unsupported render mode for $relative" }
    Resolve-SafePluginInput $sourceRelative "managed source" | Out-Null
}
if (-not $seen.ContainsKey("docs/PROJECT_STATE.md")) { throw "docs/PROJECT_STATE.md must be managed." }
$stateEntry = @($entries | Where-Object { $_.path -eq "docs/PROJECT_STATE.md" })[0]
if ($stateEntry.policy -ne "seed_once") { throw "docs/PROJECT_STATE.md must use seed_once." }

$manifestPath = Resolve-SafePath $manifestRelative -AllowControl
$manifest = $null
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifest = Read-JsonFile $manifestPath $manifestRelative
    if ($manifest.schema_version -ne 1) { throw "Unsupported manifest schema." }
    if ($AdoptFrom) { throw "-AdoptFrom is only valid when the target has no manifest." }
} elseif (-not $Rollback -and $AdoptFrom -ne "0.2.0") {
    throw "Missing .project-flow/manifest.json; explicitly pass -AdoptFrom 0.2.0 for a confirmed legacy deployment."
}

function Invoke-TransactionRollback([string]$Identifier, [bool]$Automatic = $false) {
    $transactionRoot = Resolve-TransactionRoot $Identifier
    $metaPath = Join-Path $transactionRoot "transaction.json"
    $rootItem = Get-Item -LiteralPath $transactionRoot -Force -ErrorAction SilentlyContinue
    if ($null -eq $rootItem -or -not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Transaction does not exist or is unsafe: $Identifier"
    }
    $meta = Read-JsonFile $metaPath "transaction.json"
    if ($meta.schema_version -ne 1 -or $meta.transaction_id -ne $Identifier -or $meta.target -ne $targetRoot) {
        throw "Invalid transaction metadata."
    }
    if ($meta.state -eq "rolled_back") {
        Write-Host "NOOP transaction already rolled back: $Identifier"
        return
    }
    if (@("prepared", "validating", "applied") -notcontains [string]$meta.state) {
        throw "Transaction is not rollback-eligible: $($meta.state)"
    }

    $decisions = New-Object System.Collections.Generic.List[object]
    $recordPaths = @{}
    foreach ($record in @($meta.files)) {
        if (-not (Test-Property $record "path") -or -not $seen.ContainsKey([string]$record.path) -or $recordPaths.ContainsKey([string]$record.path)) {
            throw "Transaction contains an invalid or duplicate managed path."
        }
        $recordPaths[[string]$record.path] = $true
        if (-not $record.changed) { continue }
        $live = Resolve-SafePath ([string]$record.path)
        $liveItem = Get-Item -LiteralPath $live -Force -ErrorAction SilentlyContinue
        if ($liveItem -and ($liveItem.PSIsContainer -or (($liveItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
            throw "Rollback target is not a regular file: $($record.path)"
        }
        $currentHash = if ($liveItem) { Get-FileHashNormalized $live ([string]$record.path) } else { $null }
        if ($currentHash -eq $record.applied_hash) {
            $decisions.Add([pscustomobject]@{ Record = $record; Live = $live; Decision = "restore" })
        } elseif ($currentHash -eq $record.original_hash) {
            $decisions.Add([pscustomobject]@{ Record = $record; Live = $live; Decision = "unchanged" })
        } else {
            throw "Refusing rollback because a live file changed after apply: $($record.path)"
        }
    }

    $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    $manifestCurrent = if ($manifestItem -and -not $manifestItem.PSIsContainer) { Get-FileHashNormalized $manifestPath $manifestRelative } else { $null }
    if ($manifestCurrent -eq $meta.new_manifest_hash) {
        $manifestDecision = "restore"
    } elseif ($manifestCurrent -eq $meta.old_manifest_hash) {
        $manifestDecision = "unchanged"
    } else {
        throw "Refusing rollback because the manifest changed after apply."
    }

    foreach ($decision in $decisions) {
        if ($decision.Decision -eq "unchanged") { continue }
        $record = $decision.Record
        if ($record.existed) {
            $backup = Resolve-SafePath "$controlRootName/transactions/$Identifier/backup/$($record.path)" -AllowControl
            $text = Read-NormalizedText $backup "backup for $($record.path)"
            if ((Get-TextHash $text) -ne $record.original_hash) { throw "Backup hash mismatch for $($record.path)" }
            Write-AtomicBytes $decision.Live ([System.IO.File]::ReadAllBytes($backup))
        } elseif (Test-Path -LiteralPath $decision.Live -PathType Leaf) {
            Remove-Item -LiteralPath $decision.Live -Force
        }
    }

    if ($manifestDecision -eq "restore") {
        if ($null -eq $meta.old_manifest_hash) {
            if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Remove-Item -LiteralPath $manifestPath -Force }
        } else {
            $backupManifest = Resolve-SafePath "$controlRootName/transactions/$Identifier/backup/$controlRootName/manifest.json" -AllowControl
            $text = Read-NormalizedText $backupManifest "manifest backup"
            if ((Get-TextHash $text) -ne $meta.old_manifest_hash) { throw "Manifest backup hash mismatch." }
            Write-AtomicBytes $manifestPath ([System.IO.File]::ReadAllBytes($backupManifest))
        }
    }

    $meta.state = "rolled_back"
    $meta | Add-Member -NotePropertyName rolled_back_at_utc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
    $meta | Add-Member -NotePropertyName automatic_rollback -NotePropertyValue $Automatic -Force
    Write-AtomicText $metaPath (($meta | ConvertTo-Json -Depth 20) + "`n")
    Write-Host "ROLLED_BACK $Identifier"
}

if ($Rollback) {
    if ($AdoptFrom -or $ProjectName) { throw "Rollback does not accept adoption or project-name options." }
    Invoke-TransactionRollback $Rollback
    exit 0
}

if ($ProjectName) {
    $resolvedProjectName = Confirm-ProjectName $ProjectName
} elseif ($null -ne $manifest) {
    if (Test-Property $manifest "project_name") {
        $resolvedProjectName = Confirm-ProjectName ([string]$manifest.project_name)
    } elseif ((Test-Property $manifest "project") -and (Test-Property $manifest.project "name")) {
        $resolvedProjectName = Confirm-ProjectName ([string]$manifest.project.name)
    } else {
        throw "Manifest project_name is missing."
    }
} else {
    $workflowPath = Resolve-SafePath ".agents/workflow.json"
    if (Test-Path -LiteralPath $workflowPath -PathType Leaf) {
        $workflow = Read-JsonFile $workflowPath ".agents/workflow.json"
        if ((Test-Property $workflow "project") -and (Test-Property $workflow.project "name") -and $workflow.project.name -ne "<PROJECT_NAME>") {
            $resolvedProjectName = Confirm-ProjectName ([string]$workflow.project.name)
        }
    }
    if (-not $resolvedProjectName) { $resolvedProjectName = Confirm-ProjectName (Split-Path -Leaf $targetRoot) }
}

$installedVersion = if ($null -eq $manifest) { $AdoptFrom } else { [string]$manifest.workflow_version }
if ([string]::IsNullOrWhiteSpace($installedVersion)) { throw "Manifest workflow_version is missing." }
if (@("0.2.0", $newVersion) -notcontains $installedVersion) {
    throw "No supported migration from $installedVersion to $newVersion"
}
$introduced = @{}
if ($installedVersion -eq "0.2.0" -and $installedVersion -ne $newVersion) {
    $migrationPath = Resolve-SafePluginInput "migrations/0.2.0-to-$newVersion.json" "migration descriptor"
    $migration = Read-JsonFile $migrationPath "migration descriptor"
    if ($migration.from_version -ne $installedVersion -or $migration.to_version -ne $newVersion) {
        throw "Migration descriptor does not match requested versions."
    }
    foreach ($introducedPath in @($migration.introduced_files)) {
        $introducedPath = [string]$introducedPath
        if (-not (Test-SafeRelative $introducedPath) -or -not $seen.ContainsKey($introducedPath)) {
            throw "Migration introduces an unsafe or unmanaged path: $introducedPath"
        }
        if ($introduced.ContainsKey($introducedPath)) { throw "Migration contains a duplicate introduced path: $introducedPath" }
        $introduced[$introducedPath] = $true
        $baselineCandidate = Resolve-SafePluginInput "baselines/$installedVersion/$introducedPath" "introduced-file baseline candidate" -AllowMissingTail
        if (Test-Path -LiteralPath $baselineCandidate) { throw "Introduced path must not have an old-version baseline: $introducedPath" }
    }
}

$manifestEntries = @{}
if ($null -ne $manifest) {
    $rawEntries = if (Test-Property $manifest "files") { @($manifest.files) } elseif (Test-Property $manifest "managed_files") { @($manifest.managed_files) } else { @() }
    foreach ($item in $rawEntries) {
        if ((Test-Property $item "path") -and -not [string]::IsNullOrWhiteSpace([string]$item.path)) {
            if ($manifestEntries.ContainsKey([string]$item.path)) { throw "Manifest contains a duplicate path: $($item.path)" }
            $manifestEntries[[string]$item.path] = $item
        }
    }
    $expectedManifestPaths = @($seen.Keys | Where-Object { $installedVersion -eq $newVersion -or -not $introduced.ContainsKey($_) })
    if ($manifestEntries.Count -ne $expectedManifestPaths.Count) { throw "Manifest managed paths do not match managed-files.json." }
    foreach ($relative in $expectedManifestPaths) {
        if (-not $manifestEntries.ContainsKey($relative)) { throw "Manifest managed paths do not match managed-files.json." }
        $recordedHash = [string]$manifestEntries[$relative].baseline_hash
        if ($recordedHash -notmatch '^sha256:[0-9a-f]{64}$') { throw "Manifest baseline_hash is missing or invalid for $relative" }
        $managedEntry = @($entries | Where-Object { [string]$_.path -ceq $relative })[0]
        if ([string]$manifestEntries[$relative].source -cne [string]$managedEntry.source -or
            [string]$manifestEntries[$relative].policy -cne [string]$managedEntry.policy) {
            throw "Manifest source or policy does not match managed-files.json for $relative"
        }
    }
}

$plans = New-Object System.Collections.Generic.List[object]
foreach ($entry in $entries) {
    $relative = [string]$entry.path
    $live = Resolve-SafePath $relative
    $liveItem = Get-Item -LiteralPath $live -Force -ErrorAction SilentlyContinue
    if ($liveItem -and ($liveItem.PSIsContainer -or (($liveItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
        throw "Managed target is not a regular file: $relative"
    }
    $sourcePath = Resolve-SafePluginInput ([string]$entry.source) "managed source"
    $newText = Render-Template (Read-NormalizedText $sourcePath ([string]$entry.source)) ([string]$entry.render) $resolvedProjectName
    $newHash = Get-TextHash $newText
    if ($installedVersion -eq $newVersion) {
        $baseText = $newText
    } elseif ($introduced.ContainsKey($relative)) {
        $baseText = $null
    } else {
        $baselinePath = Resolve-SafePluginInput "baselines/$installedVersion/$relative" "baseline $relative"
        $baseText = Render-Template (Read-NormalizedText $baselinePath "baseline $relative") ([string]$entry.render) $resolvedProjectName
    }
    $baseHash = if ($null -ne $baseText) { Get-TextHash $baseText } else { $null }
    if ($manifestEntries.ContainsKey($relative) -and (Test-Property $manifestEntries[$relative] "baseline_hash")) {
        if ($manifestEntries[$relative].baseline_hash -ne $baseHash) { throw "Manifest baseline hash does not match the immutable baseline for $relative" }
    }
    $liveText = if ($liveItem) { Read-NormalizedText $live $relative } else { $null }
    $liveHash = if ($null -ne $liveText) { Get-TextHash $liveText } else { $null }
    if ($null -eq $liveText) {
        $action = "CREATE"
    } elseif ($null -eq $baseText) {
        $action = if ($liveHash -eq $newHash) { "NOOP" } else { "CONFLICT" }
    } elseif ($entry.policy -eq "seed_once") {
        $action = if ($liveHash -eq $newHash) { "NOOP" } else { "PRESERVE" }
    } elseif ($liveHash -eq $newHash) {
        $action = "NOOP"
    } elseif ($liveHash -eq $baseHash) {
        $action = "REPLACE"
    } elseif ($baseHash -eq $newHash) {
        $action = "PRESERVE"
    } else {
        $action = "CONFLICT"
    }
    $plans.Add([pscustomobject]@{
        Path = $relative; Source = [string]$entry.source; Policy = [string]$entry.policy; Action = $action
        BaseHash = $baseHash; LiveHash = $liveHash; NewHash = $newHash
        BaseText = $baseText; LiveText = $liveText; NewText = $newText
    })
}

$acceptedLocalPaths = @{}
foreach ($rawPath in $AcceptLocal) {
    $relative = [string]$rawPath
    if (-not (Test-SafeRelative $relative)) { throw "Unsafe -AcceptLocal path: $relative" }
    if ($acceptedLocalPaths.ContainsKey($relative)) { throw "Duplicate -AcceptLocal path: $relative" }
    $acceptedLocalPaths[$relative] = $true
    $matchingPlans = @($plans | Where-Object { $_.Path -ceq $relative })
    if ($matchingPlans.Count -ne 1) { throw "-AcceptLocal path is not managed: $relative" }
    if ($matchingPlans[0].Action -cne "CONFLICT") { throw "-AcceptLocal is valid only for a current conflict: $relative" }
    $matchingPlans[0].Action = "ACCEPT"
}

Write-Host "UPGRADE $installedVersion -> $newVersion"
Write-Host "TARGET $targetRoot"
foreach ($item in $plans) { Write-Host (("{0,-8} {1,-22} {2}" -f $item.Action, $item.Policy, $item.Path)) }
$conflicts = @($plans | Where-Object { $_.Action -eq "CONFLICT" })
$changes = @($plans | Where-Object { $_.Action -eq "CREATE" -or $_.Action -eq "REPLACE" })
if (-not $Apply) {
    Write-Host "PLAN changes=$($changes.Count) conflicts=$($conflicts.Count)"
    exit 0
}

if ($conflicts.Count -gt 0) {
    $identifier = New-TransactionId
    $staging = Resolve-SafePath "$controlRootName/staging/$identifier" -AllowControl
    if (Test-Path -LiteralPath $staging) { throw "Staging transaction already exists: $identifier" }
    Ensure-SafeDirectory $staging
    $publicConflicts = @($conflicts | ForEach-Object {
        [pscustomobject]@{ path = $_.Path; policy = $_.Policy; base_hash = $_.BaseHash; live_hash = $_.LiveHash; new_hash = $_.NewHash }
    })
    $publicPlan = [ordered]@{ schema_version = 1; transaction_id = $identifier; from_version = $installedVersion; to_version = $newVersion; conflicts = $publicConflicts }
    Write-AtomicText (Join-Path $staging "plan.json") (($publicPlan | ConvertTo-Json -Depth 20) + "`n")
    foreach ($item in $conflicts) {
        $bundle = Join-Path (Join-Path $staging "conflicts") ($item.Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        Ensure-SafeDirectory $bundle
        if ($null -ne $item.BaseText) { Write-AtomicText (Join-Path $bundle "base") $item.BaseText }
        if ($null -ne $item.LiveText) { Write-AtomicText (Join-Path $bundle "local") $item.LiveText }
        Write-AtomicText (Join-Path $bundle "upstream") $item.NewText
    }
    Write-Error "Conflicts staged at $(Join-Path $staging 'conflicts'); live managed files and manifest were not changed." -ErrorAction Continue
    exit 4
}

if ($changes.Count -eq 0 -and $installedVersion -eq $newVersion -and $null -ne $manifest) {
    & (Join-Path $pluginRoot "scripts/validate.ps1") -Target $targetRoot
    if ($LASTEXITCODE -ne 0) { throw "Current installation failed validation; refusing NOOP." }
    Write-Host "NOOP already up to date"
    exit 0
}

$identifier = New-TransactionId
$transactionRoot = Resolve-TransactionRoot $identifier
if (Test-Path -LiteralPath $transactionRoot) { throw "Transaction already exists: $identifier" }
$backupRoot = Join-Path $transactionRoot "backup"
Ensure-SafeDirectory $backupRoot
$records = New-Object System.Collections.Generic.List[object]
foreach ($item in $plans) {
    $live = Resolve-SafePath $item.Path
    $exists = Test-Path -LiteralPath $live -PathType Leaf
    $changed = $item.Action -eq "CREATE" -or $item.Action -eq "REPLACE"
    $records.Add([pscustomobject]@{
        path = $item.Path; existed = $exists; changed = $changed; original_hash = $item.LiveHash
        applied_hash = if ($changed) { $item.NewHash } else { $item.LiveHash }
    })
    if ($exists) {
        $backup = Join-Path $backupRoot ($item.Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        Ensure-SafeDirectory (Split-Path -Parent $backup)
        Write-AtomicBytes $backup ([System.IO.File]::ReadAllBytes($live))
    }
}

$oldManifestText = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Read-NormalizedText $manifestPath $manifestRelative } else { $null }
$oldManifestHash = if ($null -ne $oldManifestText) { Get-TextHash $oldManifestText } else { $null }
if ($null -ne $oldManifestText) {
    $backupManifest = Join-Path $backupRoot "$controlRootName/manifest.json"
    Ensure-SafeDirectory (Split-Path -Parent $backupManifest)
    Write-AtomicBytes $backupManifest ([System.IO.File]::ReadAllBytes($manifestPath))
}

$now = (Get-Date).ToUniversalTime().ToString("o")
$manifestFiles = @($plans | ForEach-Object {
    [ordered]@{ path = $_.Path; source = $_.Source; policy = $_.Policy; baseline_hash = $_.NewHash }
})
$newManifest = [ordered]@{
    schema_version = 1; workflow_version = $newVersion; project_name = $resolvedProjectName
    installed_at_utc = $now; last_transaction = $identifier; files = $manifestFiles
}
$newManifestText = ($newManifest | ConvertTo-Json -Depth 20) + "`n"
$meta = [ordered]@{
    schema_version = 1; transaction_id = $identifier; target = $targetRoot
    from_version = $installedVersion; to_version = $newVersion; state = "prepared"; created_at_utc = $now
    old_manifest_hash = $oldManifestHash; new_manifest_hash = (Get-TextHash $newManifestText)
    accepted_local = @($acceptedLocalPaths.Keys | Sort-Object); files = @($records)
}
$metaPath = Join-Path $transactionRoot "transaction.json"
Write-AtomicText $metaPath (($meta | ConvertTo-Json -Depth 20) + "`n")

try {
    foreach ($item in $changes) { Write-AtomicText (Resolve-SafePath $item.Path) $item.NewText }
    Write-AtomicText $manifestPath $newManifestText
    $meta["state"] = "validating"
    Write-AtomicText $metaPath (($meta | ConvertTo-Json -Depth 20) + "`n")
    & (Join-Path $pluginRoot "scripts/validate.ps1") -Target $targetRoot
    if ($LASTEXITCODE -ne 0) { throw "Post-upgrade validation exited with $LASTEXITCODE" }
    $meta["state"] = "applied"
    $meta["validated_at_utc"] = (Get-Date).ToUniversalTime().ToString("o")
    Write-AtomicText $metaPath (($meta | ConvertTo-Json -Depth 20) + "`n")
} catch {
    Write-Error "Apply failed; attempting automatic rollback: $($_.Exception.Message)" -ErrorAction Continue
    Invoke-TransactionRollback $identifier $true
    exit 5
}

Write-Host "APPLIED $identifier"
Write-Host "VALIDATION passed"
exit 0
