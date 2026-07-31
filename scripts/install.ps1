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
$targetItem = Get-Item -LiteralPath $targetRoot -Force
if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Target directory must not be a symbolic link, junction, or reparse point: $targetRoot"
}

if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    $ProjectName = Split-Path -Leaf $targetRoot
}
foreach ($character in $ProjectName.ToCharArray()) {
    if ([char]::IsControl($character)) {
        throw "ProjectName must not contain control characters."
    }
}

$created = 0
$replaced = 0
$skipped = 0
$projectNameJson = ConvertTo-Json -InputObject $ProjectName -Compress

function Assert-InTarget([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $prefix = $targetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (($full -ne $targetRoot) -and (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Refusing path outside target: $full"
    }
}

function Assert-NoReparsePoint([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    Assert-InTarget $full

    $current = $targetRoot
    $rootItem = Get-Item -LiteralPath $current -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing target path through a reparse point: $current"
    }
    if ($full -eq $targetRoot) {
        return
    }

    $prefix = $targetRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $relative = $full.Substring($prefix.Length)
    $parts = $relative.Split(
        [char[]]@('\', '/'),
        [System.StringSplitOptions]::RemoveEmptyEntries
    )
    foreach ($part in $parts) {
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            break
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing target path through a symbolic link, junction, or reparse point: $current"
        }
    }
}

$backupStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $targetRoot ".project-flow-backup\$backupStamp"
$backupSuffix = 0
Assert-NoReparsePoint $backupRoot
while (Test-Path -LiteralPath $backupRoot) {
    $backupSuffix++
    $backupRoot = Join-Path $targetRoot ".project-flow-backup\$backupStamp-$backupSuffix"
    Assert-NoReparsePoint $backupRoot
}

function Install-TemplateFile([string]$Source, [string]$RelativePath) {
    $destination = Join-Path $targetRoot $RelativePath
    Assert-InTarget $destination
    Assert-NoReparsePoint $destination
    $exists = Test-Path -LiteralPath $destination -PathType Leaf
    if ((Test-Path -LiteralPath $destination) -and -not $exists) {
        throw "Destination exists and is not a file: $destination"
    }

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
        Assert-NoReparsePoint $backup
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
        Copy-Item -LiteralPath $destination -Destination $backup
        $script:replaced++
    } else {
        $script:created++
    }

    $content = [System.IO.File]::ReadAllText($Source)
    if ($RelativePath.Replace('\', '/') -eq ".agents/workflow.json") {
        $content = $content.Replace('"<PROJECT_NAME>"', $projectNameJson)
    } else {
        $content = $content.Replace("<PROJECT_NAME>", $ProjectName)
    }
    $temporary = "$destination.project-flow-tmp-$PID"
    [System.IO.File]::WriteAllText($temporary, $content, $utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $destination -Force
    Write-Host "WRITE $RelativePath"
}

$templateFiles = New-Object System.Collections.Generic.List[object]
$templateFiles.Add([pscustomobject]@{
    Source = Join-Path $templateRoot "AGENTS.md"
    Relative = "AGENTS.md"
})

foreach ($rootName in @(".agents", "docs")) {
    $sourceBase = Join-Path $templateRoot $rootName
    Get-ChildItem -LiteralPath $sourceBase -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($templateRoot.Length).TrimStart('\', '/')
        $templateFiles.Add([pscustomobject]@{
            Source = $_.FullName
            Relative = $relative
        })
    }
}

foreach ($templateFile in $templateFiles) {
    $destination = Join-Path $targetRoot $templateFile.Relative
    Assert-NoReparsePoint $destination
    if ($Force -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Assert-NoReparsePoint (Join-Path $backupRoot $templateFile.Relative)
    }
}

foreach ($templateFile in $templateFiles) {
    Install-TemplateFile $templateFile.Source $templateFile.Relative
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
