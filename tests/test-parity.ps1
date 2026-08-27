[CmdletBinding()]
param(
    [string]$BaselineVersion = "0.7.0",
    [switch]$RequirePosix
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$psEngine = Join-Path $repo "scripts/project-flow.ps1"
$shEngine = (Join-Path $repo "scripts/project-flow.sh").Replace("\", "/")
$temp = Join-Path ([IO.Path]::GetTempPath()) ("codex-project-flow-parity-" + [guid]::NewGuid().ToString("N"))
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Read-NormalizedText([string]$Path) {
    return (Get-Content -Raw -Encoding UTF8 -LiteralPath $Path).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-TextHash([string]$Text) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return "sha256:" + ([BitConverter]::ToString($algorithm.ComputeHash($utf8.GetBytes($Text)))).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Write-Utf8([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Render-Text([string]$Text, [string]$Mode, [string]$ProjectName) {
    switch ($Mode) {
        "none" { return $Text }
        "project_name" { return $Text.Replace("<PROJECT_NAME>", $ProjectName) }
        "project_name_json" { return $Text.Replace('"<PROJECT_NAME>"', (ConvertTo-Json $ProjectName -Compress)) }
        default { throw "Unsupported fixture render mode: $Mode" }
    }
}

function Invoke-Process([string]$FileName, [string[]]$Arguments, [hashtable]$Environment = @{}) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    foreach ($name in $Environment.Keys) { $start.Environment[$name] = [string]$Environment[$name] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout.GetAwaiter().GetResult().Replace("`r`n", "`n").Replace("`r", "`n")
        StdErr = $stderr.GetAwaiter().GetResult().Replace("`r`n", "`n").Replace("`r", "`n")
    }
}

function Find-PosixRuntime {
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($path in @(
        (Join-Path ${env:ProgramFiles} "Git/bin/bash.exe"),
        (Join-Path ${env:ProgramFiles} "Git/usr/bin/bash.exe"),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Git/bin/bash.exe" }),
        $((Get-Command bash.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1))
    )) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf) -and -not $candidates.Contains($path)) { $candidates.Add($path) }
    }

    $probeScript = @'
command -v cygpath >/dev/null 2>&1 || exit 20
for candidate in "${PYTHON-}" python3 python; do
  [ -n "$candidate" ] || continue
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done
exit 21
'@
    foreach ($bash in $candidates) {
        $probeEnvironment = @{ PYTHONIOENCODING = "utf-8" }
        if ($env:PYTHON) { $probeEnvironment.PYTHON = $env:PYTHON }
        $probe = Invoke-Process $bash @("-lc", $probeScript, "parity-probe") $probeEnvironment
        if ($probe.ExitCode -eq 0) {
            $python = @($probe.StdOut.Split("`n", [StringSplitOptions]::RemoveEmptyEntries))[-1].Trim()
            if ($python) {
                $resolved = Invoke-Process $bash @("-lc", 'exec "$PYTHON" -c ''import os,sys; print(sys.executable) if os.name == "nt" else sys.exit(22)''', "parity-python") @{
                    PYTHON = $python
                    PYTHONIOENCODING = "utf-8"
                }
                $pythonExecutable = $resolved.StdOut.Trim()
                if ($resolved.ExitCode -eq 0 -and (Test-Path -LiteralPath $pythonExecutable -PathType Leaf)) {
                    return [pscustomobject]@{ Bash = $bash; Python = $python; PythonExecutable = $pythonExecutable }
                }
            }
        }
    }
    return $null
}

function Invoke-Posix([object]$Runtime, [string]$Mode, [string]$Target, [string]$Transaction = "") {
    $script = if ($Mode -eq "rollback") {
        'exec sh "$1" rollback --target "$2" --rollback "$3"'
    } else {
        'exec sh "$1" "$2" --target "$3"'
    }
    $arguments = if ($Mode -eq "rollback") {
        @($shEngine, $Target.Replace("\", "/"), $Transaction)
    } else {
        @($shEngine, $Mode, $Target.Replace("\", "/"))
    }
    return Invoke-Process $Runtime.Bash (@("-lc", $script, "parity") + $arguments) @{
        PYTHON = $Runtime.Python
        PYTHONIOENCODING = "utf-8"
    }
}

function Invoke-PowerShellEngine([string]$Mode, [string]$Target, [string]$Transaction = "") {
    $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $arguments = @("-NoLogo", "-NoProfile", "-NonInteractive", "-File", $psEngine, $Mode, "-Target", $Target)
    if ($Mode -eq "rollback") { $arguments += @("-Rollback", $Transaction) }
    return Invoke-Process $hostPath $arguments
}

function Start-Helper([string]$FileName, [string[]]$Arguments, [hashtable]$Environment) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    foreach ($name in $Environment.Keys) { $start.Environment[$name] = [string]$Environment[$name] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    return $process
}

function Wait-HelperReady([Diagnostics.Process]$Process, [string]$Ready, [string]$ErrorFile) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Ready -PathType Leaf) { return }
        if ($Process.HasExited) {
            $detail = if (Test-Path -LiteralPath $ErrorFile -PathType Leaf) { Read-NormalizedText $ErrorFile } else { "exit=$($Process.ExitCode)" }
            throw "Lock helper exited before ready: $detail"
        }
        Start-Sleep -Milliseconds 25
    }
    throw "Lock helper did not publish ready within 10 seconds"
}

function Stop-Helper([Diagnostics.Process]$Process, [string]$Release) {
    Write-Utf8 $Release "release`n"
    if (-not $Process.WaitForExit(5000)) {
        $Process.Kill($true)
        $Process.WaitForExit()
        throw "Lock helper did not stop after release"
    }
    Assert-True ($Process.ExitCode -eq 0) "Lock helper failed after release: exit=$($Process.ExitCode)"
    $Process.Dispose()
}

function Start-PowerShellLockHolder([string]$LockPath, [string]$Ready, [string]$Release, [string]$ErrorFile) {
    $helperScript = @'
$ErrorActionPreference = "Stop"
try {
    $parent = Split-Path -Parent $env:PARITY_LOCK
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $handle = [IO.File]::Open($env:PARITY_LOCK,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    try {
        if ($handle.Length -lt 1) { $handle.SetLength(1) }
        $handle.Lock(0,1)
        [IO.File]::WriteAllText($env:PARITY_READY,"ready")
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path -LiteralPath $env:PARITY_RELEASE) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        if (-not (Test-Path -LiteralPath $env:PARITY_RELEASE)) { throw "release timeout" }
        $handle.Unlock(0,1)
    } finally { $handle.Dispose() }
} catch {
    [IO.File]::WriteAllText($env:PARITY_ERROR,$_.Exception.ToString())
    exit 1
}
'@
    $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    return Start-Helper $hostPath @("-NoLogo", "-NoProfile", "-NonInteractive", "-Command", $helperScript) @{
        PARITY_LOCK = $LockPath; PARITY_READY = $Ready; PARITY_RELEASE = $Release; PARITY_ERROR = $ErrorFile
    }
}

function Start-PythonLockHolder([object]$Runtime, [string]$LockPath, [string]$Ready, [string]$Release, [string]$ErrorFile) {
    $helperScript = @'
import os, pathlib, sys, time, traceback
lock, ready, release, error = map(pathlib.Path, sys.argv[1:])
try:
    import msvcrt
    lock.parent.mkdir(parents=True, exist_ok=True)
    handle = open(lock, "a+b", buffering=0)
    try:
        if lock.stat().st_size < 1:
            handle.write(b"\0")
        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        ready.write_text("ready", encoding="utf-8")
        deadline = time.monotonic() + 20
        while not release.exists() and time.monotonic() < deadline:
            time.sleep(0.025)
        if not release.exists():
            raise RuntimeError("release timeout")
        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
    finally:
        handle.close()
except BaseException:
    error.write_text(traceback.format_exc(), encoding="utf-8")
    raise
'@
    return Start-Helper $Runtime.PythonExecutable @("-c", $helperScript, $LockPath, $Ready, $Release, $ErrorFile) @{
        PYTHONIOENCODING = "utf-8"
    }
}

function Assert-OrdinaryLockFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    Assert-True (-not $item.PSIsContainer) "Transaction lock is a directory"
    Assert-True (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Transaction lock is a reparse point"
    Assert-True ($item.Length -ge 1) "Transaction lock is empty"
}

function New-HistoricalFixture([string]$Root, [string]$Version, [string]$ProjectName) {
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $baselineRoot = Join-Path $repo "baselines/$Version"
    $metadataPath = Join-Path $baselineRoot "managed-files.json"
    Assert-True (Test-Path -LiteralPath $metadataPath -PathType Leaf) "Missing historical baseline: $Version"
    $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $metadataPath | ConvertFrom-Json
    $records = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($metadata.files)) {
        $source = Join-Path $baselineRoot ([string]$entry.path)
        Assert-True (Test-Path -LiteralPath $source -PathType Leaf) "Missing baseline file: $Version/$($entry.path)"
        $rendered = Render-Text (Read-NormalizedText $source) ([string]$entry.render) $ProjectName
        Write-Utf8 (Join-Path $Root ([string]$entry.path)) $rendered
        $records.Add([ordered]@{
            path = [string]$entry.path
            source = [string]$entry.source
            policy = [string]$entry.policy
            baseline_hash = Get-TextHash $rendered
        })
    }
    $manifest = [ordered]@{
        schema_version = 1
        workflow_version = $Version
        project_name = $ProjectName
        installed_at_utc = "2026-01-01T00:00:00Z"
        last_transaction = $null
        files = $records.ToArray()
    }
    Write-Utf8 (Join-Path $Root ".project-flow/manifest.json") (($manifest | ConvertTo-Json -Depth 20) + "`n")
}

function Get-PlanActions([string]$Output) {
    $actions = [Collections.Generic.List[string]]::new()
    foreach ($line in $Output.Split("`n")) {
        if ($line -match '^(CREATE|NOOP|PRESERVE|REPLACE|UPSTREAM|MERGE|CONFLICT|ACCEPT|DELETE|REMOVE_NOOP)\s+(\S+)\s+(.+?)\s*$') {
            $actions.Add("$($matches[1])|$($matches[2])|$($matches[3])")
        }
    }
    return @($actions | Sort-Object)
}

function Get-ManagedContract([string]$Root, [object]$Managed) {
    $content = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Managed.files)) {
        $relative = [string]$entry.path
        $path = Join-Path $Root $relative
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing applied managed file: $relative"
        $content.Add([ordered]@{ path = $relative; hash = Get-TextHash (Read-NormalizedText $path) })
    }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root ".project-flow/manifest.json") | ConvertFrom-Json
    return [ordered]@{
        content = @($content | Sort-Object path)
        manifest = [ordered]@{
            schema_version = [int]$manifest.schema_version
            workflow_version = [string]$manifest.workflow_version
            project_name = [string]$manifest.project_name
            files = @($manifest.files | Sort-Object path | ForEach-Object {
                [ordered]@{ path = [string]$_.path; source = [string]$_.source; policy = [string]$_.policy; baseline_hash = [string]$_.baseline_hash }
            })
        }
        transaction_id = [string]$manifest.last_transaction
    }
}

