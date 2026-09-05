[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repo ".agents/workflow.json") | ConvertFrom-Json

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-Trace {
    return [ordered]@{
        list_projects = 1; hub_read = 1; read_thread = 0
        list_threads = 0; list_archived_threads = 0
        set_title = 0; unarchive = 0; pin = 0; create = 0
        lock_inspect = 0; lock_acquire = 0; lock_recover = 0; orphan_recover = 0; lock_bind = 0
        install = 0; hub_write = 0; lock_release = 0
        mode = ""; stopped = $false; lock_retained = $false; retained_phase = ""; candidates = @(); events = @()
    }
}

function Invoke-MockBootstrap([hashtable]$Scenario) {
    $trace = New-Trace
    $registryState = [string]$Scenario.registry

    if ($registryState -eq "valid") {
        $trace.read_thread++
        if ($Scenario.read -eq "valid") {
            $trace.mode = "fast"
            $trace.lock_acquire++
            if ($Scenario.read_binding -eq "conflict") {
                $trace.stopped = $true
                $trace.lock_retained = $true
                return $trace
            }
            if ($Scenario.title_truncated -or -not $Scenario.title_canonical) { $trace.set_title++ }
            if ($Scenario.archived -eq $true) { $trace.unarchive++ }
            if (-not $Scenario.pinned) { $trace.pin++ }
            if ($Scenario.fail_title -or $Scenario.fail_pin) {
                $trace.stopped = $true
                $trace.lock_release++
                return $trace
            }
            $trace.hub_write++
            $trace.lock_release++
            return $trace
        }
        $registryState = "targeted_failure"
    }

    if ($registryState -eq "missing" -and -not $Scenario.installed) {
        $trace.mode = "fresh"
        $trace.lock_acquire++
        $trace.events += "acquire"
        $trace.set_title++
        $trace.events += "claim-current"
        if ($Scenario.fail_title -or $Scenario.title_result_incomplete -or $Scenario.title_binding -eq "conflict") {
            $trace.stopped = $true
            $trace.lock_retained = $true
            return $trace
        }
        $trace.lock_bind++
        $trace.events += "bind-current"
        $trace.install++
        $trace.events += "install"
        if ($Scenario.fail_install) {
            $trace.set_title++
            $trace.events += "restore-title"
            $trace.stopped = $true
            $trace.lock_release++
            return $trace
        }
        $trace.set_title++
        $trace.events += "canonical-title"
        $trace.pin++
        if ($Scenario.fail_pin) {
            $trace.stopped = $true
            $trace.lock_retained = $true
            return $trace
        }
        $trace.hub_write++
        $trace.lock_release++
        return $trace
    }

    $trace.mode = "recovery"
    $lockState = if ($Scenario.ContainsKey("lock_state")) { [string]$Scenario.lock_state } elseif ($Scenario.stale_lock) { "stale" } else { "missing" }
    if ($lockState -ne "missing") {
        $trace.lock_inspect++
        if ($lockState -in @("busy", "live")) {
            $trace.stopped = $true
            $trace.lock_retained = $true
            return $trace
        }
    } else {
        $trace.lock_acquire++
    }
    $trace.list_threads++
    $trace.list_archived_threads++
    $trace.candidates = @($Scenario.candidates)
    if ($lockState -eq "stale" -and $null -eq $Scenario.lock_thread_id -and $trace.candidates.Count -eq 0) {
        if ($Scenario.lock_phase -notin @("install", "installing")) {
            $trace.stopped = $true
            $trace.lock_retained = $true
            return $trace
        }
        $trace.lock_recover++
        $trace.orphan_recover++
        $trace.retained_phase = "installing"
        $trace.events += "orphan-cas"
        $trace.set_title++
        $trace.events += "claim-current"
        if ($Scenario.fail_title -or $Scenario.title_result_incomplete -or $Scenario.title_binding -eq "conflict") {
            $trace.stopped = $true
            $trace.lock_retained = $true
            return $trace
        }
        $trace.lock_bind++
        $trace.events += "bind-current"
        $trace.set_title++
        $trace.events += "canonical-title"
        $trace.pin++
        if ($Scenario.fail_pin) {
            $trace.stopped = $true
            $trace.lock_retained = $true
            return $trace
        }
        $trace.hub_write++
        $trace.lock_release++
        return $trace
    }
    if ($trace.candidates.Count -ne 1) {
        $trace.stopped = $true
        $trace.lock_retained = $true
        return $trace
    }
    $candidate = $trace.candidates[0]
    if ($candidate.conflict -or $Scenario.read_binding -eq "conflict") {
        $trace.stopped = $true
        $trace.lock_retained = $true
        return $trace
    }
    $trace.read_thread++
    if ($lockState -eq "stale") {
        if ($Scenario.old_owner_active -or $Scenario.claim_match -eq $false) {
            $trace.stopped = $true
            $trace.lock_retained = $true
            return $trace
        }
        $trace.lock_recover++
    }
    if ($candidate.archived) { $trace.unarchive++ }
    if (-not $candidate.title_canonical) {
        $trace.set_title++
        if ($Scenario.title_result_incomplete -or $Scenario.title_binding -eq "conflict") {
            $trace.stopped = $true
            $trace.lock_retained = $true
            return $trace
        }
    }
    if (-not $candidate.pinned) { $trace.pin++ }
    if ($Scenario.fail_title -or $Scenario.fail_pin) {
        $trace.stopped = $true
        $trace.lock_retained = $true
        return $trace
    }
    $trace.lock_bind++
    $trace.hub_write++
    $trace.lock_release++
    return $trace
}

