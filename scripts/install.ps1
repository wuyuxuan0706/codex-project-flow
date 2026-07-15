[CmdletBinding()]
param(
    [string]$Target = ".",
    [string]$ProjectName = "",
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateRoot = Split-Path -Parent $scriptRoot
$targetRoot = [System.IO.Path]::GetFullPath($Target)

if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
    throw "Target directory does not exist: $targetRoot"
}

if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    $ProjectName = Split-Path -Leaf $targetRoot
}
if ($ProjectName.Contains("`r") -or $ProjectName.Contains("`n")) {
    throw "ProjectName must be a single line."
}

$backupStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $targetRoot ".project-flow-backup\$backupStamp"
$created = 0
$replaced = 0
$skipped = 0

function Assert-InTarget([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $prefix = $targetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (($full -ne $targetRoot) -and (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Refusing path outside target: $full"
    }
}

function Install-TemplateFile([string]$Source, [string]$RelativePath) {
    $destination = Join-Path $targetRoot $RelativePath
    Assert-InTarget $destination
    $exists = Test-Path -LiteralPath $destination -PathType Leaf

    if ($exists -and -not $Force) {
        Write-Host "SKIP  $RelativePath (already exists)"
        $script:skipped++
        return
    }

    if ($DryRun) {
        $verb = if ($exists) { "REPLACE" } else { "CREATE " }
        Write-Host "$verb $RelativePath"
        return
    }

    $destinationDir = Split-Path -Parent $destination
    [System.IO.Directory]::CreateDirectory($destinationDir) | Out-Null

    if ($exists) {
        $backup = Join-Path $backupRoot $RelativePath
        Assert-InTarget $backup
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
        Copy-Item -LiteralPath $destination -Destination $backup
        $script:replaced++
    } else {
        $script:created++
    }

    $content = [System.IO.File]::ReadAllText($Source)
    $content = $content.Replace("<PROJECT_NAME>", $ProjectName)
    $temporary = "$destination.project-flow-tmp-$PID"
    [System.IO.File]::WriteAllText($temporary, $content, $utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $destination -Force
    Write-Host "WRITE $RelativePath"
}

$staticFiles = @("AGENTS.md")
foreach ($relative in $staticFiles) {
    Install-TemplateFile (Join-Path $templateRoot $relative) $relative
}

foreach ($rootName in @(".agents", "docs")) {
    $sourceBase = Join-Path $templateRoot $rootName
    Get-ChildItem -LiteralPath $sourceBase -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($templateRoot.Length).TrimStart('\', '/')
        Install-TemplateFile $_.FullName $relative
    }
}

if ($DryRun) {
    Write-Host "Dry run complete; no files changed."
    exit 0
}

Write-Host "Installed: created=$created replaced=$replaced skipped=$skipped"
if ($replaced -gt 0) {
    Write-Host "Backups: $backupRoot"
}

& (Join-Path $scriptRoot "validate.ps1") -Target $targetRoot
exit $LASTEXITCODE
