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

function Test-JsonNumberEqualFive([object]$Value) {
    $isNumber = (
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or
        $Value -is [decimal]
    )
    return $isNumber -and ([decimal]$Value -eq 5)
}

$requiredFiles = @(
    "AGENTS.md",
    ".agents/workflow.json",
    ".agents/prompts/00_project_hub.md",
    ".agents/prompts/08_result_handoff.md",
    ".agents/prompts/09_execution_handoff.md",
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
        "managed-files.json",
        "migrations/0.2.0-to-0.3.0.json",
        "migrations/0.2.0-to-0.3.1.json",
        "migrations/0.3.0-to-0.3.1.json",
        "baselines/0.2.0/AGENTS.md",
        "baselines/0.3.0/AGENTS.md",
        "baselines/0.3.0/.agents/workflow.json",
        "baselines/0.3.0/.agents/prompts/00_project_hub.md",
        "baselines/0.3.0/.agents/prompts/08_result_handoff.md",
        "baselines/0.3.0/.agents/prompts/09_execution_handoff.md",
        "baselines/0.3.0/.agents/skills/project-workflow-manager/SKILL.md",
        "baselines/0.3.0/.agents/skills/project-workflow-manager/agents/openai.yaml",
        "baselines/0.3.0/.agents/snippets/AGENTS.integration.md",
        "baselines/0.3.0/docs/DEVELOPMENT_SOP.md",
        "baselines/0.3.0/docs/PROJECT_STATE.md",
        "baselines/0.3.0/docs/WORKFLOW_GUIDE.md",
        "scripts/upgrade.sh",
        "scripts/upgrade.ps1",
        "skills/bootstrap-project-flow/SKILL.md",
        "skills/bootstrap-project-flow/agents/openai.yaml",
        "skills/upgrade-project-flow/SKILL.md",
        "skills/upgrade-project-flow/agents/openai.yaml",
        "skills/upgrade-project-flow/references/upgrade-contract.md"
    )
}
foreach ($relative in $requiredFiles) {
    $path = Resolve-InTarget $relative
    if ($path -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Error "Missing $relative"
    }
}