$hub = [ordered]@{ id="thread-hub-0001"; archived=$false; pinned=$true; title_canonical=$true; conflict=$false }

# 1-5: registry fast path, known ID, truncated title, active and archived behavior.
$fast = Invoke-MockBootstrap @{ registry="valid"; installed=$true; read="valid"; read_binding="omitted"; title_canonical=$true; title_truncated=$false; archived=$false; pinned=$true }
Assert ($fast.mode -eq "fast" -and $fast.list_threads -eq 0 -and $fast.list_archived_threads -eq 0 -and $fast.read_thread -eq 1) "valid registry did not use the zero-list fast path"
Assert ($fast.create -eq 0 -and $fast.unarchive -eq 0 -and $fast.hub_write -eq 1) "omitted targeted-read project binding blocked the known hub"

$fastConflict = Invoke-MockBootstrap @{ registry="valid"; installed=$true; read="valid"; read_binding="conflict"; title_canonical=$true; title_truncated=$false; archived=$false; pinned=$true }
Assert ($fastConflict.stopped -and $fastConflict.lock_retained -and $fastConflict.hub_write -eq 0 -and $fastConflict.set_title -eq 0 -and $fastConflict.pin -eq 0) "explicit targeted-read project conflict was accepted"

$truncated = Invoke-MockBootstrap @{ registry="valid"; installed=$true; read="valid"; title_canonical=$false; title_truncated=$true; archived=$false; pinned=$true }
Assert ($truncated.set_title -eq 1 -and $truncated.list_threads -eq 0 -and $truncated.create -eq 0) "truncated title caused discovery or duplicate creation"

$archived = Invoke-MockBootstrap @{ registry="valid"; installed=$true; read="valid"; title_canonical=$true; title_truncated=$false; archived=$true; pinned=$false }
Assert ($archived.unarchive -eq 1 -and $archived.pin -eq 1) "explicitly archived hub was not restored exactly once"

# 6 and 14: fresh bootstrap claims this task once; failures never create a replacement.
$fresh = Invoke-MockBootstrap @{ registry="missing"; installed=$false; title_binding="omitted" }
Assert ($fresh.mode -eq "fresh" -and $fresh.create -eq 0 -and $fresh.set_title -eq 2 -and $fresh.hub_write -eq 1) "fresh bootstrap did not produce exactly one current-task hub"
Assert ($fresh.lock_bind -eq 1 -and $fresh.lock_release -eq 1) "missing title-response project binding blocked a verified current-task claim"
Assert (($fresh.events -join ",") -ceq "acquire,claim-current,bind-current,install,canonical-title") "fresh bootstrap did not bind the current task before installation"

$freshBindingConflict = Invoke-MockBootstrap @{ registry="missing"; installed=$false; title_binding="conflict" }
Assert ($freshBindingConflict.stopped -and $freshBindingConflict.lock_retained -and $freshBindingConflict.hub_write -eq 0 -and $freshBindingConflict.pin -eq 0) "explicit title-response project conflict was accepted"

