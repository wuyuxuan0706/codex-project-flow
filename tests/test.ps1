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

    $manifestPath = Join-Path $repoRoot ".codex-plugin/plugin.json"
    $bootstrapSkillPath = Join-Path $repoRoot "skills/bootstrap-project-flow/SKILL.md"
    $bootstrapOpenAiPath = Join-Path $repoRoot "skills/bootstrap-project-flow/agents/openai.yaml"
    foreach ($pluginFile in @($manifestPath, $bootstrapSkillPath, $bootstrapOpenAiPath)) {
        if (-not (Test-Path -LiteralPath $pluginFile -PathType Leaf)) {
            throw "Plugin packaging file is missing: $pluginFile"
        }
    }

    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    $baseVersion = [System.IO.File]::ReadAllText((Join-Path $repoRoot "VERSION")).Trim()
    $manifestVersionPattern = '^' + [regex]::Escape($baseVersion) +
        '(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
    if ($manifest.name -cne "codex-project-flow") {
        throw "Plugin manifest name is inconsistent with the repository."
    }
    if ($manifest.version -isnot [string] -or $manifest.version -cnotmatch $manifestVersionPattern) {
        throw "Plugin manifest version does not use VERSION as its base version."
    }
    if ($manifest.skills -cne "./skills/") {
        throw "Plugin manifest skills path is not ./skills/."
    }

    $bootstrapSkillText = [System.IO.File]::ReadAllText($bootstrapSkillPath)
    $bootstrapFrontmatter = [regex]::Match(
        $bootstrapSkillText,
        '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $bootstrapFrontmatter.Success) {
        throw "Bootstrap Skill frontmatter is missing or malformed."
    }
    $bootstrapMetadata = $bootstrapFrontmatter.Groups["frontmatter"].Value
    if ($bootstrapMetadata -notmatch '(?m)^name:\s*bootstrap-project-flow\s*$') {
        throw "Bootstrap Skill name is inconsistent with its directory."
    }
    $bootstrapDescription = [regex]::Match(
        $bootstrapMetadata,
        '(?m)^description:\s*(?<value>.+?)\s*$'
    ).Groups["value"].Value
    if (
        $bootstrapDescription -notmatch '(?i)\b(?:install|import)\w*\b' -or
        $bootstrapDescription -notmatch '(?i)\b(?:create|reuse)\w*\b' -or
        $bootstrapDescription -notmatch '(?i)\buser-visible\b.*\bproject hub\b'
    ) {
        throw "Bootstrap Skill description does not cover import and user-visible project hub creation or reuse."
    }
    if ($bootstrapSkillText -notmatch [regex]::Escape('set_thread_pinned')) {
        throw "Bootstrap Skill does not call set_thread_pinned for the permanent project hub."
    }
    if (
        $bootstrapSkillText -notmatch
            '(?i)(?:pinned[^\w\s:=]?\s*[:=]\s*\$?true\b|-pinned\s+\$?true\b)'
    ) {
        throw "Bootstrap Skill does not explicitly set pinned to true."
    }
    foreach ($toolName in @("read_thread", "set_thread_archived")) {
        $toolUsePattern = '(?is)\b(?:call|use)\b.{0,30}\b' +
            [regex]::Escape($toolName) + '\b'
        if ($bootstrapSkillText -notmatch $toolUsePattern) {
            throw "Bootstrap Skill does not use $toolName for project hub recovery."
        }
    }
    if (
        $bootstrapSkillText -notmatch
            '(?i)(?:archived[^\w\s:=]?\s*[:=]\s*\$?false\b|-archived\s+\$?false\b)'
    ) {
        throw "Bootstrap Skill does not explicitly set archived to false."
    }
    if ($bootstrapSkillText -notmatch '(?i)\bhubKey\b') {
        throw "Bootstrap Skill does not define the stable hubKey identifier."
    }
    if (
        $bootstrapSkillText -notmatch
            '(?is)\[codex-project-flow:hub:v1\].{0,160}\bprojectId\s*=.{1,120};\s*hubTitle\s*='
    ) {
        throw "Bootstrap Skill hubKey does not include the v1 prefix, projectId, and hubTitle."
    }
    if (
        $bootstrapSkillText -notmatch
            '(?is)(?:(?:full|complete).{0,30}hubKey.{0,120}(?:exact|verbatim)|(?:exact|verbatim).{0,120}(?:full|complete).{0,30}hubKey)'
    ) {
        throw "Bootstrap Skill does not compare the complete hubKey exactly during recovery."
    }
    if (
        $bootstrapSkillText -notmatch
            '(?im)^[^\r\n]*(?:queued|clientThreadId)[^\r\n]*(?:do not|never|not to)[^\r\n]*(?:call\s+)?[^\w\s]?create_thread[^\w\s]?\s+again[^\r\n]*$'
    ) {
        throw "Bootstrap Skill queued handling does not forbid another create_thread call."
    }
    if (
        $bootstrapSkillText -notmatch
            '(?im)^[^\r\n]*(?:queued|clientThreadId)[^\r\n]*(?:do not|never|not to)[^\r\n]*(?:(?:immediate(?:ly)?\s+)(?:re-?run|retry)|(?:re-?run|retry)[^\r\n]{0,40}immediate)[^\r\n]*$'
    ) {
        throw "Bootstrap Skill queued handling does not forbid an immediate rerun or retry."
    }
    $bootstrapOpenAiText = [System.IO.File]::ReadAllText($bootstrapOpenAiPath)
    $bootstrapDefaultPrompt = [regex]::Match(
        $bootstrapOpenAiText,
        '(?m)^\s+default_prompt:\s*(?<value>.+?)\s*$'
    ).Groups["value"].Value
    if ($bootstrapDefaultPrompt -notmatch [regex]::Escape('$bootstrap-project-flow')) {
        throw "Bootstrap openai.yaml default_prompt does not reference `$bootstrap-project-flow."
    }

    $stateTemplatePath = Join-Path $repoRoot "templates/PROJECT_STATE.md"
    $sourceStatePath = Join-Path $repoRoot "docs/PROJECT_STATE.md"
    if (-not (Test-Path -LiteralPath $stateTemplatePath -PathType Leaf)) {
        throw "Project-state installation template is missing."
    }
    $stateTemplateText = [System.IO.File]::ReadAllText($stateTemplatePath)
    $sourceStateText = [System.IO.File]::ReadAllText($sourceStatePath)
    if ($stateTemplateText -ceq $sourceStateText) {
        throw "Repository project state must remain distinct from the blank installation template."
    }

    & $install -Target $emptyTarget -ProjectName $specialProjectName
    if ($LASTEXITCODE -ne 0) {
        throw "Empty-project installation failed."
    }
    $installedStateText = [System.IO.File]::ReadAllText(
        (Join-Path $emptyTarget "docs/PROJECT_STATE.md")
    )
    if ($installedStateText -cne $stateTemplateText) {
        throw "Installer did not source docs/PROJECT_STATE.md from the blank installation template."
    }
    if ($installedStateText -ceq $sourceStateText) {
        throw "Installer copied the repository's live project state into the target project."
    }
    foreach ($pluginOnlyPath in @(".codex-plugin", "skills")) {
        if (Test-Path -LiteralPath (Join-Path $emptyTarget $pluginOnlyPath)) {
            throw "Installer copied plugin-only path into the target project: $pluginOnlyPath"
        }
    }
    & $validate -Target $emptyTarget
    if ($LASTEXITCODE -ne 0) {
        throw "Installed-project validation incorrectly required plugin packaging files."
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
    $invalidTaskPolicyCases = @(
        @{
            Name = "an incorrect max_active_tasks_applies_to"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.max_active_tasks_applies_to = "all_user_visible_tasks"
            }
        },
        @{
            Name = "an incorrect project_hub_task_lifecycle"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.project_hub_task_lifecycle = "ephemeral"
            }
        },
        @{
            Name = "project_hub_occupies_active_task_slot set to true"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.project_hub_occupies_active_task_slot = $true
            }
        }
    )
    foreach ($invalidCase in $invalidTaskPolicyCases) {
        $invalidConfig = $validConfigText | ConvertFrom-Json
        $mutate = $invalidCase.Mutate
        & $mutate $invalidConfig
        [System.IO.File]::WriteAllText(
            (Join-Path $emptyTarget ".agents/workflow.json"),
            ($invalidConfig | ConvertTo-Json -Depth 20),
            $utf8NoBom
        )
        & $validate -Target $emptyTarget
        if ($LASTEXITCODE -eq 0) {
            throw "Validator accepted $($invalidCase.Name)."
        }
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
