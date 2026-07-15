$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$install = Join-Path $repoRoot "scripts/install.ps1"
$validate = Join-Path $repoRoot "scripts/validate.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-project-flow-" + [guid]::NewGuid().ToString("N"))
$emptyTarget = Join-Path $testRoot "empty-project"
$existingTarget = Join-Path $testRoot "existing-project"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

    & $validate -Target $repoRoot -AllowPlaceholders
    if ($LASTEXITCODE -ne 0) { throw "Template validation failed." }

    & $install -Target $emptyTarget -ProjectName "Empty Project"
    if ($LASTEXITCODE -ne 0) { throw "Empty-project installation failed." }
    $configText = [System.IO.File]::ReadAllText((Join-Path $emptyTarget ".agents/workflow.json"))
    if ($configText.Contains("<PROJECT_NAME>") -or -not $configText.Contains("Empty Project")) {
        throw "Project name rendering failed."
    }

    $firstDigest = Get-ManagedDigest $emptyTarget
    & $install -Target $emptyTarget -ProjectName "Empty Project"
    if ($LASTEXITCODE -ne 0) { throw "Second installation failed." }
    $secondDigest = Get-ManagedDigest $emptyTarget
    if ($firstDigest -ne $secondDigest) { throw "Installation is not idempotent." }

    $existingAgents = Join-Path $existingTarget "AGENTS.md"
    [System.IO.File]::WriteAllText($existingAgents, "# Existing project rules`n", $utf8NoBom)
    & $install -Target $existingTarget -ProjectName "Existing Project"
    if ($LASTEXITCODE -ne 0) { throw "Existing-project installation failed." }
    if ([System.IO.File]::ReadAllText($existingAgents) -ne "# Existing project rules`n") {
        throw "Default install overwrote an existing AGENTS.md."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $existingTarget ".agents/snippets/AGENTS.integration.md"))) {
        throw "Integration snippet was not installed."
    }

    & $install -Target $existingTarget -ProjectName "Existing Project" -Force
    if ($LASTEXITCODE -ne 0) { throw "Forced installation failed." }
    $backup = Get-ChildItem -LiteralPath (Join-Path $existingTarget ".project-flow-backup") -Recurse -File -Filter "AGENTS.md" | Select-Object -First 1
    if (-not $backup -or [System.IO.File]::ReadAllText($backup.FullName) -ne "# Existing project rules`n") {
        throw "Forced installation did not preserve the existing AGENTS.md backup."
    }

    Write-Host "All PowerShell tests passed."
} finally {
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedTestRoot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
