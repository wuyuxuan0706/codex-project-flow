$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$install = Join-Path $repoRoot "scripts/install.ps1"
$validate = Join-Path $repoRoot "scripts/validate.ps1"
$upgrade = Join-Path $repoRoot "scripts/upgrade.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-project-flow-" + [guid]::NewGuid().ToString("N"))
$emptyTarget = Join-Path $testRoot "empty-project"
$existingTarget = Join-Path $testRoot "existing-project"
$legacyTarget = Join-Path $testRoot "legacy-project"
$upgradeTarget = Join-Path $testRoot "upgrade-project"
$conflictTarget = Join-Path $testRoot "conflict-project"
$noopInvalidTarget = Join-Path $testRoot "noop-invalid-project"
$controlTarget = Join-Path $testRoot "control-project"
$linkTarget = Join-Path $testRoot "link-project"
$outsideTarget = Join-Path $testRoot "outside-project"
$fakeHandoffTarget = Join-Path $testRoot "fake-handoff-project"
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

function Get-NormalizedText([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-NormalizedTextHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return "sha256:" + ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Assert-ManifestContract([string]$Target, [string]$ProjectName) {
    $managed = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot "managed-files.json") |
        ConvertFrom-Json
    $manifestPath = Join-Path $Target ".project-flow/manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Manifest is missing: $manifestPath"
    }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    if ($managed.workflow_version -cne "0.3.0" -or $manifest.schema_version -ne 1 -or
        $manifest.workflow_version -cne $managed.workflow_version -or $manifest.project_name -cne $ProjectName) {
        throw "Manifest metadata is inconsistent with managed-files.json."
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.installed_at_utc)) {
        throw "Manifest installation timestamp is missing."
    }
    if ($manifest.PSObject.Properties.Name -notcontains "last_transaction") {
        throw "Manifest last_transaction field is missing."
    }
    if ($null -ne $manifest.last_transaction -and
        [string]$manifest.last_transaction -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        throw "Manifest last_transaction is invalid."
    }
    $expected = @($managed.files)
    $actual = @($manifest.files)
    if ($actual.Count -ne $expected.Count) { throw "Manifest managed path count is incorrect." }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($actual[$index].path -cne $expected[$index].path -or
            $actual[$index].source -cne $expected[$index].source -or
            $actual[$index].policy -cne $expected[$index].policy) {
            throw "Manifest managed paths do not exactly match managed-files.json."
        }
        $sourceText = Get-NormalizedText (Join-Path $repoRoot ([string]$expected[$index].source))
        if ($expected[$index].render -ceq "project_name_json") {
            $replacement = ConvertTo-Json -InputObject $ProjectName -Compress
            $sourceText = $sourceText.Replace('"<PROJECT_NAME>"', $replacement)
        } else {
            $sourceText = $sourceText.Replace("<PROJECT_NAME>", $ProjectName)
        }
        $expectedHash = Get-NormalizedTextHash $sourceText
        if ([string]$actual[$index].baseline_hash -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            $actual[$index].baseline_hash -cne $expectedHash) {
            throw "Manifest baseline hash is invalid for $($expected[$index].path)."
        }
    }
    if (@($actual | Where-Object { $_.path -ceq ".agents/prompts/09_execution_handoff.md" }).Count -ne 1) {
        throw "Manifest does not manage the execution-task handoff prompt exactly once."
    }
}

function New-LegacyFixture([string]$Target, [string]$ProjectName) {
    $baselineRoot = Join-Path $repoRoot "baselines/0.2.0"
    Get-ChildItem -LiteralPath $baselineRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($baselineRoot.Length).TrimStart('\', '/')
        $destination = Join-Path $Target $relative
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        $text = Get-NormalizedText $_.FullName
        if ($relative.Replace('\', '/') -ceq ".agents/workflow.json") {
            $replacement = ConvertTo-Json -InputObject $ProjectName -Compress
            $text = $text.Replace('"<PROJECT_NAME>"', $replacement)
        } else {
            $text = $text.Replace("<PROJECT_NAME>", $ProjectName)
        }
        [System.IO.File]::WriteAllText($destination, $text, $utf8NoBom)
    }
}

function Get-DeployedDigest([string]$Root) {
    $items = Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object {
            $relative = $_.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
            -not $relative.StartsWith(".project-flow/") -and
                -not $relative.StartsWith(".project-flow-backup/")
        } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
            "$relative=$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash)"
        }
    return ($items -join "`n")
}