function Get-TransactionContract([string]$Root, [string]$Identifier) {
    $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root ".project-flow/transactions/$Identifier/transaction.json") | ConvertFrom-Json
    return [ordered]@{
        schema_version = [int]$metadata.schema_version
        from_version = [string]$metadata.from_version
        to_version = [string]$metadata.to_version
        state = [string]$metadata.state
        accepted_local = @($metadata.accepted_local | Sort-Object)
        upstream_resolved = @($metadata.upstream_resolved | Sort-Object)
        merged = @($metadata.merged | Sort-Object)
        removed_files = @($metadata.removed_files | Sort-Object)
        files = @($metadata.files | Sort-Object path | ForEach-Object {
            [ordered]@{
                path = [string]$_.path
                existed = [bool]$_.existed
                changed = [bool]$_.changed
                original_hash = if ($null -eq $_.original_hash) { $null } else { [string]$_.original_hash }
                applied_hash = if ($null -eq $_.applied_hash) { $null } else { [string]$_.applied_hash }
                resolution = [string]$_.resolution
            }
        })
    }
}

function Get-RollbackTree([string]$Root) {
    $records = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart("\", "/").Replace("\", "/")
        if ($relative.StartsWith(".project-flow/transactions/", [StringComparison]::Ordinal) -or $relative -ceq ".project-flow/transaction.lock") { continue }
        $records.Add([ordered]@{ path = $relative; hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant() })
    }
    return @($records | Sort-Object path)
}