foreach ($failure in @("fail_install", "fail_title", "title_result_incomplete", "fail_pin")) {
    $scenario = @{ registry="missing"; installed=$false; $failure=$true }
    $failed = Invoke-MockBootstrap $scenario
    Assert ($failed.stopped -and $failed.create -eq 0 -and $failed.hub_write -eq 0) "$failure created or committed a replacement hub"
    if ($failure -eq "fail_install") { Assert ($failed.lock_bind -eq 1 -and $failed.set_title -eq 2 -and $failed.lock_release -eq 1 -and (($failed.events -join ",") -ceq "acquire,claim-current,bind-current,install,restore-title")) "install failure did not restore the bound current task before release" }
    else { Assert ($failed.lock_retained -and $failed.lock_release -eq 0) "$failure discarded recoverable claim evidence" }
}

# 8-12: mismatched/copy bindings are never read or mutated; exceptions scan once.
foreach ($state in @("project_mismatch", "path_mismatch")) {
    $copy = Invoke-MockBootstrap @{ registry=$state; installed=$true; candidates=@() }
    Assert ($copy.mode -eq "recovery" -and $copy.read_thread -eq 0 -and $copy.set_title -eq 0 -and $copy.unarchive -eq 0 -and $copy.stopped) "$state touched the registered foreign task"
}

$missingThread = Invoke-MockBootstrap @{ registry="valid"; installed=$true; read="missing"; candidates=@($hub) }
Assert ($missingThread.mode -eq "recovery" -and $missingThread.list_threads -eq 1 -and $missingThread.list_archived_threads -eq 1) "missing registered task did not enter one controlled recovery scan"

$legacy = Invoke-MockBootstrap @{ registry="missing"; installed=$true; candidates=@($hub) }
Assert ($legacy.mode -eq "recovery" -and $legacy.list_threads -eq 1 -and $legacy.list_archived_threads -eq 1 -and $legacy.hub_write -eq 1) "legacy hub did not migrate through one exhaustive scan"

$duplicates = Invoke-MockBootstrap @{ registry="missing"; installed=$true; candidates=@($hub, [ordered]@{id="thread-hub-0002"}) }
Assert ($duplicates.stopped -and $duplicates.candidates.Count -eq 2 -and $duplicates.set_title -eq 0 -and $duplicates.unarchive -eq 0 -and $duplicates.pin -eq 0 -and $duplicates.create -eq 0) "duplicate hubs were selected or mutated"
Assert ($duplicates.lock_retained -and $duplicates.lock_release -eq 0) "duplicate candidates released their recovery barrier"

# 13: an existing stale lock with no bound thread is inspected, reconciled to one inactive claim, and recovered without acquire/create.
$interrupted = Invoke-MockBootstrap @{ registry="missing"; installed=$true; lock_state="stale"; lock_thread_id=$null; claim_match=$true; old_owner_active=$false; candidates=@([ordered]@{id="thread-claim-0001";archived=$false;pinned=$false;title_canonical=$false;conflict=$false}) }
Assert ($interrupted.lock_inspect -eq 1 -and $interrupted.lock_recover -eq 1 -and $interrupted.lock_acquire -eq 0 -and $interrupted.create -eq 0 -and $interrupted.hub_write -eq 1) "stale unbound claim was not inspected and recovered"

$orphaned = Invoke-MockBootstrap @{ registry="missing"; installed=$true; lock_state="stale"; lock_thread_id=$null; lock_phase="installing"; candidates=@() }
Assert ($orphaned.lock_inspect -eq 1 -and $orphaned.orphan_recover -eq 1 -and $orphaned.lock_recover -eq 1 -and $orphaned.lock_acquire -eq 0) "stale unbound zero-candidate claim did not use orphan CAS recovery"
Assert ($orphaned.create -eq 0 -and $orphaned.unarchive -eq 0 -and $orphaned.set_title -eq 2 -and $orphaned.lock_bind -eq 1 -and $orphaned.hub_write -eq 1 -and $orphaned.lock_release -eq 1 -and (($orphaned.events -join ",") -ceq "orphan-cas,claim-current,bind-current,canonical-title")) "orphan recovery did not claim only the current task and finish the registry"

