[CmdletBinding()]
param(
    [string]$Target = ".",
    [switch]$AllowPlaceholders
)

$ErrorActionPreference = "Stop"
$targetRoot = [System.IO.Path]::GetFullPath($Target)
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
    Write-Error "Target directory does not exist: $targetRoot"
    exit 2
}

function Add-Error([string]$Message) { $script:errors.Add($Message) }
function Add-Warning([string]$Message) { $script:warnings.Add($Message) }
function Report-LegacyPath([string]$Message) {
    if ($AllowPlaceholders) {
        Add-Error $Message
    } else {
        Add-Warning $Message
    }
}

function Resolve-InTarget([string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        Add-Error "Configured path is not a relative path: $RelativePath"
        return $null
    }
    try {
        $full = [System.IO.Path]::GetFullPath((Join-Path $targetRoot $RelativePath))
    } catch {
        Add-Error "Configured path is invalid: $RelativePath"
        return $null
    }
    $prefix = $targetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (($full -ne $targetRoot) -and (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        Add-Error "Configured path escapes target: $RelativePath"
        return $null
    }
    return $full
}

function Test-JsonNumberEqualOne([object]$Value) {
    $isNumber = (
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or
        $Value -is [decimal]
    )
    return $isNumber -and ([decimal]$Value -eq 1)
}

$requiredFiles = @(
    "AGENTS.md",
    ".agents/workflow.json",
    ".agents/prompts/00_project_hub.md",
    ".agents/prompts/08_result_handoff.md",
    ".agents/skills/project-workflow-manager/SKILL.md",
    ".agents/skills/project-workflow-manager/agents/openai.yaml",
    ".agents/snippets/AGENTS.integration.md",
    "docs/PROJECT_STATE.md",
    "docs/DEVELOPMENT_SOP.md",
    "docs/WORKFLOW_GUIDE.md"
)
if ($AllowPlaceholders) {
    $requiredFiles += @(
        "README.md",
        "VERSION",
        "templates/PROJECT_STATE.md",
        ".codex-plugin/plugin.json",
        "skills/bootstrap-project-flow/SKILL.md",
        "skills/bootstrap-project-flow/agents/openai.yaml"
    )
}
foreach ($relative in $requiredFiles) {
    $path = Resolve-InTarget $relative
    if ($path -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Error "Missing $relative"
    }
}

$promptsRoot = Join-Path $targetRoot ".agents/prompts"
foreach ($prefix in @("00", "08")) {
    $matches = if (Test-Path -LiteralPath $promptsRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $promptsRoot -File -Filter "${prefix}_*.md")
    } else {
        @()
    }
    if ($matches.Count -ne 1) {
        Add-Error "Expected exactly one ${prefix}_*.md prompt."
    }
}

$legacyPaths = @(
    ".agents/skills/manage-project-workflow",
    "docs/MODULE_INDEX.md",
    "docs/NEXT_TASK.md",
    "docs/RISKS.md",
    "docs/DECISIONS.md",
    "docs/WEEKLY_LOG.md"
)
foreach ($relative in $legacyPaths) {
    if (Test-Path -LiteralPath (Join-Path $targetRoot $relative)) {
        Report-LegacyPath "Legacy path remains: $relative"
    }
}
foreach ($prefix in 1..6) {
    if (Test-Path -LiteralPath $promptsRoot -PathType Container) {
        $pattern = "{0:D2}_*.md" -f $prefix
        $legacyPromptCount = @(Get-ChildItem -LiteralPath $promptsRoot -File -Filter $pattern).Count
        if ($legacyPromptCount -gt 0) {
            Report-LegacyPath "Legacy prompt pattern remains: .agents/prompts/$pattern ($legacyPromptCount file(s))"
        }
    }
}