try {
    [System.IO.Directory]::CreateDirectory($emptyTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($existingTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($legacyTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($upgradeTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($conflictTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($noopInvalidTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($controlTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($linkTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($outsideTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($fakeHandoffTarget) | Out-Null

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
        $bootstrapDescription -notmatch '(?i)\b(?:claim|adopt|make)\w*\b' -or
        $bootstrapDescription -notmatch '(?i)\buser-visible\b.*\bproject hub\b'
    ) {
        throw "Bootstrap Skill description does not cover import and current-task project hub adoption."
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
            '(?is)\[codex-project-flow:hub-claim:v1\].{0,180}\bprojectId\s*=.{1,160};\s*hubTitle\s*='
    ) {
        throw "Bootstrap Skill does not define the interrupted current-task claim identity."
    }
    if ($bootstrapSkillText -notmatch '\bseparateHubMode\b') {
        throw "Bootstrap Skill does not preserve the explicit separate-hub compatibility mode."
    }
    if ($bootstrapSkillText -notmatch '(?is)(?:omit|omitted).{0,40}threadId|threadId.{0,40}(?:omit|omitted)') {
        throw "Bootstrap Skill does not describe the implicit current-task title operation."
    }
    if ($bootstrapSkillText -notmatch '(?is)never call `?create_thread`?.{0,160}(?:failed|ambiguous)') {
        throw "Bootstrap Skill does not forbid silent create_thread fallback after claim failure."
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
    if ($bootstrapDefaultPrompt -notmatch '(?i)(?:claim|adopt).{0,80}(?:this|current).{0,40}(?:task|hub)|(?:this|current).{0,40}task.{0,80}(?:claim|adopt)') {
        throw "Bootstrap openai.yaml default_prompt does not make current-task hub adoption the default."
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
    Assert-ManifestContract $emptyTarget $specialProjectName
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
    if (-not (Test-Path -LiteralPath (Join-Path $emptyTarget ".agents/prompts/09_execution_handoff.md") -PathType Leaf)) {
        throw "Installer did not copy the execution-task handoff prompt."
    }
    $rotationKeyFormat = '[codex-project-flow:execution:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>'
    foreach ($rotationIdentityRelative in @(
        ".agents/workflow.json",
        ".agents/prompts/00_project_hub.md",
        ".agents/prompts/09_execution_handoff.md"
    )) {
        if (-not [System.IO.File]::ReadAllText((Join-Path $emptyTarget $rotationIdentityRelative)).Contains($rotationKeyFormat)) {
            throw "Execution-task rotation identity is missing from $rotationIdentityRelative"
        }
    }
    $installedHubPromptPath = Join-Path $emptyTarget ".agents/prompts/00_project_hub.md"
    $validHubPrompt = [System.IO.File]::ReadAllText($installedHubPromptPath)
    [System.IO.File]::WriteAllText(
        $installedHubPromptPath,
        ([System.IO.File]::ReadAllText((Join-Path $repoRoot "baselines/0.2.0/.agents/prompts/00_project_hub.md")) +
            "`n[codex-project-flow:execution:v1] manually merged rotation identity`n"),
        $utf8NoBom
    )
    & $validate -Target $emptyTarget *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Validator accepted a legacy hub prompt with only a fake rotation marker."
    }
    [System.IO.File]::WriteAllText($installedHubPromptPath, $validHubPrompt, $utf8NoBom)
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
        },
        @{
            Name = "task_rotation without separate authorization"
            Mutate = {
                param($Workflow)
                $Workflow.authorization.task_rotation = "combined"
            }
        },
        @{
            Name = "an incorrect execution-task rotation review threshold"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.rotation.review_after_substantive_turns = 5
            }
        },
        @{
            Name = "a rotation state machine without archive_predecessor"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.rotation.state_machine = @(
                    $Workflow.task_policy.rotation.state_machine |
                        Where-Object { $_ -cne "archive_predecessor" }
                )
            }
        },
        @{
            Name = "a reordered execution-task rotation state machine"
            Mutate = {
                param($Workflow)
                $states = @($Workflow.task_policy.rotation.state_machine)
                $temporaryState = $states[2]
                $states[2] = $states[3]
                $states[3] = $temporaryState
                $Workflow.task_policy.rotation.state_machine = $states
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
    [System.IO.File]::AppendAllText($existingAgents, "`nlocal reset candidate`n", $utf8NoBom)
    $existingManifestPath = Join-Path $existingTarget ".project-flow/manifest.json"
    $staleManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $existingManifestPath | ConvertFrom-Json
    $staleManifest.workflow_version = "9.9.9"
    [System.IO.File]::WriteAllText($existingManifestPath, ($staleManifest | ConvertTo-Json -Depth 20) + "`n", $utf8NoBom)
    & $install -Target $existingTarget -ProjectName "Existing Project" -Force
    if ($LASTEXITCODE -ne 0) { throw "Forced reset failed to replace a stale manifest." }
    Assert-ManifestContract $existingTarget "Existing Project"
    $backupText = @(Get-ChildItem -LiteralPath (Join-Path $existingTarget ".project-flow-backup") -Recurse -File | ForEach-Object {
        [System.IO.File]::ReadAllText($_.FullName)
    }) -join "`n"
    if ($backupText -notmatch 'local reset candidate' -or $backupText -notmatch '"workflow_version"\s*:\s*"9\.9\.9"') {
        throw "Forced reset did not back up the customized file and stale manifest."
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

    & $install -Target $noopInvalidTarget -ProjectName "Invalid NOOP Project"
    if ($LASTEXITCODE -ne 0) { throw "Invalid-NOOP fixture installation failed." }
    $noopManifestPath = Join-Path $noopInvalidTarget ".project-flow/manifest.json"
    $invalidNoopManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $noopManifestPath | ConvertFrom-Json
    $invalidNoopManifest.files[0].policy = "seed_once"
    [System.IO.File]::WriteAllText($noopManifestPath, ($invalidNoopManifest | ConvertTo-Json -Depth 20) + "`n", $utf8NoBom)
    $invalidNoopRejected = $false
    try {
        & $upgrade -Target $noopInvalidTarget -Apply *> $null
        $invalidNoopRejected = $LASTEXITCODE -ne 0
    } catch {
        $invalidNoopRejected = $true
    }
    if (-not $invalidNoopRejected) { throw "Upgrade reported NOOP for an invalid manifest contract." }
    if (Test-Path -LiteralPath (Join-Path $noopInvalidTarget ".project-flow/transactions")) {
        throw "Rejected invalid NOOP unexpectedly created a transaction."
    }

    $legacyProjectName = "Legacy Upgrade Project"
    New-LegacyFixture $upgradeTarget $legacyProjectName
    $legacyStatePath = Join-Path $upgradeTarget "docs/PROJECT_STATE.md"
    [System.IO.File]::WriteAllText(
        $legacyStatePath,
        "# Project state`n`nlegacy state must survive upgrade`n",
        $utf8NoBom
    )
    $legacyStateBefore = [System.IO.File]::ReadAllText($legacyStatePath)
    $legacyTreeBefore = Get-DeployedDigest $upgradeTarget

    $missingAdoptRejected = $false
    try {
        & $upgrade -Target $upgradeTarget -Plan *> $null
        $missingAdoptRejected = $LASTEXITCODE -ne 0
    } catch {
        $missingAdoptRejected = $true
    }
    if (-not $missingAdoptRejected) {
        throw "Legacy upgrade did not require explicit -AdoptFrom 0.2.0."
    }
    if (Test-Path -LiteralPath (Join-Path $upgradeTarget ".project-flow/manifest.json")) {
        throw "Rejected legacy upgrade unexpectedly created a manifest."
    }

    $legacyPlan = @(& $upgrade -Target $upgradeTarget -AdoptFrom "0.2.0" -Plan 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "Legacy adoption plan failed." }
    $legacyPlanText = $legacyPlan -join "`n"
    if ($legacyPlanText -notmatch '(?m)^UPGRADE 0\.2\.0 -> 0\.3\.0$' -or
        $legacyPlanText -notmatch '(?m)^CREATE\s+replace_if_unmodified\s+\.agents/prompts/09_execution_handoff\.md$' -or
        $legacyPlanText -notmatch '(?m)^PRESERVE\s+seed_once\s+docs/PROJECT_STATE\.md$') {
        throw "Legacy adoption plan did not expose the required 0.3 create and preserve decisions."
    }
    if ((Get-DeployedDigest $upgradeTarget) -cne $legacyTreeBefore -or
        (Test-Path -LiteralPath (Join-Path $upgradeTarget ".project-flow/manifest.json"))) {
        throw "Legacy adoption plan mutated live files or created a manifest."
    }

    New-LegacyFixture $fakeHandoffTarget "Fake Handoff Project"
    $fakeHandoffPath = Join-Path $fakeHandoffTarget ".agents/prompts/09_execution_handoff.md"
    [System.IO.File]::WriteAllText($fakeHandoffPath, "$rotationKeyFormat`n", $utf8NoBom)
    $fakeHandoffTreeBefore = Get-DeployedDigest $fakeHandoffTarget
    $fakeHandoffRejected = $false
    try {
        & $upgrade -Target $fakeHandoffTarget -AdoptFrom "0.2.0" -Apply `
            -AcceptLocal ".agents/prompts/09_execution_handoff.md" *> $null
        $fakeHandoffRejected = $LASTEXITCODE -ne 0
    } catch {
        $fakeHandoffRejected = $true
    }
    if (-not $fakeHandoffRejected) {
        throw "Upgrade accepted a fake local execution handoff containing only the rotation key."
    }
    if ((Get-DeployedDigest $fakeHandoffTarget) -cne $fakeHandoffTreeBefore -or
        (Test-Path -LiteralPath (Join-Path $fakeHandoffTarget ".project-flow/manifest.json"))) {
        throw "Rejected fake execution handoff was not rolled back completely."
    }

    $oldHub = Join-Path $repoRoot "baselines/0.2.0/.agents/prompts/00_project_hub.md"
    $newHub = Join-Path $repoRoot ".agents/prompts/00_project_hub.md"
    if ([System.IO.File]::ReadAllText($oldHub) -ceq [System.IO.File]::ReadAllText($newHub)) {
        throw "Upgrade fixture cannot prove replacement because the old and new hub prompts are identical."
    }
    $legacyApply = @(& $upgrade -Target $upgradeTarget -AdoptFrom "0.2.0" -Apply 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "Legacy adoption apply failed." }
    $transactionMatch = [regex]::Match(($legacyApply -join "`n"), '(?m)^APPLIED (?<id>[A-Za-z0-9][A-Za-z0-9._-]*)$')
    if (-not $transactionMatch.Success) { throw "Legacy adoption apply did not report a transaction." }
    $legacyTransaction = $transactionMatch.Groups["id"].Value
    if (-not (Test-Path -LiteralPath (Join-Path $upgradeTarget ".project-flow/transactions/$legacyTransaction/transaction.json") -PathType Leaf)) {
        throw "Legacy adoption transaction metadata is missing."
    }
    if ([System.IO.File]::ReadAllText((Join-Path $upgradeTarget ".agents/prompts/00_project_hub.md")) -cne
        [System.IO.File]::ReadAllText($newHub)) {
        throw "An unchanged legacy managed file was not updated to the 0.3 source."
    }
    if ([System.IO.File]::ReadAllText((Join-Path $upgradeTarget ".agents/prompts/09_execution_handoff.md")) -cne
        [System.IO.File]::ReadAllText((Join-Path $repoRoot ".agents/prompts/09_execution_handoff.md"))) {
        throw "Legacy adoption did not install the 0.3 execution-task handoff prompt."
    }
    if ([System.IO.File]::ReadAllText($legacyStatePath) -cne $legacyStateBefore) {
        throw "Legacy adoption changed docs/PROJECT_STATE.md."
    }
    Assert-ManifestContract $upgradeTarget $legacyProjectName
    $appliedManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $upgradeTarget ".project-flow/manifest.json") |
        ConvertFrom-Json
    if ($appliedManifest.last_transaction -cne $legacyTransaction) {
        throw "Legacy adoption manifest does not reference its applied transaction."
    }

    $transactionRoot = Join-Path $upgradeTarget ".project-flow/transactions"
    $transactionCountBefore = @(Get-ChildItem -LiteralPath $transactionRoot -Directory).Count
    $manifestPath = Join-Path $upgradeTarget ".project-flow/manifest.json"
    $manifestDigestBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash
    $noopOutput = @(& $upgrade -Target $upgradeTarget -Apply 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0 -or ($noopOutput -join "`n") -notmatch '(?m)^NOOP already up to date$') {
        throw "Second upgrade apply did not report NOOP."
    }
    if (@(Get-ChildItem -LiteralPath $transactionRoot -Directory).Count -ne $transactionCountBefore -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash -cne $manifestDigestBefore) {
        throw "NOOP apply created a transaction or changed the manifest."
    }

    $rollbackOutput = @(& $upgrade -Target $upgradeTarget -Rollback $legacyTransaction 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0 -or ($rollbackOutput -join "`n") -notmatch "(?m)^ROLLED_BACK $([regex]::Escape($legacyTransaction))$") {
        throw "Upgrade rollback did not report the restored transaction."
    }
    if ((Get-DeployedDigest $upgradeTarget) -cne $legacyTreeBefore) {
        throw "Rollback did not restore the complete pre-upgrade deployed state."
    }
    if ((Test-Path -LiteralPath $manifestPath) -or
        (Test-Path -LiteralPath (Join-Path $upgradeTarget ".agents/prompts/09_execution_handoff.md"))) {
        throw "Rollback did not restore the pre-adoption manifest and file set."
    }

    New-LegacyFixture $conflictTarget "Conflict Upgrade Project"
    $conflictHub = Join-Path $conflictTarget ".agents/prompts/00_project_hub.md"
    [System.IO.File]::AppendAllText($conflictHub, "`nlocal project-hub customization`n", $utf8NoBom)
    $conflictTreeBefore = Get-DeployedDigest $conflictTarget
    $conflictOutput = @(& $upgrade -Target $conflictTarget -AdoptFrom "0.2.0" -Apply 2>&1 | ForEach-Object { $_.ToString() })
    $conflictStatus = $LASTEXITCODE
    if ($conflictStatus -ne 4) {
        throw "Conflicting legacy adoption returned $conflictStatus instead of 4: $($conflictOutput -join ' ')"
    }
    if ((Get-DeployedDigest $conflictTarget) -cne $conflictTreeBefore -or
        (Test-Path -LiteralPath (Join-Path $conflictTarget ".project-flow/manifest.json"))) {
        throw "Conflict handling changed live managed files or the manifest."
    }
    $stagingPlans = @(Get-ChildItem -LiteralPath (Join-Path $conflictTarget ".project-flow/staging") -Recurse -File -Filter "plan.json")
    if ($stagingPlans.Count -eq 0) { throw "Conflict handling did not create a reviewable staging plan." }

    [System.IO.File]::WriteAllText(
        $conflictHub,
        ([System.IO.File]::ReadAllText((Join-Path $repoRoot ".agents/prompts/00_project_hub.md")) +
            "`nlocal project-hub customization retained after manual merge`n"),
        $utf8NoBom
    )
    $conflictHubBefore = [System.IO.File]::ReadAllText($conflictHub)
    $acceptedTreeBefore = Get-DeployedDigest $conflictTarget
    $acceptedOutput = @(
        & $upgrade -Target $conflictTarget -AdoptFrom "0.2.0" -Apply -AcceptLocal ".agents/prompts/00_project_hub.md" 2>&1 |
            ForEach-Object { $_.ToString() }
    )
    if ($LASTEXITCODE -ne 0 -or ($acceptedOutput -join "`n") -notmatch
        '(?m)^ACCEPT\s+replace_if_unmodified\s+\.agents/prompts/00_project_hub\.md$') {
        throw "Explicit local conflict acceptance was not reported in the apply plan."
    }
    $acceptedMatch = [regex]::Match(($acceptedOutput -join "`n"), '(?m)^APPLIED (?<id>[A-Za-z0-9][A-Za-z0-9._-]*)$')
    if (-not $acceptedMatch.Success) { throw "Explicit local conflict acceptance did not create a transaction." }
    $acceptedTransaction = $acceptedMatch.Groups["id"].Value
    if ([System.IO.File]::ReadAllText($conflictHub) -cne $conflictHubBefore) {
        throw "Explicit local conflict acceptance overwrote the reviewed live file."
    }
    Assert-ManifestContract $conflictTarget "Conflict Upgrade Project"
    $acceptedMeta = Get-Content -Raw -Encoding UTF8 -LiteralPath (
        Join-Path $conflictTarget ".project-flow/transactions/$acceptedTransaction/transaction.json"
    ) | ConvertFrom-Json
    if (@($acceptedMeta.accepted_local).Count -ne 1 -or
        [string]$acceptedMeta.accepted_local[0] -cne ".agents/prompts/00_project_hub.md") {
        throw "Accepted local path was not recorded in transaction metadata."
    }
    & $upgrade -Target $conflictTarget -Rollback $acceptedTransaction *> $null
    if ($LASTEXITCODE -ne 0 -or (Get-DeployedDigest $conflictTarget) -cne $acceptedTreeBefore -or
        (Test-Path -LiteralPath (Join-Path $conflictTarget ".project-flow/manifest.json"))) {
        throw "Rollback after local conflict acceptance did not restore the pre-acceptance state."
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
