[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$workflow = Get-Content -Raw -Encoding UTF8 (Join-Path $repo ".agents/workflow.json") | ConvertFrom-Json

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-Model {
    [ordered]@{
        Requests=@{}; Active=$null; UpgradeBarrierState=$null; UpgradeBarrierScanComplete=$true
        Created=[Collections.Generic.List[string]]::new()
        Archived=[Collections.Generic.List[string]]::new()
        HubActions=[Collections.Generic.List[string]]::new()
        ExecutionActions=[Collections.Generic.List[string]]::new()
        AcceptedSteps=[Collections.Generic.List[string]]::new()
        AcceptanceMemory=@{}
        AcceptanceArchiveAttempts=0
        RotationIntents=@{}
        NativeCreateAttempts=0
        NativeArchiveAttempts=0
        StateOnlySyncs=0
        FileTransactions=0
    }
}
function New-HubRequest($Model,[string]$RequestId,[string]$Understanding,[string[]]$ExecutionItems) {
    if ($Model.Requests.ContainsKey($RequestId)) { return $null }
    $request=[ordered]@{RequestId=$RequestId;State="awaiting_authorization";Generation=1;ThreadId=$null;Understanding=$Understanding;ExecutionItems=@($ExecutionItems);Completion=$null}
    $Model.Requests[$RequestId]=$request
    $Model.HubActions.Add("$RequestId`:request-id")
    $Model.HubActions.Add("$RequestId`:understanding")
    $Model.HubActions.Add("$RequestId`:execution-items")
    $request
}
function Confirm-HubRequest($Model,[string]$RequestId,[ValidateSet("exact","queued")][string]$IdentityKind="exact") {
    if (-not $Model.Requests.ContainsKey($RequestId)) { return $null }
    $request=$Model.Requests[$RequestId]
    if ($request.State -notin @("awaiting_authorization","queued") -or $null -ne $request.ThreadId) { return $null }
    if (-not $Model.UpgradeBarrierScanComplete -or $Model.UpgradeBarrierState -in @("provisional","active")) {
        $request.State="queued";$Model.HubActions.Add("$RequestId`:queued-by-upgrade-barrier");return $null
    }
    $identity=if($IdentityKind-ceq"queued"){"client-$RequestId-g1"}else{"task-$RequestId-g1"}
    $request.ThreadId=$identity;$request.State=if($IdentityKind-ceq"queued"){"queued"}else{"active"}
    $Model.Created.Add($identity);$Model.HubActions.Add("$RequestId`:create-once:$IdentityKind")
    if($IdentityKind-ceq"exact"){$Model.Active=$request};$identity
}
function Activate-QueuedIdentity($Model,[string]$RequestId,[string]$ExactThreadId) {
    $request=$Model.Requests[$RequestId]
    if($request.State-cne"queued"-or-not$request.ThreadId.StartsWith("client-")){return $false}
    $request.ThreadId=$ExactThreadId;$request.State="active";$Model.Active=$request
    $Model.ExecutionActions.Add("$RequestId`:queued-identity-resolved");$true
}
function Invoke-ExecutionAction($Model,[string]$RequestId,[string]$Action,[bool]$Authorized) {
    if(-not$Authorized-or$null-eq$Model.Active-or$Model.Active.RequestId-cne$RequestId-or$Model.Active.State-cne"active"){return $false}
    $Model.ExecutionActions.Add("$($Model.Active.ThreadId):$Action");$true
}
function Request-InPlaceConfirmation($Model,[string]$RequestId,[string]$Understanding,[string[]]$ExecutionItems,[string]$Reason) {
    if($null-eq$Model.Active-or$Model.Active.RequestId-cne$RequestId-or$Model.Active.State-notin@("active","awaiting_acceptance")){return $false}
    $Model.Active.State="revision_pending";$Model.Active.Understanding=$Understanding;$Model.Active.ExecutionItems=@($ExecutionItems)
    $Model.ExecutionActions.Add("$($Model.Active.ThreadId):$Reason")
    $Model.ExecutionActions.Add("$($Model.Active.ThreadId):understanding")
    $Model.ExecutionActions.Add("$($Model.Active.ThreadId):execution-items");$true
}
function Confirm-InPlace($Model,[string]$RequestId) {
    if($null-eq$Model.Active-or$Model.Active.RequestId-cne$RequestId-or$Model.Active.State-cne"revision_pending"){return $false}
    $Model.Active.State="active";$Model.ExecutionActions.Add("$($Model.Active.ThreadId):revision-confirmed");$true
}
function Complete-Round($Model,[string]$RequestId,[System.Collections.IDictionary]$Completion) {
    if($null-eq$Model.Active-or$Model.Active.RequestId-cne$RequestId-or$Model.Active.State-cne"active"){return $false}
    if((@($Completion.Keys)-join",")-cne((@($workflow.requests.completion_fields))-join",")){return $false}
    $Model.Active.Completion=$Completion;$Model.Active.State="awaiting_acceptance";$Model.ExecutionActions.Add("$($Model.Active.ThreadId):completion");$true
}
function Self-ArchiveAccepted(
    $Model,[string]$RequestId,$ArchiveResult,[string]$MappedStep="",[string]$AcceptanceText="",
    [bool]$HumanAccepted=$true,[ValidateSet("success","failure")][string]$MemoryOutcome="success"
) {
    if($null-eq$Model.Active-or$Model.Active.RequestId-cne$RequestId-or$Model.Active.State-cne"awaiting_acceptance"){return $false}
    $threadId=$Model.Active.ThreadId
    $memory=$Model.AcceptanceMemory[$RequestId]
    $mode=if([string]::IsNullOrWhiteSpace($MappedStep)){"state_only"}else{"mapped_step"}
    if($null-eq$memory){
        if(-not$HumanAccepted){return $false}
        if($MemoryOutcome-cne"success"){$Model.ExecutionActions.Add("$threadId`:acceptance-memory-failed");return $false}
        if($mode-ceq"state_only"){$Model.StateOnlySyncs=[int]$Model.StateOnlySyncs+1;$Model.ExecutionActions.Add("$threadId`:sync-state-only")}else{$Model.AcceptedSteps.Add($MappedStep);$Model.ExecutionActions.Add("$threadId`:sync-explicit-step:$MappedStep")}
        $memory=[ordered]@{ThreadId=$threadId;Mode=$mode;MappedStep=$MappedStep;State="synced"};$Model.AcceptanceMemory[$RequestId]=$memory
    } elseif($memory.ThreadId-cne$threadId-or$memory.Mode-cne$mode-or$memory.MappedStep-cne$MappedStep) {
        return $false
    }
    $Model.AcceptanceArchiveAttempts=[int]$Model.AcceptanceArchiveAttempts+1
    if($null-eq$ArchiveResult-or$ArchiveResult.success-ne$true-or[string]$ArchiveResult.archivedTaskId-cne$threadId){return $false}
    $Model.Archived.Add($threadId);$Model.Active.State="accepted_archived";$Model.ExecutionActions.Add("$threadId`:self-archived");$Model.Active=$null;$true
}
function Request-AmbiguousArchive($Model,[string]$RequestId) {
    if($null-eq$Model.Active-or$Model.Active.RequestId-cne$RequestId){return $false}
    $threadId=$Model.Active.ThreadId;$Model.ExecutionActions.Add("$threadId`:save-memory");$Model.ExecutionActions.Add("$threadId`:ask-continue-or-pause");$true
}
function Complete-ContinuationArchive($Model,$Intent,[ValidateSet("success","failure","unknown")][string]$ArchiveOutcome) {
    if($Intent.State-cne"created_gated"-or$null-eq$Model.Active-or$Model.Active.ThreadId-cne$Intent.PredecessorThreadId){return $false}
    $Model.NativeArchiveAttempts=[int]$Model.NativeArchiveAttempts+1
    if($ArchiveOutcome-cne"success"){
        $Model.ExecutionActions.Add("$($Intent.PredecessorThreadId)`:archive-$ArchiveOutcome")
        return $false
    }
    $Model.Archived.Add($Intent.PredecessorThreadId);$Model.ExecutionActions.Add("$($Intent.PredecessorThreadId)`:continued-archived")
    $Model.Active.Generation=$Intent.NextGeneration;$Model.Active.ThreadId=$Intent.SuccessorThreadId;$Model.Active.State="active"
    $Intent.State="activated";$Model.ExecutionActions.Add("$($Intent.SuccessorThreadId)`:predecessor-archive-matched");$true
}
function Continue-ExecutionTask(
    $Model,[string]$RequestId,[bool]$Authorized,[int]$OccupiedSlots=1,
    [ValidateSet("created_gated","unknown")][string]$CreateOutcome="created_gated",
    [ValidateSet("success","failure","unknown")][string]$ArchiveOutcome="success"
) {
    if(-not$Authorized-or$null-eq$Model.Active-or$Model.Active.RequestId-cne$RequestId-or$Model.Active.State-cne"active"){return $false}
    $intent=$Model.RotationIntents[$RequestId]
    if($null-eq$intent){
        if($OccupiedSlots-ge[int]$workflow.tasks.max_active){return $false}
        $predecessor=$Model.Active.ThreadId;$nextGeneration=[int]$Model.Active.Generation+1;$successor="task-$RequestId-g$nextGeneration"
        $Model.ExecutionActions.Add("$predecessor`:save-memory")
        $intent=[ordered]@{RequestId=$RequestId;PredecessorThreadId=$predecessor;SuccessorThreadId=$successor;NextGeneration=$nextGeneration;State="intent_persisted"}
        $Model.RotationIntents[$RequestId]=$intent;$Model.ExecutionActions.Add("$predecessor`:continuation-intent-persisted:$successor")
        $Model.NativeCreateAttempts=[int]$Model.NativeCreateAttempts+1
        if($CreateOutcome-ceq"unknown"){
            $intent.State="creation_unknown";$Model.ExecutionActions.Add("$successor`:creation-unknown");return $false
        }
        $Model.Created.Add($successor);$intent.State="created_gated";$Model.ExecutionActions.Add("$successor`:created-gated")
    } elseif($intent.PredecessorThreadId-cne$Model.Active.ThreadId) {
        return $false
    } elseif($intent.State-ceq"creation_unknown") {
        $Model.ExecutionActions.Add("$($intent.SuccessorThreadId)`:creation-unknown-await-recovery");return $false
    } elseif($intent.State-cne"created_gated") {
        return $false
    }
    Complete-ContinuationArchive $Model $intent $ArchiveOutcome
}
function Resolve-UnknownSuccessor(
    $Model,[string]$RequestId,[string]$ExactSuccessorThreadId,
    [ValidateSet("success","failure","unknown")][string]$ArchiveOutcome="success"
) {
    $intent=$Model.RotationIntents[$RequestId]
    if($null-eq$intent-or$intent.State-cne"creation_unknown"-or$intent.SuccessorThreadId-cne$ExactSuccessorThreadId-or$null-eq$Model.Active-or$Model.Active.ThreadId-cne$intent.PredecessorThreadId){return $false}
    $Model.Created.Add($intent.SuccessorThreadId);$intent.State="created_gated"
    $Model.ExecutionActions.Add("$($intent.SuccessorThreadId)`:creation-recovered-exact")
    Complete-ContinuationArchive $Model $intent $ArchiveOutcome
}
function Pause-ExecutionTask($Model,[string]$RequestId,[bool]$Authorized) {
    if(-not$Authorized-or$null-eq$Model.Active-or$Model.Active.RequestId-cne$RequestId){return $false}
    $threadId=$Model.Active.ThreadId;$Model.ExecutionActions.Add("$threadId`:save-memory");$Model.Archived.Add($threadId)
    $Model.Active.State="paused_archived";$Model.ExecutionActions.Add("$threadId`:paused-archived");$Model.Active=$null;$true
}
function Start-UpgradeFileTransaction($Model,[object[]]$ActiveSnapshot) {
    if(@($ActiveSnapshot).Count-ne0){$Model.ExecutionActions.Add("$($Model.Active.ThreadId):upgrade-blocked-nonempty-snapshot");return $false}
    $Model.FileTransactions=[int]$Model.FileTransactions+1;$Model.ExecutionActions.Add("$($Model.Active.ThreadId):upgrade-file-transaction");$true
}
function Test-ExecutionCapacity([string[]]$States,[string[]]$ExistingPaths,[string[]]$RequestedPaths) {
    $occupying=@("active","blocked","waiting","queued","awaiting_acceptance")
    $occupied=@($States|Where-Object{$occupying-ccontains$_}).Count
    $overlap=@($RequestedPaths|Where-Object{$ExistingPaths-ccontains$_}).Count-gt0
    ($occupied -lt [int]$workflow.tasks.max_active) -and -not $overlap
}
function Test-SuccessorPathGate([object[]]$ActiveTasks,[string]$ExactPredecessorThreadId,[string[]]$RequestedPaths) {
    if(@($ActiveTasks).Count -ge [int]$workflow.tasks.max_active){return $false}
    $conflicting=@($ActiveTasks | Where-Object {
        [string]$_.threadId -cne $ExactPredecessorThreadId -and @($_.paths | Where-Object { $RequestedPaths -ccontains $_ }).Count -gt 0
    })
    $conflicting.Count -eq 0
}
    Assert($workflow.schema_version-eq13) "request model requires schema 13"
    Assert($workflow.tasks.max_active-eq5) "visible execution limit must be five"
    Assert($workflow.requests.initial_owner-ceq"hub") "hub must own only the initial phase"
    Assert($workflow.requests.handoff_boundary-ceq"exact_or_queued_execution_task_identity_established") "handoff boundary mismatch"
    Assert($workflow.requests.post_handoff_owner-ceq"execution_task") "execution task must own post-handoff lifecycle"
    Assert($workflow.requests.hub_post_handoff-ceq"no_participation_for_same_request") "hub post-handoff participation must be forbidden"
    Assert($workflow.requests.acceptance_owner-ceq"execution_task") "execution task must own acceptance"
    Assert($workflow.requests.execution_task_binding-ceq"one_current_visible_task_per_request_with_authorized_successor") "request successor binding mismatch"
    Assert($workflow.requests.acceptance_archive-ceq"sync_explicitly_mapped_step_or_state_only_then_exact_self_archive_without_next_step") "self-archive contract mismatch"
    Assert($workflow.requests.rejection_route-ceq"execution_task_reconfirm_in_place") "rejection route mismatch"
    Assert($workflow.requests.scope_change_route-ceq"execution_task_reconfirm_in_place") "scope-change route mismatch"
    Assert($workflow.documents.PSObject.Properties.Name-cnotcontains"review") "retired document review contract remains"
    Assert($workflow.rotation.mode-ceq"manual_natural_language_continue_or_pause") "manual continuation policy mismatch"
    Assert($null-eq$workflow.rotation.context_threshold) "rotation must not use an automatic context threshold"
    Assert($workflow.rotation.successor_gate-ceq"wait_for_matching_predecessor_archive_before_work") "successor gate mismatch"
    Assert($workflow.rotation.capacity-ceq"reserve_one_slot_before_create_never_exceed_max_active") "successor capacity rule mismatch"
    Assert(Test-ExecutionCapacity @("active","blocked","waiting","queued") @("src/a.cpp") @("src/b.cpp")) "four occupied slots did not permit an independent fifth request"
    Assert(-not(Test-ExecutionCapacity @("active","blocked","waiting","queued","awaiting_acceptance") @("src/a.cpp") @("src/b.cpp"))) "sixth request bypassed the five-slot limit"
    Assert(-not(Test-ExecutionCapacity @("active") @("src/shared.cpp") @("src/shared.cpp"))) "overlapping paths were allowed to run concurrently"
    $barrierModel=New-Model;[void](New-HubRequest $barrierModel "B1" "independent" @("inspect"));$barrierModel.UpgradeBarrierScanComplete=$false
    Assert(($null -eq (Confirm-HubRequest $barrierModel "B1")) -and $barrierModel.Created.Count -eq 0) "incomplete barrier scan allowed a new execution task"
    $barrierModel.UpgradeBarrierScanComplete=$true;$barrierModel.UpgradeBarrierState="provisional"
    Assert(($null -eq (Confirm-HubRequest $barrierModel "B1")) -and $barrierModel.Created.Count -eq 0) "provisional barrier allowed a new execution task"
    $barrierModel.UpgradeBarrierState="active"
    Assert(($null -eq (Confirm-HubRequest $barrierModel "B1")) -and $barrierModel.Created.Count -eq 0) "active barrier allowed a new execution task"
    $barrierModel.UpgradeBarrierState="released"
    Assert(((Confirm-HubRequest $barrierModel "B1") -ceq "task-B1-g1") -and $barrierModel.Created.Count -eq 1) "released barrier did not resume queued task creation"
    Assert($workflow.upgrade.reconcile.active_snapshot-ceq"empty_required_before_file_transaction_fail_closed") "upgrade active snapshot must be empty before file transaction"
    foreach($retiredField in @("successor_key","task_handshake")){Assert($workflow.upgrade.PSObject.Properties.Name-cnotcontains$retiredField) "retired upgrade field remains: $retiredField"}
    foreach($retiredField in @("successor_creation","pair_order")){Assert($workflow.upgrade.reconcile.PSObject.Properties.Name-cnotcontains$retiredField) "retired reconcile field remains: $retiredField"}
    Assert($workflow.upgrade.PSObject.Properties.Name-cnotcontains"recovery") "empty upgrade recovery container must be removed"

    $model=New-Model;$request=New-HubRequest $model "R1" "understand R1" @("inspect","modify","test")
    Assert($null-ne$request-and$model.Created.Count-eq0) "hub created a task before initial authorization"
    $threadId=Confirm-HubRequest $model "R1"
    Assert($threadId-ceq"task-R1-g1"-and$model.Created.Count-eq1) "hub did not create exactly one execution task"
    $hubActionsAfterHandoff=$model.HubActions.Count
    foreach($action in @("inspect","modify","build","test","self_check","evidence")){Assert(Invoke-ExecutionAction $model "R1" $action $true) "authorized execution action failed"}
    Assert(Request-InPlaceConfirmation $model "R1" "expanded understanding" @("modify","test") "scope-change") "scope change did not pause in the execution task"
    Assert($model.Active.ThreadId-ceq$threadId-and$model.Active.Generation-eq1) "scope change altered task identity or generation"
    Assert(Confirm-InPlace $model "R1") "scope change confirmation failed"
    Assert($model.Created.Count-eq1-and$model.HubActions.Count-eq$hubActionsAfterHandoff) "scope change created another task or returned to hub"

    $completion=[ordered]@{changes=@("changed");verification=@("passed");uncovered=@("none");risk=@("low")}
    Assert(-not(Complete-Round $model "R1" ([ordered]@{verification=@("passed");changes=@("changed");uncovered=@("none");risk=@("low")}))) "out-of-order completion was accepted"
    Assert(Complete-Round $model "R1" $completion) "valid completion failed"
    Assert(Request-InPlaceConfirmation $model "R1" "address rejection" @("modify","test") "completion-rejected") "completion rejection did not stay in execution task"
    Assert(Confirm-InPlace $model "R1") "rejection reconfirmation failed"
    Assert($model.Active.ThreadId-ceq$threadId-and$model.Active.Generation-eq1-and$model.Created.Count-eq1) "completion rejection changed task identity"
    Assert(Complete-Round $model "R1" $completion) "revised completion failed"
    Assert($model.HubActions.Count-eq$hubActionsAfterHandoff) "completion or rejection returned to hub"

    Assert(-not(Self-ArchiveAccepted $model "R1" ([ordered]@{success=$true;archivedTaskId="task-wrong-g1"}) "S01" "接受")) "wrong self-archive task ID ended request"
    Assert($model.Active.State-ceq"awaiting_acceptance"-and$model.Archived.Count-eq0-and$model.AcceptedSteps.Count-eq1-and$model.AcceptanceArchiveAttempts-eq1) "wrong self-archive did not preserve one completed acceptance-memory sync"
    Assert(-not(Self-ArchiveAccepted $model "R1" ([ordered]@{success=$true;archivedTaskId=$threadId}) "S02" "接受")) "archive retry changed the explicit mapped step"
    Assert($model.AcceptedSteps.Count-eq1-and$model.AcceptedSteps[0]-ceq"S01"-and$model.AcceptanceArchiveAttempts-eq1) "mismatched retry repeated memory sync or attempted archive"
    Assert(-not(Self-ArchiveAccepted $model "R1" ([ordered]@{success=$false;archivedTaskId=$threadId}) "S01" "接受")) "failed self-archive ended request"
    Assert(-not(Self-ArchiveAccepted $model "R1" $null "S01" "接受")) "uncertain self-archive ended request"
    Assert($model.Active.State-ceq"awaiting_acceptance"-and$model.Created.Count-eq1-and$model.AcceptedSteps.Count-eq1-and$model.AcceptanceArchiveAttempts-eq3) "failed or unknown self-archive changed lifecycle or repeated memory sync"
    Assert(Self-ArchiveAccepted $model "R1" ([ordered]@{success=$true;archivedTaskId=$threadId}) "S01" "接受并继续下一步") "exact self-archive failed"
    Assert($model.Requests["R1"].State-ceq"accepted_archived"-and$model.Archived.Count-eq1-and$model.Archived[0]-ceq$threadId) "request did not end on exact self-archive"
    Assert(($model.ExecutionActions -join ",").Contains("$threadId`:sync-explicit-step:S01,$threadId`:self-archived")) "explicitly mapped step was not synced before self-archive"
    Assert($model.AcceptedSteps.Count-eq1-and$model.AcceptedSteps[0]-ceq"S01"-and$model.StateOnlySyncs-eq0-and$model.AcceptanceArchiveAttempts-eq4) "acceptance did not use one explicit step sync followed by archive retries"
    Assert($model.Created.Count-eq1) "acceptance text requesting continuation incorrectly created a next-step task"
    Assert($model.HubActions.Count-eq$hubActionsAfterHandoff) "acceptance or archival involved the hub"

    $rotationModel=New-Model;[void](New-HubRequest $rotationModel "R2" "rotate" @("modify"));$predecessor=Confirm-HubRequest $rotationModel "R2"
    Assert(Request-AmbiguousArchive $rotationModel "R2") "ambiguous archive did not save and ask"
    Assert($rotationModel.Archived.Count-eq0-and$rotationModel.Created.Count-eq1-and$rotationModel.Active.ThreadId-ceq$predecessor-and$rotationModel.AcceptedSteps.Count-eq0-and$rotationModel.StateOnlySyncs-eq0) "ambiguous archive created, archived, or accepted work"
    $predecessorTask=[ordered]@{threadId=$predecessor;state="active";paths=@("src/shared.cpp")}
    $otherSharedTask=[ordered]@{threadId="task-other-g1";state="active";paths=@("src/shared.cpp")}
    $otherDisjointTask=[ordered]@{threadId="task-other-g2";state="active";paths=@("src/other.cpp")}
    Assert(Test-SuccessorPathGate @($predecessorTask) $predecessor @("src/shared.cpp")) "successor path gate did not exclude the exact predecessor"
    Assert(-not(Test-SuccessorPathGate @($predecessorTask) "task-wrong-g1" @("src/shared.cpp"))) "successor path gate excluded a non-matching predecessor"
    Assert(-not(Test-SuccessorPathGate @($predecessorTask,$otherSharedTask) $predecessor @("src/shared.cpp"))) "successor path gate ignored another task with the same path"
    Assert(Test-SuccessorPathGate @($predecessorTask,$otherDisjointTask) $predecessor @("src/shared.cpp")) "disjoint task incorrectly blocked successor creation"
    Assert(-not(Continue-ExecutionTask $rotationModel "R2" $false 1)) "unauthorized continuation created a successor"
    Assert(-not(Continue-ExecutionTask $rotationModel "R2" $true 5)) "continuation exceeded the five-slot limit"
    Assert(Continue-ExecutionTask $rotationModel "R2" $true 4) "authorized continuation failed with one reserved slot"
    Assert($rotationModel.Active.ThreadId-ceq"task-R2-g2"-and$rotationModel.Active.Generation-eq2) "successor identity or generation mismatch"
    $rotationEvents=$rotationModel.ExecutionActions -join ","
    Assert($rotationEvents.Contains("$predecessor`:save-memory,$predecessor`:continuation-intent-persisted:task-R2-g2,task-R2-g2:created-gated,$predecessor`:continued-archived,task-R2-g2:predecessor-archive-matched")) "continuation order, durable intent, or successor gate mismatch"
    Assert($rotationModel.NativeCreateAttempts-eq1-and$rotationModel.NativeArchiveAttempts-eq1-and$rotationModel.RotationIntents["R2"].State-ceq"activated") "successful continuation did not use one durable create/archive sequence"
    Assert(Pause-ExecutionTask $rotationModel "R2" $true) "authorized pause failed"
    Assert($null-eq$rotationModel.Active-and$rotationModel.Created.Count-eq2-and$rotationModel.Archived.Count-eq2-and$rotationModel.AcceptedSteps.Count-eq0-and$rotationModel.StateOnlySyncs-eq0) "pause created a task, accepted work, or retained an active task"

    $archiveFailureModel=New-Model;[void](New-HubRequest $archiveFailureModel "R4" "archive failure" @("modify"));$failurePredecessor=Confirm-HubRequest $archiveFailureModel "R4"
    Assert(-not(Continue-ExecutionTask $archiveFailureModel "R4" $true 4 "created_gated" "failure")) "failed predecessor archive activated the successor"
    $failureIntent=$archiveFailureModel.RotationIntents["R4"];$failureSuccessor=$failureIntent.SuccessorThreadId
    Assert($failureIntent.State-ceq"created_gated"-and$failureIntent.PredecessorThreadId-ceq$failurePredecessor-and$archiveFailureModel.Active.ThreadId-ceq$failurePredecessor) "archive failure did not retain the exact gated continuation intent"
    Assert($archiveFailureModel.NativeCreateAttempts-eq1-and$archiveFailureModel.NativeArchiveAttempts-eq1-and$archiveFailureModel.Created.Count-eq2-and$archiveFailureModel.Archived.Count-eq0) "archive failure repeated creation, archived, or lost the gated successor"
    Assert(-not(($archiveFailureModel.ExecutionActions-join",").Contains("$failurePredecessor`:continued-archived"))) "archive failure marked the predecessor continued_archived"
    Assert(Continue-ExecutionTask $archiveFailureModel "R4" $true 5 "unknown" "success") "archive-failure retry did not recover the exact gated successor"
    Assert($archiveFailureModel.NativeCreateAttempts-eq1-and$archiveFailureModel.NativeArchiveAttempts-eq2-and$archiveFailureModel.Active.ThreadId-ceq$failureSuccessor-and$archiveFailureModel.Created.Count-eq2) "archive-failure retry repeated creation or activated a different successor"
    Assert($archiveFailureModel.Archived.Count-eq1-and$archiveFailureModel.Archived[0]-ceq$failurePredecessor-and$failureIntent.State-ceq"activated") "archive-failure retry did not close the exact predecessor intent"

    $archiveUnknownModel=New-Model;[void](New-HubRequest $archiveUnknownModel "R5" "archive unknown" @("modify"));$unknownArchivePredecessor=Confirm-HubRequest $archiveUnknownModel "R5"
    Assert(-not(Continue-ExecutionTask $archiveUnknownModel "R5" $true 4 "created_gated" "unknown")) "unknown predecessor archive activated the successor"
    $unknownArchiveIntent=$archiveUnknownModel.RotationIntents["R5"];$unknownArchiveSuccessor=$unknownArchiveIntent.SuccessorThreadId
    Assert($archiveUnknownModel.Active.ThreadId-ceq$unknownArchivePredecessor-and$archiveUnknownModel.NativeCreateAttempts-eq1-and$archiveUnknownModel.NativeArchiveAttempts-eq1-and$archiveUnknownModel.Archived.Count-eq0) "unknown archive changed identity, repeated creation, or archived the predecessor"
    Assert(-not(($archiveUnknownModel.ExecutionActions-join",").Contains("$unknownArchivePredecessor`:continued-archived"))) "unknown archive marked the predecessor continued_archived"
    Assert(Continue-ExecutionTask $archiveUnknownModel "R5" $true 5 "unknown" "success") "unknown-archive retry did not recover the exact gated successor"
    Assert($archiveUnknownModel.NativeCreateAttempts-eq1-and$archiveUnknownModel.NativeArchiveAttempts-eq2-and$archiveUnknownModel.Active.ThreadId-ceq$unknownArchiveSuccessor-and$archiveUnknownModel.Created.Count-eq2) "unknown-archive retry repeated creation or changed successor identity"
    Assert($archiveUnknownModel.Archived.Count-eq1-and$archiveUnknownModel.Archived[0]-ceq$unknownArchivePredecessor-and$unknownArchiveIntent.State-ceq"activated") "unknown-archive retry did not close the exact predecessor intent"

    $creationUnknownModel=New-Model;[void](New-HubRequest $creationUnknownModel "R6" "creation unknown" @("modify"));$creationUnknownPredecessor=Confirm-HubRequest $creationUnknownModel "R6"
    Assert(-not(Continue-ExecutionTask $creationUnknownModel "R6" $true 4 "unknown" "success")) "unknown successor creation archived the predecessor or activated a successor"
    $creationUnknownIntent=$creationUnknownModel.RotationIntents["R6"];$intendedSuccessor=$creationUnknownIntent.SuccessorThreadId
    Assert($creationUnknownIntent.State-ceq"creation_unknown"-and$creationUnknownIntent.PredecessorThreadId-ceq$creationUnknownPredecessor-and$creationUnknownModel.Active.ThreadId-ceq$creationUnknownPredecessor) "unknown creation did not retain the durable intent and original identity"
    Assert($creationUnknownModel.NativeCreateAttempts-eq1-and$creationUnknownModel.NativeArchiveAttempts-eq0-and$creationUnknownModel.Created.Count-eq1-and$creationUnknownModel.Archived.Count-eq0) "unknown creation fabricated a created successor or attempted predecessor archive"
    Assert(-not(Continue-ExecutionTask $creationUnknownModel "R6" $true 5 "created_gated" "success")) "unknown creation retry repeated create or skipped exact recovery"
    Assert($creationUnknownModel.NativeCreateAttempts-eq1-and$creationUnknownModel.NativeArchiveAttempts-eq0-and$creationUnknownModel.Created.Count-eq1-and$creationUnknownModel.Active.ThreadId-ceq$creationUnknownPredecessor) "unknown creation retry changed identity or repeated a native call"
    Assert(-not(Resolve-UnknownSuccessor $creationUnknownModel "R6" "task-R6-wrong" "success")) "unknown creation accepted a non-matching successor identity"
    Assert(Resolve-UnknownSuccessor $creationUnknownModel "R6" $intendedSuccessor "success") "unknown creation did not recover the exact intended successor"
    Assert($creationUnknownModel.NativeCreateAttempts-eq1-and$creationUnknownModel.NativeArchiveAttempts-eq1-and$creationUnknownModel.Created.Count-eq2-and$creationUnknownModel.Active.ThreadId-ceq$intendedSuccessor) "exact unknown-create recovery repeated creation or activated a different successor"
    Assert($creationUnknownModel.Archived.Count-eq1-and$creationUnknownModel.Archived[0]-ceq$creationUnknownPredecessor-and$creationUnknownIntent.State-ceq"activated") "exact unknown-create recovery did not close the predecessor intent"

    $memoryFailureModel=New-Model;[void](New-HubRequest $memoryFailureModel "R7" "memory ordering" @("inspect"));$memoryFailureThread=Confirm-HubRequest $memoryFailureModel "R7"
    Assert(Complete-Round $memoryFailureModel "R7" $completion) "memory-ordering completion failed"
    Assert(-not(Self-ArchiveAccepted $memoryFailureModel "R7" ([ordered]@{success=$true;archivedTaskId=$memoryFailureThread}) "" "not accepted" $false "success")) "non-acceptance triggered memory sync or archive"
    Assert($memoryFailureModel.StateOnlySyncs-eq0-and$memoryFailureModel.AcceptanceMemory.Count-eq0-and$memoryFailureModel.AcceptanceArchiveAttempts-eq0-and$memoryFailureModel.Archived.Count-eq0) "non-acceptance changed acceptance state"
    Assert(-not(Self-ArchiveAccepted $memoryFailureModel "R7" ([ordered]@{success=$true;archivedTaskId=$memoryFailureThread}) "" "接受" $true "failure")) "memory failure proceeded to archive"
    Assert($memoryFailureModel.Active.State-ceq"awaiting_acceptance"-and$memoryFailureModel.StateOnlySyncs-eq0-and$memoryFailureModel.AcceptanceMemory.Count-eq0-and$memoryFailureModel.AcceptanceArchiveAttempts-eq0-and$memoryFailureModel.Archived.Count-eq0) "memory failure wrote acceptance state or attempted archive"
    Assert(Self-ArchiveAccepted $memoryFailureModel "R7" ([ordered]@{success=$true;archivedTaskId=$memoryFailureThread}) "" "接受" $true "success") "memory-ordering retry did not sync then archive"
    Assert($memoryFailureModel.StateOnlySyncs-eq1-and$memoryFailureModel.AcceptanceArchiveAttempts-eq1-and$memoryFailureModel.Archived.Count-eq1) "successful memory retry did not precede exactly one archive attempt"

    $stateOnlyModel=New-Model;[void](New-HubRequest $stateOnlyModel "R3" "standalone" @("inspect"));$stateOnlyThread=Confirm-HubRequest $stateOnlyModel "R3"
    Assert(Complete-Round $stateOnlyModel "R3" $completion) "standalone completion failed"
    Assert(-not(Self-ArchiveAccepted $stateOnlyModel "R3" $null "" "接受")) "unknown state-only archive ended request"
    Assert($stateOnlyModel.Active.State-ceq"awaiting_acceptance"-and$stateOnlyModel.StateOnlySyncs-eq1-and$stateOnlyModel.AcceptanceArchiveAttempts-eq1-and$stateOnlyModel.Archived.Count-eq0) "unknown state-only archive did not preserve one synced receipt"
    Assert(Self-ArchiveAccepted $stateOnlyModel "R3" ([ordered]@{success=$true;archivedTaskId=$stateOnlyThread}) "" "接受") "state-only request archival failed"
    Assert($stateOnlyModel.StateOnlySyncs-eq1-and$stateOnlyModel.AcceptedSteps.Count-eq0-and$stateOnlyModel.AcceptanceArchiveAttempts-eq2-and$stateOnlyModel.Created.Count-eq1) "unmapped standalone request repeated its receipt, guessed a plan step, or created a successor"

    $queuedModel=New-Model;[void](New-HubRequest $queuedModel "Q1" "queued" @("inspect"));$queuedId=Confirm-HubRequest $queuedModel "Q1" "queued";$queuedHubActions=$queuedModel.HubActions.Count
    Assert($queuedId-ceq"client-Q1-g1"-and$queuedModel.Created.Count-eq1) "queued identity was not created once"
    Assert(Activate-QueuedIdentity $queuedModel "Q1" "task-Q1-g1") "queued identity did not resolve inside execution ownership"
    Assert($queuedModel.HubActions.Count-eq$queuedHubActions-and$queuedModel.Created.Count-eq1) "queued handoff returned to hub or created twice"

    $upgradeModel=New-Model;[void](New-HubRequest $upgradeModel "U1" "upgrade" @("plan","apply"));$upgradeTask=Confirm-HubRequest $upgradeModel "U1"
    $createdBefore=$upgradeModel.Created.Count;$archivedBefore=$upgradeModel.Archived.Count;$transactionsBefore=$upgradeModel.FileTransactions
    $snapshot=@([ordered]@{threadId="existing-task";state="active"})
    Assert(-not(Start-UpgradeFileTransaction $upgradeModel $snapshot)) "non-empty active snapshot started a file transaction"
    Assert($upgradeModel.FileTransactions-eq$transactionsBefore) "non-empty active snapshot mutated transaction state"
    Assert($upgradeModel.Archived.Count-eq$archivedBefore) "non-empty active snapshot archived an existing task"
    Assert($upgradeModel.Created.Count-eq$createdBefore-and$upgradeModel.Active.ThreadId-ceq$upgradeTask) "non-empty active snapshot created a second task or replaced the upgrade task"
    Assert(Start-UpgradeFileTransaction $upgradeModel @()) "empty active snapshot did not permit the file transaction"
    Assert($upgradeModel.FileTransactions-eq1-and$upgradeModel.Created.Count-eq1-and$upgradeModel.Archived.Count-eq0) "empty-snapshot transaction changed task lifecycle"
    Write-Host "Five-slot scheduling, hub handoff, request authorization, and self-archive tests passed."
