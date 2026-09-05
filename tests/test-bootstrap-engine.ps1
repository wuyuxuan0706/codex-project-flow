[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$engine = Join-Path $repo "scripts/project-flow.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("codex-project-flow-bootstrap-" + [guid]::NewGuid().ToString("N"))
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $utf8) }
function Invoke-Engine([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @("-NoLogo", "-NoProfile", "-NonInteractive", "-File", $engine) + $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start; [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync(); $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout.GetAwaiter().GetResult(); StdErr = $stderr.GetAwaiter().GetResult() }
}
function Start-Engine([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @("-NoLogo", "-NoProfile", "-NonInteractive", "-File", $engine) + $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start; [void]$process.Start(); $process
}

try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $missingRoot = Join-Path $temp "inspect-missing"; [IO.Directory]::CreateDirectory($missingRoot) | Out-Null
    $result = Invoke-Engine @("bootstrap-lock-inspect", "-Target", $missingRoot, "-ProjectId", "project-bootstrap-0001")
    Assert ($result.ExitCode -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $missingRoot ".project-flow"))) "missing-lock inspect mutated the target"
    $root = Join-Path $temp "lifecycle"; [IO.Directory]::CreateDirectory($root) | Out-Null
    $project = "project-bootstrap-0001"; $ownerA = "claim-owner-0001"; $ownerB = "claim-owner-0002"; $ownerC = "claim-owner-0003"
    $threadA = "thread-hub-0001"; $threadB = "thread-hub-0002"; $title = "项目中枢 · Bootstrap"

    $result = Invoke-Engine @("bootstrap-lock-acquire", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerA, "-Phase", "install")
    Assert ($result.ExitCode -eq 0) ("initial lock acquire failed: " + $result.StdErr)
    $lock = $result.StdOut | ConvertFrom-Json
    Assert ($lock.projectId -ceq $project -and $lock.ownerId -ceq $ownerA -and $null -eq $lock.threadId) "initial lock contract"
    $lockPath = Join-Path $root ".project-flow/bootstrap.lock"
    $lockBeforeInspect = [IO.File]::ReadAllBytes($lockPath)
    $result = Invoke-Engine @("bootstrap-lock-inspect", "-Target", $root, "-ProjectId", $project)
    Assert ($result.ExitCode -eq 0) ("initial lock inspect failed: " + $result.StdErr)
    $inspection = $result.StdOut | ConvertFrom-Json -DateKind String
    Assert ($inspection.ownerId -ceq $ownerA -and $inspection.isStale -eq $false -and $inspection.staleAt) "initial lock inspection contract"
    Assert (([Convert]::ToBase64String($lockBeforeInspect)) -ceq ([Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)))) "lock inspect changed the lock file"
    $result = Invoke-Engine @("bootstrap-lock-acquire", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB, "-Phase", "install")
    Assert ($result.ExitCode -ne 0) "second owner acquired an existing lock"

    $result = Invoke-Engine @("bootstrap-lock-renew", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerA, "-ThreadId", $threadA, "-Phase", "claim")
    Assert ($result.ExitCode -eq 0) ("lock bind failed: " + $result.StdErr)
    $result = Invoke-Engine @("bootstrap-lock-renew", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerA, "-Phase", "claim")
    $preserved = $result.StdOut | ConvertFrom-Json
    Assert ($result.ExitCode -eq 0 -and $preserved.threadId -ceq $threadA) "bound owner fence did not preserve the existing thread"
    $result = Invoke-Engine @("bootstrap-lock-renew", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerA, "-ThreadId", $threadB, "-Phase", "claim")
    Assert ($result.ExitCode -ne 0) "ordinary renew switched an existing thread binding"
    $result = Invoke-Engine @("hub-write", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB, "-HubThreadId", $threadA, "-HubTitle", $title)
    Assert ($result.ExitCode -ne 0) "non-owner wrote the hub registry"
    $result = Invoke-Engine @("hub-write", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerA, "-HubThreadId", $threadA, "-HubTitle", $title)
    Assert ($result.ExitCode -eq 0) ("hub registry write failed: " + $result.StdErr)
    $hubPath = Join-Path $root ".project-flow/hub.json"; $hubBefore = [IO.File]::ReadAllBytes($hubPath)
    $hub = (Invoke-Engine @("hub-read", "-Target", $root, "-ProjectId", $project)).StdOut | ConvertFrom-Json
    Assert ($hub.schemaVersion -eq 1 -and $hub.projectId -ceq $project -and $hub.threadId -ceq $threadA -and $hub.projectPath -ceq [IO.Path]::GetFullPath($root)) "hub registry contract"
    Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $hubPath) -Filter "*.project-flow-tmp-*" -Force).Count -eq 0) "atomic registry write left a temporary file"

    $validHubText = Get-Content -Raw -Encoding UTF8 $hubPath
    $caseHub = $validHubText | ConvertFrom-Json; $caseHub.projectPath = $caseHub.projectPath.Substring(0, 1).ToLowerInvariant() + $caseHub.projectPath.Substring(1)
    Write-Utf8 $hubPath (($caseHub | ConvertTo-Json -Depth 10) + "`n")
    $result = Invoke-Engine @("hub-read", "-Target", $root, "-ProjectId", $project)
    Assert ($result.ExitCode -eq 0) "Windows canonical path casing was treated as a different project"
    $extraHub = $validHubText | ConvertFrom-Json; $extraHub | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    Write-Utf8 $hubPath (($extraHub | ConvertTo-Json -Depth 10) + "`n")
    $result = Invoke-Engine @("hub-read", "-Target", $root, "-ProjectId", $project)
    Assert ($result.ExitCode -ne 0) "hub registry accepted an unexpected field"
    Write-Utf8 $hubPath $validHubText
    $result = Invoke-Engine @("hub-write", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerA, "-HubThreadId", $threadA, "-HubTitle", "bad`ntitle")
    Assert ($result.ExitCode -ne 0) "hub registry accepted a control character"

    $result = Invoke-Engine @("hub-read", "-Target", $root, "-ProjectId", "project-bootstrap-9999")
    Assert ($result.ExitCode -ne 0) "mismatched projectId read the registry"
    Assert (([Convert]::ToBase64String($hubBefore)) -ceq ([Convert]::ToBase64String([IO.File]::ReadAllBytes($hubPath)))) "projectId mismatch modified registry"
    $copy = Join-Path $temp "copied-project"; Copy-Item -LiteralPath $root -Destination $copy -Recurse
    $result = Invoke-Engine @("hub-read", "-Target", $copy, "-ProjectId", $project)
    Assert ($result.ExitCode -ne 0) "copied project reused the original registry"
    $result = Invoke-Engine @("hub-read", "-Target", $root, "-ProjectId", "bad/id")
    Assert ($result.ExitCode -ne 0) "illegal identifier was accepted"

    $result = Invoke-Engine @("bootstrap-lock-release", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB)
    Assert ($result.ExitCode -ne 0) "non-owner released the lock"
    $validLockText = Get-Content -Raw -Encoding UTF8 $lockPath
    $invalidTimes = $validLockText | ConvertFrom-Json; $invalidTimes.renewedAt = "2025-01-01T00:00:00Z"
    Write-Utf8 $lockPath (($invalidTimes | ConvertTo-Json -Depth 10) + "`n")
    $result = Invoke-Engine @("bootstrap-lock-release", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerA)
    Assert ($result.ExitCode -ne 0) "bootstrap lock accepted inconsistent timestamps"
    Write-Utf8 $lockPath $validLockText
    $shortened = $validLockText | ConvertFrom-Json; $now = [DateTimeOffset]::UtcNow
    $shortened.createdAt = $now.AddSeconds(-3).ToString("o"); $shortened.renewedAt = $now.AddSeconds(-2).ToString("o"); $shortened.expiresAt = $now.AddSeconds(-1).ToString("o")
    Write-Utf8 $lockPath (($shortened | ConvertTo-Json -Depth 10) + "`n")
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB, "-Phase", "recover", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", $shortened.renewedAt, "-ConfirmedOwnerInactive")
    Assert ($result.ExitCode -ne 0) "edited expiresAt shortened the fixed stale threshold"
    Write-Utf8 $lockPath $validLockText
    $stale = Get-Content -Raw -Encoding UTF8 $lockPath | ConvertFrom-Json
    $stale.createdAt = "2026-01-01T00:00:00.0000000Z"; $stale.renewedAt = "2026-01-01T00:00:01.0000001Z"; $stale.expiresAt = "2026-01-01T00:00:02.0000000Z"
    Write-Utf8 $lockPath (($stale | ConvertTo-Json -Depth 10) + "`n")
    $staleBeforeInspect = [IO.File]::ReadAllBytes($lockPath)
    $result = Invoke-Engine @("bootstrap-lock-inspect", "-Target", $root, "-ProjectId", $project)
    Assert ($result.ExitCode -eq 0) ("stale lock inspect failed: " + $result.StdErr)
    $inspection = $result.StdOut | ConvertFrom-Json -DateKind String
    Assert ($inspection.isStale -eq $true -and $inspection.ownerId -ceq $ownerA -and $inspection.threadId -ceq $threadA) "stale lock inspection did not preserve owner evidence"
    Assert (([Convert]::ToBase64String($staleBeforeInspect)) -ceq ([Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)))) "stale inspect changed the lock file"
    $result = Invoke-Engine @("bootstrap-lock-inspect", "-Target", $root, "-ProjectId", "project-bootstrap-9999")
    Assert ($result.ExitCode -ne 0) "lock inspect accepted a different projectId"
    Assert (([Convert]::ToBase64String($staleBeforeInspect)) -ceq ([Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)))) "mismatched inspect changed the lock file"
    $result = Invoke-Engine @("bootstrap-lock-acquire", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB, "-Phase", "recover")
    Assert ($result.ExitCode -ne 0) "normal acquire took over a stale lock"
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB, "-ThreadId", $threadA, "-Phase", "recover", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", $inspection.renewedAt)
    Assert ($result.ExitCode -ne 0) "stale recovery omitted owner-inactive proof"
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB, "-ThreadId", $threadA, "-Phase", "recover", "-ExpectedOwnerId", "claim-owner-9999", "-ExpectedRenewedAt", $inspection.renewedAt, "-ConfirmedOwnerInactive")
    Assert ($result.ExitCode -ne 0) "stale recovery accepted the wrong previous owner"
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB, "-ThreadId", $threadA, "-Phase", "recover", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", "2026-01-01T00:00:01.0000000Z", "-ConfirmedOwnerInactive")
    Assert ($result.ExitCode -ne 0) "stale recovery accepted changed renewedAt evidence"
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB, "-ThreadId", $threadB, "-Phase", "recover", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", $inspection.renewedAt, "-ConfirmedOwnerInactive")
    Assert ($result.ExitCode -ne 0) "bound stale recovery switched to a different thread"
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB, "-ThreadId", $threadA, "-Phase", "recover", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", $inspection.renewedAt, "-ConfirmedOwnerInactive")
    Assert ($result.ExitCode -eq 0) ("authenticated stale recovery failed: " + $result.StdErr)
    $result = Invoke-Engine @("hub-write", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB, "-HubThreadId", $threadB, "-HubTitle", $title)
    Assert ($result.ExitCode -ne 0) "recovered lock overwrote a different registered hub"
    $result = Invoke-Engine @("bootstrap-lock-release", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerA)
    Assert ($result.ExitCode -ne 0) "previous owner released a recovered lock"
    $result = Invoke-Engine @("bootstrap-lock-release", "-Target", $root, "-ProjectId", $project, "-OwnerId", $ownerB)
    Assert ($result.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $lockPath)) "current owner could not release lock"

    $orphanRoot = Join-Path $temp "orphan"; [IO.Directory]::CreateDirectory($orphanRoot) | Out-Null
    $result = Invoke-Engine @("bootstrap-lock-acquire", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerA, "-Phase", "installing")
    Assert ($result.ExitCode -eq 0) "orphan fixture acquire failed"
    $result = Invoke-Engine @("bootstrap-lock-renew", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerA, "-Phase", "installing")
    $unbound = $result.StdOut | ConvertFrom-Json
    Assert ($result.ExitCode -eq 0 -and $null -eq $unbound.threadId) "unbound owner fence did not preserve null thread"
    $orphanLockPath = Join-Path $orphanRoot ".project-flow/bootstrap.lock"
    $orphan = Get-Content -Raw -Encoding UTF8 $orphanLockPath | ConvertFrom-Json
    $orphan.createdAt = "2026-01-01T00:00:00.0000000Z"; $orphan.renewedAt = "2026-01-01T00:00:01.0000000Z"; $orphan.expiresAt = "2026-01-01T00:00:02.0000000Z"
    Write-Utf8 $orphanLockPath (($orphan | ConvertTo-Json -Depth 10) + "`n")
    $orphanInspect = (Invoke-Engine @("bootstrap-lock-inspect", "-Target", $orphanRoot, "-ProjectId", $project)).StdOut | ConvertFrom-Json -DateKind String
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerB, "-Phase", "installing", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", $orphanInspect.renewedAt, "-ConfirmedOwnerInactive")
    Assert ($result.ExitCode -ne 0) "zero-candidate recovery omitted orphan confirmation"
    $orphan.phase = "creating"; Write-Utf8 $orphanLockPath (($orphan | ConvertTo-Json -Depth 10) + "`n")
    $wrongPhaseInspect = (Invoke-Engine @("bootstrap-lock-inspect", "-Target", $orphanRoot, "-ProjectId", $project)).StdOut | ConvertFrom-Json -DateKind String
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerB, "-Phase", "installing", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", $wrongPhaseInspect.renewedAt, "-ConfirmedOrphanedClaim")
    Assert ($result.ExitCode -ne 0) "non-install stale lock used orphan recovery"
    $orphan.phase = "installing"; Write-Utf8 $orphanLockPath (($orphan | ConvertTo-Json -Depth 10) + "`n")
    $orphanInspect = (Invoke-Engine @("bootstrap-lock-inspect", "-Target", $orphanRoot, "-ProjectId", $project)).StdOut | ConvertFrom-Json -DateKind String
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerB, "-Phase", "orphan-recovery", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", $orphanInspect.renewedAt, "-ConfirmedOrphanedClaim")
    Assert ($result.ExitCode -ne 0) "orphan recovery accepted a non-recoverable new phase"
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerB, "-Phase", "installing", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", $orphanInspect.renewedAt, "-ConfirmedOrphanedClaim")
    $recoveredOrphan = $result.StdOut | ConvertFrom-Json
    Assert ($result.ExitCode -eq 0 -and $recoveredOrphan.ownerId -ceq $ownerB -and $null -eq $recoveredOrphan.threadId -and $recoveredOrphan.phase -ceq "installing") "orphan recovery did not atomically transfer a recoverable unbound lock"
    $orphan = Get-Content -Raw -Encoding UTF8 $orphanLockPath | ConvertFrom-Json
    $orphan.createdAt = "2026-01-01T00:00:00.0000000Z"; $orphan.renewedAt = "2026-01-01T00:00:03.0000000Z"; $orphan.expiresAt = "2026-01-01T00:00:04.0000000Z"
    Write-Utf8 $orphanLockPath (($orphan | ConvertTo-Json -Depth 10) + "`n")
    $secondOrphanInspect = (Invoke-Engine @("bootstrap-lock-inspect", "-Target", $orphanRoot, "-ProjectId", $project)).StdOut | ConvertFrom-Json -DateKind String
    $result = Invoke-Engine @("bootstrap-lock-recover", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerC, "-Phase", "installing", "-ExpectedOwnerId", $ownerB, "-ExpectedRenewedAt", $secondOrphanInspect.renewedAt, "-ConfirmedOrphanedClaim")
    $recoveredAgain = $result.StdOut | ConvertFrom-Json
    Assert ($result.ExitCode -eq 0 -and $recoveredAgain.ownerId -ceq $ownerC -and $null -eq $recoveredAgain.threadId -and $recoveredAgain.phase -ceq "installing") "interrupted orphan title claim could not be recovered a second time"
    $result = Invoke-Engine @("bootstrap-lock-renew", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerA, "-Phase", "claim")
    Assert ($result.ExitCode -ne 0) "previous orphan owner passed a post-recovery fence"
    $result = Invoke-Engine @("bootstrap-lock-renew", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerB, "-ThreadId", $threadB, "-Phase", "claim")
    Assert ($result.ExitCode -ne 0) "first recovery owner passed the second recovery fence"
    $result = Invoke-Engine @("bootstrap-lock-renew", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerC, "-ThreadId", $threadB, "-Phase", "claim")
    Assert ($result.ExitCode -eq 0) "recovered orphan owner could not bind the current task"
    $result = Invoke-Engine @("hub-write", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerC, "-HubThreadId", $threadB, "-HubTitle", $title)
    Assert ($result.ExitCode -eq 0) "recovered orphan owner could not commit the hub"
    $result = Invoke-Engine @("bootstrap-lock-release", "-Target", $orphanRoot, "-ProjectId", $project, "-OwnerId", $ownerC)
    Assert ($result.ExitCode -eq 0) "recovered orphan owner could not release the lock"

    $orphanRaceRoot = Join-Path $temp "orphan-race"; [IO.Directory]::CreateDirectory($orphanRaceRoot) | Out-Null
    [void](Invoke-Engine @("bootstrap-lock-acquire", "-Target", $orphanRaceRoot, "-ProjectId", $project, "-OwnerId", $ownerA, "-Phase", "installing"))
    $orphanRacePath = Join-Path $orphanRaceRoot ".project-flow/bootstrap.lock"; $orphanRace = Get-Content -Raw -Encoding UTF8 $orphanRacePath | ConvertFrom-Json
    $orphanRace.createdAt = "2026-01-01T00:00:00.0000000Z"; $orphanRace.renewedAt = "2026-01-01T00:00:01.0000000Z"; $orphanRace.expiresAt = "2026-01-01T00:00:02.0000000Z"; Write-Utf8 $orphanRacePath (($orphanRace | ConvertTo-Json -Depth 10) + "`n")
    $raceArgsA = @("bootstrap-lock-recover", "-Target", $orphanRaceRoot, "-ProjectId", $project, "-OwnerId", $ownerB, "-Phase", "installing", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", $orphanRace.renewedAt, "-ConfirmedOrphanedClaim")
    $raceArgsB = @("bootstrap-lock-recover", "-Target", $orphanRaceRoot, "-ProjectId", $project, "-OwnerId", $ownerC, "-Phase", "installing", "-ExpectedOwnerId", $ownerA, "-ExpectedRenewedAt", $orphanRace.renewedAt, "-ConfirmedOrphanedClaim")
    $orphanFirst = Start-Engine $raceArgsA; $orphanSecond = Start-Engine $raceArgsB; $orphanFirst.WaitForExit(); $orphanSecond.WaitForExit()
    $orphanCodes = @($orphanFirst.ExitCode, $orphanSecond.ExitCode)
    Assert ((@($orphanCodes | Where-Object { $_ -eq 0 }).Count -eq 1) -and (@($orphanCodes | Where-Object { $_ -ne 0 }).Count -eq 1)) "concurrent orphan recovery did not produce one winner"
    $orphanWinner = (Get-Content -Raw -Encoding UTF8 $orphanRacePath | ConvertFrom-Json).ownerId
    [void](Invoke-Engine @("bootstrap-lock-release", "-Target", $orphanRaceRoot, "-ProjectId", $project, "-OwnerId", $orphanWinner))

    $raceRoot = Join-Path $temp "concurrent"; [IO.Directory]::CreateDirectory($raceRoot) | Out-Null
    $argumentsA = @("bootstrap-lock-acquire", "-Target", $raceRoot, "-ProjectId", $project, "-OwnerId", $ownerA, "-Phase", "claim")
    $argumentsB = @("bootstrap-lock-acquire", "-Target", $raceRoot, "-ProjectId", $project, "-OwnerId", $ownerB, "-Phase", "claim")
    $first = Start-Engine $argumentsA; $second = Start-Engine $argumentsB; $first.WaitForExit(); $second.WaitForExit()
    $codes = @($first.ExitCode, $second.ExitCode) | Sort-Object
    $firstOutput = $first.StandardOutput.ReadToEnd() + $first.StandardError.ReadToEnd(); $secondOutput = $second.StandardOutput.ReadToEnd() + $second.StandardError.ReadToEnd()
    Assert (($codes -join ",") -ceq "0,1") ("concurrent acquire exit codes: " + ($codes -join ",") + "`n" + $firstOutput + "`n" + $secondOutput)
    $winner = (Get-Content -Raw -Encoding UTF8 (Join-Path $raceRoot ".project-flow/bootstrap.lock") | ConvertFrom-Json).ownerId
    $result = Invoke-Engine @("bootstrap-lock-release", "-Target", $raceRoot, "-ProjectId", $project, "-OwnerId", $winner)
    Assert ($result.ExitCode -eq 0) "concurrent acquire winner could not release lock"

    Write-Host "Bootstrap PowerShell engine tests passed."
} finally {
    if ((Test-Path -LiteralPath $temp) -and (Split-Path -Leaf $temp).StartsWith("codex-project-flow-bootstrap-", [StringComparison]::Ordinal)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
