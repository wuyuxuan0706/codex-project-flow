$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$install = Join-Path $repoRoot "scripts/install.ps1"
$validate = Join-Path $repoRoot "scripts/validate.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-project-flow-" + [guid]::NewGuid().ToString("N"))
$emptyTarget = Join-Path $testRoot "empty-project"
$existingTarget = Join-Path $testRoot "existing-project"
$legacyTarget = Join-Path $testRoot "legacy-project"
$controlTarget = Join-Path $testRoot "control-project"
$linkTarget = Join-Path $testRoot "link-project"
$outsideTarget = Join-Path $testRoot "outside-project"
$createdReparsePaths = New-Object System.Collections.Generic.List[string]
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$specialProjectName = 'Quote "value" Backslash \ Ampersand & Pipe |'

function Get-ManagedDigest([string]$Root) {
    $items = Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object { $_.FullName -notlike "*\.project-flow-backup\*" } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($Root.Length).TrimStart('\', '/')
            "$relative=$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash)"
        }
    return ($items -join "`n")
}

try {
    [System.IO.Directory]::CreateDirectory($emptyTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($existingTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($legacyTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($controlTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($linkTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($outsideTarget) | Out-Null

    & $validate -Target $repoRoot -AllowPlaceholders
    if ($LASTEXITCODE -ne 0) {
        throw "Template validation failed."
    }

    & $install -Target $emptyTarget -ProjectName $specialProjectName
    if ($LASTEXITCODE -ne 0) {
        throw "Empty-project installation failed."
    }
    $config = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $emptyTarget ".agents/workflow.json") |
        ConvertFrom-Json
    if ($config.project.name -cne $specialProjectName) {
        throw "JSON project name rendering failed for quotes, backslashes, ampersands, or pipes."
    }
    if (-not [System.IO.File]::ReadAllText((Join-Path $emptyTarget "AGENTS.md")).Contains($specialProjectName)) {
        throw "Plain-text project name rendering failed."
    }
    $unresolved = @(
        Get-ChildItem -LiteralPath $emptyTarget -Recurse -File |
            Select-String -SimpleMatch "<PROJECT_NAME>"
    )
    if ($unresolved.Count -gt 0) {
        throw "Installed project still contains <PROJECT_NAME>."
    }

    $validConfigText = [System.IO.File]::ReadAllText((Join-Path $emptyTarget ".agents/workflow.json"))
    foreach ($invalidRoot in @("null", "false", "0", "[]")) {
        [System.IO.File]::WriteAllText(
            (Join-Path $emptyTarget ".agents/workflow.json"),
            $invalidRoot,
            $utf8NoBom
        )
        & $validate -Target $emptyTarget
        if ($LASTEXITCODE -eq 0) {
            throw "Validator accepted non-object JSON root: $invalidRoot"
        }
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $emptyTarget ".agents/workflow.json"),
        "[$validConfigText]",
        $utf8NoBom
    )
    & $validate -Target $emptyTarget
    if ($LASTEXITCODE -eq 0) {
        throw "Validator accepted an array containing an otherwise valid configuration object."
    }
    $invalidConfig = $validConfigText | ConvertFrom-Json
    $invalidConfig.project.name = "   "
    [System.IO.File]::WriteAllText(
        (Join-Path $emptyTarget ".agents/workflow.json"),
        ($invalidConfig | ConvertTo-Json -Depth 20),
        $utf8NoBom
    )
    & $validate -Target $emptyTarget
    if ($LASTEXITCODE -eq 0) {
        throw "Validator accepted a whitespace-only project.name."
    }
    $invalidConfig = $validConfigText | ConvertFrom-Json
    $invalidConfig.task_policy.return_to_work_on_change = @(
        "scope",
        "interface",
        "environment",
        "acceptance_criteria",
        42
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $emptyTarget ".agents/workflow.json"),
        ($invalidConfig | ConvertTo-Json -Depth 20),
        $utf8NoBom
    )
    & $validate -Target $emptyTarget
    if ($LASTEXITCODE -eq 0) {
        throw "Validator accepted a non-string return_to_work_on_change entry."
    }
    $invalidConfig = $validConfigText | ConvertFrom-Json
    $invalidConfig.handoff_policy.only_when = @(
        "coordination_required",
        "user_choice_required",
        "user_requested",
        $false
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $emptyTarget ".agents/workflow.json"),
        ($invalidConfig | ConvertTo-Json -Depth 20),
        $utf8NoBom
    )
    & $validate -Target $emptyTarget
    if ($LASTEXITCODE -eq 0) {
        throw "Validator accepted a non-string handoff_policy.only_when entry."
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $emptyTarget ".agents/workflow.json"),
        $validConfigText,
        $utf8NoBom
    )

    $firstDigest = Get-ManagedDigest $emptyTarget
    & $install -Target $emptyTarget -ProjectName $specialProjectName
    if ($LASTEXITCODE -ne 0) {
        throw "Second installation failed."
    }
    $secondDigest = Get-ManagedDigest $emptyTarget
    if ($firstDigest -ne $secondDigest) {
        throw "Installation is not idempotent."
    }

    $controlRejected = $false
    try {
        & $install -Target $controlTarget -ProjectName "Bad`tName"
        $controlRejected = $LASTEXITCODE -ne 0
    } catch {
        $controlRejected = $true
    }
    if (-not $controlRejected) {
        throw "Installer accepted a project name containing a control character."
    }
    if (@(Get-ChildItem -LiteralPath $controlTarget -Force).Count -ne 0) {
        throw "Installer wrote files before rejecting a control-character project name."
    }
    $controlRejected = $false
    try {
        & $install -Target $controlTarget -ProjectName "Bad`nName"
        $controlRejected = $LASTEXITCODE -ne 0
    } catch {
        $controlRejected = $true
    }
    if (-not $controlRejected) {
        throw "Installer accepted a project name containing a line feed."
    }
    if (@(Get-ChildItem -LiteralPath $controlTarget -Force).Count -ne 0) {
        throw "Installer wrote files before rejecting a line-feed project name."
    }

    $agentsLink = Join-Path $linkTarget ".agents"
    $linkCreated = $false
    $linkError = $null
    foreach ($itemType in @("Junction", "SymbolicLink")) {
        try {
            New-Item -ItemType $itemType -Path $agentsLink -Target $outsideTarget -ErrorAction Stop | Out-Null
            $linkCreated = $true
            $createdReparsePaths.Add($agentsLink)
            break
        } catch {
            $linkError = $_.Exception.Message
        }
    }
    if ($linkCreated) {
        $linkRejected = $false
        try {
            & $install -Target $linkTarget -ProjectName "Linked Project"
            $linkRejected = $LASTEXITCODE -ne 0
        } catch {
            $linkRejected = $true
        }
        if (-not $linkRejected) {
            throw "Installer accepted a target containing a reparse point."
        }
        if (@(Get-ChildItem -LiteralPath $outsideTarget -Force).Count -ne 0) {
            throw "Installer wrote template files through a reparse point."
        }
        [System.IO.Directory]::Delete($agentsLink)
        $createdReparsePaths.Remove($agentsLink) | Out-Null
    } else {
        Write-Host "SKIP  reparse-point safety subtest (link creation unavailable: $linkError)"
    }

    $backupLink = Join-Path $linkTarget ".project-flow-backup"
    $backupLinkCreated = $false
    $backupLinkError = $null
    foreach ($itemType in @("Junction", "SymbolicLink")) {
        try {
            New-Item -ItemType $itemType -Path $backupLink -Target $outsideTarget -ErrorAction Stop | Out-Null
            $backupLinkCreated = $true
            $createdReparsePaths.Add($backupLink)
            break
        } catch {
            $backupLinkError = $_.Exception.Message
        }
    }
    if ($backupLinkCreated) {
        $backupLinkRejected = $false
        try {
            & $install -Target $linkTarget -ProjectName "Backup Link Project"
            $backupLinkRejected = $LASTEXITCODE -ne 0
        } catch {
            $backupLinkRejected = $true
        }
        if (-not $backupLinkRejected) {
            throw "Installer accepted a reparse point at .project-flow-backup."
        }
        if (@(Get-ChildItem -LiteralPath $outsideTarget -Force).Count -ne 0) {
            throw "Installer wrote backup or template files through a reparse point."
        }
        [System.IO.Directory]::Delete($backupLink)
        $createdReparsePaths.Remove($backupLink) | Out-Null
    } else {
        Write-Host "SKIP  backup reparse-point subtest (link creation unavailable: $backupLinkError)"
    }

    $existingAgents = Join-Path $existingTarget "AGENTS.md"
    [System.IO.File]::WriteAllText($existingAgents, "# Existing project rules`n", $utf8NoBom)
    & $install -Target $existingTarget -ProjectName "Existing Project"
    if ($LASTEXITCODE -ne 0) {
        throw "Existing-project installation failed."
    }
    if ([System.IO.File]::ReadAllText($existingAgents) -ne "# Existing project rules`n") {
        throw "Default install overwrote an existing AGENTS.md."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $existingTarget ".agents/snippets/AGENTS.integration.md"))) {
        throw "Integration snippet was not installed."
    }

    & $install -Target $existingTarget -ProjectName "Existing Project" -Force
    if ($LASTEXITCODE -ne 0) {
        throw "Forced installation failed."
    }
    $backup = Get-ChildItem -LiteralPath (Join-Path $existingTarget ".project-flow-backup") -Recurse -File -Filter "AGENTS.md" |
        Select-Object -First 1
    if (-not $backup -or [System.IO.File]::ReadAllText($backup.FullName) -ne "# Existing project rules`n") {
        throw "Forced installation did not preserve the existing AGENTS.md backup."
    }

    $legacyPrompt = Join-Path $legacyTarget ".agents/prompts/01_start_project.md"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $legacyPrompt)) | Out-Null
    [System.IO.File]::WriteAllText($legacyPrompt, "# Legacy prompt`n", $utf8NoBom)
    & $install -Target $legacyTarget -ProjectName "Legacy Project"
    if ($LASTEXITCODE -ne 0) {
        throw "Non-destructive installation with a legacy prompt failed."
    }
    if (-not (Test-Path -LiteralPath $legacyPrompt -PathType Leaf)) {
        throw "Installer destructively removed a legacy prompt."
    }

    Write-Host "All PowerShell tests passed."
} finally {
    foreach ($reparsePath in @($createdReparsePaths)) {
        $item = Get-Item -LiteralPath $reparsePath -Force -ErrorAction SilentlyContinue
        if (
            $item -and
            (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        ) {
            [System.IO.Directory]::Delete($reparsePath)
        }
    }
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') +
        [System.IO.Path]::DirectorySeparatorChar
    if (
        $resolvedTestRoot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTestRoot)
    ) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

exit 0
