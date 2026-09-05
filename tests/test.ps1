[CmdletBinding()]
param()
$ErrorActionPreference="Stop"
$repo=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$temp=Join-Path ([IO.Path]::GetTempPath()) ("codex-project-flow-tests-"+[guid]::NewGuid().ToString("N"))
$utf8=[Text.UTF8Encoding]::new($false)
function Assert([bool]$c,[string]$m){if(-not $c){throw $m}}
function Text([string]$p){(Get-Content -Raw -Encoding UTF8 -LiteralPath $p).Replace(([char]13).ToString()+[char]10,([char]10).ToString()).Replace(([char]13).ToString(),([char]10).ToString())}
function HashText([string]$v){$h=[Security.Cryptography.SHA256]::Create();try{"sha256:"+([BitConverter]::ToString($h.ComputeHash($utf8.GetBytes($v)))).Replace("-","").ToLowerInvariant()}finally{$h.Dispose()}}
function Render([string]$v,[string]$m,[string]$n){if($m -eq "project_name"){return $v.Replace("<PROJECT_NAME>",$n)};if($m -eq "project_name_json"){return $v.Replace('"<PROJECT_NAME>"',(ConvertTo-Json $n -Compress))};$v}
function WriteUtf8([string]$p,[string]$v){$d=Split-Path -Parent $p;if(-not (Test-Path $d)){[IO.Directory]::CreateDirectory($d)|Out-Null};[IO.File]::WriteAllText($p,$v,$utf8)}
function TreeHashes([string]$r){$m=@{};Get-ChildItem $r -Recurse -File|Where-Object{$_.FullName-notmatch'[\\/].project-flow[\\/]transactions[\\/]'-and$_.FullName-notmatch'[\\/].project-flow[\\/]transaction\.lock$'}|ForEach-Object{$k=$_.FullName.Substring($r.Length).TrimStart('\').Replace('\','/');$m[$k]=(Get-FileHash -Algorithm SHA256 $_.FullName).Hash};$m}
function SameMap($a,$b){if($a.Count -ne $b.Count){return $false};foreach($k in $a.Keys){if(-not $b.ContainsKey($k) -or $a[$k] -cne $b[$k]){return $false}};$true}
$managed=Get-Content -Raw -Encoding UTF8 (Join-Path $repo managed-files.json)|ConvertFrom-Json
$currentVersion=[string]$managed.workflow_version
$currentPaths=@($managed.files.path)
$engine=Join-Path $repo scripts/project-flow.ps1
function New-Fixture([string]$version,[string]$name,[switch]$NoManifest){
 $root=Join-Path $temp ($name+"-"+[guid]::NewGuid().ToString("N"));[IO.Directory]::CreateDirectory($root)|Out-Null
 $baseline=Get-Content -Raw -Encoding UTF8 (Join-Path $repo "baselines/$version/managed-files.json")|ConvertFrom-Json
 $items=@($baseline.files)
 foreach($e in $items){$src=Join-Path $repo "baselines/$version/$($e.path)";Assert (Test-Path $src -PathType Leaf) "missing baseline $version $($e.path)";$dst=Join-Path $root $e.path;WriteUtf8 $dst (Render (Text $src) $e.render $name)}
 if(-not $NoManifest){$records=@();foreach($e in $items){$base=Text (Join-Path $repo "baselines/$version/$($e.path)");$records+=[ordered]@{path=$e.path;source=$e.source;policy=$e.policy;baseline_hash=HashText (Render $base $e.render $name)}};$manifest=[ordered]@{schema_version=1;workflow_version=$version;project_name=$name;installed_at_utc="2026-01-01T00:00:00Z";last_transaction=$null;files=$records};WriteUtf8 (Join-Path $root ".project-flow/manifest.json") (($manifest|ConvertTo-Json -Depth 20)+[char]10)}
 $root
}
function Invoke-ApplyRace([string]$root,[ValidateSet("live","manifest")][string]$kind){
 $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 foreach($argument in @("-NoLogo","-NoProfile","-NonInteractive","-File",$engine,"apply","-Target",$root)){[void]$psi.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::new();$process.StartInfo=$psi;[void]$process.Start();$changed=$false;$output=[Collections.Generic.List[string]]::new()
 while(-not $process.StandardOutput.EndOfStream){$line=$process.StandardOutput.ReadLine();$output.Add($line);if(-not$changed-and$line.StartsWith("TARGET ")){if($kind-eq"live"){$path=Join-Path $root "AGENTS.md";WriteUtf8 $path ((Text $path)+"RACE-LIVE"+[char]10)}else{$path=Join-Path $root ".project-flow/manifest.json";WriteUtf8 $path ((Text $path)+[char]10)};$changed=$true}}
 $errorText=$process.StandardError.ReadToEnd();$process.WaitForExit();[pscustomobject]@{Changed=$changed;ExitCode=$process.ExitCode;Output=($output-join[char]10);Error=$errorText}
}
function Invoke-BackupRace([string]$root){
 $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 foreach($argument in @("-NoLogo","-NoProfile","-NonInteractive","-File",$engine,"apply","-Target",$root)){[void]$psi.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::new();$process.StartInfo=$psi;[void]$process.Start();$changed=$false
 while(-not $process.HasExited){if(-not$changed){$transactionRoot=Join-Path $root ".project-flow/transactions";$backup=if(Test-Path $transactionRoot){Get-ChildItem -LiteralPath $transactionRoot -Recurse -File -Filter "AGENTS.md" -ErrorAction SilentlyContinue|Select-Object -First 1}else{$null};if($null-ne$backup){$path=Join-Path $root "AGENTS.md";WriteUtf8 $path ((Text $path)+"RACE-AFTER-BACKUP"+[char]10);$changed=$true}};Start-Sleep -Milliseconds 1}
 $output=$process.StandardOutput.ReadToEnd();$errorText=$process.StandardError.ReadToEnd();$process.WaitForExit();[pscustomobject]@{Changed=$changed;ExitCode=$process.ExitCode;Output=$output;Error=$errorText}
}
function Start-ApplyProcess([string]$root){
 $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 foreach($argument in @("-NoLogo","-NoProfile","-NonInteractive","-File",$engine,"apply","-Target",$root)){[void]$psi.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::new();$process.StartInfo=$psi;[void]$process.Start();$process
}
function Invoke-RollbackMetadataRace([string]$root,[string]$transaction){
 $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 foreach($argument in @("-NoLogo","-NoProfile","-NonInteractive","-File",$engine,"rollback","-Target",$root,"-Rollback",$transaction)){[void]$psi.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::new();$process.StartInfo=$psi;[void]$process.Start();$changed=$false;$output=[Collections.Generic.List[string]]::new();$metadata=Join-Path $root ".project-flow/transactions/$transaction/transaction.json"
 while(-not $process.StandardOutput.EndOfStream){$line=$process.StandardOutput.ReadLine();$output.Add($line);if(-not$changed-and$line.StartsWith("ROLLBACK PREFLIGHT ")){WriteUtf8 $metadata ((Text $metadata)+[char]10);$changed=$true}}
 $errorText=$process.StandardError.ReadToEnd();$process.WaitForExit();[pscustomobject]@{Changed=$changed;ExitCode=$process.ExitCode;Output=($output-join[char]10);Error=$errorText}
}
try{
 [IO.Directory]::CreateDirectory($temp)|Out-Null
 foreach($s in @("project-flow.ps1","install.ps1","upgrade.ps1","validate.ps1")){[void][scriptblock]::Create((Get-Content -Raw -Encoding UTF8 (Join-Path $repo "scripts/$s")))}
 & $engine validate -Target $repo -AllowPlaceholders;$ok=$?;Assert $ok "engine source validation"
 cmd /c exit 37;Assert($LASTEXITCODE-eq37)"failed to preset LASTEXITCODE"
 & $engine validate -Target $repo -AllowPlaceholders;$ok=$?;Assert $ok "validation read stale LASTEXITCODE";Assert($LASTEXITCODE-eq0)"validation exit code"
 & (Join-Path $repo scripts/validate.ps1) -Target $repo -AllowPlaceholders;$ok=$?;Assert $ok "validate wrapper smoke"
 & (Join-Path $repo scripts/validate.ps1) -Target (Join-Path $temp missing) 2>$null;$ok=$?;Assert(-not $ok)"validate wrapper failure exit";Assert($LASTEXITCODE-eq1)"validate wrapper failure code"
 $clean=Join-Path $temp clean;[IO.Directory]::CreateDirectory($clean)|Out-Null
 & $engine install -Target $clean -ProjectName Clean;$ok=$?;Assert $ok "clean install"
 $probe=& $engine probe -Target $clean|ConvertFrom-Json;Assert($probe.managed-and$probe.workflow_version-ceq$currentVersion-and$probe.managed_files-eq6)"managed probe"
 $cleanLock=Join-Path $clean ".project-flow/transaction.lock";Remove-Item -LiteralPath $cleanLock -Force
 & $engine validate -Target $clean;$ok=$?;Assert $ok "clean validation";Assert(-not(Test-Path $cleanLock))"validation created transaction lock"
 & $engine upgrade -Target $clean -Apply -AcceptLocal ("bad"+[char]9+"path") 2>$null;$ok=$?;Assert(-not $ok)"upgrade accepted control character path"
 cmd /c exit 41;Assert($LASTEXITCODE-eq41)"failed to preset NOOP LASTEXITCODE"
 & $engine upgrade -Target $clean -Apply;$ok=$?;Assert $ok "NOOP upgrade read stale LASTEXITCODE";Assert($LASTEXITCODE-eq0)"NOOP upgrade exit code"
 $cm=Get-Content -Raw -Encoding UTF8 (Join-Path $clean .project-flow/manifest.json)|ConvertFrom-Json
 Assert($cm.workflow_version-ceq$currentVersion)"clean version";Assert(@($cm.files).Count-eq6)"managed count"
 foreach($x in @(".agents/prompts/08_result_handoff.md",".agents/snippets/AGENTS.integration.md","docs/WORKFLOW_GUIDE.md","docs/DEVELOPMENT_SOP.md")){Assert (-not (Test-Path (Join-Path $clean $x))) "clean retired file"}
 $bounded=Join-Path $temp bounded;[IO.Directory]::CreateDirectory((Join-Path $bounded "docs/unrelated"))|Out-Null;WriteUtf8 (Join-Path $bounded "docs/unrelated/conflict.md") "任务管理不可用时回到中枢"
 $probe=& $engine probe -Target $bounded|ConvertFrom-Json;Assert(-not$probe.managed)"unmanaged probe"
 & $engine install -Target $bounded -ProjectName Bounded;$ok=$?;Assert $ok "bounded install scanned unrelated project docs"
 & $engine validate -Target $bounded -Runtime;$ok=$?;Assert $ok "bounded runtime validation scanned unrelated project docs"
 & $engine apply -Target $bounded;$ok=$?;Assert $ok "bounded NOOP scanned unrelated project docs"
 & $engine validate -Target $bounded 2>$null;$ok=$?;Assert(-not$ok)"package audit ignored conflicting project docs"
 $unsafe=Join-Path $temp unsafe-reparse;& $engine install -Target ([IO.Directory]::CreateDirectory($unsafe).FullName) -ProjectName Unsafe;$ok=$?;Assert $ok "unsafe fixture install"
 $unsafeAgents=Join-Path $unsafe ".agents";$outsideAgents=Join-Path $temp "unsafe-reparse-target";Move-Item -LiteralPath $unsafeAgents -Destination $outsideAgents
 try{
  $junction=New-Item -ItemType Junction -Path $unsafeAgents -Target $outsideAgents -Force
  Assert((($junction.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0))"junction fixture is not a reparse point"
  & $engine validate -Target $unsafe -Runtime 2>$null;$ok=$?;Assert(-not$ok)"runtime validation accepted a managed path through a junction"
 }finally{if(Test-Path -LiteralPath $unsafeAgents){Remove-Item -LiteralPath $unsafeAgents -Force};Move-Item -LiteralPath $outsideAgents -Destination $unsafeAgents}
 $wp=Join-Path $clean .agents/workflow.json;$original=Text $wp;WriteUtf8 $wp ($original.Replace('"max_active": 1','"max_active": 2'))
 & $engine validate -Target $clean 2>$null;$ok=$?;Assert (-not $ok) "validator accepted multiple visible tasks";WriteUtf8 $wp $original
 $cleanManifest=Join-Path $clean .project-flow/manifest.json;$savedManifest=Join-Path $temp clean-manifest.json;Move-Item -LiteralPath $cleanManifest -Destination $savedManifest
 $contractCases=@(
  [pscustomobject]@{Name="transaction role";Expected="transaction-task-role";Mutate={param($v)$v.upgrade.transaction_task_role="coordinator_only"}},
  [pscustomobject]@{Name="upgrade post-handoff owner";Expected="upgrade-post-handoff-owner";Mutate={param($v)$v.upgrade.post_handoff_owner="hub"}},
  [pscustomobject]@{Name="upgrade barrier owner";Expected="upgrade-barrier-owner";Mutate={param($v)$v.upgrade.barrier_owner="hub"}},
  [pscustomobject]@{Name="zero-active fast path";Expected="zero-active-fast-path";Mutate={param($v)$v.upgrade.zero_active_fast_path=$false}},
  [pscustomobject]@{Name="discovery listing";Expected="discovery-listing";Mutate={param($v)$v.upgrade.discovery.listing="full_history"}},
  [pscustomobject]@{Name="discovery history";Expected="discovery-history";Mutate={param($v)$v.upgrade.discovery.history="exhaustive"}},
  [pscustomobject]@{Name="discovery fallback";Expected="discovery-fallback";Mutate={param($v)$v.upgrade.discovery.fallback="never"}},
  [pscustomobject]@{Name="request identity";Expected="request-key";Mutate={param($v)$v.tasks.request_key=$v.tasks.request_key.Replace("requestId=<exactRequestId>; ","")}},
  [pscustomobject]@{Name="request ID timing";Expected="request-id-assignment";Mutate={param($v)$v.requests.request_id_assignment="after_task_creation"}},
  [pscustomobject]@{Name="request initial owner";Expected="request-initial-owner";Mutate={param($v)$v.requests.initial_owner="execution_task"}},
  [pscustomobject]@{Name="request handoff boundary";Expected="request-handoff-boundary";Mutate={param($v)$v.requests.handoff_boundary="after_completion"}},
  [pscustomobject]@{Name="request post-handoff owner";Expected="request-post-handoff-owner";Mutate={param($v)$v.requests.post_handoff_owner="hub"}},
  [pscustomobject]@{Name="hub post-handoff";Expected="request-hub-post-handoff";Mutate={param($v)$v.requests.hub_post_handoff="route_messages"}},
  [pscustomobject]@{Name="request acceptance owner";Expected="request-acceptance-owner";Mutate={param($v)$v.requests.acceptance_owner="coordinator"}},
  [pscustomobject]@{Name="request rejection route";Expected="request-rejection-route";Mutate={param($v)$v.requests.rejection_route="create_new_task"}},
  [pscustomobject]@{Name="request scope-change route";Expected="request-scope-change-route";Mutate={param($v)$v.requests.scope_change_route="return_to_hub"}},
  [pscustomobject]@{Name="request acceptance slot";Expected="request-acceptance-slot";Mutate={param($v)$v.requests.awaiting_acceptance_occupies_slot=$false}},
  [pscustomobject]@{Name="supplemental authorization";Expected="supplemental-authorization";Mutate={param($v)$v.execution.supplemental_authorization="create_new_task"}},
  [pscustomobject]@{Name="different goal";Expected="different-goal";Mutate={param($v)$v.execution.different_goal="parallel"}},
  [pscustomobject]@{Name="scope continuation";Expected="scope-change";Mutate={param($v)$v.execution.scope_change="create_successor"}},
  [pscustomobject]@{Name="replacement authorization";Expected="replacement";Mutate={param($v)$v.execution.replacement="automatic"}},
  [pscustomobject]@{Name="visible execution serialization";Expected="execution-serial";Mutate={param($v)$v.execution.serial=@("high_risk")}},
  [pscustomobject]@{Name="Markdown extension";Expected="document-extension";Mutate={param($v)$v.documents.default_extension=".docx"}},
  [pscustomobject]@{Name="document review required";Expected="document-review-required";Mutate={param($v)$v.documents.review.required=$false}},
  [pscustomobject]@{Name="document approval evidence";Expected="document-review-evidence";Mutate={param($v)$v.documents.review.approval_evidence="chat_approval_without_binding"}},
  [pscustomobject]@{Name="rotation authorization";Expected="rotation-mode";Mutate={param($v)$v.rotation.mode="automatic"}},
  [pscustomobject]@{Name="reconcile authorization";Expected="reconcile-active-snapshot";Mutate={param($v)$v.upgrade.reconcile.active_snapshot="automatic"}},
  [pscustomobject]@{Name="retired reconcile successor";Expected="reconcile-fields";Mutate={param($v)$v.upgrade.reconcile|Add-Member -NotePropertyName successor_creation -NotePropertyValue "parallel"}},
  [pscustomobject]@{Name="retired reconcile pair order";Expected="reconcile-fields";Mutate={param($v)$v.upgrade.reconcile|Add-Member -NotePropertyName pair_order -NotePropertyValue @("archive_predecessor","queue_successor")}},
  [pscustomobject]@{Name="retired recovery container";Expected="upgrade-fields";Mutate={param($v)$v.upgrade|Add-Member -NotePropertyName recovery -NotePropertyValue ([pscustomobject]@{compensating_successors=1})}},
  [pscustomobject]@{Name="retired successor key";Expected="upgrade-fields";Mutate={param($v)$v.upgrade|Add-Member -NotePropertyName successor_key -NotePropertyValue "retired"}},
  [pscustomobject]@{Name="retired task handshake";Expected="upgrade-fields";Mutate={param($v)$v.upgrade|Add-Member -NotePropertyName task_handshake -NotePropertyValue "retired"}},
  [pscustomobject]@{Name="active barrier";Expected="active-barrier";Mutate={param($v)$v.upgrade.barrier.active=$v.upgrade.barrier.active.Replace("state=active","state=provisional")}}
 )
 foreach($case in $contractCases){$value=$original|ConvertFrom-Json;& $case.Mutate $value;WriteUtf8 $wp (($value|ConvertTo-Json -Depth 20)+[char]10);$validation=& $engine validate -Target $clean 2>&1|Out-String;$ok=$?;Assert(-not$ok)"validator accepted invalid $($case.Name)";Assert($validation.Contains($case.Expected))"validator did not report $($case.Name) contract"}
 WriteUtf8 $wp $original;Move-Item -LiteralPath $savedManifest -Destination $cleanManifest
 $failedInstall=Join-Path $temp failed-install;[IO.Directory]::CreateDirectory((Join-Path $failedInstall ".agents"))|Out-Null;$invalidWorkflow=Join-Path $failedInstall ".agents/workflow.json";WriteUtf8 $invalidWorkflow "{}"
 & $engine install -Target $failedInstall -ProjectName FailedInstall 2>$null;$ok=$?;Assert(-not $ok)"post-manifest validation failure unexpectedly succeeded";Assert(-not(Test-Path(Join-Path $failedInstall ".project-flow/manifest.json")))"failed install left manifest"
 foreach($path in @($currentPaths|Where-Object{$_-cne'.agents/workflow.json'})){Assert(-not(Test-Path(Join-Path $failedInstall $path)))"failed install left managed file $path"};Assert((Text $invalidWorkflow)-ceq"{}")"failed install changed preexisting invalid workflow"
 $versions=@(Get-ChildItem -LiteralPath (Join-Path $repo baselines) -Directory|Where-Object{$_.Name-match'^\d+\.\d+\.\d+$'}|Sort-Object{[version]$_.Name}|ForEach-Object Name)
 Assert(($versions-join',')-ceq'0.8.3,0.9.0,0.9.1,0.10.0')"unexpected retained baselines"
 foreach($version in $versions){
  $f=New-Fixture $version ("plan-"+$version.Replace(".","-"));$plan=& $engine plan -Target $f *>&1|Out-String
  $ok=$?;Assert $ok "$version plan";Assert($plan.Contains("UPGRADE $version -> $currentVersion"))"$version target"
  Assert(-not(Test-Path(Join-Path $f ".project-flow/transaction.lock")))"plan created transaction lock"
  $old=(Get-Content -Raw -Encoding UTF8 (Join-Path $repo "baselines/$version/managed-files.json")|ConvertFrom-Json).files.path
  foreach($x in @($old|Where-Object{$currentPaths-cnotcontains$_})){Assert ($plan.Contains($x)) "$version missing retirement $x"}
 }
 $unsupported=New-Fixture "0.8.3" unsupported;$unsupportedManifestPath=Join-Path $unsupported ".project-flow/manifest.json";$unsupportedManifest=Get-Content -Raw -Encoding UTF8 $unsupportedManifestPath|ConvertFrom-Json;$unsupportedManifest.workflow_version="0.8.2";WriteUtf8 $unsupportedManifestPath (($unsupportedManifest|ConvertTo-Json -Depth 20)+[char]10)
 $unsupportedError=& $engine plan -Target $unsupported 2>&1|Out-String;$ok=$?;Assert(-not$ok)"unsupported source version was accepted";Assert($unsupportedError.Contains("No supported migration from 0.8.2"))"unsupported source rejection reason missing"
 $liveRace=New-Fixture "0.8.3" live-race;$liveRaceManifest=Text(Join-Path $liveRace ".project-flow/manifest.json");$race=Invoke-ApplyRace $liveRace live;Assert $race.Changed "live race hook did not run";Assert($race.ExitCode-eq1)"live race apply exit";Assert((Text(Join-Path $liveRace "AGENTS.md")).Contains("RACE-LIVE"))"live race content was overwritten";Assert((Text(Join-Path $liveRace ".project-flow/manifest.json"))-ceq$liveRaceManifest)"live race changed manifest";Assert($race.Error.Contains("changed after planning"))"live race reason missing"
 $manifestRace=New-Fixture "0.8.3" manifest-race;$manifestRaceAgents=Text(Join-Path $manifestRace "AGENTS.md");$manifestBefore=Text(Join-Path $manifestRace ".project-flow/manifest.json");$race=Invoke-ApplyRace $manifestRace manifest;Assert $race.Changed "manifest race hook did not run";Assert($race.ExitCode-eq1)"manifest race apply exit";Assert((Text(Join-Path $manifestRace "AGENTS.md"))-ceq$manifestRaceAgents)"manifest race changed managed files";Assert((Text(Join-Path $manifestRace ".project-flow/manifest.json"))-ceq($manifestBefore+[char]10))"manifest race edit not preserved";Assert($race.Error.Contains("Manifest changed after planning"))"manifest race reason missing"
 $backupRace=New-Fixture "0.8.3" backup-race;$backupAgents=Join-Path $backupRace "AGENTS.md";WriteUtf8 $backupAgents ((Text $backupAgents)+("X"*8388608)+[char]10);$backupBefore=TreeHashes $backupRace;$race=Invoke-BackupRace $backupRace;Assert $race.Changed "backup race hook did not run";Assert($race.ExitCode-eq5)"backup race apply exit";Assert((Text $backupAgents).Contains("RACE-AFTER-BACKUP"))"backup race external edit was lost";$backupAfter=TreeHashes $backupRace;[void]$backupBefore.Remove("AGENTS.md");[void]$backupAfter.Remove("AGENTS.md");Assert(SameMap $backupBefore $backupAfter)"backup race polluted other project files";$transactionRoot=Join-Path $backupRace ".project-flow/transactions";Assert(@(Get-ChildItem -LiteralPath $transactionRoot -Directory -ErrorAction SilentlyContinue).Count-eq0)"backup race left transaction";$stagingRoot=Join-Path $backupRace ".project-flow/staging";Assert(@(Get-ChildItem -LiteralPath $stagingRoot -Directory -ErrorAction SilentlyContinue).Count-eq0)"backup race left staging";Assert($race.Error.Contains("Managed target changed") -and $race.Error.Contains("AGENTS.md"))("backup race reason missing: "+$race.Error)
 $concurrent=New-Fixture "0.8.3" concurrent;$concurrentAgents=Join-Path $concurrent "AGENTS.md";WriteUtf8 $concurrentAgents ((Text $concurrentAgents)+("C"*16777216)+[char]10);$first=Start-ApplyProcess $concurrent;$second=Start-ApplyProcess $concurrent;$first.WaitForExit();$second.WaitForExit();$firstOutput=$first.StandardOutput.ReadToEnd()+$first.StandardError.ReadToEnd();$secondOutput=$second.StandardOutput.ReadToEnd()+$second.StandardError.ReadToEnd();$codes=@($first.ExitCode,$second.ExitCode)|Sort-Object;Assert(($codes-join",")-ceq"0,1")("concurrent apply exit codes: "+($codes-join",")+"`n"+$firstOutput+"`n"+$secondOutput);Assert(($firstOutput+$secondOutput).Contains("transaction lock"))"concurrent apply did not report lock contention";& $engine validate -Target $concurrent;$ok=$?;Assert $ok "concurrent apply final validation"
 $corrupt=New-Fixture "0.8.3" corrupt-backup;& $engine apply -Target $corrupt;$ok=$?;Assert $ok "corrupt fixture apply";$corruptManifest=Get-Content -Raw -Encoding UTF8 (Join-Path $corrupt ".project-flow/manifest.json")|ConvertFrom-Json;$corruptTxn=[string]$corruptManifest.last_transaction;$corruptBefore=TreeHashes $corrupt;$lateBackup=Join-Path $corrupt ".project-flow/transactions/$corruptTxn/backup/.agents/WORKFLOW_PROTOCOL.md";Assert(Test-Path $lateBackup -PathType Leaf)"late rollback backup missing";WriteUtf8 $lateBackup "CORRUPTED-BACKUP";& $engine rollback -Target $corrupt -Rollback $corruptTxn 2>$null;$ok=$?;Assert(-not$ok)"rollback accepted corrupt late backup";$corruptAfter=TreeHashes $corrupt;Assert(SameMap $corruptBefore $corruptAfter)"corrupt late backup caused partial restore";$corruptManifestAfter=Get-Content -Raw -Encoding UTF8 (Join-Path $corrupt ".project-flow/manifest.json")|ConvertFrom-Json;Assert($corruptManifestAfter.workflow_version-ceq$currentVersion)"corrupt rollback changed manifest"
 $metaRace=New-Fixture "0.8.3" metadata-race;$metaRaceAgents=Join-Path $metaRace "AGENTS.md";WriteUtf8 $metaRaceAgents ((Text $metaRaceAgents)+("M"*16777216)+[char]10);& $engine apply -Target $metaRace;$ok=$?;Assert $ok "metadata race fixture apply";$metaRaceManifest=Get-Content -Raw -Encoding UTF8 (Join-Path $metaRace ".project-flow/manifest.json")|ConvertFrom-Json;$metaRaceTxn=[string]$metaRaceManifest.last_transaction;$metaRaceBefore=TreeHashes $metaRace;$race=Invoke-RollbackMetadataRace $metaRace $metaRaceTxn;Assert $race.Changed "metadata race hook did not run";Assert($race.ExitCode-eq1)("metadata race rollback exit: "+$race.ExitCode+"`n"+$race.Output+"`n"+$race.Error);Assert($race.Error.Contains("Transaction metadata changed during rollback preflight"))("metadata race reason missing: "+$race.Error);$metaRaceAfter=TreeHashes $metaRace;Assert(SameMap $metaRaceBefore $metaRaceAfter)"metadata race caused partial restore";$metaRacePath=Join-Path $metaRace ".project-flow/transactions/$metaRaceTxn/transaction.json";$typedMeta=Get-Content -Raw -Encoding UTF8 $metaRacePath|ConvertFrom-Json;$typedMeta.files[0].changed="true";WriteUtf8 $metaRacePath (($typedMeta|ConvertTo-Json -Depth 20)+[char]10);$typedError=& $engine rollback -Target $metaRace -Rollback $metaRaceTxn 2>&1|Out-String;$ok=$?;Assert(-not$ok)"rollback accepted string changed flag";Assert($typedError.Contains("changed/existed fields must be booleans"))"typed metadata rejection reason missing";Assert(SameMap $metaRaceBefore (TreeHashes $metaRace))"typed metadata rejection changed project files"
 $upgrade=New-Fixture "0.8.3" upgrade;$before=TreeHashes $upgrade
 $plan=& $engine plan -Target $upgrade *>&1|Out-String
 Assert(([regex]::Matches($plan,"(?m)^DELETE\s+")).Count-eq0)"supported upgrade unexpectedly deletes files"
 & $engine apply -Target $upgrade;$ok=$?;Assert $ok "apply"
 $am=Get-Content -Raw -Encoding UTF8 (Join-Path $upgrade .project-flow/manifest.json)|ConvertFrom-Json
 Assert($am.workflow_version-ceq$currentVersion)"upgrade version";Assert(@($am.files).Count-eq6)"upgrade count"
 $txn=[string]$am.last_transaction;$meta=Get-Content -Raw -Encoding UTF8 (Join-Path $upgrade ".project-flow/transactions/$txn/transaction.json")|ConvertFrom-Json
 Assert(@($meta.removed_files).Count-eq0)"supported upgrade recorded retired files";Assert(@($meta.files|Where-Object resolution -eq DELETE).Count-eq0)"supported upgrade recorded delete actions"
 & $engine validate -Target $upgrade;$ok=$?;Assert $ok "upgraded validation"
 & $engine rollback -Target $upgrade -Rollback $txn;$ok=$?;Assert $ok "rollback"
 $restored=TreeHashes $upgrade;Assert(SameMap $before $restored)"rollback tree mismatch"
 & $engine rollback -Target $upgrade -Rollback $txn;$ok=$?;Assert $ok "idempotent rollback";$restoredAgain=TreeHashes $upgrade;Assert(SameMap $restored $restoredAgain)"idempotent rollback changed tree"
foreach($patchVersion in @("0.9.0","0.9.1","0.10.0")){
 $patchFixture=New-Fixture $patchVersion ("patch-upgrade-"+$patchVersion.Replace(".","-"));$patchBefore=TreeHashes $patchFixture
 $patchPlan=& $engine plan -Target $patchFixture *>&1|Out-String
 Assert($patchPlan.Contains("UPGRADE $patchVersion -> $currentVersion"))"$patchVersion patch target"
 Assert(([regex]::Matches($patchPlan,"(?m)^DELETE\s+")).Count-eq0)"$patchVersion patch unexpectedly retires files"
 & $engine apply -Target $patchFixture;$ok=$?;Assert $ok "$patchVersion patch apply"
 $patchManifest=Get-Content -Raw -Encoding UTF8 (Join-Path $patchFixture ".project-flow/manifest.json")|ConvertFrom-Json
 Assert($patchManifest.workflow_version-ceq$currentVersion)"$patchVersion patch version"
 & $engine validate -Target $patchFixture;$ok=$?;Assert $ok "$patchVersion patch validate"
 & $engine rollback -Target $patchFixture -Rollback ([string]$patchManifest.last_transaction);$ok=$?;Assert $ok "$patchVersion patch rollback"
 Assert(SameMap $patchBefore (TreeHashes $patchFixture))"$patchVersion patch rollback tree mismatch"
}
 $custom=New-Fixture "0.8.3" custom;$cp=Join-Path $custom ".agents/WORKFLOW_PROTOCOL.md";WriteUtf8 $cp ((Text $cp)+"LOCAL-CUSTOM"+[char]10);$cb=Text $cp
 & $engine apply -Target $custom;$ok=$?;Assert $ok "custom apply";Assert(-not((Text $cp).Contains("LOCAL-CUSTOM")))"plugin-owned customization was not replaced"
 $xm=Get-Content -Raw -Encoding UTF8 (Join-Path $custom .project-flow/manifest.json)|ConvertFrom-Json;& $engine rollback -Target $custom -Rollback ([string]$xm.last_transaction);Assert((Text $cp)-ceq$cb)"custom rollback"
 $legacy=New-Fixture "0.8.3" legacy -NoManifest
 & $engine plan -Target $legacy 2>$null;$ok=$?;Assert (-not $ok) "legacy accepted without flag"
 $legacyError=& $engine apply -Target $legacy -AdoptFrom "0.8.3" -ProjectName Legacy 2>&1|Out-String;$ok=$?;Assert(-not$ok)"manifest-free adoption was accepted";Assert($legacyError.Contains("Manifest-free adoption is no longer supported"))"manifest-free rejection reason missing"
 $smoke=New-Fixture "0.8.3" wrapper
 & (Join-Path $repo scripts/upgrade.ps1) -Target $smoke -Plan;$ok=$?;Assert $ok "upgrade wrapper smoke"
 $dry=Join-Path $temp wrapper-install;[IO.Directory]::CreateDirectory($dry)|Out-Null;& (Join-Path $repo scripts/install.ps1) -Target $dry -ProjectName Wrapper -DryRun;$ok=$?;Assert $ok "install wrapper smoke"
 Assert(-not(Test-Path(Join-Path $dry ".project-flow/transaction.lock")))"dry-run created transaction lock"
$contract=Text (Join-Path $repo .agents/workflow.json);foreach($needle in @('"schema_version": 10','"max_active": 1','"request_key": "[codex-project-flow:request:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; requestId=<exactRequestId>; generation=1"','"request_id_assignment": "hub_before_first_work_output"','"states": ["awaiting_authorization", "queued", "active", "awaiting_acceptance", "revision_pending", "accepted_archived"]','"confirmation_fields": ["understanding", "execution_items"]','"completion_fields": ["changes", "verification", "uncovered", "risk"]','"initial_owner": "hub"','"handoff_boundary": "exact_or_queued_execution_task_identity_established"','"post_handoff_owner": "execution_task"','"hub_post_handoff": "no_participation_for_same_request"','"acceptance_owner": "execution_task"','"acceptance_archive": "exact_self_archive_success_and_matching_archived_task_id_required"','"rejection_route": "execution_task_reconfirm_in_place"','"scope_change_route": "execution_task_reconfirm_in_place"','"awaiting_acceptance_occupies_slot": true','"supplemental_authorization": "continue_original_task"','"different_goal": "queue_until_active_task_completes"','"scope_change": "pause_for_execution_task_confirmation_then_continue_original_task"','"replacement": "explicit_user_authorization"','"serial": ["all_visible_execution"]','"default_extension": ".md"','"standalone_cover": false','"first_heading": "#"','"heading_progression": "no_skipped_levels"','"validation_scope": "created_or_updated_delivery_documents"','"required": true','"states": ["draft_pending_review", "approved_for_write", "revision_required", "written"]','"approval_evidence": "explicit_user_chat_approval_bound_to_exact_path_and_content_sha256"','"write_authorization": "approved_exact_content_only"','"rotation"','"mode": "explicit_user_authorization_only"','"protocol": 3','"post_handoff_owner": "transaction_task"','"barrier_owner": "transaction_task"','"request_key": "[codex-project-flow:upgrade-request:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; requestId=<exactRequestId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>"','"active_snapshot": "empty_required_before_file_transaction_fail_closed"','"coordinator_claim": "[codex-project-flow:upgrade-claim:v2] projectId=<exactProjectId>; requestId=<exactRequestId>; coordinatorThreadId=<exactCoordinatorThreadId>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>"')){Assert ($contract.Contains($needle)) "missing $needle"}
foreach($retiredNeedle in @('"hub_handshake"','"hub_followups"','"successor_key"','"task_handshake"','"successor_creation"','"pair_order"','"successor_followups"','"compensating_successors"')){Assert(-not$contract.Contains($retiredNeedle)) "retired post-handoff contract remains: $retiredNeedle"}
$contractValue=$contract|ConvertFrom-Json;Assert($contractValue.upgrade.PSObject.Properties.Name-cnotcontains"recovery") "retired upgrade recovery container remains"
$markdownPath=Join-Path $clean "docs/PROJECT_STATE.md";$markdownOriginal=Text $markdownPath
 WriteUtf8 $markdownPath "## Invalid first heading`n";$validation=& $engine validate -Target $clean -Runtime 2>&1|Out-String;$ok=$?;Assert(-not$ok)"validator accepted non-H1 first heading";Assert($validation.Contains("first heading"))"first heading rejection reason missing"
 WriteUtf8 $markdownPath "# Valid first heading`n`n### Skipped level`n";$validation=& $engine validate -Target $clean -Runtime 2>&1|Out-String;$ok=$?;Assert(-not$ok)"validator accepted skipped Markdown heading";Assert($validation.Contains("heading levels"))"heading progression rejection reason missing"
 WriteUtf8 $markdownPath $markdownOriginal
 & (Join-Path $repo "tests/test-bootstrap-interaction.ps1");$ok=$?;Assert $ok "bootstrap interaction contract"
 & (Join-Path $repo "tests/test-bootstrap-engine.ps1");$ok=$?;Assert $ok "bootstrap PowerShell engine contract"
 & (Join-Path $repo "tests/test-request-execution.ps1");$ok=$?;Assert $ok "request execution contract"
 Write-Host "All PowerShell regression tests passed."
}finally{if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