$configRelative = ".agents/workflow.json"
$configPath = Join-Path $targetRoot $configRelative
$config = $null
$configParsed = $false
$configIsObject = $false
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $parsedConfig = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
        $configParsed = $true
        if (
            $null -ne $parsedConfig -and
            $parsedConfig.GetType().FullName -eq "System.Management.Automation.PSCustomObject"
        ) {
            $config = $parsedConfig
            $configIsObject = $true
        } else {
            Add-Error "The JSON root in $configRelative must be an object."
        }
    } catch {
        Add-Error "Invalid JSON in ${configRelative}: $($_.Exception.Message)"
    }
}

if ($configParsed -and $configIsObject) {
    if (-not (Test-JsonNumberEqualOne $config.schema_version)) {
        Add-Error "Unsupported schema_version: $($config.schema_version)"
    }

    $requiredContextProperty = $config.PSObject.Properties["required_context"]
    if (-not $requiredContextProperty -or $config.required_context -isnot [System.Array]) {
        Add-Error "required_context must be a JSON array."
    } elseif (@($config.required_context).Count -eq 0) {
        Add-Error "required_context must not be empty."
    } else {
        foreach ($relativeValue in @($config.required_context)) {
            if ($relativeValue -isnot [string]) {
                Add-Error "Every required_context entry must be a string."
                continue
            }
            $relative = [string]$relativeValue
            $path = Resolve-InTarget $relative
            if ($path -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Add-Error "required_context path is missing: $relative"
            }
        }
    }

    $projectProperty = $config.PSObject.Properties["project"]
    $projectNameProperty = if ($projectProperty -and $config.project -is [pscustomobject]) {
        $config.project.PSObject.Properties["name"]
    } else {
        $null
    }
    if (-not $projectNameProperty -or $config.project.name -isnot [string] -or [string]::IsNullOrWhiteSpace($config.project.name)) {
        Add-Error "project.name must be a non-empty string."
    } elseif ($AllowPlaceholders -and $config.project.name -cne "<PROJECT_NAME>") {
        Add-Error "Template project.name must be <PROJECT_NAME>."
    } elseif (-not $AllowPlaceholders -and $config.project.name -ceq "<PROJECT_NAME>") {
        Add-Error "Installed project.name still contains <PROJECT_NAME>."
    }

    $pathsProperty = $config.PSObject.Properties["paths"]
    if (-not $pathsProperty -or $config.paths -isnot [pscustomobject]) {
        Add-Error "paths must be a JSON object."
    } else {
        foreach ($role in @("rules", "sop", "project_state")) {
            $roleProperty = $config.paths.PSObject.Properties[$role]
            if (-not $roleProperty -or $roleProperty.Value -isnot [string]) {
                Add-Error "paths.$role must be a relative path string."
                continue
            }
            $relative = [string]$roleProperty.Value
            $path = Resolve-InTarget $relative
            if ($path -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Add-Error "Configured path is missing: paths.$role=$relative"
            }
        }
    }

    $workProperty = $config.PSObject.Properties["work"]
    if (
        -not $workProperty -or $config.work -isnot [pscustomobject] -or
        $config.work.mode -isnot [string] -or $config.work.mode -cne "read_only"
    ) {
        Add-Error "work.mode must be read_only."
    }

    $authorizationProperty = $config.PSObject.Properties["authorization"]
    if (-not $authorizationProperty -or $config.authorization -isnot [pscustomobject]) {
        Add-Error "authorization must be a JSON object."
    } else {
        foreach ($field in @("modify", "check", "build", "test", "documentation_sync", "commit", "push")) {
            $fieldProperty = $config.authorization.PSObject.Properties[$field]
            if (
                -not $fieldProperty -or $fieldProperty.Value -isnot [string] -or
                $fieldProperty.Value -cne "separate"
            ) {
                Add-Error "authorization.$field must be separate."
            }
        }
    }

    $taskPolicyProperty = $config.PSObject.Properties["task_policy"]
    if (-not $taskPolicyProperty -or $config.task_policy -isnot [pscustomobject]) {
        Add-Error "task_policy must be a JSON object."
    } else {
        if (-not (Test-JsonNumberEqualOne $config.task_policy.max_active_tasks)) {
            Add-Error "task_policy.max_active_tasks must be the number 1."
        }
        if (
            $config.task_policy.blocked_or_waiting_occupies_slot -isnot [bool] -or
            -not $config.task_policy.blocked_or_waiting_occupies_slot
        ) {
            Add-Error "task_policy.blocked_or_waiting_occupies_slot must be true."
        }
        if (
            $config.task_policy.max_active_tasks_applies_to -isnot [string] -or
            $config.task_policy.max_active_tasks_applies_to -cne
                "subsequent_user_visible_execution_tasks"
        ) {
            Add-Error "task_policy.max_active_tasks_applies_to must be subsequent_user_visible_execution_tasks."
        }
        if (
            $config.task_policy.project_hub_task_lifecycle -isnot [string] -or
            $config.task_policy.project_hub_task_lifecycle -cne "persistent"
        ) {
            Add-Error "task_policy.project_hub_task_lifecycle must be persistent."
        }
        if (
            $config.task_policy.project_hub_occupies_active_task_slot -isnot [bool] -or
            $config.task_policy.project_hub_occupies_active_task_slot
        ) {
            Add-Error "task_policy.project_hub_occupies_active_task_slot must be false."
        }
        if ($config.task_policy.return_to_work_on_change -isnot [System.Array]) {
            Add-Error "task_policy.return_to_work_on_change must be a JSON array."
        } else {
            if (
                @(
                    $config.task_policy.return_to_work_on_change |
                        Where-Object { $_ -isnot [string] }
                ).Count -gt 0
            ) {
                Add-Error "task_policy.return_to_work_on_change entries must all be strings."
            }
            foreach ($requiredValue in @("scope", "interface", "environment", "acceptance_criteria")) {
                if ($config.task_policy.return_to_work_on_change -cnotcontains $requiredValue) {
                    Add-Error "task_policy.return_to_work_on_change is missing: $requiredValue"
                }
            }
        }
    }

    $executionPolicyProperty = $config.PSObject.Properties["execution_policy"]
    if (-not $executionPolicyProperty -or $config.execution_policy -isnot [pscustomobject]) {
        Add-Error "execution_policy must be a JSON object."
    } else {
        foreach ($field in @("high_risk_operations", "external_operations")) {
            $fieldProperty = $config.execution_policy.PSObject.Properties[$field]
            if (
                -not $fieldProperty -or $fieldProperty.Value -isnot [string] -or
                $fieldProperty.Value -cne "serial"
            ) {
                Add-Error "execution_policy.$field must be serial."
            }
        }
    }

    $handoffPolicyProperty = $config.PSObject.Properties["handoff_policy"]
    if (-not $handoffPolicyProperty -or $config.handoff_policy -isnot [pscustomobject]) {
        Add-Error "handoff_policy must be a JSON object."
    } elseif ($config.handoff_policy.only_when -isnot [System.Array]) {
        Add-Error "handoff_policy.only_when must be a JSON array."
    } else {
        if (
            @(
                $config.handoff_policy.only_when |
                    Where-Object { $_ -isnot [string] }
            ).Count -gt 0
        ) {
            Add-Error "handoff_policy.only_when entries must all be strings."
        }
        foreach ($requiredValue in @("coordination_required", "user_choice_required", "user_requested")) {
            if ($config.handoff_policy.only_when -cnotcontains $requiredValue) {
                Add-Error "handoff_policy.only_when is missing: $requiredValue"
            }
        }
    }
}