function Get-CanonicalJson([object]$Value) {
    return $Value | ConvertTo-Json -Depth 30 -Compress
}

function Get-RecordSetDifference([object[]]$Expected, [object[]]$Actual) {
    $expectedMap = @{}; foreach ($record in $Expected) { $expectedMap[[string]$record.path] = [string]$record.hash }
    $actualMap = @{}; foreach ($record in $Actual) { $actualMap[[string]$record.path] = [string]$record.hash }
    $differences = [Collections.Generic.List[string]]::new()
    foreach ($path in @($expectedMap.Keys + $actualMap.Keys | Sort-Object -Unique)) {
        if (-not $expectedMap.ContainsKey($path)) { $differences.Add("added:$path"); continue }
        if (-not $actualMap.ContainsKey($path)) { $differences.Add("missing:$path"); continue }
        if ($expectedMap[$path] -cne $actualMap[$path]) { $differences.Add("changed:$path") }
    }
    return $differences -join ", "
}

$runtime = Find-PosixRuntime
if ($null -eq $runtime) {
    $message = "Cross-platform parity requires Git Bash with a working Python 3 interpreter."
    if ($RequirePosix) { throw "FAIL parity: $message" }
    Write-Warning "SKIP parity: $message Re-run with -RequirePosix to make this a failure."
    return
}