$promptsRoot = Join-Path $targetRoot ".agents/prompts"
foreach ($prefix in @("00", "08", "09")) {
    $matches = if (Test-Path -LiteralPath $promptsRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $promptsRoot -File -Filter "${prefix}_*.md")
    } else {
        @()
    }
    if ($matches.Count -ne 1) {
        Add-Error "Expected exactly one ${prefix}_*.md prompt."
    }
}
$rotationKeyFormat = '[codex-project-flow:execution:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>'
foreach ($rotationIdentityRelative in @(
    ".agents/workflow.json",
    ".agents/prompts/00_project_hub.md",
    ".agents/prompts/09_execution_handoff.md"
)) {
    $rotationIdentityPath = Join-Path $targetRoot $rotationIdentityRelative
    if ((Test-Path -LiteralPath $rotationIdentityPath -PathType Leaf) -and
        -not [System.IO.File]::ReadAllText($rotationIdentityPath).Contains($rotationKeyFormat)) {
        Add-Error "Missing the complete v1 execution rotation key format in $rotationIdentityRelative"
    }
}
$hubPromptPath = Join-Path $targetRoot ".agents/prompts/00_project_hub.md"
if (Test-Path -LiteralPath $hubPromptPath -PathType Leaf) {
    $hubPromptText = [System.IO.File]::ReadAllText($hubPromptPath)
    foreach ($requiredRecoveryText in @(
        "list_threads",
        "read_thread",
        "pinnedThreads",
        "codexDelegation.input",
        "无法证明穷尽",
        "零个匹配继续等待",
        "多个匹配停止并报告歧义"
    )) {
        if (-not $hubPromptText.Contains($requiredRecoveryText)) {
            Add-Error "Project hub prompt is missing queued-recovery semantics: $requiredRecoveryText"
        }
    }
}
$handoffPromptPath = Join-Path $targetRoot ".agents/prompts/09_execution_handoff.md"
if (Test-Path -LiteralPath $handoffPromptPath -PathType Leaf) {
    $handoffPromptText = [System.IO.File]::ReadAllText($handoffPromptPath)
    foreach ($requiredHandoffText in @(
        "当前代次与继任代次",
        "前任任务 ID",
        "目标、范围、不做项、环境、验收标准",
        "已授权动作",
        "已完成修改及实际工作区状态",
        "历史验证",
        "剩余步骤、已知风险与下一安全点",
        "不可轮换",
        "中枢确认内容完整并 ACK"
    )) {
        if (-not $handoffPromptText.Contains($requiredHandoffText)) {
            Add-Error "Execution handoff prompt is missing required protocol text: $requiredHandoffText"
        }
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

$installManifestPath = Join-Path $targetRoot ".project-flow/manifest.json"
if (Test-Path -LiteralPath $installManifestPath) {
    if (-not (Test-Path -LiteralPath $installManifestPath -PathType Leaf)) {
        Add-Error ".project-flow/manifest.json exists and is not a regular file."
    } else {
        try {
            $installManifestText = Get-Content -Raw -Encoding UTF8 -LiteralPath $installManifestPath
            if ($installManifestText -notmatch '^\s*\{') { throw "JSON root must be an object" }
            $installManifest = $installManifestText | ConvertFrom-Json
            if ($installManifest -isnot [pscustomobject]) { throw "JSON root must be an object" }
            $expectedManifestFiles = [ordered]@{
                "AGENTS.md" = @("AGENTS.md", "merge_manual")
                ".agents/workflow.json" = @(".agents/workflow.json", "structured_manual")
                ".agents/prompts/00_project_hub.md" = @(".agents/prompts/00_project_hub.md", "replace_if_unmodified")
                ".agents/prompts/08_result_handoff.md" = @(".agents/prompts/08_result_handoff.md", "replace_if_unmodified")
                ".agents/prompts/09_execution_handoff.md" = @(".agents/prompts/09_execution_handoff.md", "replace_if_unmodified")
                ".agents/skills/project-workflow-manager/SKILL.md" = @(".agents/skills/project-workflow-manager/SKILL.md", "replace_if_unmodified")
                ".agents/skills/project-workflow-manager/agents/openai.yaml" = @(".agents/skills/project-workflow-manager/agents/openai.yaml", "replace_if_unmodified")
                ".agents/snippets/AGENTS.integration.md" = @(".agents/snippets/AGENTS.integration.md", "replace_if_unmodified")
                "docs/DEVELOPMENT_SOP.md" = @("docs/DEVELOPMENT_SOP.md", "merge_manual")
                "docs/PROJECT_STATE.md" = @("templates/PROJECT_STATE.md", "seed_once")
                "docs/WORKFLOW_GUIDE.md" = @("docs/WORKFLOW_GUIDE.md", "replace_if_unmodified")
            }
            if ($installManifest.schema_version -ne 1 -or [string]$installManifest.workflow_version -cne "0.3.1") {
                throw "unsupported schema or workflow version"
            }
            $manifestProjectName = [string]$installManifest.project_name
            if ([string]::IsNullOrWhiteSpace($manifestProjectName)) { throw "project_name is empty" }
            foreach ($character in $manifestProjectName.ToCharArray()) {
                if ([char]::IsControl($character)) { throw "project_name contains a control character" }
            }
            if ([string]::IsNullOrWhiteSpace([string]$installManifest.installed_at_utc)) { throw "installed_at_utc is empty" }
            if ($null -ne $installManifest.last_transaction -and [string]$installManifest.last_transaction -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
                throw "last_transaction is invalid"
            }
            $manifestEntries = @($installManifest.files)
            if ($manifestEntries.Count -ne $expectedManifestFiles.Count) { throw "managed path count differs" }
            $observedManifestFiles = @{}
            foreach ($entry in $manifestEntries) {
                $relative = [string]$entry.path
                $relativeParts = $relative.Split([char[]]@('/', '\'))
                $unsafeRelative = (
                    [string]::IsNullOrWhiteSpace($relative) -or
                    [System.IO.Path]::IsPathRooted($relative) -or
                    $relative.Contains('\') -or
                    $relative -match '^[A-Za-z]:' -or
                    @($relativeParts | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0
                )
                if ($unsafeRelative -or $observedManifestFiles.ContainsKey($relative)) {
                    throw "unsafe or duplicate managed path: $relative"
                }
                if ([string]$entry.baseline_hash -cnotmatch '^sha256:[0-9a-f]{64}$') {
                    throw "invalid baseline_hash for $relative"
                }
                $observedManifestFiles[$relative] = @([string]$entry.source, [string]$entry.policy)
            }
            foreach ($relative in $expectedManifestFiles.Keys) {
                if (-not $observedManifestFiles.ContainsKey($relative)) { throw "missing managed path: $relative" }
                $expectedPair = $expectedManifestFiles[$relative]
                $actualPair = $observedManifestFiles[$relative]
                if ($actualPair[0] -cne $expectedPair[0] -or $actualPair[1] -cne $expectedPair[1]) {
                    throw "source or policy differs for $relative"
                }
            }
        } catch {
            Add-Error ".project-flow/manifest.json does not satisfy the 0.3.1 install contract: $($_.Exception.Message)"
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
        $configText = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath
        if ($configText -notmatch '^\s*\{') {
            Add-Error "The JSON root in $configRelative must be an object."
            throw "JSON root is not an object"
        }
        $parsedConfig = $configText | ConvertFrom-Json
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
        if ($configText -match '^\s*\{') {
            Add-Error "Invalid JSON in ${configRelative}: $($_.Exception.Message)"
        }
    }
}

if ($configParsed -and $configIsObject) {
    if ($config.schema_version -isnot [ValueType] -or [double]$config.schema_version -ne 2) {
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
    } elseif ($null -ne $installManifest -and [string]$installManifest.project_name -cne [string]$config.project.name) {
        Add-Error ".project-flow/manifest.json project_name must match project.name."
    }

    $pathsProperty = $config.PSObject.Properties["paths"]
    if (-not $pathsProperty -or $config.paths -isnot [pscustomobject]) {
        Add-Error "paths must be a JSON object."
    } else {
        foreach ($role in @("rules", "sop", "project_state", "execution_handoff")) {
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
        foreach ($field in @("modify", "check", "build", "test", "documentation_sync", "commit", "push", "task_rotation")) {
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
        if (-not (Test-JsonNumberEqualFive $config.task_policy.max_active_tasks)) {
            Add-Error "task_policy.max_active_tasks must be the number 5."
        }
        if (
            $config.task_policy.blocked_waiting_or_queued_occupies_slot -isnot [bool] -or
            -not $config.task_policy.blocked_waiting_or_queued_occupies_slot
        ) {
            Add-Error "task_policy.blocked_waiting_or_queued_occupies_slot must be true."
        }
        $expectedTaskPolicyStrings = @{
            execution_task_requirement = "user_visible_active_task_required"
            selected_item_authorization = "authorize_creation_of_corresponding_execution_task"
            task_management_failure = "stop_and_report_no_hub_fallback"
            hidden_subagents = "must_not_substitute_user_visible_execution_tasks"
        }
        foreach ($entry in $expectedTaskPolicyStrings.GetEnumerator()) {
            $property = $config.task_policy.PSObject.Properties[$entry.Key]
            if (-not $property -or $property.Value -isnot [string] -or $property.Value -cne $entry.Value) {
                Add-Error "task_policy.$($entry.Key) must be $($entry.Value)."
            }
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
            foreach ($requiredValue in @("requirements", "scope", "interface", "protocol", "environment", "acceptance_criteria")) {
                if ($config.task_policy.return_to_work_on_change -cnotcontains $requiredValue) {
                    Add-Error "task_policy.return_to_work_on_change is missing: $requiredValue"
                }
            }
        }

        $rotation = $config.task_policy.rotation
        if ($rotation -isnot [pscustomobject]) {
            Add-Error "task_policy.rotation must be a JSON object."
        } else {
            $expectedRotationStrings = @{
                primary_trigger = "milestone_boundary_or_complete_modify_verify_cycle"
                authorization_scope = "same_already_authorized_scope_only"
                change_behavior = "return_to_work"
                create_failure_without_id = "restore_predecessor"
                queued_client_thread_id = "occupies_active_task_slot_and_do_not_retry"
                successor_identity = "exact_rotation_key_v1_in_first_user_message"
                queued_recovery = "exhaustive_same_project_discovery_and_exact_rotation_key_match"
                rotation_key_format = "[codex-project-flow:execution:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>"
                independent_worktree_requirement = "authorized_transferable_code_checkpoint"
            }
            foreach ($entry in $expectedRotationStrings.GetEnumerator()) {
                $property = $rotation.PSObject.Properties[$entry.Key]
                if (-not $property -or $property.Value -isnot [string] -or $property.Value -cne $entry.Value) {
                    Add-Error "task_policy.rotation.$($entry.Key) must be $($entry.Value)."
                }
            }
            if ($rotation.review_after_substantive_turns -isnot [ValueType] -or [double]$rotation.review_after_substantive_turns -ne 6) {
                Add-Error "task_policy.rotation.review_after_substantive_turns must be 6."
            }
            if ($rotation.rotate_no_later_than_substantive_turns -isnot [ValueType] -or [double]$rotation.rotate_no_later_than_substantive_turns -ne 10) {
                Add-Error "task_policy.rotation.rotate_no_later_than_substantive_turns must be 10."
            }
            foreach ($arraySpec in @(
                [pscustomobject]@{ Name = "additional_triggers"; Values = @("context_pressure", "user_request") },
                [pscustomobject]@{ Name = "state_machine"; Values = @("prepare_handoff_package", "project_hub_acknowledges_complete_handoff", "archive_predecessor", "create_successor", "successor_rechecks_rules_and_workspace") }
            )) {
                $property = $rotation.PSObject.Properties[$arraySpec.Name]
                if (-not $property -or $property.Value -isnot [System.Array]) {
                    Add-Error "task_policy.rotation.$($arraySpec.Name) must be a JSON array."
                    continue
                }
                if (@($property.Value | Where-Object { $_ -isnot [string] }).Count -gt 0) {
                    Add-Error "task_policy.rotation.$($arraySpec.Name) entries must all be strings."
                }
                foreach ($requiredValue in $arraySpec.Values) {
                    if ($property.Value -cnotcontains $requiredValue) {
                        Add-Error "task_policy.rotation.$($arraySpec.Name) is missing: $requiredValue"
                    }
                }
                if ($arraySpec.Name -eq "state_machine") {
                    $actualSequence = @($property.Value | ForEach-Object { [string]$_ })
                    if ($actualSequence.Count -ne $arraySpec.Values.Count -or
                        ($actualSequence -join "`n") -cne ($arraySpec.Values -join "`n")) {
                        Add-Error "task_policy.rotation.state_machine must contain the exact ordered five-state sequence without duplicates."
                    }
                }
            }
        }
    }

    $executionPolicyProperty = $config.PSObject.Properties["execution_policy"]
    if (-not $executionPolicyProperty -or $config.execution_policy -isnot [pscustomobject]) {
        Add-Error "execution_policy must be a JSON object."
    } else {
        $expectedExecutionPolicyStrings = @{
            project_hub_role = "analyze_clarify_design_number_create_wait_coordinate_and_summarize_only"
            project_hub_execution_fallback = "forbidden"
            non_conflicting_operations = "parallel_allowed"
            high_risk_operations = "serial"
            external_operations = "serial"
        }
        foreach ($entry in $expectedExecutionPolicyStrings.GetEnumerator()) {
            $fieldProperty = $config.execution_policy.PSObject.Properties[$entry.Key]
            if (
                -not $fieldProperty -or $fieldProperty.Value -isnot [string] -or
                $fieldProperty.Value -cne $entry.Value
            ) {
                Add-Error "execution_policy.$($entry.Key) must be $($entry.Value)."
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
            $pluginText = Get-Content -Raw -Encoding UTF8 -LiteralPath $pluginPath
            if ($pluginText -notmatch '^\s*\{') { throw "JSON root must be an object" }
            $plugin = $pluginText | ConvertFrom-Json
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
                if ($bootstrapDescription -notmatch '(?i)\b(?:claim|adopt|make)\w*\b') {
                    Add-Error "Bootstrap Skill description must cover making the current task the project hub."
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
                    '(?is)\[codex-project-flow:hub-claim:v1\].{0,180}\bprojectId\s*=.{1,160};\s*hubTitle\s*='
            ) {
                Add-Error "Bootstrap Skill must define the interrupted current-task claim identity."
            }
            if (
                $bootstrapSkillText -notmatch
                    '(?is)\[codex-project-flow:hub-retired:v1\].{0,180}\bprojectId\s*=.{1,160};\s*retainedThreadId\s*='
            ) {
                Add-Error "Bootstrap Skill must define a durable retired-hub tombstone."
            }
            if (-not $bootstrapSkillText.Contains('Archiving alone is not cleanup')) {
                Add-Error "Bootstrap Skill must explain why archiving alone cannot retire a v1 recovery candidate."
            }
            if (-not $bootstrapSkillText.Contains('exclude a same-project entry only when its complete title exactly matches')) {
                Add-Error "Bootstrap Skill must exclude only an exact retired-hub tombstone."
            }
            if ($bootstrapSkillText -notmatch '\bseparateHubMode\b') {
                Add-Error "Bootstrap Skill must preserve the explicit separate-hub compatibility mode."
            }
            if ($bootstrapSkillText -notmatch '(?is)(?:omit|omitted).{0,40}threadId|threadId.{0,40}(?:omit|omitted)') {
                Add-Error "Bootstrap Skill must describe the implicit current-task title operation."
            }
            if ($bootstrapSkillText -notmatch '(?is)never call `?create_thread`?.{0,160}(?:failed|ambiguous)|failed.{0,160}never call `?create_thread`?') {
                Add-Error "Bootstrap Skill must forbid silent create_thread fallback after claim failure."
            }
            if ($bootstrapSkillText -notmatch '(?i)exhaust(?:ive|ively|ion)|prove exhaustion') {
                Add-Error "Bootstrap Skill must require exhaustive task discovery."
            }
            if ($bootstrapSkillText -notmatch '(?is)(?:reaches|reached).{0,60}(?:requested )?limit.{0,100}stop|stop.{0,100}(?:reaches|reached).{0,60}(?:requested )?limit') {
                Add-Error "Bootstrap Skill must stop when task-list exhaustion cannot be proven."
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
        if (
            -not $defaultPromptMatch.Success -or
            $defaultPromptMatch.Groups["value"].Value -notmatch
                '(?i)(?:claim|adopt).{0,80}(?:this|current).{0,40}(?:task|hub)|(?:this|current).{0,40}task.{0,80}(?:claim|adopt)'
        ) {
            Add-Error "Bootstrap openai.yaml default_prompt must make current-task hub adoption the default."
        }
    }

    $upgradeSkillPath = Join-Path $targetRoot "skills/upgrade-project-flow/SKILL.md"
    if (Test-Path -LiteralPath $upgradeSkillPath -PathType Leaf) {
        $upgradeSkillText = [System.IO.File]::ReadAllText($upgradeSkillPath)
        $upgradeFrontmatterMatch = [regex]::Match(
            $upgradeSkillText,
            '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
        if (-not $upgradeFrontmatterMatch.Success) {
            Add-Error "Upgrade Skill frontmatter is missing or malformed."
        } else {
            $upgradeFrontmatter = $upgradeFrontmatterMatch.Groups["frontmatter"].Value
            if ($upgradeFrontmatter -notmatch '(?m)^name:\s*upgrade-project-flow\s*$') {
                Add-Error "Upgrade Skill frontmatter name must be upgrade-project-flow."
            }
            if ($upgradeFrontmatter -notmatch '(?im)^description:\s*.*\b(?:upgrade|sync)\w*\b') {
                Add-Error "Upgrade Skill description must cover upgrading or syncing deployed projects."
            }
        }
        if ($upgradeSkillText -notmatch [regex]::Escape('references/upgrade-contract.md')) {
            Add-Error "Upgrade Skill must reference the upgrade contract."
        }
        if ($upgradeSkillText -notmatch [regex]::Escape('--adopt-from 0.2.0')) {
            Add-Error "Upgrade Skill must require explicit 0.2.0 legacy adoption."
        }
        if ($upgradeSkillText -notmatch [regex]::Escape('--accept-local')) {
            Add-Error "Upgrade Skill must expose explicit per-path local conflict acceptance."
        }
        if ($upgradeSkillText -notmatch '(?is)default.{0,40}(?:read-only|plan)') {
            Add-Error "Upgrade Skill must make read-only planning the default."
        }
    }

    $upgradeOpenAiPath = Join-Path $targetRoot "skills/upgrade-project-flow/agents/openai.yaml"
    if (Test-Path -LiteralPath $upgradeOpenAiPath -PathType Leaf) {
        $upgradeOpenAiText = [System.IO.File]::ReadAllText($upgradeOpenAiPath)
        if ($upgradeOpenAiText -notmatch '(?m)^interface:\s*(?:#.*)?$') {
            Add-Error "Upgrade openai.yaml is missing the interface mapping."
        }
        if ($upgradeOpenAiText -notmatch [regex]::Escape('$upgrade-project-flow')) {
            Add-Error "Upgrade openai.yaml default_prompt must reference `$upgrade-project-flow."
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