if ($AllowPlaceholders) {
    $versionPath = Join-Path $targetRoot "VERSION"
    $pluginPath = Join-Path $targetRoot ".codex-plugin/plugin.json"
    if (
        (Test-Path -LiteralPath $versionPath -PathType Leaf) -and
        (Test-Path -LiteralPath $pluginPath -PathType Leaf)
    ) {
        $templateVersion = [System.IO.File]::ReadAllText($versionPath).Trim()
        if ($templateVersion -notmatch '^\d+\.\d+\.\d+$') {
            Add-Error "VERSION must contain a strict semantic version."
        }
        try {
            $plugin = Get-Content -Raw -Encoding UTF8 -LiteralPath $pluginPath | ConvertFrom-Json
            if (
                $null -eq $plugin -or
                $plugin.GetType().FullName -ne "System.Management.Automation.PSCustomObject"
            ) {
                Add-Error "The JSON root in .codex-plugin/plugin.json must be an object."
            } else {
                if ($plugin.name -isnot [string] -or $plugin.name -cne "codex-project-flow") {
                    Add-Error "Plugin manifest name must be codex-project-flow."
                }
                $versionPattern = '^' + [regex]::Escape($templateVersion) +
                    '(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
                if ($plugin.version -isnot [string] -or $plugin.version -cnotmatch $versionPattern) {
                    Add-Error "Plugin manifest version must use VERSION as its base version."
                }
                if ($plugin.description -isnot [string] -or [string]::IsNullOrWhiteSpace($plugin.description)) {
                    Add-Error "Plugin manifest description must be non-empty."
                }
                if ($plugin.skills -isnot [string] -or $plugin.skills -cne "./skills/") {
                    Add-Error "Plugin manifest skills must be ./skills/."
                }
            }
        } catch {
            Add-Error "Invalid JSON in .codex-plugin/plugin.json: $($_.Exception.Message)"
        }
    }

    $bootstrapSkillPath = Join-Path $targetRoot "skills/bootstrap-project-flow/SKILL.md"
    if (Test-Path -LiteralPath $bootstrapSkillPath -PathType Leaf) {
        $bootstrapSkillText = [System.IO.File]::ReadAllText($bootstrapSkillPath)
        $bootstrapFrontmatterMatch = [regex]::Match(
            $bootstrapSkillText,
            '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
        if (-not $bootstrapFrontmatterMatch.Success) {
            Add-Error "Bootstrap Skill frontmatter is missing or malformed."
        } else {
            $bootstrapFrontmatter = $bootstrapFrontmatterMatch.Groups["frontmatter"].Value
            if ($bootstrapFrontmatter -notmatch '(?m)^name:\s*bootstrap-project-flow\s*$') {
                Add-Error "Bootstrap Skill frontmatter name must be bootstrap-project-flow."
            }
            $bootstrapDescriptionMatch = [regex]::Match(
                $bootstrapFrontmatter,
                '(?m)^description:\s*(?<value>.+?)\s*$'
            )
            if (
                -not $bootstrapDescriptionMatch.Success -or
                $bootstrapDescriptionMatch.Groups["value"].Value -in @('', '""', "''")
            ) {
                Add-Error "Bootstrap Skill frontmatter description must be non-empty."
            } else {
                $bootstrapDescription = $bootstrapDescriptionMatch.Groups["value"].Value
                if ($bootstrapDescription -notmatch '(?i)\b(?:install|import)\w*\b') {
                    Add-Error "Bootstrap Skill description must cover installing or importing the workflow."
                }
                if ($bootstrapDescription -notmatch '(?i)\b(?:create|reuse)\w*\b') {
                    Add-Error "Bootstrap Skill description must cover creating or reusing the project hub task."
                }
                if ($bootstrapDescription -notmatch '(?i)\buser-visible\b.*\bproject hub\b') {
                    Add-Error "Bootstrap Skill description must identify a user-visible project hub task."
                }
            }
            if ($bootstrapSkillText -notmatch [regex]::Escape('set_thread_pinned')) {
                Add-Error "Bootstrap Skill must call set_thread_pinned for a permanent project hub."
            }
            if (
                $bootstrapSkillText -notmatch
                    '(?i)(?:pinned[^\w\s:=]?\s*[:=]\s*\$?true\b|-pinned\s+\$?true\b)'
            ) {
                Add-Error "Bootstrap Skill must explicitly set pinned to true."
            }
            foreach ($toolName in @("read_thread", "set_thread_archived")) {
                $toolUsePattern = '(?is)\b(?:call|use)\b.{0,30}\b' +
                    [regex]::Escape($toolName) + '\b'
                if ($bootstrapSkillText -notmatch $toolUsePattern) {
                    Add-Error "Bootstrap Skill must use $toolName for project hub recovery."
                }
            }
            if (
                $bootstrapSkillText -notmatch
                    '(?i)(?:archived[^\w\s:=]?\s*[:=]\s*\$?false\b|-archived\s+\$?false\b)'
            ) {
                Add-Error "Bootstrap Skill must explicitly set archived to false."
            }
            if ($bootstrapSkillText -notmatch '(?i)\bhubKey\b') {
                Add-Error "Bootstrap Skill must define the stable hubKey identifier."
            }
            if (
                $bootstrapSkillText -notmatch
                    '(?is)\[codex-project-flow:hub:v1\].{0,160}\bprojectId\s*=.{1,120};\s*hubTitle\s*='
            ) {
                Add-Error "Bootstrap Skill hubKey must use the v1 prefix, projectId, and hubTitle."
            }
            if (
                $bootstrapSkillText -notmatch
                    '(?is)(?:(?:full|complete).{0,30}hubKey.{0,120}(?:exact|verbatim)|(?:exact|verbatim).{0,120}(?:full|complete).{0,30}hubKey)'
            ) {
                Add-Error "Bootstrap Skill recovery must compare the complete hubKey exactly."
            }
            if (
                $bootstrapSkillText -notmatch
                    '(?im)^[^\r\n]*(?:queued|clientThreadId)[^\r\n]*(?:do not|never|not to)[^\r\n]*(?:call\s+)?[^\w\s]?create_thread[^\w\s]?\s+again[^\r\n]*$'
            ) {
                Add-Error "Bootstrap Skill queued handling must forbid another create_thread call."
            }
            if (
                $bootstrapSkillText -notmatch
                    '(?im)^[^\r\n]*(?:queued|clientThreadId)[^\r\n]*(?:do not|never|not to)[^\r\n]*(?:(?:immediate(?:ly)?\s+)(?:re-?run|retry)|(?:re-?run|retry)[^\r\n]{0,40}immediate)[^\r\n]*$'
            ) {
                Add-Error "Bootstrap Skill queued handling must forbid an immediate rerun or retry."
            }
        }
    }

    $bootstrapOpenAiPath = Join-Path $targetRoot "skills/bootstrap-project-flow/agents/openai.yaml"
    if (Test-Path -LiteralPath $bootstrapOpenAiPath -PathType Leaf) {
        $bootstrapOpenAiText = [System.IO.File]::ReadAllText($bootstrapOpenAiPath)
        if ($bootstrapOpenAiText -notmatch '(?m)^interface:\s*(?:#.*)?$') {
            Add-Error "Bootstrap openai.yaml is missing the interface mapping."
        }
        foreach ($field in @("display_name", "short_description", "default_prompt")) {
            $fieldMatch = [regex]::Match(
                $bootstrapOpenAiText,
                "(?m)^\s+$field`:\s*(?<value>.+?)\s*$"
            )
            if (-not $fieldMatch.Success -or $fieldMatch.Groups["value"].Value -in @('', '""', "''")) {
                Add-Error "Bootstrap openai.yaml is missing a non-empty interface.$field."
            }
        }
        $defaultPromptMatch = [regex]::Match(
            $bootstrapOpenAiText,
            '(?m)^\s+default_prompt:\s*(?<value>.+?)\s*$'
        )
        if (
            -not $defaultPromptMatch.Success -or
            $defaultPromptMatch.Groups["value"].Value -notmatch
                [regex]::Escape('$bootstrap-project-flow')
        ) {
            Add-Error "Bootstrap openai.yaml default_prompt must reference `$bootstrap-project-flow."
        }
    }
}

$skillPath = Join-Path $targetRoot ".agents/skills/project-workflow-manager/SKILL.md"
if (Test-Path -LiteralPath $skillPath -PathType Leaf) {
    $skillText = [System.IO.File]::ReadAllText($skillPath)
    $frontmatterMatch = [regex]::Match(
        $skillText,
        '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $frontmatterMatch.Success) {
        Add-Error "Skill frontmatter is missing or malformed."
    } else {
        $frontmatter = $frontmatterMatch.Groups["frontmatter"].Value
        if ($frontmatter -notmatch '(?m)^name:\s*project-workflow-manager\s*$') {
            Add-Error "Skill frontmatter name must be project-workflow-manager."
        }
        $descriptionMatch = [regex]::Match($frontmatter, '(?m)^description:\s*(?<value>.+?)\s*$')
        if (-not $descriptionMatch.Success -or $descriptionMatch.Groups["value"].Value -in @('""', "''")) {
            Add-Error "Skill frontmatter description must be non-empty."
        }
    }
}

$openAiPath = Join-Path $targetRoot ".agents/skills/project-workflow-manager/agents/openai.yaml"
if (Test-Path -LiteralPath $openAiPath -PathType Leaf) {
    $openAiText = [System.IO.File]::ReadAllText($openAiPath)
    if ($openAiText -notmatch '(?m)^interface:\s*(?:#.*)?$') {
        Add-Error "openai.yaml is missing the interface mapping."
    }
    foreach ($field in @("display_name", "short_description", "default_prompt")) {
        $fieldMatch = [regex]::Match($openAiText, "(?m)^\s+$field`:\s*(?<value>.+?)\s*$")
        if (-not $fieldMatch.Success -or $fieldMatch.Groups["value"].Value -in @('""', "''")) {
            Add-Error "openai.yaml is missing a non-empty interface.$field."
        }
    }
    if ($openAiText -notmatch [regex]::Escape('$project-workflow-manager')) {
        Add-Error "openai.yaml default_prompt must reference `$project-workflow-manager."
    }
}

$textFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
$agentRules = Join-Path $targetRoot "AGENTS.md"
if (Test-Path -LiteralPath $agentRules -PathType Leaf) {
    $textFiles.Add((Get-Item -LiteralPath $agentRules))
}
foreach ($managedRoot in @(".agents", "docs")) {
    $managedPath = Join-Path $targetRoot $managedRoot
    if (Test-Path -LiteralPath $managedPath -PathType Container) {
        Get-ChildItem -LiteralPath $managedPath -Recurse -File |
            Where-Object { $_.Extension -in @(".md", ".json", ".yaml", ".yml") } |
            ForEach-Object { $textFiles.Add($_) }
    }
}
$projectTokenFiles = @(
    $textFiles |
        Select-String -SimpleMatch "<PROJECT_NAME>" |
        Select-Object -ExpandProperty Path -Unique
)
if ($projectTokenFiles.Count -gt 0) {
    $relativeTokenFiles = $projectTokenFiles | ForEach-Object {
        $_.Substring($targetRoot.Length).TrimStart('\', '/')
    }
    $message = "Unresolved <PROJECT_NAME> in: " + ($relativeTokenFiles -join ", ")
    if ($AllowPlaceholders) {
        Add-Warning $message
    } else {
        Add-Error $message
    }
} elseif ($AllowPlaceholders) {
    Add-Error "Template does not contain the required <PROJECT_NAME> placeholder."
}

foreach ($warning in $warnings) {
    Write-Host "WARN  $warning" -ForegroundColor Yellow
}
foreach ($errorItem in $errors) {
    Write-Host "ERROR $errorItem" -ForegroundColor Red
}

if ($errors.Count -gt 0) {
    Write-Host "Validation failed: $($errors.Count) error(s), $($warnings.Count) warning(s)."
    exit 1
}

Write-Host "Validation passed: $($warnings.Count) warning(s)."
exit 0