try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $baselinePath = Join-Path $repo "baselines/$BaselineVersion/managed-files.json"
    Assert-True (Test-Path -LiteralPath $baselinePath -PathType Leaf) "Unknown baseline version: $BaselineVersion"
    $managed = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repo "managed-files.json") | ConvertFrom-Json
    $psRoot = Join-Path $temp "powershell"
    $posixRoot = Join-Path $temp "posix"
    New-HistoricalFixture $psRoot $BaselineVersion "ParityProject"
    New-HistoricalFixture $posixRoot $BaselineVersion "ParityProject"
    $psBefore = Get-RollbackTree $psRoot
    $posixBefore = Get-RollbackTree $posixRoot
    Assert-True ((Get-CanonicalJson $psBefore) -ceq (Get-CanonicalJson $posixBefore)) "Fixtures are not identical before execution"

    $signalRoot = Join-Path $temp "helper-signals"
    [IO.Directory]::CreateDirectory($signalRoot) | Out-Null
    $psHeldRoot = Join-Path $temp "powershell-lock-posix-apply"
    New-HistoricalFixture $psHeldRoot $BaselineVersion "ParityLockProject"
    $psHeldBefore = Get-RollbackTree $psHeldRoot
    $psLock = Join-Path $psHeldRoot ".project-flow/transaction.lock"
    $psReady = Join-Path $signalRoot "powershell.ready"
    $psRelease = Join-Path $signalRoot "powershell.release"
    $psError = Join-Path $signalRoot "powershell.error"
    $psHolder = Start-PowerShellLockHolder $psLock $psReady $psRelease $psError
    try {
        Wait-HelperReady $psHolder $psReady $psError
        $blockedPosix = Invoke-Posix $runtime "apply" $psHeldRoot
        Assert-True ($blockedPosix.ExitCode -ne 0) "POSIX apply ignored a PowerShell-held transaction lock"
        Assert-True (($blockedPosix.StdOut + $blockedPosix.StdErr) -match '(?i)lock.*(busy|hold)|another.*lock') "POSIX lock failure did not report a lock-busy reason"
        $psHeldAfter = Get-RollbackTree $psHeldRoot
        Assert-True ((Get-CanonicalJson $psHeldBefore) -ceq (Get-CanonicalJson $psHeldAfter)) "POSIX lock-busy attempt changed the project: $(Get-RecordSetDifference $psHeldBefore $psHeldAfter)"
    } finally {
        Stop-Helper $psHolder $psRelease
    }
    Assert-OrdinaryLockFile $psLock

    $pythonHeldRoot = Join-Path $temp "python-lock-powershell-apply"
    New-HistoricalFixture $pythonHeldRoot $BaselineVersion "ParityLockProject"
    $pythonHeldBefore = Get-RollbackTree $pythonHeldRoot
    $pythonLock = Join-Path $pythonHeldRoot ".project-flow/transaction.lock"
    $pythonReady = Join-Path $signalRoot "python.ready"
    $pythonRelease = Join-Path $signalRoot "python.release"
    $pythonError = Join-Path $signalRoot "python.error"
    $pythonHolder = Start-PythonLockHolder $runtime $pythonLock $pythonReady $pythonRelease $pythonError
    try {
        Wait-HelperReady $pythonHolder $pythonReady $pythonError
        $blockedPowerShell = Invoke-PowerShellEngine "apply" $pythonHeldRoot
        Assert-True ($blockedPowerShell.ExitCode -ne 0) "PowerShell apply ignored a Python-held transaction lock"
        Assert-True (($blockedPowerShell.StdOut + $blockedPowerShell.StdErr) -match '(?i)lock.*(busy|hold)|another.*lock') "PowerShell lock failure did not report a lock-busy reason"
        $pythonHeldAfter = Get-RollbackTree $pythonHeldRoot
        Assert-True ((Get-CanonicalJson $pythonHeldBefore) -ceq (Get-CanonicalJson $pythonHeldAfter)) "PowerShell lock-busy attempt changed the project: $(Get-RecordSetDifference $pythonHeldBefore $pythonHeldAfter)"
    } finally {
        Stop-Helper $pythonHolder $pythonRelease
    }
    Assert-OrdinaryLockFile $pythonLock

    $psPlan = Invoke-PowerShellEngine "plan" $psRoot
    $posixPlan = Invoke-Posix $runtime "plan" $posixRoot
    Assert-True ($psPlan.ExitCode -eq 0) "PowerShell plan failed: $($psPlan.StdErr)"
    Assert-True ($posixPlan.ExitCode -eq 0) "POSIX plan failed: $($posixPlan.StdErr)"
    $psActions = Get-PlanActions $psPlan.StdOut
    $posixActions = Get-PlanActions $posixPlan.StdOut
    Assert-True ($psActions.Count -gt 0) "PowerShell plan contained no actions"
    Assert-True ((Get-CanonicalJson $psActions) -ceq (Get-CanonicalJson $posixActions)) "Normalized plan action sets differ"
    Assert-True ((Get-CanonicalJson $psBefore) -ceq (Get-CanonicalJson (Get-RollbackTree $psRoot))) "PowerShell plan mutated its fixture"
    Assert-True ((Get-CanonicalJson $posixBefore) -ceq (Get-CanonicalJson (Get-RollbackTree $posixRoot))) "POSIX plan mutated its fixture"

    $psApply = Invoke-PowerShellEngine "apply" $psRoot
    $posixApply = Invoke-Posix $runtime "apply" $posixRoot
    Assert-True ($psApply.ExitCode -eq 0) "PowerShell apply failed: $($psApply.StdErr)"
    Assert-True ($posixApply.ExitCode -eq 0) "POSIX apply failed: $($posixApply.StdErr)"
    $psMatch = [regex]::Match($psApply.StdOut, '(?m)^APPLIED\s+(\S+)\s*$')
    $posixMatch = [regex]::Match($posixApply.StdOut, '(?m)^APPLIED\s+(\S+)\s*$')
    Assert-True $psMatch.Success "PowerShell apply omitted APPLIED transaction evidence"
    Assert-True $posixMatch.Success "POSIX apply omitted APPLIED transaction evidence"
    $psTransaction = $psMatch.Groups[1].Value
    $posixTransaction = $posixMatch.Groups[1].Value

    $psValidate = Invoke-PowerShellEngine "validate" $psRoot
    $posixValidate = Invoke-Posix $runtime "validate" $posixRoot
    Assert-True ($psValidate.ExitCode -eq 0) "PowerShell validation failed after apply: $($psValidate.StdErr)"
    Assert-True ($posixValidate.ExitCode -eq 0) "POSIX validation failed after apply: $($posixValidate.StdErr)"
    $psApplied = Get-ManagedContract $psRoot $managed
    $posixApplied = Get-ManagedContract $posixRoot $managed
    Assert-True ((Get-CanonicalJson ([ordered]@{ content = $psApplied.content; manifest = $psApplied.manifest })) -ceq (Get-CanonicalJson ([ordered]@{ content = $posixApplied.content; manifest = $posixApplied.manifest }))) "Applied managed content or manifest contract differs"

    $psMetadata = Get-TransactionContract $psRoot $psTransaction
    $posixMetadata = Get-TransactionContract $posixRoot $posixTransaction
    Assert-True ((Get-CanonicalJson $psMetadata) -ceq (Get-CanonicalJson $posixMetadata)) "Stable transaction metadata differs"

    $psRollback = Invoke-PowerShellEngine "rollback" $psRoot $psTransaction
    $posixRollback = Invoke-Posix $runtime "rollback" $posixRoot $posixTransaction
    Assert-True ($psRollback.ExitCode -eq 0) "PowerShell rollback failed: $($psRollback.StdErr)"
    Assert-True ($posixRollback.ExitCode -eq 0) "POSIX rollback failed: $($posixRollback.StdErr)"
    Assert-True ($psRollback.StdOut -match '(?m)^ROLLED_BACK\s+') "PowerShell rollback omitted evidence"
    Assert-True ($posixRollback.StdOut -match '(?m)^ROLLED_BACK\s+') "POSIX rollback omitted evidence"
    $psAfter = Get-RollbackTree $psRoot
    $posixAfter = Get-RollbackTree $posixRoot
    Assert-True ((Get-CanonicalJson $psBefore) -ceq (Get-CanonicalJson $psAfter)) "PowerShell rollback did not restore its fixture: $(Get-RecordSetDifference $psBefore $psAfter)"
    Assert-True ((Get-CanonicalJson $posixBefore) -ceq (Get-CanonicalJson $posixAfter)) "POSIX rollback did not restore its fixture: $(Get-RecordSetDifference $posixBefore $posixAfter)"
    Assert-True ((Get-CanonicalJson $psAfter) -ceq (Get-CanonicalJson $posixAfter)) "Rollback results differ between platforms"

    Write-Host "PASS cross-platform parity: baseline=$BaselineVersion actions=$($psActions.Count) managed=$(@($managed.files).Count) locks=2"
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temp)
    $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolvedTemp) -and $resolvedTemp.StartsWith($resolvedSystemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTemp).StartsWith("codex-project-flow-parity-", [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
