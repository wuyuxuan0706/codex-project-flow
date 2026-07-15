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
function Resolve-InTarget([string]$RelativePath) {
    $full = [System.IO.Path]::GetFullPath((Join-Path $targetRoot $RelativePath))
    $prefix = $targetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (($full -ne $targetRoot) -and (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        Add-Error "Configured path escapes target: $RelativePath"
        return $null
    }
    return $full
}

$configRelative = ".agents/workflow.json"
$configPath = Resolve-InTarget $configRelative
$config = $null
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Add-Error "Missing $configRelative"
} else {
    try {
        $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
    } catch {
        Add-Error "Invalid JSON in ${configRelative}: $($_.Exception.Message)"
    }
}

$fixedRequired = @(
    "AGENTS.md",
    ".agents/skills/manage-project-workflow/SKILL.md",
    ".agents/skills/manage-project-workflow/agents/openai.yaml",
    ".agents/skills/manage-project-workflow/references/document-contracts.md"
)
foreach ($relative in $fixedRequired) {
    $path = Resolve-InTarget $relative
    if ($path -and -not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-Error "Missing $relative" }
}

1..6 | ForEach-Object {
    $pattern = ".agents/prompts/{0:D2}_*.md" -f $_
    $matches = @(Get-ChildItem -Path (Join-Path $targetRoot $pattern) -File -ErrorAction SilentlyContinue)
    if ($matches.Count -ne 1) { Add-Error "Expected one prompt matching $pattern" }
}

if ($config) {
    if ($config.schema_version -ne 1) { Add-Error "Unsupported schema_version: $($config.schema_version)" }
    foreach ($relative in @($config.required_context)) {
        $path = Resolve-InTarget $relative
        if ($path -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-Error "required_context path is missing: $relative"
        }
    }
    foreach ($property in @($config.paths.documents.PSObject.Properties)) {
        $relative = [string]$property.Value
        $path = Resolve-InTarget $relative
        if ($path -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-Error "Configured document role '$($property.Name)' is missing: $relative"
        }
    }
    foreach ($root in @($config.paths.source_roots)) {
        if ($root -eq "<AUTO_DISCOVER>") {
            Add-Warning "Source roots are set to automatic discovery; confirm MODULE_INDEX.md after installation."
        } else {
            $path = Resolve-InTarget $root
            if ($path -and -not (Test-Path -LiteralPath $path -PathType Container)) {
                Add-Warning "Configured source root does not exist: $root"
            }
        }
    }
}

$skillPath = Join-Path $targetRoot ".agents/skills/manage-project-workflow/SKILL.md"
if (Test-Path -LiteralPath $skillPath -PathType Leaf) {
    $head = @(Get-Content -Encoding UTF8 -LiteralPath $skillPath | Select-Object -First 4)
    if (($head.Count -lt 4) -or ($head[0] -ne "---") -or ($head[1] -ne "name: manage-project-workflow") -or ($head[3] -ne "---")) {
        Add-Error "Skill frontmatter is invalid or the name does not match its folder."
    }
}

$textFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
$agentRules = Join-Path $targetRoot "AGENTS.md"
if (Test-Path -LiteralPath $agentRules -PathType Leaf) { $textFiles.Add((Get-Item -LiteralPath $agentRules)) }
foreach ($managedRoot in @(".agents", "docs")) {
    $managedPath = Join-Path $targetRoot $managedRoot
    if (Test-Path -LiteralPath $managedPath -PathType Container) {
        Get-ChildItem -LiteralPath $managedPath -Recurse -File -Include *.md,*.json,*.yaml | ForEach-Object { $textFiles.Add($_) }
    }
}
$projectTokenFiles = @($textFiles | Select-String -SimpleMatch "<PROJECT_NAME>" | Select-Object -ExpandProperty Path -Unique)
if ($projectTokenFiles.Count -gt 0) {
    $message = "Unresolved <PROJECT_NAME> in: " + (($projectTokenFiles | ForEach-Object { $_.Substring($targetRoot.Length).TrimStart('\', '/') }) -join ", ")
    if ($AllowPlaceholders) { Add-Warning $message } else { Add-Error $message }
}

foreach ($warning in $warnings) { Write-Host "WARN  $warning" -ForegroundColor Yellow }
foreach ($errorItem in $errors) { Write-Host "ERROR $errorItem" -ForegroundColor Red }

if ($errors.Count -gt 0) {
    Write-Host "Validation failed: $($errors.Count) error(s), $($warnings.Count) warning(s)."
    exit 1
}

Write-Host "Validation passed: $($warnings.Count) warning(s)."
exit 0