$orphanTitleFailure = Invoke-MockBootstrap @{ registry="missing"; installed=$true; lock_state="stale"; lock_thread_id=$null; lock_phase="installing"; candidates=@(); title_result_incomplete=$true }
Assert ($orphanTitleFailure.stopped -and $orphanTitleFailure.orphan_recover -eq 1 -and $orphanTitleFailure.lock_retained -and $orphanTitleFailure.hub_write -eq 0 -and $orphanTitleFailure.create -eq 0) "incomplete orphan claim discarded its recovered owner evidence"
$orphanRetry = Invoke-MockBootstrap @{ registry="missing"; installed=$true; lock_state="stale"; lock_thread_id=$null; lock_phase=$orphanTitleFailure.retained_phase; candidates=@() }
Assert ($orphanTitleFailure.retained_phase -ceq "installing" -and $orphanRetry.orphan_recover -eq 1 -and $orphanRetry.create -eq 0 -and $orphanRetry.hub_write -eq 1) "interrupted orphan title claim was not recoverable on the next invocation"

$orphanWrongPhase = Invoke-MockBootstrap @{ registry="missing"; installed=$true; lock_state="stale"; lock_thread_id=$null; lock_phase="creating"; candidates=@() }
Assert ($orphanWrongPhase.stopped -and $orphanWrongPhase.orphan_recover -eq 0 -and $orphanWrongPhase.set_title -eq 0 -and $orphanWrongPhase.create -eq 0) "non-install stale lock used orphan recovery"

foreach ($state in @("busy", "live")) {
    $blocked = Invoke-MockBootstrap @{ registry="missing"; installed=$true; lock_state=$state; candidates=@($hub) }
    Assert ($blocked.stopped -and $blocked.lock_inspect -eq 1 -and $blocked.lock_acquire -eq 0 -and $blocked.lock_recover -eq 0 -and $blocked.list_threads -eq 0 -and $blocked.create -eq 0) "$state lock was scanned, acquired, recovered, or replaced"
}

$activeOwner = Invoke-MockBootstrap @{ registry="missing"; installed=$true; lock_state="stale"; claim_match=$true; old_owner_active=$true; candidates=@([ordered]@{id="thread-claim-0001";archived=$false;pinned=$false;title_canonical=$false;conflict=$false}) }
Assert ($activeOwner.stopped -and $activeOwner.lock_inspect -eq 1 -and $activeOwner.lock_recover -eq 0 -and $activeOwner.set_title -eq 0 -and $activeOwner.pin -eq 0) "active stale-lock owner was recovered or mutated"

$ambiguousClaim = Invoke-MockBootstrap @{ registry="missing"; installed=$true; lock_state="stale"; claim_match=$true; old_owner_active=$false; candidates=@($hub, [ordered]@{id="thread-claim-0002"}) }
Assert ($ambiguousClaim.stopped -and $ambiguousClaim.lock_inspect -eq 1 -and $ambiguousClaim.lock_recover -eq 0 -and $ambiguousClaim.create -eq 0) "ambiguous stale claim was recovered or replaced"

# Machine policy is the production contract consumed by the Skill.
Assert ($workflow.schema_version -eq 10) "bootstrap interaction model requires workflow schema 10"
Assert ($workflow.bootstrap.fast_path -eq "registry_targeted_read") "fast-path policy mismatch"
Assert ($workflow.bootstrap.recovery_path -eq "exhaustive_metadata_on_exception") "recovery policy mismatch"
Assert ($workflow.bootstrap.unarchive -eq "only_when_explicitly_archived") "unarchive policy mismatch"
Assert ($workflow.bootstrap.title_identity -eq "saved_project_binding_plus_mutation_thread") "title identity policy mismatch"
Assert ($workflow.bootstrap.lock_acquire -eq "atomic_create_new") "lock acquire policy mismatch"
Assert ($workflow.bootstrap.lock_inspect -eq "validated_read_only") "lock inspect policy mismatch"
Assert ($workflow.bootstrap.existing_lock -eq "inspect_then_recover_or_stop") "existing lock routing policy mismatch"
Assert ($workflow.bootstrap.stale_recovery -eq "exact_token_cas_same_thread_or_install_orphan") "stale recovery policy mismatch"

Write-Host "All bootstrap interaction contract tests passed."
