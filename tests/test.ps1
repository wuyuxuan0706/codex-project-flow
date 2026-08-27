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
 foreach($e in $items){$src=Join-Path $repo "baselines/$version/$($e.path)";Assert (Test-Path $src -PathType Leaf) "missing baseline $version $($e.path)";$dst=Join-Path $root $e.path;$d=Split-Path -Parent $dst;if(-not (Test-Path $d)){[IO.Directory]::CreateDirectory($d)|Out-Null};Copy-Item $src $dst}
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
 $cleanLock=Join-Path $clean ".project-flow/transaction.lock";Remove-Item -LiteralPath $cleanLock -Force
 & $engine validate -Target $clean;$ok=$?;Assert $ok "clean validation";Assert(-not(Test-Path $cleanLock))"validation created transaction lock"
 & $engine upgrade -Target $clean -Apply -AcceptLocal ("bad"+[char]9+"path") 2>$null;$ok=$?;Assert(-not $ok)"upgrade accepted control character path"
 cmd /c exit 41;Assert($LASTEXITCODE-eq41)"failed to preset NOOP LASTEXITCODE"
 & $engine upgrade -Target $clean -Apply;$ok=$?;Assert $ok "NOOP upgrade read stale LASTEXITCODE";Assert($LASTEXITCODE-eq0)"NOOP upgrade exit code"
 $cm=Get-Content -Raw -Encoding UTF8 (Join-Path $clean .project-flow/manifest.json)|ConvertFrom-Json
 Assert($cm.workflow_version-ceq$currentVersion)"clean version";Assert(@($cm.files).Count-eq6)"managed count"
 foreach($x in @(".agents/prompts/08_result_handoff.md",".agents/snippets/AGENTS.integration.md","docs/WORKFLOW_GUIDE.md","docs/DEVELOPMENT_SOP.md")){Assert (-not (Test-Path (Join-Path $clean $x))) "clean retired file"}
 $wp=Join-Path $clean .agents/workflow.json;$original=Text $wp;WriteUtf8 $wp ($original.Replace('"max_active": 5','"max_active": 1'))
 & $engine validate -Target $clean 2>$null;$ok=$?;Assert (-not $ok) "validator accepted one task";WriteUtf8 $wp $original
 $cleanManifest=Join-Path $clean .project-flow/manifest.json;$savedManifest=Join-Path $temp clean-manifest.json;Move-Item -LiteralPath $cleanManifest -Destination $savedManifest
 $contractCases=@(
  [pscustomobject]@{Name="transaction role";Expected="transaction-task-role";Mutate={param($v)$v.upgrade.transaction_task_role="coordinator_only"}},
  [pscustomobject]@{Name="zero-active fast path";Expected="zero-active-fast-path";Mutate={param($v)$v.upgrade.zero_active_fast_path=$false}},
  [pscustomobject]@{Name="discovery listing";Expected="discovery-listing";Mutate={param($v)$v.upgrade.discovery.listing="full_history"}},
  [pscustomobject]@{Name="discovery history";Expected="discovery-history";Mutate={param($v)$v.upgrade.discovery.history="exhaustive"}},
  [pscustomobject]@{Name="discovery fallback";Expected="discovery-fallback";Mutate={param($v)$v.upgrade.discovery.fallback="never"}},
  [pscustomobject]@{Name="reconcile parallelism";Expected="reconcile-independent-pairs";Mutate={param($v)$v.upgrade.reconcile.independent_pairs="serial"}},
  [pscustomobject]@{Name="reconcile pair order";Expected="reconcile-pair-order";Mutate={param($v)$v.upgrade.reconcile.pair_order=@("create_successor","archive_predecessor","verify_handshake")}},
  [pscustomobject]@{Name="active barrier";Expected="active-barrier";Mutate={param($v)$v.upgrade.barrier.active=$v.upgrade.barrier.active.Replace("state=active","state=provisional")}}
 )
 foreach($case in $contractCases){$value=$original|ConvertFrom-Json;& $case.Mutate $value;WriteUtf8 $wp (($value|ConvertTo-Json -Depth 20)+[char]10);$validation=& $engine validate -Target $clean 2>&1|Out-String;$ok=$?;Assert(-not$ok)"validator accepted invalid $($case.Name)";Assert($validation.Contains($case.Expected))"validator did not report $($case.Name) contract"}
 WriteUtf8 $wp $original;Move-Item -LiteralPath $savedManifest -Destination $cleanManifest
 $failedInstall=Join-Path $temp failed-install;[IO.Directory]::CreateDirectory((Join-Path $failedInstall ".agents/prompts"))|Out-Null;$retiredPath=Join-Path $failedInstall ".agents/prompts/00_project_hub.md";WriteUtf8 $retiredPath "RETIRED-PREEXISTING"
 & $engine install -Target $failedInstall -ProjectName FailedInstall 2>$null;$ok=$?;Assert(-not $ok)"post-manifest validation failure unexpectedly succeeded";Assert(-not(Test-Path(Join-Path $failedInstall ".project-flow/manifest.json")))"failed install left manifest"
 foreach($path in $currentPaths){Assert(-not(Test-Path(Join-Path $failedInstall $path)))"failed install left managed file $path"};Assert((Text $retiredPath)-ceq"RETIRED-PREEXISTING")"failed install changed preexisting retired file"
 $versions=@(Get-ChildItem -LiteralPath (Join-Path $repo baselines) -Directory|Where-Object{$_.Name-match'^\d+\.\d+\.\d+$'}|Sort-Object{[version]$_.Name}|ForEach-Object Name)
 Assert($versions.Count-gt0)"no baselines discovered"
 foreach($version in $versions){
  $f=New-Fixture $version ("plan-"+$version.Replace(".","-"));$plan=& $engine plan -Target $f *>&1|Out-String
  $ok=$?;Assert $ok "$version plan";Assert($plan.Contains("UPGRADE $version -> $currentVersion"))"$version target"
  Assert(-not(Test-Path(Join-Path $f ".project-flow/transaction.lock")))"plan created transaction lock"
  $old=(Get-Content -Raw -Encoding UTF8 (Join-Path $repo "baselines/$version/managed-files.json")|ConvertFrom-Json).files.path
  foreach($x in @($old|Where-Object{$currentPaths-cnotcontains$_})){Assert ($plan.Contains($x)) "$version missing retirement $x"}
 }
 $liveRace=New-Fixture "0.6.0" live-race;$liveRaceManifest=Text(Join-Path $liveRace ".project-flow/manifest.json");$race=Invoke-ApplyRace $liveRace live;Assert $race.Changed "live race hook did not run";Assert($race.ExitCode-eq1)"live race apply exit";Assert((Text(Join-Path $liveRace "AGENTS.md")).Contains("RACE-LIVE"))"live race content was overwritten";Assert((Text(Join-Path $liveRace ".project-flow/manifest.json"))-ceq$liveRaceManifest)"live race changed manifest";Assert($race.Error.Contains("changed after planning"))"live race reason missing"
 $manifestRace=New-Fixture "0.6.0" manifest-race;$manifestRaceAgents=Text(Join-Path $manifestRace "AGENTS.md");$manifestBefore=Text(Join-Path $manifestRace ".project-flow/manifest.json");$race=Invoke-ApplyRace $manifestRace manifest;Assert $race.Changed "manifest race hook did not run";Assert($race.ExitCode-eq1)"manifest race apply exit";Assert((Text(Join-Path $manifestRace "AGENTS.md"))-ceq$manifestRaceAgents)"manifest race changed managed files";Assert((Text(Join-Path $manifestRace ".project-flow/manifest.json"))-ceq($manifestBefore+[char]10))"manifest race edit not preserved";Assert($race.Error.Contains("Manifest changed after planning"))"manifest race reason missing"
 $backupRace=New-Fixture "0.6.0" backup-race;$backupAgents=Join-Path $backupRace "AGENTS.md";WriteUtf8 $backupAgents ((Text $backupAgents)+("X"*8388608)+[char]10);$backupBefore=TreeHashes $backupRace;$race=Invoke-BackupRace $backupRace;Assert $race.Changed "backup race hook did not run";Assert($race.ExitCode-eq5)"backup race apply exit";Assert((Text $backupAgents).Contains("RACE-AFTER-BACKUP"))"backup race external edit was lost";$backupAfter=TreeHashes $backupRace;[void]$backupBefore.Remove("AGENTS.md");[void]$backupAfter.Remove("AGENTS.md");Assert(SameMap $backupBefore $backupAfter)"backup race polluted other project files";$transactionRoot=Join-Path $backupRace ".project-flow/transactions";Assert(@(Get-ChildItem -LiteralPath $transactionRoot -Directory -ErrorAction SilentlyContinue).Count-eq0)"backup race left transaction";$stagingRoot=Join-Path $backupRace ".project-flow/staging";Assert(@(Get-ChildItem -LiteralPath $stagingRoot -Directory -ErrorAction SilentlyContinue).Count-eq0)"backup race left staging";Assert($race.Error.Contains("Managed target changed") -and $race.Error.Contains("AGENTS.md"))("backup race reason missing: "+$race.Error)
 $concurrent=New-Fixture "0.6.0" concurrent;$concurrentAgents=Join-Path $concurrent "AGENTS.md";WriteUtf8 $concurrentAgents ((Text $concurrentAgents)+("C"*16777216)+[char]10);$first=Start-ApplyProcess $concurrent;$second=Start-ApplyProcess $concurrent;$first.WaitForExit();$second.WaitForExit();$firstOutput=$first.StandardOutput.ReadToEnd()+$first.StandardError.ReadToEnd();$secondOutput=$second.StandardOutput.ReadToEnd()+$second.StandardError.ReadToEnd();$codes=@($first.ExitCode,$second.ExitCode)|Sort-Object;Assert(($codes-join",")-ceq"0,1")("concurrent apply exit codes: "+($codes-join",")+"`n"+$firstOutput+"`n"+$secondOutput);Assert(($firstOutput+$secondOutput).Contains("transaction lock"))"concurrent apply did not report lock contention";& $engine validate -Target $concurrent;$ok=$?;Assert $ok "concurrent apply final validation"
 $corrupt=New-Fixture "0.6.0" corrupt-backup;& $engine apply -Target $corrupt;$ok=$?;Assert $ok "corrupt fixture apply";$corruptManifest=Get-Content -Raw -Encoding UTF8 (Join-Path $corrupt ".project-flow/manifest.json")|ConvertFrom-Json;$corruptTxn=[string]$corruptManifest.last_transaction;$corruptBefore=TreeHashes $corrupt;$lateBackup=Join-Path $corrupt ".project-flow/transactions/$corruptTxn/backup/.agents/prompts/10_upgrade_coordination.md";Assert(Test-Path $lateBackup -PathType Leaf)"late rollback backup missing";WriteUtf8 $lateBackup "CORRUPTED-BACKUP";& $engine rollback -Target $corrupt -Rollback $corruptTxn 2>$null;$ok=$?;Assert(-not$ok)"rollback accepted corrupt late backup";$corruptAfter=TreeHashes $corrupt;Assert(SameMap $corruptBefore $corruptAfter)"corrupt late backup caused partial restore";$corruptManifestAfter=Get-Content -Raw -Encoding UTF8 (Join-Path $corrupt ".project-flow/manifest.json")|ConvertFrom-Json;Assert($corruptManifestAfter.workflow_version-ceq$currentVersion)"corrupt rollback changed manifest"
 $metaRace=New-Fixture "0.6.0" metadata-race;$metaRaceAgents=Join-Path $metaRace "AGENTS.md";WriteUtf8 $metaRaceAgents ((Text $metaRaceAgents)+("M"*16777216)+[char]10);& $engine apply -Target $metaRace;$ok=$?;Assert $ok "metadata race fixture apply";$metaRaceManifest=Get-Content -Raw -Encoding UTF8 (Join-Path $metaRace ".project-flow/manifest.json")|ConvertFrom-Json;$metaRaceTxn=[string]$metaRaceManifest.last_transaction;$metaRaceBefore=TreeHashes $metaRace;$race=Invoke-RollbackMetadataRace $metaRace $metaRaceTxn;Assert $race.Changed "metadata race hook did not run";Assert($race.ExitCode-eq1)("metadata race rollback exit: "+$race.ExitCode+"`n"+$race.Output+"`n"+$race.Error);Assert($race.Error.Contains("Transaction metadata changed during rollback preflight"))("metadata race reason missing: "+$race.Error);$metaRaceAfter=TreeHashes $metaRace;Assert(SameMap $metaRaceBefore $metaRaceAfter)"metadata race caused partial restore";$metaRacePath=Join-Path $metaRace ".project-flow/transactions/$metaRaceTxn/transaction.json";$typedMeta=Get-Content -Raw -Encoding UTF8 $metaRacePath|ConvertFrom-Json;$typedMeta.files[0].changed="true";WriteUtf8 $metaRacePath (($typedMeta|ConvertTo-Json -Depth 20)+[char]10);$typedError=& $engine rollback -Target $metaRace -Rollback $metaRaceTxn 2>&1|Out-String;$ok=$?;Assert(-not$ok)"rollback accepted string changed flag";Assert($typedError.Contains("changed/existed fields must be booleans"))"typed metadata rejection reason missing";Assert(SameMap $metaRaceBefore (TreeHashes $metaRace))"typed metadata rejection changed project files"
 $upgrade=New-Fixture "0.6.0" upgrade;$before=TreeHashes $upgrade
 $plan=& $engine plan -Target $upgrade *>&1|Out-String
 Assert(([regex]::Matches($plan,"(?m)^DELETE\s+")).Count-eq3)"three deletes"
 & $engine apply -Target $upgrade;$ok=$?;Assert $ok "apply"
 $am=Get-Content -Raw -Encoding UTF8 (Join-Path $upgrade .project-flow/manifest.json)|ConvertFrom-Json
 Assert($am.workflow_version-ceq$currentVersion)"upgrade version";Assert(@($am.files).Count-eq6)"upgrade count"
 Assert (-not (Test-Path (Join-Path $upgrade "docs/DEVELOPMENT_SOP.md"))) "retired remains"
 $txn=[string]$am.last_transaction;$meta=Get-Content -Raw -Encoding UTF8 (Join-Path $upgrade ".project-flow/transactions/$txn/transaction.json")|ConvertFrom-Json
 $retired=@(".agents/prompts/00_project_hub.md",".agents/prompts/09_execution_handoff.md",".agents/prompts/10_upgrade_coordination.md");Assert((@($meta.removed_files)-join[char]10)-ceq($retired-join[char]10))"transaction retired";Assert(@($meta.files|Where-Object resolution -eq DELETE).Count-eq3)"delete records"
 & $engine validate -Target $upgrade;$ok=$?;Assert $ok "upgraded validation"
 & $engine rollback -Target $upgrade -Rollback $txn;$ok=$?;Assert $ok "rollback"
 $restored=TreeHashes $upgrade;Assert(SameMap $before $restored)"rollback tree mismatch"
 & $engine rollback -Target $upgrade -Rollback $txn;$ok=$?;Assert $ok "idempotent rollback";$restoredAgain=TreeHashes $upgrade;Assert(SameMap $restored $restoredAgain)"idempotent rollback changed tree"
 $patchFixture=New-Fixture "0.7.0" patch-upgrade;$patchBefore=TreeHashes $patchFixture;$patchPlan=& $engine plan -Target $patchFixture *>&1|Out-String;Assert($patchPlan.Contains("UPGRADE 0.7.0 -> $currentVersion"))"patch target";Assert(([regex]::Matches($patchPlan,"(?m)^DELETE\s+")).Count-eq0)"patch unexpectedly retires files";& $engine apply -Target $patchFixture;$ok=$?;Assert $ok "patch apply";$patchManifest=Get-Content -Raw -Encoding UTF8 (Join-Path $patchFixture ".project-flow/manifest.json")|ConvertFrom-Json;Assert($patchManifest.workflow_version-ceq$currentVersion)"patch version";& $engine validate -Target $patchFixture;$ok=$?;Assert $ok "patch validate";& $engine rollback -Target $patchFixture -Rollback ([string]$patchManifest.last_transaction);$ok=$?;Assert $ok "patch rollback";Assert(SameMap $patchBefore (TreeHashes $patchFixture))"patch rollback tree mismatch"
 $custom=New-Fixture "0.6.0" custom;$cp=Join-Path $custom ".agents/prompts/10_upgrade_coordination.md";WriteUtf8 $cp ((Text $cp)+"LOCAL-CUSTOM"+[char]10);$cb=Text $cp
 & $engine apply -Target $custom;$ok=$?;Assert $ok "custom apply";Assert(-not(Test-Path $cp))"custom not deleted"
 $xm=Get-Content -Raw -Encoding UTF8 (Join-Path $custom .project-flow/manifest.json)|ConvertFrom-Json;& $engine rollback -Target $custom -Rollback ([string]$xm.last_transaction);Assert((Text $cp)-ceq$cb)"custom rollback"
 $legacy=New-Fixture "0.2.0" legacy -NoManifest
 & $engine plan -Target $legacy 2>$null;$ok=$?;Assert (-not $ok) "legacy accepted without flag"
 & $engine apply -Target $legacy -AdoptFrom "0.2.0" -ProjectName Legacy;$ok=$?;Assert $ok "legacy apply"
 & $engine validate -Target $legacy;$ok=$?;Assert $ok "legacy validate"
 $smoke=New-Fixture "0.6.0" wrapper
 & (Join-Path $repo scripts/upgrade.ps1) -Target $smoke -Plan;$ok=$?;Assert $ok "upgrade wrapper smoke"
 $dry=Join-Path $temp wrapper-install;[IO.Directory]::CreateDirectory($dry)|Out-Null;& (Join-Path $repo scripts/install.ps1) -Target $dry -ProjectName Wrapper -DryRun;$ok=$?;Assert $ok "install wrapper smoke"
 Assert(-not(Test-Path(Join-Path $dry ".project-flow/transaction.lock")))"dry-run created transaction lock"
 $contract=Text (Join-Path $repo .agents/workflow.json);foreach($needle in @('"schema_version": 6','"workflow_protocol": ".agents/WORKFLOW_PROTOCOL.md"','"parallel": ["non_conflicting"]','"serial": ["high_risk", "external"]','"transaction_task_role": "visible_coordinator_executor"','"listing": "exhaustive_metadata"','"history": "targeted"','"fallback": "full_on_ambiguity"','"zero_active_fast_path": true','"independent_pairs": "parallel_within_available_slots"','"pair_order": ["archive_predecessor", "create_successor", "verify_handshake"]','"provisional": "[codex-project-flow:upgrade-barrier:v1] state=provisional; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>"','"active": "[codex-project-flow:upgrade-barrier:v1] state=active; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>"','"released": "[codex-project-flow:upgrade-barrier:v1] state=released; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>"','"cancelled": "[codex-project-flow:upgrade-barrier:v1] state=cancelled; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>"','"coordinator_claim": "[codex-project-flow:upgrade-claim:v1] projectId=<exactProjectId>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>"','"transaction_key": "[codex-project-flow:upgrade:v1] projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>"','"attempt_deadline_seconds": 60','"include_outputs": false','"poll_scan_latest_turns": 3')){Assert ($contract.Contains($needle)) "missing $needle"};foreach($retiredField in @('"authorization"','"hub"','"handoff"','"scope"','"snapshot"','"fast_path"','"failure"','"release"')){Assert(-not$contract.Contains($retiredField))"retired workflow field remains $retiredField"}
 Write-Host "All PowerShell regression tests passed."
}finally{if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
