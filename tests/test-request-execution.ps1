[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$workflow = Get-Content -Raw -Encoding UTF8 (Join-Path $repo ".agents/workflow.json") | ConvertFrom-Json
$utf8 = [Text.UTF8Encoding]::new($false)
$temp = Join-Path ([IO.Path]::GetTempPath()) ("codex-project-flow-request-test-" + [guid]::NewGuid().ToString("N"))

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-ContentSha256([string]$Content) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { "sha256:" + ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Content))).Replace("-", "").ToLowerInvariant()) }
    finally { $sha.Dispose() }
}
function New-Model {
    [ordered]@{
        Requests=@{}; Active=$null
        Created=[Collections.Generic.List[string]]::new()
        Archived=[Collections.Generic.List[string]]::new()
        HubActions=[Collections.Generic.List[string]]::new()
        ExecutionActions=[Collections.Generic.List[string]]::new()
        Documents=@{}
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
    if ($request.State -cne "awaiting_authorization" -or $null -ne $request.ThreadId) { return $null }
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
function Self-ArchiveAccepted($Model,[string]$RequestId,$ArchiveResult) {
    if($null-eq$Model.Active-or$Model.Active.RequestId-cne$RequestId-or$Model.Active.State-cne"awaiting_acceptance"){return $false}
    $threadId=$Model.Active.ThreadId
    if($null-eq$ArchiveResult-or$ArchiveResult.success-ne$true-or[string]$ArchiveResult.archivedTaskId-cne$threadId){return $false}
    $Model.Archived.Add($threadId);$Model.Active.State="accepted_archived";$Model.ExecutionActions.Add("$threadId`:self-archived");$Model.Active=$null;$true
}
function Submit-DocumentDraft($Model,[string]$RequestId,[string]$Path,[string]$Content) {
    if($null-eq$Model.Active-or$Model.Active.RequestId-cne$RequestId-or[IO.Path]::GetExtension($Path)-cne".md"){return $null}
    $record=[ordered]@{Path=$Path;Content=$Content;ContentSha256=(Get-ContentSha256 $Content);State="draft_pending_review";History=@("draft_pending_review");ApprovedPath=$null;ApprovedSha256=$null}
    $Model.Documents[$Path]=$record;$Model.ExecutionActions.Add("$($Model.Active.ThreadId):document-draft:$Path");$record
}
function Approve-DocumentDraft($Model,[string]$Path,[string]$ContentSha256,[bool]$ExplicitUserApproval) {
    if(-not$ExplicitUserApproval-or-not$Model.Documents.ContainsKey($Path)){return $false}
    $record=$Model.Documents[$Path]
    if($record.State-cne"draft_pending_review"-or$record.Path-cne$Path-or$record.ContentSha256-cne$ContentSha256){return $false}
    $record.State="approved_for_write";$record.History=@($record.History)+"approved_for_write";$record.ApprovedPath=$Path;$record.ApprovedSha256=$ContentSha256;$true
}
function Reject-And-ReviseDocument($Model,[string]$Path,[string]$RevisedContent) {
    if(-not$Model.Documents.ContainsKey($Path)){return $null};$record=$Model.Documents[$Path]
    $record.State="revision_required";$record.History=@($record.History)+"revision_required";$record.Content=$RevisedContent;$record.ContentSha256=Get-ContentSha256 $RevisedContent
    $record.ApprovedPath=$null;$record.ApprovedSha256=$null;$record.State="draft_pending_review";$record.History=@($record.History)+"draft_pending_review"
    $Model.ExecutionActions.Add("$($Model.Active.ThreadId):document-revised:$Path");$record
}
function Write-ApprovedDocument($Model,[string]$Path,[string]$ContentSha256,[string]$Root) {
    if(-not$Model.Documents.ContainsKey($Path)){return $false};$record=$Model.Documents[$Path]
    if($record.State-cne"approved_for_write"-or$record.ApprovedPath-cne$Path-or$record.ApprovedSha256-cne$ContentSha256-or$record.ContentSha256-cne$ContentSha256){return $false}
    $target=Join-Path $Root $Path;$directory=Split-Path -Parent $target
    if(-not(Test-Path -LiteralPath $directory)){[IO.Directory]::CreateDirectory($directory)|Out-Null}
    [IO.File]::WriteAllText($target,$record.Content,$utf8);$record.State="written";$record.History=@($record.History)+"written"
    $Model.ExecutionActions.Add("$($Model.Active.ThreadId):document-written:$Path");$true
}
function Start-UpgradeFileTransaction($Model,[object[]]$ActiveSnapshot) {
    if(@($ActiveSnapshot).Count-ne0){$Model.ExecutionActions.Add("$($Model.Active.ThreadId):upgrade-blocked-nonempty-snapshot");return $false}
    $Model.FileTransactions=[int]$Model.FileTransactions+1;$Model.ExecutionActions.Add("$($Model.Active.ThreadId):upgrade-file-transaction");$true
}

try {
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    Assert($workflow.schema_version-eq10) "request model requires schema 10"
    Assert($workflow.tasks.max_active-eq1) "visible execution limit must be one"
    Assert($workflow.requests.initial_owner-ceq"hub") "hub must own only the initial phase"
    Assert($workflow.requests.handoff_boundary-ceq"exact_or_queued_execution_task_identity_established") "handoff boundary mismatch"
    Assert($workflow.requests.post_handoff_owner-ceq"execution_task") "execution task must own post-handoff lifecycle"
    Assert($workflow.requests.hub_post_handoff-ceq"no_participation_for_same_request") "hub post-handoff participation must be forbidden"
    Assert($workflow.requests.acceptance_owner-ceq"execution_task") "execution task must own acceptance"
    Assert($workflow.requests.acceptance_archive-ceq"exact_self_archive_success_and_matching_archived_task_id_required") "self-archive contract mismatch"
    Assert($workflow.requests.rejection_route-ceq"execution_task_reconfirm_in_place") "rejection route mismatch"
    Assert($workflow.requests.scope_change_route-ceq"execution_task_reconfirm_in_place") "scope-change route mismatch"
    Assert($workflow.documents.review.required) "document review must be required"
    Assert((@($workflow.documents.review.states)-join",")-ceq"draft_pending_review,approved_for_write,revision_required,written") "document review states mismatch"
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

    $documentPath="docs/output.md";$draft=Submit-DocumentDraft $model "R1" $documentPath "# Draft one`n";$target=Join-Path $temp $documentPath
    Assert(-not(Write-ApprovedDocument $model $documentPath $draft.ContentSha256 $temp)) "unapproved Markdown was written"
    Assert(-not(Test-Path -LiteralPath $target)) "unapproved Markdown target exists"
    Assert(-not(Approve-DocumentDraft $model "docs/wrong.md" $draft.ContentSha256 $true)) "wrong-path approval was accepted"
    Assert(-not(Approve-DocumentDraft $model $documentPath (Get-ContentSha256 "wrong") $true)) "wrong-hash approval was accepted"
    Assert(-not(Approve-DocumentDraft $model $documentPath $draft.ContentSha256 $false)) "non-user approval was accepted"
    Assert(Approve-DocumentDraft $model $documentPath $draft.ContentSha256 $true) "exact document approval failed"
    $oldHash=$draft.ContentSha256;$revised=Reject-And-ReviseDocument $model $documentPath "# Draft two`n"
    Assert($revised.ContentSha256-cne$oldHash-and$revised.State-ceq"draft_pending_review") "revision did not invalidate old approval"
    Assert(-not(Write-ApprovedDocument $model $documentPath $oldHash $temp)) "old approval authorized revised content"
    Assert(-not(Test-Path -LiteralPath $target)) "revised unapproved Markdown target exists"
    Assert(Approve-DocumentDraft $model $documentPath $revised.ContentSha256 $true) "revised draft approval failed"
    Assert(Write-ApprovedDocument $model $documentPath $revised.ContentSha256 $temp) "approved exact Markdown was not written"
    Assert((Get-Content -Raw -Encoding UTF8 $target)-ceq"# Draft two`n") "written Markdown differs from approved content"
    Assert((@($revised.History)-join",")-ceq"draft_pending_review,approved_for_write,revision_required,draft_pending_review,approved_for_write,written") "document did not traverse all four review states"
    $writtenHash=$revised.ContentSha256;$postWriteRevision=Reject-And-ReviseDocument $model $documentPath "# Draft three`n"
    Assert($postWriteRevision.State-ceq"draft_pending_review"-and$postWriteRevision.ContentSha256-cne$writtenHash) "post-write change did not return to draft review"
    Assert(-not(Write-ApprovedDocument $model $documentPath $writtenHash $temp)) "post-write change reused stale approval"
    Assert((Get-Content -Raw -Encoding UTF8 $target)-ceq"# Draft two`n") "unapproved post-write change modified Markdown"
    Assert($model.HubActions.Count-eq$hubActionsAfterHandoff-and$model.Created.Count-eq1) "document review involved the hub or created a second task"

    $completion=[ordered]@{changes=@("changed");verification=@("passed");uncovered=@("none");risk=@("low")}
    Assert(-not(Complete-Round $model "R1" ([ordered]@{verification=@("passed");changes=@("changed");uncovered=@("none");risk=@("low")}))) "out-of-order completion was accepted"
    Assert(Complete-Round $model "R1" $completion) "valid completion failed"
    Assert(Request-InPlaceConfirmation $model "R1" "address rejection" @("modify","test") "completion-rejected") "completion rejection did not stay in execution task"
    Assert(Confirm-InPlace $model "R1") "rejection reconfirmation failed"
    Assert($model.Active.ThreadId-ceq$threadId-and$model.Active.Generation-eq1-and$model.Created.Count-eq1) "completion rejection changed task identity"
    Assert(Complete-Round $model "R1" $completion) "revised completion failed"
    Assert($model.HubActions.Count-eq$hubActionsAfterHandoff) "completion or rejection returned to hub"

    Assert(-not(Self-ArchiveAccepted $model "R1" ([ordered]@{success=$true;archivedTaskId="task-wrong-g1"}))) "wrong self-archive task ID ended request"
    Assert($model.Active.State-ceq"awaiting_acceptance"-and$model.Archived.Count-eq0) "wrong self-archive result released the slot"
    Assert(-not(Self-ArchiveAccepted $model "R1" ([ordered]@{success=$false;archivedTaskId=$threadId}))) "failed self-archive ended request"
    Assert(-not(Self-ArchiveAccepted $model "R1" $null)) "uncertain self-archive ended request"
    Assert($model.Active.State-ceq"awaiting_acceptance"-and$model.Created.Count-eq1) "failed self-archive changed lifecycle"
    Assert(Self-ArchiveAccepted $model "R1" ([ordered]@{success=$true;archivedTaskId=$threadId})) "exact self-archive failed"
    Assert($model.Requests["R1"].State-ceq"accepted_archived"-and$model.Archived.Count-eq1-and$model.Archived[0]-ceq$threadId) "request did not end on exact self-archive"
    Assert($model.HubActions.Count-eq$hubActionsAfterHandoff) "acceptance or archival involved the hub"

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
    Write-Host "Hub handoff, execution-task lifecycle, exact self-archive, and Markdown review tests passed."
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }
