$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$install = Join-Path $repoRoot "scripts/install.ps1"
$validate = Join-Path $repoRoot "scripts/validate.ps1"
$upgrade = Join-Path $repoRoot "scripts/upgrade.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-project-flow-" + [guid]::NewGuid().ToString("N"))
$emptyTarget = Join-Path $testRoot "empty-project"
$existingTarget = Join-Path $testRoot "existing-project"
$legacyTarget = Join-Path $testRoot "legacy-project"
$versionedTarget = Join-Path $testRoot "versioned-project"
$previousTarget = Join-Path $testRoot "previous-project"
$latestPreviousTarget = Join-Path $testRoot "latest-previous-project"
$upgradeTarget = Join-Path $testRoot "upgrade-project"
$ownershipTarget = Join-Path $testRoot "ownership-project"
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
    if ($managed.workflow_version -cne "0.4.2" -or $manifest.schema_version -ne 1 -or
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
    if (@($actual | Where-Object { $_.path -ceq ".agents/prompts/10_upgrade_coordination.md" }).Count -ne 1) {
        throw "Manifest does not manage the upgrade-coordination prompt exactly once."
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

function New-VersionedFixture([string]$Target, [string]$ProjectName, [string]$Version = "0.3.0") {
    $baselineRoot = Join-Path $repoRoot "baselines/$Version"
    $managed = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot "managed-files.json") |
        ConvertFrom-Json
    $migration = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot "migrations/$Version-to-0.4.2.json") |
        ConvertFrom-Json
    $introduced = @{}
    foreach ($relative in @($migration.introduced_files)) { $introduced[[string]$relative] = $true }
    $manifestFiles = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($managed.files)) {
        $relative = [string]$entry.path
        if ($introduced.ContainsKey($relative)) { continue }
        $source = Join-Path $baselineRoot $relative
        $destination = Join-Path $Target $relative
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        $text = Get-NormalizedText $source
        if ([string]$entry.render -ceq "project_name_json") {
            $replacement = ConvertTo-Json -InputObject $ProjectName -Compress
            $text = $text.Replace('"<PROJECT_NAME>"', $replacement)
        } else {
            $text = $text.Replace("<PROJECT_NAME>", $ProjectName)
        }
        [System.IO.File]::WriteAllText($destination, $text, $utf8NoBom)
        $manifestFiles.Add([ordered]@{
            path = $relative
            source = [string]$entry.source
            policy = [string]$entry.policy
            baseline_hash = Get-NormalizedTextHash $text
        })
    }
    $manifest = [ordered]@{
        schema_version = 1
        workflow_version = $Version
        project_name = $ProjectName
        installed_at_utc = "2026-08-22T00:00:00Z"
        last_transaction = $null
        files = $manifestFiles.ToArray()
    }
    $manifestPath = Join-Path $Target ".project-flow/manifest.json"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $manifestPath)) | Out-Null
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20) + "`n", $utf8NoBom)
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
    [System.IO.Directory]::CreateDirectory($versionedTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($previousTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($upgradeTarget) | Out-Null
    [System.IO.Directory]::CreateDirectory($ownershipTarget) | Out-Null
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

    $contractFiles = @(
        "AGENTS.md",
        ".agents/workflow.json",
        ".agents/prompts/00_project_hub.md",
        ".agents/snippets/AGENTS.integration.md",
        "docs/DEVELOPMENT_SOP.md",
        "docs/WORKFLOW_GUIDE.md",
        "README.md",
        "skills/bootstrap-project-flow/SKILL.md"
    )
    $contractText = @($contractFiles | ForEach-Object {
        [System.IO.File]::ReadAllText((Join-Path $repoRoot $_))
    }) -join "`n"
    foreach ($forbiddenPattern in @(
        '默认最多(?:保留|维护)?一个',
        'at most one active',
        '在当前(?:中枢任务|会话)继续'
    )) {
        if ($contractText -match $forbiddenPattern) {
            throw "Workflow surfaces retain a conflicting hub rule: $forbiddenPattern"
        }
    }
    foreach ($requiredPattern in @(
        '最多(?:保留|维护|协调)?五个',
        '禁止回退',
        '隐藏子代理',
        '无冲突.{0,20}并行',
        '选择编号.{0,30}授权创建'
    )) {
        if ($contractText -notmatch $requiredPattern) {
            throw "Workflow surfaces are missing a fail-closed rule: $requiredPattern"
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
    if (-not (Test-Path -LiteralPath (Join-Path $emptyTarget ".agents/prompts/10_upgrade_coordination.md") -PathType Leaf)) {
        throw "Installer did not copy the upgrade-coordination prompt."
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
    $successorKeyFormat = '[codex-project-flow:execution:v2] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>'
    $taskHandshakeFormat = '[codex-project-flow:handshake:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>; generation=<positiveInteger>'
    $hubHandshakeFormat = '[codex-project-flow:hub-handshake:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>'
    foreach ($upgradeIdentityRelative in @(
        ".agents/workflow.json",
        ".agents/prompts/00_project_hub.md",
        ".agents/prompts/09_execution_handoff.md",
        ".agents/prompts/10_upgrade_coordination.md"
    )) {
        if (-not [System.IO.File]::ReadAllText((Join-Path $emptyTarget $upgradeIdentityRelative)).Contains($successorKeyFormat)) {
            throw "Upgrade successor identity is missing from $upgradeIdentityRelative"
        }
    }
    $installedUpgradePromptPath = Join-Path $emptyTarget ".agents/prompts/10_upgrade_coordination.md"
    $validUpgradePrompt = [System.IO.File]::ReadAllText($installedUpgradePromptPath)
    foreach ($requiredHandshake in @($taskHandshakeFormat, $hubHandshakeFormat)) {
        if (-not $validUpgradePrompt.Contains($requiredHandshake)) {
            throw "Upgrade coordination prompt is missing handshake: $requiredHandshake"
        }
    }
    [System.IO.File]::WriteAllText($installedUpgradePromptPath, "$successorKeyFormat`n", $utf8NoBom)
    & $validate -Target $emptyTarget *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Validator accepted a fake upgrade prompt containing only the v2 successor key."
    }
    [System.IO.File]::WriteAllText($installedUpgradePromptPath, $validUpgradePrompt, $utf8NoBom)
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
    $invalidConfig = $validConfigText | ConvertFrom-Json
    $invalidConfig.upgrade_policy.failure_behavior = "release_barrier_and_continue"
    [System.IO.File]::WriteAllText(
        (Join-Path $emptyTarget ".agents/workflow.json"),
        ($invalidConfig | ConvertTo-Json -Depth 20),
        $utf8NoBom
    )
    & $validate -Target $emptyTarget *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Validator accepted an upgrade policy that releases the barrier on failure."
    }
    $invalidUpgradePolicyCases = @(
        @{
            Name = "cross-project scope"
            Mutate = { param($Workflow) $Workflow.upgrade_policy.project_scope = "any_named_project" }
        },
        @{
            Name = "summary-based handshake evidence"
            Mutate = { param($Workflow) $Workflow.upgrade_policy.handshake_evidence = "task_summary_allowed" }
        },
        @{
            Name = "missing empty-snapshot fast path"
            Mutate = { param($Workflow) $Workflow.upgrade_policy.empty_snapshot_fast_path = "always_create_successors" }
        },
        @{
            Name = "unbounded empty-successor follow-up"
            Mutate = { param($Workflow) $Workflow.upgrade_policy.empty_successor_followup_limit = 2 }
        },
        @{
            Name = "unbounded compensating successor"
            Mutate = { param($Workflow) $Workflow.upgrade_policy.compensating_successor_limit = 2 }
        }
    )
    foreach ($case in $invalidUpgradePolicyCases) {
        $invalidConfig = $validConfigText | ConvertFrom-Json
        & $case.Mutate $invalidConfig
        [System.IO.File]::WriteAllText(
            (Join-Path $emptyTarget ".agents/workflow.json"),
            ($invalidConfig | ConvertTo-Json -Depth 20),
            $utf8NoBom
        )
        & $validate -Target $emptyTarget *> $null
        if ($LASTEXITCODE -eq 0) {
            throw "Validator accepted invalid upgrade policy: $($case.Name)."
        }
    }
    $invalidTaskPolicyCases = @(
        @{
            Name = "max_active_tasks set to 1"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.max_active_tasks = 1
            }
        },
        @{
            Name = "queued tasks not occupying a slot"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.blocked_waiting_or_queued_occupies_slot = $false
            }
        },
        @{
            Name = "a missing user-visible execution-task requirement"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.execution_task_requirement = "hub_execution_allowed"
            }
        },
        @{
            Name = "selection authorizing hub execution"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.selected_item_authorization = "authorize_hub_execution"
            }
        },
        @{
            Name = "task-management failure allowing hub fallback"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.task_management_failure = "continue_in_hub"
            }
        },
        @{
            Name = "hidden subagents substituting for user-visible tasks"
            Mutate = {
                param($Workflow)
                $Workflow.task_policy.hidden_subagents = "may_substitute"
            }
        },
        @{
            Name = "a project hub allowed to execute"
            Mutate = {
                param($Workflow)
                $Workflow.execution_policy.project_hub_role = "execute"
            }
        },
        @{
            Name = "project hub execution fallback enabled"
            Mutate = {
                param($Workflow)
                $Workflow.execution_policy.project_hub_execution_fallback = "allowed"
            }
        },
        @{
            Name = "non-conflicting operations forced serial"
            Mutate = {
                param($Workflow)
                $Workflow.execution_policy.non_conflicting_operations = "serial"
            }
        },
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

    $latestPreviousProjectName = "Latest Previous Upgrade Project"
    New-VersionedFixture $latestPreviousTarget $latestPreviousProjectName "0.4.1"
    $latestPreviousTreeBefore = Get-DeployedDigest $latestPreviousTarget
    $latestPreviousManifestPath = Join-Path $latestPreviousTarget ".project-flow/manifest.json"
    $latestPreviousManifestHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $latestPreviousManifestPath).Hash
    $latestPreviousPlan = @(& $upgrade -Target $latestPreviousTarget -Plan *>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    if ($LASTEXITCODE -ne 0 -or
        $latestPreviousPlan -notmatch '(?m)^UPGRADE 0\.4\.1 -> 0\.4\.2$' -or
        $latestPreviousPlan -notmatch '(?m)^REPLACE\s+structured_manual\s+\.agents/workflow\.json$' -or
        $latestPreviousPlan -notmatch '(?m)^REPLACE\s+replace_if_unmodified\s+\.agents/prompts/10_upgrade_coordination\.md$') {
        throw "0.4.1 upgrade plan did not expose the required 0.4.2 workflow replacements."
    }
    if ((Get-DeployedDigest $latestPreviousTarget) -cne $latestPreviousTreeBefore -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $latestPreviousManifestPath).Hash -cne $latestPreviousManifestHashBefore) {
        throw "0.4.1 upgrade plan mutated the project."
    }
    $latestPreviousApply = @(& $upgrade -Target $latestPreviousTarget -Apply *>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    $latestPreviousMatch = [regex]::Match($latestPreviousApply, '(?m)^APPLIED (?<id>[A-Za-z0-9][A-Za-z0-9._-]*)$')
    if ($LASTEXITCODE -ne 0 -or -not $latestPreviousMatch.Success) {
        throw "0.4.1 upgrade apply failed: $latestPreviousApply"
    }
    $latestPreviousTransaction = $latestPreviousMatch.Groups["id"].Value
    Assert-ManifestContract $latestPreviousTarget $latestPreviousProjectName
    & $upgrade -Target $latestPreviousTarget -Rollback $latestPreviousTransaction *> $null
    if ($LASTEXITCODE -ne 0 -or (Get-DeployedDigest $latestPreviousTarget) -cne $latestPreviousTreeBefore -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $latestPreviousManifestPath).Hash -cne $latestPreviousManifestHashBefore) {
        throw "0.4.1 upgrade rollback did not restore the original project and manifest."
    }

    $previousProjectName = "Previous Upgrade Project"
    New-VersionedFixture $previousTarget $previousProjectName "0.3.1"
    $previousTreeBefore = Get-DeployedDigest $previousTarget
    $previousManifestPath = Join-Path $previousTarget ".project-flow/manifest.json"
    $previousManifestHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $previousManifestPath).Hash
    $previousPlan = @(& $upgrade -Target $previousTarget -Plan *>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "0.3.1 upgrade plan failed." }
    $previousPlanText = $previousPlan -join "`n"
    if ($previousPlanText -notmatch '(?m)^UPGRADE 0\.3\.1 -> 0\.4\.2$' -or
        $previousPlanText -notmatch '(?m)^CREATE\s+replace_if_unmodified\s+\.agents/prompts/10_upgrade_coordination\.md$') {
        throw "0.3.1 upgrade plan did not expose the required 0.4.2 coordination prompt."
    }
    if ((Get-DeployedDigest $previousTarget) -cne $previousTreeBefore -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $previousManifestPath).Hash -cne $previousManifestHashBefore) {
        throw "0.3.1 upgrade plan mutated the project."
    }
    $previousApply = @(& $upgrade -Target $previousTarget -Apply *>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "0.3.1 upgrade apply failed." }
    $previousMatch = [regex]::Match(($previousApply -join "`n"), '(?m)^APPLIED (?<id>[A-Za-z0-9][A-Za-z0-9._-]*)$')
    if (-not $previousMatch.Success) { throw "0.3.1 upgrade apply did not report a transaction." }
    $previousTransaction = $previousMatch.Groups["id"].Value
    Assert-ManifestContract $previousTarget $previousProjectName
    $previousManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $previousManifestPath | ConvertFrom-Json
    if ($previousManifest.workflow_version -cne "0.4.2" -or
        $previousManifest.last_transaction -cne $previousTransaction) {
        throw "0.3.1 upgrade did not advance the manifest to 0.4.2."
    }
    $previousTransactionCount = @(Get-ChildItem -LiteralPath (Join-Path $previousTarget ".project-flow/transactions") -Directory).Count
    $previousNoop = @(& $upgrade -Target $previousTarget -Apply *>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0 -or ($previousNoop -join "`n") -notmatch '(?m)^NOOP already up to date$' -or
        @(Get-ChildItem -LiteralPath (Join-Path $previousTarget ".project-flow/transactions") -Directory).Count -ne $previousTransactionCount) {
        throw "Second 0.4.2 apply after 0.3.1 upgrade did not remain a transaction-free NOOP."
    }
    & $upgrade -Target $previousTarget -Rollback $previousTransaction *> $null
    if ($LASTEXITCODE -ne 0 -or (Get-DeployedDigest $previousTarget) -cne $previousTreeBefore -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $previousManifestPath).Hash -cne $previousManifestHashBefore) {
        throw "0.3.1 upgrade rollback did not restore the original project and manifest."
    }

    $versionedProjectName = "Versioned Upgrade Project"
    New-VersionedFixture $versionedTarget $versionedProjectName
    $versionedTreeBefore = Get-DeployedDigest $versionedTarget
    $versionedManifestPath = Join-Path $versionedTarget ".project-flow/manifest.json"
    $versionedManifestHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $versionedManifestPath).Hash
    $versionedPlan = @(& $upgrade -Target $versionedTarget -Plan *>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "0.3.0 upgrade plan failed." }
    $versionedPlanText = $versionedPlan -join "`n"
    if ($versionedPlanText -notmatch '(?m)^UPGRADE 0\.3\.0 -> 0\.4\.2$' -or
        $versionedPlanText -notmatch '(?m)^REPLACE\s+structured_manual\s+\.agents/workflow\.json$' -or
        $versionedPlanText -notmatch '(?m)^CREATE\s+replace_if_unmodified\s+\.agents/prompts/10_upgrade_coordination\.md$') {
        throw "0.3.0 upgrade plan did not expose the required 0.4.2 replacements."
    }
    if ((Get-DeployedDigest $versionedTarget) -cne $versionedTreeBefore -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $versionedManifestPath).Hash -cne $versionedManifestHashBefore) {
        throw "0.3.0 upgrade plan mutated the project."
    }
    $versionedApply = @(& $upgrade -Target $versionedTarget -Apply *>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "0.3.0 upgrade apply failed." }
    $versionedMatch = [regex]::Match(($versionedApply -join "`n"), '(?m)^APPLIED (?<id>[A-Za-z0-9][A-Za-z0-9._-]*)$')
    if (-not $versionedMatch.Success) { throw "0.3.0 upgrade apply did not report a transaction." }
    $versionedTransaction = $versionedMatch.Groups["id"].Value
    Assert-ManifestContract $versionedTarget $versionedProjectName
    $versionedManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $versionedManifestPath | ConvertFrom-Json
    $versionedMetaPath = Join-Path $versionedTarget ".project-flow/transactions/$versionedTransaction/transaction.json"
    $versionedMeta = Get-Content -Raw -Encoding UTF8 -LiteralPath $versionedMetaPath | ConvertFrom-Json
    if ((Get-NormalizedTextHash (Get-NormalizedText $versionedManifestPath)) -cne $versionedMeta.new_manifest_hash) {
        throw "0.3.0 upgrade apply produced a manifest outside its recorded transaction hash."
    }
    if ($versionedManifest.workflow_version -cne "0.4.2" -or
        $versionedManifest.last_transaction -cne $versionedTransaction) {
        throw "0.3.0 upgrade did not advance the manifest to 0.4.2."
    }
    $versionedTransactionCount = @(Get-ChildItem -LiteralPath (Join-Path $versionedTarget ".project-flow/transactions") -Directory).Count
    $versionedNoop = @(& $upgrade -Target $versionedTarget -Apply *>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0 -or ($versionedNoop -join "`n") -notmatch '(?m)^NOOP already up to date$' -or
        @(Get-ChildItem -LiteralPath (Join-Path $versionedTarget ".project-flow/transactions") -Directory).Count -ne $versionedTransactionCount) {
        throw "Second 0.4.2 apply did not remain a transaction-free NOOP."
    }
    if ((Get-NormalizedTextHash (Get-NormalizedText $versionedManifestPath)) -cne $versionedMeta.new_manifest_hash) {
        throw "Second 0.4.2 apply changed the manifest during NOOP."
    }
    try {
        $versionedRollback = @(& $upgrade -Target $versionedTarget -Rollback $versionedTransaction *>&1 | ForEach-Object { $_.ToString() })
    } catch {
        throw "0.3.0 upgrade rollback invocation failed: $($_.Exception.Message)"
    }
    if ($LASTEXITCODE -ne 0 -or ($versionedRollback -join "`n") -notmatch
        "(?m)^ROLLED_BACK $([regex]::Escape($versionedTransaction))$" -or
        (Get-DeployedDigest $versionedTarget) -cne $versionedTreeBefore -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $versionedManifestPath).Hash -cne $versionedManifestHashBefore) {
        throw "0.3.0 upgrade rollback did not restore the original project and manifest."
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

    $legacyPlan = @(& $upgrade -Target $upgradeTarget -AdoptFrom "0.2.0" -Plan *>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "Legacy adoption plan failed." }
    $legacyPlanText = $legacyPlan -join "`n"
    if ($legacyPlanText -notmatch '(?m)^UPGRADE 0\.2\.0 -> 0\.4\.2$' -or
        $legacyPlanText -notmatch '(?m)^CREATE\s+replace_if_unmodified\s+\.agents/prompts/09_execution_handoff\.md$' -or
        $legacyPlanText -notmatch '(?m)^CREATE\s+replace_if_unmodified\s+\.agents/prompts/10_upgrade_coordination\.md$' -or
        $legacyPlanText -notmatch '(?m)^PRESERVE\s+seed_once\s+docs/PROJECT_STATE\.md$') {
        throw "Legacy adoption plan did not expose the required 0.4.2 create and preserve decisions."
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
    $legacyApply = @(& $upgrade -Target $upgradeTarget -AdoptFrom "0.2.0" -Apply *>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "Legacy adoption apply failed." }
    $transactionMatch = [regex]::Match(($legacyApply -join "`n"), '(?m)^APPLIED (?<id>[A-Za-z0-9][A-Za-z0-9._-]*)$')
    if (-not $transactionMatch.Success) { throw "Legacy adoption apply did not report a transaction." }
    $legacyTransaction = $transactionMatch.Groups["id"].Value
    if (-not (Test-Path -LiteralPath (Join-Path $upgradeTarget ".project-flow/transactions/$legacyTransaction/transaction.json") -PathType Leaf)) {
        throw "Legacy adoption transaction metadata is missing."
    }
    if ([System.IO.File]::ReadAllText((Join-Path $upgradeTarget ".agents/prompts/00_project_hub.md")) -cne
        [System.IO.File]::ReadAllText($newHub)) {
        throw "An unchanged legacy managed file was not updated to the 0.4.2 source."
    }
    if ([System.IO.File]::ReadAllText((Join-Path $upgradeTarget ".agents/prompts/09_execution_handoff.md")) -cne
        [System.IO.File]::ReadAllText((Join-Path $repoRoot ".agents/prompts/09_execution_handoff.md"))) {
        throw "Legacy adoption did not install the 0.4.2 execution-task handoff prompt."
    }
    if ([System.IO.File]::ReadAllText((Join-Path $upgradeTarget ".agents/prompts/10_upgrade_coordination.md")) -cne
        [System.IO.File]::ReadAllText((Join-Path $repoRoot ".agents/prompts/10_upgrade_coordination.md"))) {
        throw "Legacy adoption did not install the 0.4.2 upgrade-coordination prompt."
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
    $noopOutput = @(& $upgrade -Target $upgradeTarget -Apply *>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0 -or ($noopOutput -join "`n") -notmatch '(?m)^NOOP already up to date$') {
        throw "Second upgrade apply did not report NOOP."
    }
    if (@(Get-ChildItem -LiteralPath $transactionRoot -Directory).Count -ne $transactionCountBefore -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash -cne $manifestDigestBefore) {
        throw "NOOP apply created a transaction or changed the manifest."
    }

    try {
        $rollbackOutput = @(& $upgrade -Target $upgradeTarget -Rollback $legacyTransaction *>&1 | ForEach-Object { $_.ToString() })
    } catch {
        throw "Legacy adoption rollback invocation failed: $($_.Exception.Message)"
    }
    if ($LASTEXITCODE -ne 0 -or ($rollbackOutput -join "`n") -notmatch "(?m)^ROLLED_BACK $([regex]::Escape($legacyTransaction))$") {
        throw "Upgrade rollback did not report the restored transaction."
    }
    if ((Get-DeployedDigest $upgradeTarget) -cne $legacyTreeBefore) {
        throw "Rollback did not restore the complete pre-upgrade deployed state."
    }
    if ((Test-Path -LiteralPath $manifestPath) -or
        (Test-Path -LiteralPath (Join-Path $upgradeTarget ".agents/prompts/09_execution_handoff.md")) -or
        (Test-Path -LiteralPath (Join-Path $upgradeTarget ".agents/prompts/10_upgrade_coordination.md"))) {
        throw "Rollback did not restore the pre-adoption manifest and file set."
    }

    New-VersionedFixture $ownershipTarget "Ownership Upgrade Project" "0.4.0"
    $ownershipAgents = Join-Path $ownershipTarget "AGENTS.md"
    $ownershipPrompt = Join-Path $ownershipTarget ".agents/prompts/10_upgrade_coordination.md"
    $ownershipState = Join-Path $ownershipTarget "docs/PROJECT_STATE.md"
    $agentsText = Get-NormalizedText $ownershipAgents
    $agentsText = [regex]::Replace($agentsText, '(?m)^(## 项目事实\n)', '$1' + "`n- 必须保留的本地项目事实。`n", 1)
    [System.IO.File]::WriteAllText($ownershipAgents, $agentsText, $utf8NoBom)
    [System.IO.File]::AppendAllText($ownershipPrompt, "`nlocal plugin workflow customization`n", $utf8NoBom)
    [System.IO.File]::WriteAllText($ownershipState, "# 项目状态`n`n必须保留的项目状态。`n", $utf8NoBom)
    $ownershipTreeBefore = Get-DeployedDigest $ownershipTarget
    $ownershipManifestPath = Join-Path $ownershipTarget ".project-flow/manifest.json"
    $ownershipManifestBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $ownershipManifestPath).Hash
    $ownershipPlan = @(& $upgrade -Target $ownershipTarget -Plan *>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    if ($LASTEXITCODE -ne 0 -or
        $ownershipPlan -notmatch '(?m)^MERGE\s+merge_manual\s+AGENTS\.md$' -or
        $ownershipPlan -notmatch '(?m)^UPSTREAM\s+replace_if_unmodified\s+\.agents/prompts/10_upgrade_coordination\.md$' -or
        $ownershipPlan -notmatch '(?m)^PRESERVE\s+seed_once\s+docs/PROJECT_STATE\.md$') {
        throw "0.4.0 ownership-aware plan did not expose MERGE, UPSTREAM, and PRESERVE actions."
    }
    $ownershipOutput = @(& $upgrade -Target $ownershipTarget -Apply *>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    $ownershipMatch = [regex]::Match($ownershipOutput, '(?m)^APPLIED (?<id>[A-Za-z0-9][A-Za-z0-9._-]*)$')
    if ($LASTEXITCODE -ne 0 -or -not $ownershipMatch.Success) { throw "Ownership-aware apply failed: $ownershipOutput" }
    $ownershipTransaction = $ownershipMatch.Groups["id"].Value
    if ((Get-NormalizedText $ownershipPrompt) -cne (Get-NormalizedText (Join-Path $repoRoot ".agents/prompts/10_upgrade_coordination.md"))) {
        throw "Plugin-owned conflict did not take the upstream workflow content."
    }
    $mergedAgents = Get-NormalizedText $ownershipAgents
    if (-not $mergedAgents.Contains("必须保留的本地项目事实。") -or -not $mergedAgents.Contains("插件所有的工作流内容出现 B/L/N 双向修改时自动采用新版")) {
        throw "Mixed AGENTS.md merge did not preserve project facts and apply upstream rules."
    }
    if ((Get-NormalizedText $ownershipState) -cne "# 项目状态`n`n必须保留的项目状态。`n") {
        throw "Ownership-aware upgrade changed docs/PROJECT_STATE.md."
    }
    $ownershipMeta = Get-Content -Raw -Encoding UTF8 -LiteralPath (
        Join-Path $ownershipTarget ".project-flow/transactions/$ownershipTransaction/transaction.json"
    ) | ConvertFrom-Json
    if (@($ownershipMeta.upstream_resolved) -cnotcontains ".agents/prompts/10_upgrade_coordination.md" -or
        @($ownershipMeta.merged) -cnotcontains "AGENTS.md") {
        throw "Ownership-aware resolutions were not recorded in transaction metadata."
    }
    Assert-ManifestContract $ownershipTarget "Ownership Upgrade Project"
    & $upgrade -Target $ownershipTarget -Rollback $ownershipTransaction *> $null
    if ($LASTEXITCODE -ne 0 -or (Get-DeployedDigest $ownershipTarget) -cne $ownershipTreeBefore -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $ownershipManifestPath).Hash -cne $ownershipManifestBefore) {
        throw "Ownership-aware rollback did not restore the 0.4.0 project."
    }

    New-LegacyFixture $conflictTarget "Conflict Upgrade Project"
    $conflictCollision = Join-Path $conflictTarget ".agents/prompts/10_upgrade_coordination.md"
    [System.IO.File]::WriteAllText(
        $conflictCollision,
        (Get-NormalizedText (Join-Path $repoRoot ".agents/prompts/10_upgrade_coordination.md")) +
            "`n有效但尚未纳管的本地补充。`n",
        $utf8NoBom
    )
    $conflictTreeBefore = Get-DeployedDigest $conflictTarget
    $conflictOutput = @(& $upgrade -Target $conflictTarget -AdoptFrom "0.2.0" -Apply *>&1 | ForEach-Object { $_.ToString() })
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

    $conflictCollisionBefore = [System.IO.File]::ReadAllText($conflictCollision)
    $acceptedTreeBefore = Get-DeployedDigest $conflictTarget
    $acceptedOutput = @(
        & $upgrade -Target $conflictTarget -AdoptFrom "0.2.0" -Apply -AcceptLocal ".agents/prompts/10_upgrade_coordination.md" *>&1 |
            ForEach-Object { $_.ToString() }
    )
    if ($LASTEXITCODE -ne 0 -or ($acceptedOutput -join "`n") -notmatch
        '(?m)^ACCEPT\s+replace_if_unmodified\s+\.agents/prompts/10_upgrade_coordination\.md$') {
        throw "Explicit local conflict acceptance was not reported in the apply plan."
    }
    $acceptedMatch = [regex]::Match(($acceptedOutput -join "`n"), '(?m)^APPLIED (?<id>[A-Za-z0-9][A-Za-z0-9._-]*)$')
    if (-not $acceptedMatch.Success) { throw "Explicit local conflict acceptance did not create a transaction." }
    $acceptedTransaction = $acceptedMatch.Groups["id"].Value
    if ([System.IO.File]::ReadAllText($conflictCollision) -cne $conflictCollisionBefore) {
        throw "Explicit local conflict acceptance overwrote the reviewed live file."
    }
    Assert-ManifestContract $conflictTarget "Conflict Upgrade Project"
    $acceptedMeta = Get-Content -Raw -Encoding UTF8 -LiteralPath (
        Join-Path $conflictTarget ".project-flow/transactions/$acceptedTransaction/transaction.json"
    ) | ConvertFrom-Json
    if (@($acceptedMeta.accepted_local).Count -ne 1 -or
        [string]$acceptedMeta.accepted_local[0] -cne ".agents/prompts/10_upgrade_coordination.md") {
        throw "Accepted local path was not recorded in transaction metadata."
    }
    $acceptedManifestPath = Join-Path $conflictTarget ".project-flow/manifest.json"
    if ((Get-NormalizedTextHash (Get-NormalizedText $acceptedManifestPath)) -cne $acceptedMeta.new_manifest_hash) {
        throw "Accepted-local apply produced a manifest outside its recorded transaction hash."
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
