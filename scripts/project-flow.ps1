[CmdletBinding()]
param([Parameter(Mandatory,Position=0)][ValidateSet("probe","install","upgrade","plan","apply","rollback","validate","hub-read","hub-write","hub-replacement-prepare","hub-replacement-commit","bootstrap-lock-inspect","bootstrap-lock-acquire","bootstrap-lock-renew","bootstrap-lock-release","bootstrap-lock-recover")][string]$Command,[string]$Target=".",[string]$ProjectName="",[switch]$Force,[switch]$DryRun,[switch]$Plan,[switch]$Apply,[string]$Rollback="",[string]$AdoptFrom="",[string[]]$AcceptLocal=@(),[switch]$AllowPlaceholders,[switch]$Runtime,[string]$ProjectId="",[string]$HubThreadId="",[string]$HubTitle="",[string]$OwnerId="",[string]$ThreadId="",[string]$Phase="",[string]$ExpectedOwnerId="",[string]$ExpectedRenewedAt="",[string]$ExpectedHubThreadId="",[string]$ExpectedRegistryToken="",[string]$NewHubThreadId="",[switch]$ConfirmedOwnerInactive,[switch]$ConfirmedOrphanedClaim,[switch]$ConfirmedOldHubInactive,[switch]$ConfirmedReplacementRetired,[ValidateRange(1,3600)][int]$LeaseSeconds=300)
$ErrorActionPreference="Stop"
$script:EngineRoot=Split-Path -Parent $MyInvocation.MyCommand.Path;$script:PluginRoot=Split-Path -Parent $script:EngineRoot
$script:Utf8NoBom=[Text.UTF8Encoding]::new($false);$script:Utf8Strict=[Text.UTF8Encoding]::new($false,$true);$OutputEncoding=$script:Utf8NoBom;[Console]::OutputEncoding=$script:Utf8NoBom
$script:ControlRootName=".project-flow";$script:BackupRootName=".project-flow-backup";$script:ManifestRelative=".project-flow/manifest.json";$script:BootstrapStaleSeconds=300
$script:ValidPolicies=@("seed_once","merge_manual","structured_manual","replace_if_unmodified");$script:ValidRenderModes=@("none","project_name","project_name_json");$script:ValidOwnership=@("plugin","mixed","project");$script:ValidConflictResolution=@("upstream_wins","preserve_markdown_sections","preserve");$script:FlowContext=$null
function Set-FlowContext([string]$Target,[string]$ProjectName=""){$root=[IO.Path]::GetFullPath($Target);if(-not(Test-Path -LiteralPath $root -PathType Container)){throw "Target directory does not exist: $root"};$item=Get-Item -LiteralPath $root -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Target directory must not be a symbolic link, junction, or reparse point: $root"};$script:FlowContext=[pscustomobject]@{TargetRoot=$root;PluginRoot=$script:PluginRoot;ProjectName=$ProjectName}}
function Test-SafeRelative([string]$RelativePath,[switch]$AllowControl){if([string]::IsNullOrWhiteSpace($RelativePath)-or[IO.Path]::IsPathRooted($RelativePath)-or$RelativePath.Contains("\")-or$RelativePath-match"^[A-Za-z]:"){return $false};foreach($character in $RelativePath.ToCharArray()){if([char]::IsControl($character)){return $false}};$parts=$RelativePath.Split('/');if(@($parts|Where-Object{$_-in@("",".","..")}).Count){return $false};if(-not$AllowControl-and$parts[0]-in@($script:ControlRootName,$script:BackupRootName)){return $false};return $true}
function Assert-WithinRoot([string]$Path,[string]$Root,[string]$Label){$full=[IO.Path]::GetFullPath($Path);$base=[IO.Path]::GetFullPath($Root);$prefix=$base.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;if($full-ne$base-and-not$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "$Label escapes its root: $full"}}
function Resolve-TargetPath([string]$RelativePath,[switch]$AllowControl){if(-not(Test-SafeRelative $RelativePath -AllowControl:$AllowControl)){throw "Unsafe relative target path: $RelativePath"};$root=$script:FlowContext.TargetRoot;$full=[IO.Path]::GetFullPath((Join-Path $root ($RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar))));Assert-WithinRoot $full $root "Target path";$current=$root;foreach($part in $RelativePath.Split('/')){$current=Join-Path $current $part;$item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue;if($null-eq$item){break};if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Refusing target path through a symbolic link, junction, or reparse point: $current"}};return $full}
function Resolve-PluginPath([string]$RelativePath,[string]$Label="plugin input",[switch]$AllowMissingTail){if(-not(Test-SafeRelative $RelativePath -AllowControl)){throw "Unsafe plugin input path: $RelativePath"};$root=$script:PluginRoot;$full=[IO.Path]::GetFullPath((Join-Path $root ($RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar))));Assert-WithinRoot $full $root $Label;$current=$root;$missing=$false;foreach($part in $RelativePath.Split('/')){$current=Join-Path $current $part;if($missing){continue};$item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue;if($null-eq$item){if($AllowMissingTail){$missing=$true;continue};throw "$Label is missing or unsafe: $RelativePath"};if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "$Label path uses a symbolic link, junction, or reparse point: $RelativePath"}};if(-not$missing){$item=Get-Item -LiteralPath $full -Force;if($item.PSIsContainer){throw "$Label is not a regular file: $RelativePath"}};return $full}
function Ensure-SafeDirectory([string]$Directory){$root=$script:FlowContext.TargetRoot;$full=[IO.Path]::GetFullPath($Directory);Assert-WithinRoot $full $root "Directory";if($full-eq$root){return};$prefix=$root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;$current=$root;foreach($part in $full.Substring($prefix.Length).Split([char[]]@('\','/'),[StringSplitOptions]::RemoveEmptyEntries)){$current=Join-Path $current $part;$item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue;if($null-eq$item){[IO.Directory]::CreateDirectory($current)|Out-Null}elseif(-not$item.PSIsContainer-or(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw "Directory path is not a real directory: $current"}}}
function Enter-TransactionLock {
    $path = Resolve-TargetPath "$script:ControlRootName/transaction.lock" -AllowControl
    Ensure-SafeDirectory (Split-Path -Parent $path)
    $handle = $null
    try {
        $handle = [IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        if ($handle.Length -lt 1) { $handle.SetLength(1) }
        $handle.Lock(0,1)
        return $handle
    } catch [IO.IOException] {
        if ($null -ne $handle) { $handle.Dispose() }
        throw "Another project-flow mutation holds the transaction lock: $path"
    } catch {
        if ($null -ne $handle) { $handle.Dispose() }
        throw
    }
}
function Exit-TransactionLock([IO.FileStream]$Handle) { if ($null -ne $Handle) { try { $Handle.Unlock(0,1) } catch { } finally { $Handle.Dispose() } } }
function Test-SafeFile([string]$Path,[string]$Label){$item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue;if($null-eq$item){return $false};if($item.PSIsContainer-or(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw "$Label exists and is not a safe regular file: $Path"};return $true}
function ConvertFrom-Utf8Bytes([byte[]]$Bytes,[string]$Label){$offset=if($Bytes.Length-ge3-and$Bytes[0]-eq0xEF-and$Bytes[1]-eq0xBB-and$Bytes[2]-eq0xBF){3}else{0};try{$text=$script:Utf8Strict.GetString($Bytes,$offset,$Bytes.Length-$offset)}catch{throw "$Label is not UTF-8 text: $($_.Exception.Message)"};return $text.Replace("`r`n","`n").Replace("`r","`n")}
function Read-NormalizedText([string]$Path,[string]$Label){if(-not(Test-SafeFile $Path $Label)){throw "$Label is missing: $Path"};return ConvertFrom-Utf8Bytes ([IO.File]::ReadAllBytes($Path)) $Label}
function ConvertFrom-JsonObjectText([string]$Text,[string]$Label){try{if($Text-notmatch'^\s*\{'){throw "JSON root must be an object"};$parsed=$Text|ConvertFrom-Json -DateKind String;if($parsed-isnot[pscustomobject]){throw "JSON root must be an object"};return $parsed}catch{throw "$Label is invalid JSON: $($_.Exception.Message)"}}
function Read-JsonFile([string]$Path,[string]$Label){return ConvertFrom-JsonObjectText (Read-NormalizedText $Path $Label) $Label}
function Get-TextHash([string]$Text){$sha=[Security.Cryptography.SHA256]::Create();try{return "sha256:"+([BitConverter]::ToString($sha.ComputeHash($script:Utf8NoBom.GetBytes($Text)))).Replace("-","").ToLowerInvariant()}finally{$sha.Dispose()}}
function Get-BytesHash([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{return "sha256:"+([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-","").ToLowerInvariant()}finally{$sha.Dispose()}}
function Get-FileHashNormalized([string]$Path,[string]$Label){return Get-TextHash (Read-NormalizedText $Path $Label)}
function Write-AtomicBytes([string]$Path,[byte[]]$Bytes){Assert-WithinRoot $Path $script:FlowContext.TargetRoot "Write path";Ensure-SafeDirectory (Split-Path -Parent $Path);$exists=Test-SafeFile $Path "Destination";$tmp="$Path.project-flow-tmp-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8))";try{[IO.File]::WriteAllBytes($tmp,$Bytes);if($exists){[IO.File]::Move($tmp,$Path,$true)}else{[IO.File]::Move($tmp,$Path)}}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}}
function Write-AtomicText([string]$Path,[string]$Text){Write-AtomicBytes $Path ($script:Utf8NoBom.GetBytes($Text))}
function Render-Template([string]$Text,[string]$Mode,[string]$Name){if($Mode-eq"none"){return $Text};if($Mode-eq"project_name"){return $Text.Replace("<PROJECT_NAME>",$Name)};if($Mode-eq"project_name_json"){return $Text.Replace('"<PROJECT_NAME>"',(ConvertTo-Json $Name -Compress))};throw "Unsupported render mode: $Mode"}
function Test-Property([object]$Object,[string]$Name){return $null-ne$Object-and$null-ne$Object.PSObject.Properties[$Name]}
function Confirm-ProjectName([string]$Name){if([string]::IsNullOrWhiteSpace($Name)){throw "Project name must not be empty."};foreach($character in $Name.ToCharArray()){if([char]::IsControl($character)){throw "Project name must not contain control characters."}};return $Name}
function Confirm-IdentityValue([string]$Value,[string]$Label){if([string]::IsNullOrWhiteSpace($Value)){throw "$Label must not be empty."};foreach($character in $Value.ToCharArray()){if([char]::IsControl($character)){throw "$Label must not contain control characters."}};return $Value}
function Confirm-Identifier([string]$Value,[string]$Label){Confirm-IdentityValue $Value $Label|Out-Null;if($Value-notmatch'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$'){throw "$Label contains an illegal identifier."};return $Value}
function Confirm-RegistryToken([string]$Value,[string]$Label="RegistryToken"){if($Value-notmatch'^sha256:[0-9a-f]{64}$'){throw "$Label must be a lowercase raw SHA-256 token."};return $Value}
function Get-UtcNowText{return ([DateTime]::UtcNow).ToString("o",[Globalization.CultureInfo]::InvariantCulture)}
function ConvertTo-StrictUtc([object]$Value,[string]$Label){if($Value -isnot [string]){throw "$Label must be a UTC timestamp."};$parsed=[DateTimeOffset]::MinValue;$ok=[DateTimeOffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed);if((-not $ok) -or ($parsed.Offset -ne [TimeSpan]::Zero)){throw "$Label must be a UTC timestamp."};return $parsed.ToUniversalTime()}
function Assert-ExactProperties([object]$Value,[string[]]$Expected,[string]$Label){if($null-eq$Value-or$Value-isnot[pscustomobject]){throw "$Label must be an object."};$actual=@($Value.PSObject.Properties.Name|Sort-Object);$wanted=@($Expected|Sort-Object);if(($actual-join"`n")-cne($wanted-join"`n")){throw "$Label has unexpected fields."}}
function Get-HubPath{return Resolve-TargetPath "$script:ControlRootName/hub.json" -AllowControl}
function Get-BootstrapLockPath{return Resolve-TargetPath "$script:ControlRootName/bootstrap.lock" -AllowControl}
function Test-CanonicalProjectPath([string]$Actual,[string]$Expected){return [string]::Equals($Actual,$Expected,[StringComparison]::OrdinalIgnoreCase)}
function Get-HubSnapshot([string]$ExpectedProjectId){$projectId=Confirm-Identifier $ExpectedProjectId "ProjectId";$path=Get-HubPath;if(-not(Test-SafeFile $path "Hub registry")){throw "Hub registry is missing: $path"};$bytes=[IO.File]::ReadAllBytes($path);$record=ConvertFrom-JsonObjectText (ConvertFrom-Utf8Bytes $bytes ".project-flow/hub.json") ".project-flow/hub.json";Assert-ExactProperties $record @("schemaVersion","projectId","projectPath","threadId","hubTitle","updatedAt") "Hub registry";if($record.schemaVersion-ne1){throw "Hub registry schema is invalid."};Confirm-Identifier ([string]$record.projectId) "Hub registry projectId"|Out-Null;Confirm-IdentityValue ([string]$record.projectPath) "Hub registry projectPath"|Out-Null;Confirm-Identifier ([string]$record.threadId) "Hub registry threadId"|Out-Null;Confirm-IdentityValue ([string]$record.hubTitle) "Hub registry hubTitle"|Out-Null;if([string]$record.projectId-cne$projectId){throw "Hub registry projectId does not match the expected project."};if(-not(Test-CanonicalProjectPath ([string]$record.projectPath) $script:FlowContext.TargetRoot)){throw "Hub registry project path does not match this target."};[void](ConvertTo-StrictUtc $record.updatedAt "Hub registry updatedAt");return [pscustomobject]@{Record=$record;Token=(Get-BytesHash $bytes)}}
function Read-HubRecord([string]$ExpectedProjectId){return (Get-HubSnapshot $ExpectedProjectId).Record}
function ConvertTo-HubResult([object]$Snapshot,[bool]$Switched=$false,[bool]$AlreadyCommitted=$false){$r=$Snapshot.Record;return [ordered]@{schemaVersion=[int]$r.schemaVersion;projectId=[string]$r.projectId;projectPath=[string]$r.projectPath;threadId=[string]$r.threadId;hubTitle=[string]$r.hubTitle;updatedAt=[string]$r.updatedAt;registryToken=[string]$Snapshot.Token;switched=$Switched;alreadyCommitted=$AlreadyCommitted}}
function New-BootstrapLockRecord([string]$ProjectId,[string]$OwnerId,[string]$ThreadId,[string]$Phase,[int]$LeaseSeconds,[object]$Replacement=$null){$now=[DateTimeOffset]::UtcNow;$stamp=$now.ToString("o",[Globalization.CultureInfo]::InvariantCulture);$boundThread=if([string]::IsNullOrWhiteSpace($ThreadId)){$null}else{Confirm-Identifier $ThreadId "ThreadId"};return [ordered]@{schemaVersion=2;projectId=(Confirm-Identifier $ProjectId "ProjectId");projectPath=$script:FlowContext.TargetRoot;ownerId=(Confirm-Identifier $OwnerId "OwnerId");threadId=$boundThread;phase=(Confirm-IdentityValue $Phase "Phase");createdAt=$stamp;renewedAt=$stamp;expiresAt=($now.AddSeconds($LeaseSeconds)).ToString("o",[Globalization.CultureInfo]::InvariantCulture);replacement=$Replacement}}
function Read-BootstrapLockRecord([IO.FileStream]$Handle,[string]$ExpectedProjectId){$Handle.Position=0;$bytes=New-Object byte[] ([int]$Handle.Length);$read=0;while($read-lt$bytes.Length){$count=$Handle.Read($bytes,$read,$bytes.Length-$read);if($count-le0){throw "Bootstrap lock changed while reading."};$read+=$count};$record=ConvertFrom-JsonObjectText (ConvertFrom-Utf8Bytes $bytes ".project-flow/bootstrap.lock") ".project-flow/bootstrap.lock";$common=@("schemaVersion","projectId","projectPath","ownerId","threadId","phase","createdAt","renewedAt","expiresAt");if($record.schemaVersion-eq1){Assert-ExactProperties $record $common "Bootstrap lock";$record|Add-Member -NotePropertyName replacement -NotePropertyValue $null}elseif($record.schemaVersion-eq2){Assert-ExactProperties $record ($common+"replacement") "Bootstrap lock"}else{throw "Bootstrap lock schema is invalid."};Confirm-Identifier ([string]$record.projectId) "Bootstrap lock projectId"|Out-Null;Confirm-IdentityValue ([string]$record.projectPath) "Bootstrap lock projectPath"|Out-Null;Confirm-Identifier ([string]$record.ownerId) "Bootstrap lock ownerId"|Out-Null;Confirm-IdentityValue ([string]$record.phase) "Bootstrap lock phase"|Out-Null;if($null-ne$record.threadId){Confirm-Identifier ([string]$record.threadId) "Bootstrap lock threadId"|Out-Null};if($null-ne$record.replacement){Assert-ExactProperties $record.replacement @("expectedHubThreadId","expectedRegistryToken","newHubThreadId","newHubTitle") "Bootstrap lock replacement";Confirm-Identifier ([string]$record.replacement.expectedHubThreadId) "ExpectedHubThreadId"|Out-Null;Confirm-RegistryToken ([string]$record.replacement.expectedRegistryToken) "ExpectedRegistryToken"|Out-Null;Confirm-Identifier ([string]$record.replacement.newHubThreadId) "NewHubThreadId"|Out-Null;Confirm-IdentityValue ([string]$record.replacement.newHubTitle) "NewHubTitle"|Out-Null;if($null-eq$record.threadId-or[string]$record.threadId-cne[string]$record.replacement.newHubThreadId){throw "Bootstrap replacement evidence does not match the bound current task."}};if([string]$record.projectId-cne(Confirm-Identifier $ExpectedProjectId "ProjectId")){throw "Bootstrap lock projectId does not match the expected project."};if(-not(Test-CanonicalProjectPath ([string]$record.projectPath) $script:FlowContext.TargetRoot)){throw "Bootstrap lock project path does not match this target."};$created=ConvertTo-StrictUtc $record.createdAt "Bootstrap lock createdAt";$renewed=ConvertTo-StrictUtc $record.renewedAt "Bootstrap lock renewedAt";$expires=ConvertTo-StrictUtc $record.expiresAt "Bootstrap lock expiresAt";if($renewed-lt$created-or$expires-le$renewed){throw "Bootstrap lock timestamps are inconsistent."};return $record}
function Enter-BootstrapLock([string]$ProjectId,[switch]$CreateNew){$path=Get-BootstrapLockPath;if($CreateNew){Ensure-SafeDirectory (Split-Path -Parent $path)};$handle=$null;try{$mode=if($CreateNew){[IO.FileMode]::CreateNew}else{if(-not(Test-SafeFile $path "Bootstrap lock")){throw "Bootstrap lock is missing: $path"};[IO.FileMode]::Open};$handle=[IO.File]::Open($path,$mode,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete));$handle.Lock(0,1);return [pscustomobject]@{Path=$path;Handle=$handle;ProjectId=$ProjectId}}catch [IO.IOException]{if($null-ne$handle){$handle.Dispose()};throw "Bootstrap lock is busy or unavailable: $path"}catch{if($null-ne$handle){$handle.Dispose()};throw}}
function Exit-BootstrapLock([object]$Lock){if($null-ne$Lock-and$null-ne$Lock.Handle){try{$Lock.Handle.Unlock(0,1)}catch{}finally{$Lock.Handle.Dispose()}}}
function Write-BootstrapLockRecord([IO.FileStream]$Handle,[object]$Record){$text=(($Record|ConvertTo-Json -Depth 10)+"`n").Replace("`r`n","`n").Replace("`r","`n");$bytes=$script:Utf8NoBom.GetBytes($text);$Handle.Position=0;$Handle.SetLength(0);$Handle.Write($bytes,0,$bytes.Length);$Handle.Flush($true)}
function Get-BootstrapStaleAt([object]$Record){$renewed=ConvertTo-StrictUtc $Record.renewedAt "Bootstrap lock renewedAt";$expires=ConvertTo-StrictUtc $Record.expiresAt "Bootstrap lock expiresAt";$staleAt=$renewed.AddSeconds($script:BootstrapStaleSeconds);if($expires-gt$staleAt){$staleAt=$expires};return $staleAt}
function Invoke-BootstrapInspect([string]$Target,[string]$ProjectId){Set-FlowContext $Target;$lock=Enter-BootstrapLock $ProjectId;try{$record=Read-BootstrapLockRecord $lock.Handle $ProjectId;$staleAt=Get-BootstrapStaleAt $record;$result=[ordered]@{schemaVersion=[int]$record.schemaVersion;projectId=[string]$record.projectId;projectPath=[string]$record.projectPath;ownerId=[string]$record.ownerId;threadId=if($null-eq$record.threadId){$null}else{[string]$record.threadId};phase=[string]$record.phase;createdAt=[string]$record.createdAt;renewedAt=[string]$record.renewedAt;expiresAt=[string]$record.expiresAt;replacement=$record.replacement;staleAt=$staleAt.ToString("o",[Globalization.CultureInfo]::InvariantCulture);isStale=([DateTimeOffset]::UtcNow-ge$staleAt)};[Console]::Out.WriteLine(($result|ConvertTo-Json -Depth 10 -Compress))}finally{Exit-BootstrapLock $lock}}
function Invoke-BootstrapAcquire([string]$Target,[string]$ProjectId,[string]$OwnerId,[string]$ThreadId,[string]$Phase,[int]$LeaseSeconds){Set-FlowContext $Target;$lock=Enter-BootstrapLock $ProjectId -CreateNew;try{$record=New-BootstrapLockRecord $ProjectId $OwnerId $ThreadId $Phase $LeaseSeconds;Write-BootstrapLockRecord $lock.Handle $record;[Console]::Out.WriteLine(($record|ConvertTo-Json -Compress))}finally{Exit-BootstrapLock $lock}}
function Invoke-BootstrapRecover([string]$Target,[string]$ProjectId,[string]$OwnerId,[string]$ThreadId,[string]$Phase,[string]$ExpectedOwnerId,[string]$ExpectedRenewedAt,[int]$LeaseSeconds,[switch]$ConfirmedOwnerInactive,[switch]$ConfirmedOrphanedClaim){[void](ConvertTo-StrictUtc $ExpectedRenewedAt "ExpectedRenewedAt");Set-FlowContext $Target;$lock=Enter-BootstrapLock $ProjectId;try{$existing=Read-BootstrapLockRecord $lock.Handle $ProjectId;if([string]$existing.ownerId-cne(Confirm-Identifier $ExpectedOwnerId "ExpectedOwnerId")){throw "Bootstrap lock owner does not match the expected stale owner."};if([string]$existing.renewedAt-cne$ExpectedRenewedAt){throw "Bootstrap lock changed after inspection; refusing stale recovery."};if([DateTimeOffset]::UtcNow-lt(Get-BootstrapStaleAt $existing)){throw "Bootstrap lock is not stale enough to recover."};$requested=if([string]::IsNullOrWhiteSpace($ThreadId)){$null}else{Confirm-Identifier $ThreadId "ThreadId"};if($null-ne$existing.threadId){if(-not$ConfirmedOwnerInactive){throw "Bound bootstrap recovery requires -ConfirmedOwnerInactive."};if($ConfirmedOrphanedClaim){throw "A bound bootstrap lock cannot use orphan recovery."};if($null-eq$requested-or[string]$requested-cne[string]$existing.threadId){throw "A bound bootstrap lock must recover the same thread."}}elseif($null-eq$requested){if(-not$ConfirmedOrphanedClaim){throw "Unbound zero-candidate recovery requires -ConfirmedOrphanedClaim."};if([string]$existing.phase-notin@("install","installing")){throw "Only an unpublished install-phase lock can use orphan recovery."};if([string]$Phase-cne"installing"){throw "Orphan recovery must preserve the recoverable installing phase until the current task is bound."};if(Test-Path -LiteralPath (Get-HubPath)){throw "Hub registry exists; refusing orphan recovery."}}else{if(-not$ConfirmedOwnerInactive){throw "Discovered claim recovery requires -ConfirmedOwnerInactive."};if($ConfirmedOrphanedClaim){throw "A discovered claim thread must not use orphan recovery."}};$record=New-BootstrapLockRecord $ProjectId $OwnerId $requested $Phase $LeaseSeconds $existing.replacement;Write-BootstrapLockRecord $lock.Handle $record;[Console]::Out.WriteLine(($record|ConvertTo-Json -Depth 10 -Compress))}finally{Exit-BootstrapLock $lock}}
function Invoke-BootstrapRenew([string]$Target,[string]$ProjectId,[string]$OwnerId,[string]$ThreadId,[string]$Phase,[int]$LeaseSeconds){Set-FlowContext $Target;$lock=Enter-BootstrapLock $ProjectId;try{$record=Read-BootstrapLockRecord $lock.Handle $ProjectId;if([string]$record.ownerId-cne(Confirm-Identifier $OwnerId "OwnerId")){throw "Bootstrap lock owner does not match; refusing renewal."};$bound=if([string]::IsNullOrWhiteSpace($ThreadId)){$record.threadId}else{Confirm-Identifier $ThreadId "ThreadId"};if($null-ne$record.threadId-and[string]$record.threadId-cne[string]$bound){throw "Bootstrap lock thread does not match; refusing renewal."};$now=[DateTimeOffset]::UtcNow;$record.schemaVersion=2;$record.threadId=$bound;$record.phase=Confirm-IdentityValue $Phase "Phase";$record.renewedAt=$now.ToString("o",[Globalization.CultureInfo]::InvariantCulture);$record.expiresAt=($now.AddSeconds($LeaseSeconds)).ToString("o",[Globalization.CultureInfo]::InvariantCulture);Write-BootstrapLockRecord $lock.Handle $record;[Console]::Out.WriteLine(($record|ConvertTo-Json -Depth 10 -Compress))}finally{Exit-BootstrapLock $lock}}
function Invoke-BootstrapRelease([string]$Target,[string]$ProjectId,[string]$OwnerId,[switch]$ConfirmedReplacementRetired){Set-FlowContext $Target;$lock=Enter-BootstrapLock $ProjectId;try{$existing=Read-BootstrapLockRecord $lock.Handle $ProjectId;if([string]$existing.ownerId-cne(Confirm-Identifier $OwnerId "OwnerId")){throw "Bootstrap lock owner does not match; refusing release."};if($null-ne$existing.replacement){if([string]$existing.phase-cne"hub_replacement_retiring_old"){throw "Hub replacement lock cannot be released before registry commit."};if(-not$ConfirmedReplacementRetired){throw "Hub replacement release requires explicit confirmation that the exact old hub is retired."}};Remove-Item -LiteralPath $lock.Path -Force;[Console]::Out.WriteLine('{"released":true}')}finally{Exit-BootstrapLock $lock}}
function Invoke-HubRead([string]$Target,[string]$ProjectId){Set-FlowContext $Target;$snapshot=Get-HubSnapshot $ProjectId;[Console]::Out.WriteLine(((ConvertTo-HubResult $snapshot)|ConvertTo-Json -Compress))}
function Invoke-HubWrite([string]$Target,[string]$ProjectId,[string]$HubThreadId,[string]$HubTitle,[string]$OwnerId){Set-FlowContext $Target;$lock=Enter-BootstrapLock $ProjectId;try{$lease=Read-BootstrapLockRecord $lock.Handle $ProjectId;if([string]$lease.ownerId-cne(Confirm-Identifier $OwnerId "OwnerId")){throw "Bootstrap lock owner does not match; refusing hub registry write."};$thread=Confirm-Identifier $HubThreadId "HubThreadId";if($null-eq$lease.threadId-or[string]$lease.threadId-cne$thread){throw "Bootstrap lock is not bound to the hub thread; refusing registry write."};if((ConvertTo-StrictUtc $lease.expiresAt "Bootstrap lock expiresAt")-lt[DateTimeOffset]::UtcNow){throw "Bootstrap lock expired; renew or explicitly recover before writing the hub registry."};$path=Get-HubPath;$record=[ordered]@{schemaVersion=1;projectId=(Confirm-Identifier $ProjectId "ProjectId");projectPath=$script:FlowContext.TargetRoot;threadId=$thread;hubTitle=(Confirm-IdentityValue $HubTitle "HubTitle");updatedAt=Get-UtcNowText};if(Test-Path -LiteralPath $path){$existing=Read-HubRecord $ProjectId;if([string]$existing.threadId-cne$thread){throw "Hub registry already binds a different thread; refusing overwrite."};Write-AtomicText $path (($record|ConvertTo-Json -Depth 10)+"`n");$verified=Read-HubRecord $ProjectId;[Console]::Out.WriteLine(($verified|ConvertTo-Json -Compress));return};Ensure-SafeDirectory (Split-Path -Parent $path);$bytes=$script:Utf8NoBom.GetBytes((($record|ConvertTo-Json -Depth 10)+"`n"));$tmp="$path.project-flow-tmp-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8))";try{$handle=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$handle.Write($bytes,0,$bytes.Length);$handle.Flush($true)}finally{$handle.Dispose()};try{[IO.File]::Move($tmp,$path)}catch [IO.IOException]{throw "Hub registry appeared during atomic create; retry only to verify its existing thread binding."}}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}};$verified=Read-HubRecord $ProjectId;[Console]::Out.WriteLine(($verified|ConvertTo-Json -Compress))}finally{Exit-BootstrapLock $lock}}
function Assert-ManagedEntry([object]$Entry,[hashtable]$Seen,[switch]$Baseline){$r=[string]$Entry.path;$s=[string]$Entry.source;if(-not(Test-SafeRelative $r)-or-not(Test-SafeRelative $s -AllowControl)-or$Seen.ContainsKey($r)){throw "Unsafe or duplicate managed path: $r"};$Seen[$r]=$true;if($script:ValidPolicies-notcontains[string]$Entry.policy){throw "Unsupported policy for $r"};if($script:ValidRenderModes-notcontains[string]$Entry.render){throw "Unsupported render mode for $r"};if($Baseline){if([string]$Entry.content_hash-notmatch'^sha256:[0-9a-f]{64}$'){throw "Invalid baseline hash for $r"};return};if($script:ValidOwnership-notcontains[string]$Entry.ownership){throw "Unsupported ownership for $r"};if($script:ValidConflictResolution-notcontains[string]$Entry.conflict_resolution){throw "Unsupported conflict_resolution for $r"};if($Entry.conflict_resolution-eq"upstream_wins"-and$Entry.ownership-ne"plugin"){throw "upstream_wins requires plugin ownership for $r"};if($Entry.conflict_resolution-eq"preserve"-and$Entry.ownership-ne"project"){throw "preserve requires project ownership for $r"};if($Entry.conflict_resolution-eq"preserve_markdown_sections"){if($Entry.ownership-ne"mixed"-or$Entry.preserve_sections-isnot[Array]-or@($Entry.preserve_sections).Count-eq0){throw "Invalid protected sections for $r"}}elseif(Test-Property $Entry "preserve_sections"){throw "Unexpected preserve_sections for $r"}}
function Get-CurrentManagedContract{$version=(Read-NormalizedText (Resolve-PluginPath "VERSION" "VERSION") "VERSION").Trim();if($version-notmatch'^\d+\.\d+\.\d+$'){throw "VERSION must be SemVer"};$managed=Read-JsonFile (Resolve-PluginPath "managed-files.json" "managed-files.json") "managed-files.json";if($managed.schema_version-ne1-or[string]$managed.workflow_version-cne$version-or$managed.files-isnot[Array]-or$managed.retired_paths-isnot[Array]){throw "managed-files.json does not match VERSION"};$entries=@($managed.files);if(-not$entries.Count){throw "managed files empty"};$seen=@{};foreach($e in $entries){Assert-ManagedEntry $e $seen;Resolve-PluginPath ([string]$e.source) "managed source"|Out-Null};$retired=@($managed.retired_paths);$retiredSeen=@{};foreach($r in $retired){if($r-isnot[string]){throw "Retired path must be a string"};$path=[string]$r;if(-not(Test-SafeRelative $path)-or$seen.ContainsKey($path)-or$retiredSeen.ContainsKey($path)){throw "Unsafe, active, or duplicate retired path: $path"};$retiredSeen[$path]=$true};$state=@($entries|Where-Object path -ceq "docs/PROJECT_STATE.md");if($state.Count-ne1-or$state[0].policy-cne"seed_once"-or$state[0].ownership-cne"project"-or$state[0].conflict_resolution-cne"preserve"){throw "PROJECT_STATE contract invalid"};$agents=@($entries|Where-Object path -ceq "AGENTS.md");if($agents.Count-ne1-or$agents[0].ownership-cne"mixed"-or$agents[0].conflict_resolution-cne"preserve_markdown_sections"-or(@($agents[0].preserve_sections)-join"`n")-cne"项目事实"){throw "AGENTS contract invalid"};return [pscustomobject]@{Version=$version;Managed=$managed;Entries=$entries;Seen=$seen;Retired=$retired}}
function Get-BaselineContract([string]$Version){if($Version-notmatch'^\d+\.\d+\.\d+$'){throw "Invalid baseline version: $Version"};$p=Resolve-PluginPath "baselines/$Version/managed-files.json" "baseline metadata" -AllowMissingTail;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "No supported migration from $Version"};$c=Read-JsonFile $p "baseline metadata";if($c.schema_version-ne1-or$c.kind-cne"managed_files_baseline"-or$c.workflow_version-cne$Version-or$c.files-isnot[Array]-or-not@($c.files).Count){throw "Invalid baseline contract: $Version"};$seen=@{};foreach($e in @($c.files)){Assert-ManagedEntry $e $seen -Baseline;$bp=Resolve-PluginPath "baselines/$Version/$([string]$e.path)" "baseline $([string]$e.path)";if((Get-FileHashNormalized $bp "baseline $([string]$e.path)")-cne[string]$e.content_hash){throw "Baseline content hash mismatch for $([string]$e.path)"}};return [pscustomobject]@{Version=$Version;Entries=@($c.files);Seen=$seen}}
function Remove-EmptyParents([string]$Path){$current=Split-Path -Parent $Path;while($current-ne$script:FlowContext.TargetRoot-and(Split-Path -Leaf $current)-ne$script:ControlRootName){$item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue;if($null-eq$item-or-not$item.PSIsContainer-or(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0)){break};if(@(Get-ChildItem -LiteralPath $current -Force).Count-ne0){break};Remove-Item -LiteralPath $current -Force;$current=Split-Path -Parent $current}}

function Invoke-HubReplacementPrepare([string]$Target,[string]$ProjectId,[string]$OwnerId,[string]$ExpectedHubThreadId,[string]$ExpectedRegistryToken,[string]$NewHubThreadId,[string]$HubTitle,[int]$LeaseSeconds,[switch]$ConfirmedOldHubInactive){if(-not$ConfirmedOldHubInactive){throw "Hub replacement prepare requires explicit confirmed inactive old hub evidence."};Set-FlowContext $Target;$old=Confirm-Identifier $ExpectedHubThreadId "ExpectedHubThreadId";$new=Confirm-Identifier $NewHubThreadId "NewHubThreadId";if($old-ceq$new){throw "Replacement hub must differ from the registered old hub."};$token=Confirm-RegistryToken $ExpectedRegistryToken "ExpectedRegistryToken";$title=Confirm-IdentityValue $HubTitle "HubTitle";$lock=$null;$published=$false;try{$lock=Enter-BootstrapLock $ProjectId -CreateNew;$snapshot=Get-HubSnapshot $ProjectId;if([string]$snapshot.Record.threadId-cne$old-or[string]$snapshot.Token-cne$token){throw "Hub registry changed after authorization; refusing replacement prepare."};$replacement=[ordered]@{expectedHubThreadId=$old;expectedRegistryToken=$token;newHubThreadId=$new;newHubTitle=$title};$record=New-BootstrapLockRecord $ProjectId $OwnerId $new "hub_replacement_prepared" $LeaseSeconds $replacement;Write-BootstrapLockRecord $lock.Handle $record;$published=$true;[Console]::Out.WriteLine(($record|ConvertTo-Json -Depth 10 -Compress))}catch{if(-not$published-and$null-ne$lock-and(Test-Path -LiteralPath $lock.Path)){Remove-Item -LiteralPath $lock.Path -Force};throw}finally{if($null-ne$lock){Exit-BootstrapLock $lock}}}
function Invoke-HubReplacementCommit([string]$Target,[string]$ProjectId,[string]$OwnerId){Set-FlowContext $Target;$lock=Enter-BootstrapLock $ProjectId;try{$lease=Read-BootstrapLockRecord $lock.Handle $ProjectId;if([string]$lease.ownerId-cne(Confirm-Identifier $OwnerId "OwnerId")){throw "Bootstrap lock owner does not match; refusing hub replacement commit."};if($null-eq$lease.replacement-or[string]$lease.phase-notin@("hub_replacement_prepared","hub_replacement_retiring_old")){throw "Bootstrap lock does not contain a recoverable hub replacement."};if((ConvertTo-StrictUtc $lease.expiresAt "Bootstrap lock expiresAt")-lt[DateTimeOffset]::UtcNow){throw "Bootstrap lock expired; renew the exact replacement owner before commit."};$e=$lease.replacement;$snapshot=Get-HubSnapshot $ProjectId;$already=$false;if([string]$snapshot.Record.threadId-ceq[string]$e.newHubThreadId){$already=$true}elseif([string]$snapshot.Record.threadId-cne[string]$e.expectedHubThreadId-or[string]$snapshot.Token-cne[string]$e.expectedRegistryToken){throw "Hub registry token or old hub changed; refusing replacement commit."}else{$record=[ordered]@{schemaVersion=1;projectId=(Confirm-Identifier $ProjectId "ProjectId");projectPath=$script:FlowContext.TargetRoot;threadId=(Confirm-Identifier ([string]$e.newHubThreadId) "NewHubThreadId");hubTitle=(Confirm-IdentityValue ([string]$e.newHubTitle) "NewHubTitle");updatedAt=Get-UtcNowText};Write-AtomicText (Get-HubPath) (($record|ConvertTo-Json -Depth 10)+"`n");$snapshot=Get-HubSnapshot $ProjectId;if([string]$snapshot.Record.threadId-cne[string]$e.newHubThreadId){throw "Hub replacement commit did not persist the exact new hub."}};$now=[DateTimeOffset]::UtcNow;$lease.schemaVersion=2;$lease.phase="hub_replacement_retiring_old";$lease.renewedAt=$now.ToString("o",[Globalization.CultureInfo]::InvariantCulture);$lease.expiresAt=$now.AddSeconds(300).ToString("o",[Globalization.CultureInfo]::InvariantCulture);Write-BootstrapLockRecord $lock.Handle $lease;$result=ConvertTo-HubResult $snapshot (-not$already) $already;[Console]::Out.WriteLine(($result|ConvertTo-Json -Compress))}finally{Exit-BootstrapLock $lock}}

function Invoke-Probe([string]$Target="."){
 Set-FlowContext $Target
 $manifestPath=Resolve-TargetPath $script:ManifestRelative -AllowControl
 if(-not(Test-Path -LiteralPath $manifestPath)){Write-Output '{"managed":false}';return}
 $manifest=Read-JsonFile $manifestPath $script:ManifestRelative
 if($manifest.schema_version-ne1-or[string]$manifest.workflow_version-notmatch'^\d+\.\d+\.\d+$'-or[string]::IsNullOrWhiteSpace([string]$manifest.project_name)-or$manifest.files-isnot[Array]){throw "Manifest probe contract is invalid"}
 Confirm-ProjectName ([string]$manifest.project_name)|Out-Null
 $last=if(Test-Property $manifest 'last_transaction'){$manifest.last_transaction}else{$null}
 Write-Output ([ordered]@{managed=$true;workflow_version=[string]$manifest.workflow_version;project_name=[string]$manifest.project_name;managed_files=@($manifest.files).Count;last_transaction=$last}|ConvertTo-Json -Compress)
}

function Invoke-Install {[CmdletBinding()]param([string]$Target=".",[string]$ProjectName="",[switch]$Force,[switch]$DryRun)
 Set-FlowContext $Target $ProjectName;$targetRoot=$script:FlowContext.TargetRoot;$templateRoot=$script:PluginRoot;$controlRootName=$script:ControlRootName;$manifestRelative=$script:ManifestRelative;$backupRootName=$script:BackupRootName
if ([string]::IsNullOrWhiteSpace($ProjectName)) { $ProjectName = Split-Path -Leaf $targetRoot }
$ProjectName = Confirm-ProjectName $ProjectName

$script:FlowContext.ProjectName = $ProjectName
$contract = Get-CurrentManagedContract
$workflowVersion = $contract.Version
$rawEntries = $contract.Entries
$entries = [Collections.Generic.List[object]]::new()
foreach ($raw in $rawEntries) {
 $sourcePath=Resolve-PluginPath ([string]$raw.source) "managed source";$sourceText=Read-NormalizedText $sourcePath ([string]$raw.source)
 $entries.Add([pscustomobject]@{Path=[string]$raw.path;Source=[string]$raw.source;Policy=[string]$raw.policy;Render=[string]$raw.render;SourcePath=$sourcePath;Rendered=Render-Template $sourceText ([string]$raw.render) $ProjectName})
}
$manifestPath = Resolve-TargetPath $manifestRelative -AllowControl
$manifestExisted = Test-SafeFile $manifestPath "Manifest"
$hadExistingManaged = $false
foreach ($entry in $entries) {
    $destination = Resolve-TargetPath $entry.Path
    if (Test-SafeFile $destination "Destination") { $hadExistingManaged = $true }
}

$legacyWithoutManifest = -not $Force -and -not $manifestExisted -and $hadExistingManaged
if ($legacyWithoutManifest -and -not $DryRun) {
    Write-Host "NOTICE Existing managed files were found without a manifest."
    Write-Host "NOTICE The files will keep normal non-force skip behavior, but the manifest will not be initialized."
    Write-Host "NOTICE Manifest-free adoption is not supported; restore a 0.8.3-or-newer manifest or perform a clean installation."
}

$backupStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRelative = "$backupRootName/$backupStamp"
$backupRoot = Resolve-TargetPath $backupRelative -AllowControl
$backupSuffix = 0
while (Test-Path -LiteralPath $backupRoot) {
    $backupSuffix++
    $backupRelative = "$backupRootName/$backupStamp-$backupSuffix"
    $backupRoot = Resolve-TargetPath $backupRelative -AllowControl
}

$created = 0
$replaced = 0
$skipped = 0
$written = 0
$manifestBackedUp = $false
$installState = [pscustomobject]@{ ManifestChanged = $false }
$writeRecords = New-Object System.Collections.Generic.List[object]

function Backup-File([string]$Source, [string]$RelativePath) {
    $backup = Resolve-TargetPath "$backupRelative/$RelativePath" -AllowControl
    Ensure-SafeDirectory (Split-Path -Parent $backup)
    [System.IO.File]::WriteAllBytes($backup, [System.IO.File]::ReadAllBytes($Source))
}

function Restore-InstallChanges {
    for ($index = $writeRecords.Count - 1; $index -ge 0; $index--) {
        $record = $writeRecords[$index]
        $destination = Resolve-TargetPath $record.Path
        if ($record.Existed) {
            $backup = Resolve-TargetPath "$backupRelative/$($record.Path)" -AllowControl
            [System.IO.File]::WriteAllBytes($destination, [System.IO.File]::ReadAllBytes($backup))
        } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            [System.IO.File]::Delete($destination)
        }
    }
    if ($installState.ManifestChanged) {
        if ($manifestExisted) {
            $backupManifest = Resolve-TargetPath "$backupRelative/$manifestRelative" -AllowControl
            [System.IO.File]::WriteAllBytes($manifestPath, [System.IO.File]::ReadAllBytes($backupManifest))
        } elseif (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            [System.IO.File]::Delete($manifestPath)
        }
        $installState.ManifestChanged = $false
    }
    Write-Warning "Restored install changes after validation failure."
}

$mutationLock = if ($DryRun) { $null } else { Enter-TransactionLock }
try {
if ($Force -and $manifestExisted -and -not $DryRun) {
    Backup-File $manifestPath $manifestRelative
    $manifestBackedUp = $true
}

try {
    foreach ($entry in $entries) {
        $destination = Resolve-TargetPath $entry.Path
        $exists = Test-SafeFile $destination "Destination"
        if ($exists -and -not $Force) {
            Write-Host "SKIP  $($entry.Path) (already exists)"
            $skipped++
            continue
        }
        if ($DryRun) {
            $verb = if ($exists) { "REPLACE" } else { "CREATE " }
            Write-Host "$verb $($entry.Path)"
            continue
        }
        if ($exists) {
            Backup-File $destination $entry.Path
            $replaced++
        } else {
            $created++
        }
        $writeRecords.Add([pscustomobject]@{ Path = $entry.Path; Existed = $exists })
        Write-AtomicText $destination $entry.Rendered
        $written++
        Write-Host "WRITE $($entry.Path)"
    }
} catch {
    if (-not $DryRun) { Restore-InstallChanges }
    throw
}

if ($DryRun) {
    if ($Force) {
        Write-Host "DRY RUN manifest reset was not performed."
    } elseif ($manifestExisted) {
        Write-Host "PRESERVE $manifestRelative (already exists; dry run)"
    } elseif ($legacyWithoutManifest) {
        Write-Host "MANIFEST NOT INITIALIZED; manifest-free adoption is not supported."
    } else {
        Write-Host "DRY RUN manifest initialization was not performed."
    }
    Write-Host "Dry run complete; no files changed and the manifest was not created or replaced."
    return 0
}

Write-Host "Installed: created=$created replaced=$replaced skipped=$skipped"
if (Test-Path -LiteralPath $backupRoot -PathType Container) {
    Write-Host "Backups: $backupRoot"
}

if (-not $Force) {
    if (-not (Invoke-Validation -Target $targetRoot -Runtime)) { Restore-InstallChanges; throw "Post-install validation failed." }
}

$initializeManifest = $false
$replaceManifest = $false
if ($Force) {
    if ($written -ne $entries.Count) {
        Restore-InstallChanges
        throw "Force reset did not render every managed file; manifest was preserved."
    }
    $initializeManifest = $true
    $replaceManifest = $manifestExisted
} elseif ($manifestExisted) {
    Write-Host "PRESERVE $manifestRelative (already exists)"
} elseif ($legacyWithoutManifest) {
    Write-Host "MANIFEST NOT INITIALIZED; manifest-free adoption is not supported."
} else {
    if ($written -ne $entries.Count) {
        Restore-InstallChanges
        throw "Clean install did not render every managed file; manifest was not initialized."
    }
    $initializeManifest = $true
}

if ($initializeManifest) {
    $manifestFiles = @($entries | ForEach-Object {
        $destination = Resolve-TargetPath $_.Path
        $liveText = Read-NormalizedText $destination $_.Path
        $baselineHash = Get-TextHash $_.Rendered
        if ((Get-TextHash $liveText) -ne $baselineHash) {
            Restore-InstallChanges
            throw "Installed file does not match its rendered baseline: $($_.Path)"
        }
        [ordered]@{
            path = $_.Path
            source = $_.Source
            policy = $_.Policy
            baseline_hash = $baselineHash
        }
    })
    if ($replaceManifest -and -not $manifestBackedUp) {
        Restore-InstallChanges
        throw "Refusing to replace a manifest that was not backed up."
    }
    $manifest = [ordered]@{
        schema_version = 1
        workflow_version = $workflowVersion
        project_name = $ProjectName
        installed_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        last_transaction = $null
        files = $manifestFiles
    }
    try {
        Write-AtomicText $manifestPath (($manifest | ConvertTo-Json -Depth 20) + "`n")
        $installState.ManifestChanged = $true
    } catch {
        Restore-InstallChanges
        throw
    }
    Write-Host "$(if ($replaceManifest) { 'RESET' } else { 'WRITE' }) $manifestRelative"
    if (-not (Invoke-Validation -Target $targetRoot -Runtime)) { Restore-InstallChanges; throw "Post-manifest validation failed." }
}
 return 0
} finally {
    Exit-TransactionLock $mutationLock
}
}

function Invoke-Upgrade {[CmdletBinding()]param([string]$Target=".",[switch]$Plan,[switch]$Apply,[string]$Rollback="",[string]$AdoptFrom="",[string]$ProjectName="",[string[]]$AcceptLocal=@())
 Set-FlowContext $Target $ProjectName;$targetRoot=$script:FlowContext.TargetRoot;$pluginRoot=$script:PluginRoot;$controlRootName=$script:ControlRootName;$manifestRelative=$script:ManifestRelative;$validPolicies=$script:ValidPolicies;$validOwnership=$script:ValidOwnership;$validConflictResolution=$script:ValidConflictResolution
if ($Apply -and $Plan) { throw "-Apply and -Plan are mutually exclusive." }
if ($Rollback -and ($Apply -or $Plan)) { throw "-Rollback is mutually exclusive with -Apply and -Plan." }
if ($AcceptLocal.Count -gt 0 -and -not $Apply) { throw "-AcceptLocal requires -Apply." }
function Merge-ProtectedMarkdownSections(
    [string]$LiveText,
    [string]$NewText,
    [object[]]$SectionNames,
    [string]$RelativePath
) {
    $merged = $NewText
    foreach ($rawName in $SectionNames) {
        $name = [string]$rawName
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains("`n") -or $name.Contains("`r")) {
            throw "Invalid protected Markdown section for $RelativePath"
        }
        $pattern = "(?ms)^##[ \t]+$([regex]::Escape($name))[ \t]*\n.*?(?=^##[ \t]+|\z)"
        $liveMatches = [regex]::Matches($LiveText, $pattern)
        $newMatches = [regex]::Matches($merged, $pattern)
        if ($liveMatches.Count -ne 1 -or $newMatches.Count -ne 1) {
            throw "Protected Markdown section '$name' must appear exactly once in local and upstream $RelativePath"
        }
        $match = $newMatches[0]
        $merged = $merged.Remove($match.Index, $match.Length).Insert($match.Index, $liveMatches[0].Value)
    }
    return $merged
}

function New-TransactionId {
    return (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + "-$PID-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Resolve-TransactionRoot([string]$Identifier) {
    if ($Identifier -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw "Invalid transaction identifier." }
    return Resolve-TargetPath "$controlRootName/transactions/$Identifier" -AllowControl
}

function Remove-PreparedTransaction([string]$Identifier) {
    $root = Resolve-TransactionRoot $Identifier
    $item = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Prepared transaction root is unsafe: $Identifier" }
    foreach ($child in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Prepared transaction contains a reparse point: $($child.FullName)" }
    }
    [IO.Directory]::Delete($root,$true)
}

$contract=Get-CurrentManagedContract
$newVersion=$contract.Version
$entries=@($contract.Entries)
$seen=$contract.Seen

function Get-VersionPathMap([string]$Version){$map=@{};$sourceEntries=if($Version-eq$newVersion){$entries}else{(Get-BaselineContract $Version).Entries};foreach($entry in $sourceEntries){$map[[string]$entry.path]=$true};return $map}

function Get-VerifiedManagedSnapshot([object]$PlanItem,[string]$Stage) {
    $path = Resolve-TargetPath $PlanItem.Path
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))) {
        throw "Managed target changed to a non-regular file $Stage`: $($PlanItem.Path)"
    }
    $bytes = if ($item) { [IO.File]::ReadAllBytes($path) } else { $null }
    $hash = if ($item) { Get-TextHash (ConvertFrom-Utf8Bytes $bytes $PlanItem.Path) } else { $null }
    if ($hash -cne $PlanItem.LiveHash) { throw "Managed target changed $Stage`; refusing apply: $($PlanItem.Path)" }
    return [pscustomobject]@{ Path = $path; Exists = ($null -ne $item); Bytes = $bytes; Hash = $hash }
}

function Get-VerifiedManifestSnapshot([AllowNull()][object]$ExpectedHash,[string]$Stage) {
    $item = Get-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))) {
        throw "Manifest changed to a non-regular file $Stage."
    }
    $bytes = if ($item) { [IO.File]::ReadAllBytes($manifestPath) } else { $null }
    $text = if ($item) { ConvertFrom-Utf8Bytes $bytes $manifestRelative } else { $null }
    $hash = if ($item) { Get-TextHash $text } else { $null }
    if ($hash -cne $ExpectedHash) { throw "Manifest changed $Stage`; refusing apply." }
    return [pscustomobject]@{ Exists = ($null -ne $item); Bytes = $bytes; Text = $text; Hash = $hash }
}

$manifestPath = Resolve-TargetPath $manifestRelative -AllowControl
$manifest = $null
$plannedManifestHash = $null
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $plannedManifestText = Read-NormalizedText $manifestPath $manifestRelative
    $manifest = ConvertFrom-JsonObjectText $plannedManifestText $manifestRelative
    $plannedManifestHash = Get-TextHash $plannedManifestText
    if ($manifest.schema_version -ne 1) { throw "Unsupported manifest schema." }
    if ($AdoptFrom) { throw "-AdoptFrom is only valid when the target has no manifest." }
} elseif (-not $Rollback) {
    if ($AdoptFrom) { throw "Manifest-free adoption is no longer supported; the minimum supported upgrade is 0.8.3 with a valid manifest." }
    throw "Missing .project-flow/manifest.json; the minimum supported upgrade is 0.8.3 with a valid manifest."
}

function Invoke-TransactionRollback([string]$Identifier,[bool]$Automatic=$false,[string[]]$AppliedPaths=$null,[bool]$ManifestWritten=$true) {
    $transactionRoot = Resolve-TransactionRoot $Identifier
    $metaPath = Join-Path $transactionRoot "transaction.json"
    $rootItem = Get-Item -LiteralPath $transactionRoot -Force -ErrorAction SilentlyContinue
    if ($null -eq $rootItem -or -not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Transaction does not exist or is unsafe: $Identifier"
    }
    $metaText = Read-NormalizedText $metaPath "transaction.json"
    $meta = ConvertFrom-JsonObjectText $metaText "transaction.json"
    $metaPreflightHash = Get-TextHash $metaText
    if ($meta.schema_version -ne 1 -or $meta.transaction_id -ne $Identifier -or $meta.target -ne $targetRoot) {
        throw "Invalid transaction metadata."
    }
    if ($meta.state -eq "rolled_back") {
        Write-Host "NOOP transaction already rolled back: $Identifier"
        return
    }
    if (@("prepared", "validating", "applied") -notcontains [string]$meta.state) {
        throw "Transaction is not rollback-eligible: $($meta.state)"
    }

    $fromPaths = Get-VersionPathMap ([string]$meta.from_version)
    $toPaths = Get-VersionPathMap ([string]$meta.to_version)
    $allowedTransactionPaths = @{}
    foreach ($relative in @($fromPaths.Keys) + @($toPaths.Keys)) { $allowedTransactionPaths[$relative] = $true }
    if ($meta.removed_files -isnot [System.Array]) { throw "Transaction removed_files must be an array." }
    $expectedRemoved = @($fromPaths.Keys | Where-Object { -not $toPaths.ContainsKey($_) } | Sort-Object)
    $actualRemoved = @($meta.removed_files | ForEach-Object { [string]$_ } | Sort-Object)
    if (($expectedRemoved -join "`n") -cne ($actualRemoved -join "`n")) { throw "Transaction removed_files do not match version contracts." }
    $decisions = New-Object System.Collections.Generic.List[object]
    $appliedFilter = if ($null -ne $AppliedPaths) { @{} } else { $null }
    if ($null -ne $appliedFilter) { foreach ($path in $AppliedPaths) { $appliedFilter[[string]$path] = $true } }
    if ($meta.files -isnot [System.Array]) { throw "Transaction files must be an array." }
    $recordPaths = @{}
    foreach ($record in @($meta.files)) {
        if (-not (Test-Property $record "path") -or -not $allowedTransactionPaths.ContainsKey([string]$record.path) -or $recordPaths.ContainsKey([string]$record.path)) {
            throw "Transaction contains an invalid or duplicate managed path."
        }
        if ($record.changed -isnot [bool] -or $record.existed -isnot [bool]) { throw "Transaction changed/existed fields must be booleans: $($record.path)" }
        $recordPaths[[string]$record.path] = $true
        if (-not $record.changed) { continue }
        if ($null -ne $appliedFilter -and -not $appliedFilter.ContainsKey([string]$record.path)) { continue }
        $live = Resolve-TargetPath ([string]$record.path)
        $liveItem = Get-Item -LiteralPath $live -Force -ErrorAction SilentlyContinue
        if ($liveItem -and ($liveItem.PSIsContainer -or (($liveItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
            throw "Rollback target is not a regular file: $($record.path)"
        }
        $currentHash = if ($liveItem) { Get-FileHashNormalized $live ([string]$record.path) } else { $null }
        if ($currentHash -eq $record.applied_hash) {
            $decisions.Add([pscustomobject]@{ Record = $record; Live = $live; Decision = "restore"; PreflightHash = $currentHash; BackupBytes = $null })
        } elseif ($currentHash -eq $record.original_hash) {
            $decisions.Add([pscustomobject]@{ Record = $record; Live = $live; Decision = "unchanged"; PreflightHash = $currentHash; BackupBytes = $null })
        } else {
            throw "Refusing rollback because a live file changed after apply: $($record.path)"
        }
    }
    if ($recordPaths.Count -ne $allowedTransactionPaths.Count) { throw "Transaction file records do not match version contracts." }

    if ($Automatic -and -not $ManifestWritten) {
        $manifestDecision = "unchanged"
        $manifestPreflightHash = $null
    } else {
        $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        $manifestCurrent = if ($manifestItem -and -not $manifestItem.PSIsContainer) { Get-FileHashNormalized $manifestPath $manifestRelative } else { $null }
        $manifestPreflightHash = $manifestCurrent
        if ($manifestCurrent -eq $meta.new_manifest_hash) {
            $manifestDecision = "restore"
        } elseif ($manifestCurrent -eq $meta.old_manifest_hash) {
            $manifestDecision = "unchanged"
        } else {
            throw "Refusing rollback because the manifest changed after apply (transaction=$Identifier manifest=$manifestPath current=$manifestCurrent expected=$($meta.new_manifest_hash))."
        }
    }

    Write-Host "ROLLBACK PREFLIGHT $Identifier"
    # Phase 1: authenticate every backup that could be consumed before restoring any live path.
    foreach ($decision in $decisions) {
        if ($decision.Decision -eq "unchanged") { continue }
        $record = $decision.Record
        if ($record.existed) {
            $backup = Resolve-TargetPath "$controlRootName/transactions/$Identifier/backup/$($record.path)" -AllowControl
            if (-not (Test-SafeFile $backup "backup for $($record.path)")) { throw "Backup is missing for $($record.path)" }
            $bytes = [IO.File]::ReadAllBytes($backup)
            $text = ConvertFrom-Utf8Bytes $bytes "backup for $($record.path)"
            if ((Get-TextHash $text) -ne $record.original_hash) { throw "Backup hash mismatch for $($record.path)" }
            $decision.BackupBytes = $bytes
        }
    }
    $manifestBackupBytes = $null
    if ($manifestDecision -eq "restore") {
        if ($null -ne $meta.old_manifest_hash) {
            $backupManifest = Resolve-TargetPath "$controlRootName/transactions/$Identifier/backup/$controlRootName/manifest.json" -AllowControl
            if (-not (Test-SafeFile $backupManifest "manifest backup")) { throw "Manifest backup is missing." }
            $manifestBackupBytes = [IO.File]::ReadAllBytes($backupManifest)
            $text = ConvertFrom-Utf8Bytes $manifestBackupBytes "manifest backup"
            if ((Get-TextHash $text) -ne $meta.old_manifest_hash) { throw "Manifest backup hash mismatch." }
        }
    }

    foreach ($decision in $decisions) {
        $liveItem = Get-Item -LiteralPath $decision.Live -Force -ErrorAction SilentlyContinue
        if ($liveItem -and ($liveItem.PSIsContainer -or (($liveItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))) { throw "Rollback target changed during preflight: $($decision.Record.path)" }
        $currentHash = if ($liveItem) { Get-FileHashNormalized $decision.Live ([string]$decision.Record.path) } else { $null }
        if ($currentHash -cne $decision.PreflightHash) { throw "Rollback target changed during preflight: $($decision.Record.path)" }
    }
    if (-not ($Automatic -and -not $ManifestWritten)) {
        $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        if ($manifestItem -and ($manifestItem.PSIsContainer -or (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))) { throw "Manifest changed during rollback preflight." }
        $currentManifestHash = if ($manifestItem) { Get-FileHashNormalized $manifestPath $manifestRelative } else { $null }
        if ($currentManifestHash -cne $manifestPreflightHash) { throw "Manifest changed during rollback preflight." }
    }
    if ((Get-FileHashNormalized $metaPath "transaction.json") -cne $metaPreflightHash) { throw "Transaction metadata changed during rollback preflight." }

    # Phase 2: recheck each live precondition immediately before its restore.
    foreach ($decision in $decisions) {
        if ($decision.Decision -eq "unchanged") { continue }
        $record = $decision.Record
        $liveItem = Get-Item -LiteralPath $decision.Live -Force -ErrorAction SilentlyContinue
        if ($liveItem -and ($liveItem.PSIsContainer -or (($liveItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))) { throw "Rollback target changed after preflight: $($record.path)" }
        $currentHash = if ($liveItem) { Get-FileHashNormalized $decision.Live ([string]$record.path) } else { $null }
        if ($currentHash -cne $decision.PreflightHash) { throw "Rollback target changed after preflight: $($record.path)" }
        if ($record.existed) {
            Write-AtomicBytes $decision.Live $decision.BackupBytes
        } elseif ($liveItem) {
            Remove-Item -LiteralPath $decision.Live -Force
            Remove-EmptyParents $decision.Live
        }
    }

    if ($manifestDecision -eq "restore") {
        $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        if ($manifestItem -and ($manifestItem.PSIsContainer -or (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))) { throw "Manifest changed after rollback preflight." }
        $currentManifestHash = if ($manifestItem) { Get-FileHashNormalized $manifestPath $manifestRelative } else { $null }
        if ($currentManifestHash -cne $manifestPreflightHash) { throw "Manifest changed after rollback preflight." }
        if ($null -eq $meta.old_manifest_hash) {
            if ($manifestItem) { Remove-Item -LiteralPath $manifestPath -Force }
        } else {
            Write-AtomicBytes $manifestPath $manifestBackupBytes
        }
    }

    $meta.state = "rolled_back"
    $meta | Add-Member -NotePropertyName rolled_back_at_utc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
    $meta | Add-Member -NotePropertyName automatic_rollback -NotePropertyValue $Automatic -Force
    Write-AtomicText $metaPath (($meta | ConvertTo-Json -Depth 20) + "`n")
    Write-Host "ROLLED_BACK $Identifier"
}

if ($Rollback) {
    if ($AdoptFrom -or $ProjectName) { throw "Rollback does not accept adoption or project-name options." }
    $mutationLock = Enter-TransactionLock
    try {
        Invoke-TransactionRollback $Rollback
        return 0
    } finally {
        Exit-TransactionLock $mutationLock
    }
}

if ($ProjectName) {
    $resolvedProjectName = Confirm-ProjectName $ProjectName
} else {
    if (Test-Property $manifest "project_name") {
        $resolvedProjectName = Confirm-ProjectName ([string]$manifest.project_name)
    } elseif ((Test-Property $manifest "project") -and (Test-Property $manifest.project "name")) {
        $resolvedProjectName = Confirm-ProjectName ([string]$manifest.project.name)
    } else {
        throw "Manifest project_name is missing."
    }
}

$installedVersion = [string]$manifest.workflow_version
if ([string]::IsNullOrWhiteSpace($installedVersion)) { throw "Manifest workflow_version is missing." }
$introduced = @{}
$removed = @{}
$oldEntries = @()
$oldSeen = @{}
if($installedVersion-ne$newVersion){$baselineContract=Get-BaselineContract $installedVersion;$oldEntries=@($baselineContract.Entries);foreach($oldEntry in $oldEntries){$oldSeen[[string]$oldEntry.path]=$oldEntry};foreach($relative in $seen.Keys){if(-not$oldSeen.ContainsKey($relative)){$introduced[$relative]=$true}};foreach($relative in $oldSeen.Keys){if(-not$seen.ContainsKey($relative)){$removed[$relative]=$oldSeen[$relative]}}}else{$oldEntries=$entries;foreach($entry in $entries){$oldSeen[[string]$entry.path]=$entry}}

$manifestEntries = @{}
if ($null -ne $manifest) {
    $rawEntries = if (Test-Property $manifest "files") { @($manifest.files) } elseif (Test-Property $manifest "managed_files") { @($manifest.managed_files) } else { @() }
    foreach ($item in $rawEntries) {
        if ((Test-Property $item "path") -and -not [string]::IsNullOrWhiteSpace([string]$item.path)) {
            if ($manifestEntries.ContainsKey([string]$item.path)) { throw "Manifest contains a duplicate path: $($item.path)" }
            $manifestEntries[[string]$item.path] = $item
        }
    }
    $expectedManifestPaths = @($oldSeen.Keys)
    if ($manifestEntries.Count -ne $expectedManifestPaths.Count) { throw "Manifest managed paths do not match managed-files.json." }
    foreach ($relative in $expectedManifestPaths) {
        if (-not $manifestEntries.ContainsKey($relative)) { throw "Manifest managed paths do not match managed-files.json." }
        $recordedHash = [string]$manifestEntries[$relative].baseline_hash
        if ($recordedHash -notmatch '^sha256:[0-9a-f]{64}$') { throw "Manifest baseline_hash is missing or invalid for $relative" }
        $contractEntry = $oldSeen[$relative]
        if ([string]$manifestEntries[$relative].source -cne [string]$contractEntry.source -or
            [string]$manifestEntries[$relative].policy -cne [string]$contractEntry.policy) {
            throw "Manifest source or policy does not match managed-files.json for $relative"
        }
        if ($installedVersion -ne $newVersion) {
            $baselinePath = Resolve-PluginPath "baselines/$installedVersion/$relative" "baseline $relative"
            $baselineText = Render-Template (Read-NormalizedText $baselinePath "baseline $relative") ([string]$contractEntry.render) $resolvedProjectName
            if ($recordedHash -cne (Get-TextHash $baselineText)) { throw "Manifest baseline hash does not match the immutable baseline for $relative" }
        }
    }
}

$plans = New-Object System.Collections.Generic.List[object]
foreach ($entry in $entries) {
    $relative = [string]$entry.path
    $live = Resolve-TargetPath $relative
    $liveItem = Get-Item -LiteralPath $live -Force -ErrorAction SilentlyContinue
    if ($liveItem -and ($liveItem.PSIsContainer -or (($liveItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
        throw "Managed target is not a regular file: $relative"
    }
    $sourcePath = Resolve-PluginPath ([string]$entry.source) "managed source"
    $newText = Render-Template (Read-NormalizedText $sourcePath ([string]$entry.source)) ([string]$entry.render) $resolvedProjectName
    $newHash = Get-TextHash $newText
    if ($installedVersion -eq $newVersion) {
        $baseText = $newText
    } elseif ($introduced.ContainsKey($relative)) {
        $baseText = $null
    } else {
        $baselinePath = Resolve-PluginPath "baselines/$installedVersion/$relative" "baseline $relative"
        $oldEntry = $oldSeen[$relative]
        $baseText = Render-Template (Read-NormalizedText $baselinePath "baseline $relative") ([string]$oldEntry.render) $resolvedProjectName
    }
    $baseHash = if ($null -ne $baseText) { Get-TextHash $baseText } else { $null }
    if ($manifestEntries.ContainsKey($relative) -and (Test-Property $manifestEntries[$relative] "baseline_hash")) {
        if ($manifestEntries[$relative].baseline_hash -ne $baseHash) { throw "Manifest baseline hash does not match the immutable baseline for $relative" }
    }
    $liveText = if ($liveItem) { Read-NormalizedText $live $relative } else { $null }
    $liveHash = if ($null -ne $liveText) { Get-TextHash $liveText } else { $null }
    $appliedText = $liveText
    if ($null -eq $liveText) {
        $action = "CREATE"
        $appliedText = $newText
    } elseif ($null -eq $baseText) {
        $action = if ($liveHash -eq $newHash) { "NOOP" } else { "CONFLICT" }
    } elseif ($entry.policy -eq "seed_once") {
        $action = if ($liveHash -eq $newHash) { "NOOP" } else { "PRESERVE" }
    } elseif ($liveHash -eq $newHash) {
        $action = "NOOP"
    } elseif ($liveHash -eq $baseHash) {
        $action = "REPLACE"
        $appliedText = $newText
    } elseif ($baseHash -eq $newHash) {
        $action = "PRESERVE"
    } elseif ($entry.conflict_resolution -eq "upstream_wins") {
        $action = "UPSTREAM"
        $appliedText = $newText
    } elseif ($entry.conflict_resolution -eq "preserve_markdown_sections") {
        $action = "MERGE"
        $appliedText = Merge-ProtectedMarkdownSections $liveText $newText @($entry.preserve_sections) $relative
    } elseif ($entry.conflict_resolution -eq "preserve") {
        $action = "PRESERVE"
    } else {
        $action = "CONFLICT"
    }
    $plans.Add([pscustomobject]@{
        Path = $relative; Source = [string]$entry.source; Policy = [string]$entry.policy
        Ownership = [string]$entry.ownership; ConflictResolution = [string]$entry.conflict_resolution; Action = $action
        BaseHash = $baseHash; LiveHash = $liveHash; NewHash = $newHash
        BaseText = $baseText; LiveText = $liveText; NewText = $newText; AppliedText = $appliedText
    })
}
foreach ($relative in @($removed.Keys | Sort-Object)) {
    $entry = $removed[$relative]
    $live = Resolve-TargetPath $relative
    $liveItem = Get-Item -LiteralPath $live -Force -ErrorAction SilentlyContinue
    if ($liveItem -and ($liveItem.PSIsContainer -or (($liveItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
        throw "Retired target is not a regular file: $relative"
    }
    $baselinePath = Resolve-PluginPath "baselines/$installedVersion/$relative" "removed-file baseline"
    $baseText = Render-Template (Read-NormalizedText $baselinePath "removed-file baseline $relative") ([string]$entry.render) $resolvedProjectName
    $baseHash = Get-TextHash $baseText
    $liveText = if ($liveItem) { Read-NormalizedText $live $relative } else { $null }
    $liveHash = if ($null -ne $liveText) { Get-TextHash $liveText } else { $null }
    $plans.Add([pscustomobject]@{
        Path = $relative; Source = [string]$entry.source; Policy = [string]$entry.policy
        Ownership = "plugin"; ConflictResolution = "retire"; Action = if ($liveItem) { "DELETE" } else { "REMOVE_NOOP" }
        BaseHash = $baseHash; LiveHash = $liveHash; NewHash = $null
        BaseText = $baseText; LiveText = $liveText; NewText = $null; AppliedText = $null; IsRemoved = $true
    })
}

$acceptedLocalPaths = @{}
foreach ($rawPath in $AcceptLocal) {
    $relative = [string]$rawPath
    if (-not (Test-SafeRelative $relative)) { throw "Unsafe -AcceptLocal path: $relative" }
    if ($acceptedLocalPaths.ContainsKey($relative)) { throw "Duplicate -AcceptLocal path: $relative" }
    $acceptedLocalPaths[$relative] = $true
    $matchingPlans = @($plans | Where-Object { $_.Path -ceq $relative })
    if ($matchingPlans.Count -ne 1) { throw "-AcceptLocal path is not managed: $relative" }
    if ($matchingPlans[0].Action -cne "CONFLICT") { throw "-AcceptLocal is valid only for a current conflict: $relative" }
    $matchingPlans[0].Action = "ACCEPT"
    $matchingPlans[0].AppliedText = $matchingPlans[0].LiveText
}

Write-Host "UPGRADE $installedVersion -> $newVersion"
Write-Host "TARGET $targetRoot"
foreach ($item in $plans) { Write-Host (("{0,-8} {1,-22} {2}" -f $item.Action, $item.Policy, $item.Path)) }
$conflicts = @($plans | Where-Object { $_.Action -eq "CONFLICT" })
$changes = @($plans | Where-Object { @("CREATE", "REPLACE", "UPSTREAM", "MERGE", "DELETE") -contains $_.Action })
if ($Apply) {
    foreach ($item in $plans) {
        Get-VerifiedManagedSnapshot $item "after planning" | Out-Null
    }
    Get-VerifiedManifestSnapshot $plannedManifestHash "after planning" | Out-Null
}
if (-not $Apply) {
    Write-Host "PLAN changes=$($changes.Count) conflicts=$($conflicts.Count)"
    return 0
}

$mutationLock = Enter-TransactionLock
try {
foreach ($item in $plans) { Get-VerifiedManagedSnapshot $item "after lock acquisition" | Out-Null }
Get-VerifiedManifestSnapshot $plannedManifestHash "after lock acquisition" | Out-Null

if ($conflicts.Count -gt 0) {
    $identifier = New-TransactionId
    $staging = Resolve-TargetPath "$controlRootName/staging/$identifier" -AllowControl
    if (Test-Path -LiteralPath $staging) { throw "Staging transaction already exists: $identifier" }
    Ensure-SafeDirectory $staging
    $publicConflicts = @($conflicts | ForEach-Object {
        [pscustomobject]@{ path = $_.Path; policy = $_.Policy; ownership = $_.Ownership; conflict_resolution = $_.ConflictResolution; base_hash = $_.BaseHash; live_hash = $_.LiveHash; new_hash = $_.NewHash }
    })
    $publicPlan = [ordered]@{ schema_version = 1; transaction_id = $identifier; from_version = $installedVersion; to_version = $newVersion; conflicts = $publicConflicts }
    Write-AtomicText (Join-Path $staging "plan.json") (($publicPlan | ConvertTo-Json -Depth 20) + "`n")
    foreach ($item in $conflicts) {
        $bundle = Join-Path (Join-Path $staging "conflicts") ($item.Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        Ensure-SafeDirectory $bundle
        if ($null -ne $item.BaseText) { Write-AtomicText (Join-Path $bundle "base") $item.BaseText }
        if ($null -ne $item.LiveText) { Write-AtomicText (Join-Path $bundle "local") $item.LiveText }
        Write-AtomicText (Join-Path $bundle "upstream") $item.NewText
    }
    Write-Error "Conflicts staged at $(Join-Path $staging 'conflicts'); live managed files and manifest were not changed." -ErrorAction Continue
    return 4
}

if ($changes.Count -eq 0 -and $installedVersion -eq $newVersion -and $null -ne $manifest) {
    if(-not(Invoke-Validation -Target $targetRoot -Runtime)){throw "Current installation failed validation; refusing NOOP."}
    Write-Host "NOOP already up to date"
    return 0
}

$identifier = New-TransactionId
$transactionRoot = Resolve-TransactionRoot $identifier
if (Test-Path -LiteralPath $transactionRoot) { throw "Transaction already exists: $identifier" }
$backupRoot = Join-Path $transactionRoot "backup"
Ensure-SafeDirectory $backupRoot
$records = New-Object System.Collections.Generic.List[object]
foreach ($item in $plans) {
    $snapshot = Get-VerifiedManagedSnapshot $item "during backup"
    $exists = $snapshot.Exists
    $changed = @("CREATE", "REPLACE", "UPSTREAM", "MERGE", "DELETE") -contains $item.Action
    $records.Add([pscustomobject]@{
        path = $item.Path; existed = $exists; changed = $changed; original_hash = $item.LiveHash
        applied_hash = if ($item.Action -eq "DELETE") { $null } elseif ($changed) { Get-TextHash $item.AppliedText } else { $item.LiveHash }
        resolution = $item.Action
    })
    if ($exists) {
        $backup = Join-Path $backupRoot ($item.Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        Ensure-SafeDirectory (Split-Path -Parent $backup)
        Write-AtomicBytes $backup $snapshot.Bytes
    }
}

$manifestSnapshot = Get-VerifiedManifestSnapshot $plannedManifestHash "during backup"
$oldManifestText = $manifestSnapshot.Text
$oldManifestHash = $manifestSnapshot.Hash
if ($null -ne $oldManifestText) {
    $backupManifest = Join-Path $backupRoot "$controlRootName/manifest.json"
    Ensure-SafeDirectory (Split-Path -Parent $backupManifest)
    Write-AtomicBytes $backupManifest $manifestSnapshot.Bytes
}

$now = (Get-Date).ToUniversalTime().ToString("o")
$manifestFiles = @($plans | Where-Object { -not $_.IsRemoved } | ForEach-Object {
    [ordered]@{ path = $_.Path; source = $_.Source; policy = $_.Policy; baseline_hash = $_.NewHash }
})
$newManifest = [ordered]@{
    schema_version = 1; workflow_version = $newVersion; project_name = $resolvedProjectName
    installed_at_utc = $now; last_transaction = $identifier; files = $manifestFiles
}
$newManifestText = (($newManifest | ConvertTo-Json -Depth 20) + "`n").Replace("`r`n", "`n").Replace("`r", "`n")
$meta = [ordered]@{
    schema_version = 1; transaction_id = $identifier; target = $targetRoot
    from_version = $installedVersion; to_version = $newVersion; state = "prepared"; created_at_utc = $now
    old_manifest_hash = $oldManifestHash; new_manifest_hash = (Get-TextHash $newManifestText)
    accepted_local = @($acceptedLocalPaths.Keys | Sort-Object)
    upstream_resolved = @($plans | Where-Object { $_.Action -eq "UPSTREAM" } | ForEach-Object { $_.Path } | Sort-Object)
    merged = @($plans | Where-Object { $_.Action -eq "MERGE" } | ForEach-Object { $_.Path } | Sort-Object)
    removed_files = @($removed.Keys | Sort-Object)
    files = $records.ToArray()
}
$metaPath = Join-Path $transactionRoot "transaction.json"
Write-AtomicText $metaPath (($meta | ConvertTo-Json -Depth 20) + "`n")

$appliedPaths = [Collections.Generic.List[string]]::new()
$manifestWritten = $false
try {
    foreach ($item in $plans) { Get-VerifiedManagedSnapshot $item "after transaction preparation" | Out-Null }
    Get-VerifiedManifestSnapshot $plannedManifestHash "after transaction preparation" | Out-Null
    foreach ($item in $changes) {
        $snapshot = Get-VerifiedManagedSnapshot $item "immediately before write"
        $destination = $snapshot.Path
        if ($item.Action -eq "DELETE") {
            Remove-Item -LiteralPath $destination -Force
            Remove-EmptyParents $destination
        } else {
            Write-AtomicText $destination $item.AppliedText
        }
        $appliedPaths.Add([string]$item.Path)
    }
    Get-VerifiedManifestSnapshot $plannedManifestHash "immediately before manifest write" | Out-Null
    Write-AtomicText $manifestPath $newManifestText
    $manifestWritten = $true
    $writtenManifestHash = Get-FileHashNormalized $manifestPath $manifestRelative
    if ($writtenManifestHash -ne $meta.new_manifest_hash) {
        throw "Written manifest hash mismatch (current=$writtenManifestHash expected=$($meta.new_manifest_hash))."
    }
    $meta["state"] = "validating"
    Write-AtomicText $metaPath (($meta | ConvertTo-Json -Depth 20) + "`n")
    if(-not(Invoke-Validation -Target $targetRoot -Runtime)){throw "Post-upgrade validation failed."}
    $meta["state"] = "applied"
    $meta["validated_at_utc"] = (Get-Date).ToUniversalTime().ToString("o")
    Write-AtomicText $metaPath (($meta | ConvertTo-Json -Depth 20) + "`n")
} catch {
    $applyError = $_.Exception.Message
    Write-Error "Apply failed; attempting automatic rollback: $applyError" -ErrorAction Continue
    try {
        if ($appliedPaths.Count -eq 0 -and -not $manifestWritten) {
            Remove-PreparedTransaction $identifier
        } else {
            Invoke-TransactionRollback -Identifier $identifier -Automatic $true -AppliedPaths $appliedPaths.ToArray() -ManifestWritten $manifestWritten
        }
    } catch {
        throw "Apply failed ($applyError) and automatic rollback also failed: $($_.Exception.Message)"
    }
    return 5
}

Write-Host "APPLIED $identifier"
Write-Host "VALIDATION passed"
return 0
} finally {
    Exit-TransactionLock $mutationLock
}
}

function Invoke-Validation {
    [CmdletBinding()]
    param([string]$Target = ".", [switch]$AllowPlaceholders, [switch]$Runtime)
$errors = [Collections.Generic.List[string]]::new()
Set-FlowContext $Target
$pluginRoot=$script:PluginRoot
$targetRoot=$script:FlowContext.TargetRoot
function Fail([string]$m){$errors.Add($m)}
function Json([string]$p,[string]$n){try{Read-JsonFile $p $n}catch{Fail $_.Exception.Message;$null}}
function Text([string]$p){Read-NormalizedText $p $p}
function Hash([string]$s){Get-TextHash $s}
function Render([string]$s,[string]$m,[string]$n){Render-Template $s $m $n}
function Eq($a,$b,[string]$n){if($a-is[Array]-or$b-is[Array]){if((@($a)-join"`n")-cne(@($b)-join"`n")){Fail "$n invalid"}}elseif($a-cne$b){Fail "$n must be $b"}}
function Markdown([string]$p,[string]$n){if([IO.Path]::GetExtension($p)-cne".md"){Fail "$n must use .md";return};$first=$null;$previous=0;$fence=$null;foreach($line in (Text $p).Split("`n")){if($line-match'^\s*(```|~~~)'){$marker=$matches[1];if($null-eq$fence){$fence=$marker}elseif($fence-ceq$marker){$fence=$null};continue};if($null-ne$fence){continue};if($line-match'^(#{1,6})[ \t]+\S'){$level=$matches[1].Length;if($null-eq$first){$first=$level;if($level-ne1){Fail "$n first heading must be #"}}elseif($level-gt($previous+1)){Fail "$n heading levels must not skip"};$previous=$level}};if($null-eq$first){Fail "$n must contain a heading"}}
$contract=Get-CurrentManagedContract
$version=$contract.Version
$managed=$contract.Managed
$plugin=Json (Join-Path $pluginRoot .codex-plugin/plugin.json) plugin.json
if(([string]$plugin.version)-cne$version-and-not([string]$plugin.version).StartsWith("$version+codex.")){Fail "plugin version invalid"}

$paths=@("AGENTS.md",".agents/workflow.json",".agents/WORKFLOW_PROTOCOL.md",".agents/skills/project-workflow-manager/SKILL.md",".agents/skills/project-workflow-manager/agents/openai.yaml","docs/PROJECT_STATE.md")
$entries=@($contract.Entries);Eq @($entries.path) $paths managed-paths;$seen=$contract.Seen;$retiredPaths=@($contract.Retired)

$historical=[Collections.Generic.HashSet[string]]::new()
if(-not$Runtime){foreach($dir in Get-ChildItem -LiteralPath(Join-Path $pluginRoot baselines)-Directory){try{$baseline=Get-BaselineContract $dir.Name;foreach($e in $baseline.Entries){[void]$historical.Add([string]$e.path)};$actual=@(Get-ChildItem $dir.FullName -Recurse -File|ForEach-Object{$_.FullName.Substring($dir.FullName.Length+1).Replace('\','/')}|Where-Object{$_-ne'managed-files.json'}|Sort-Object);Eq $actual @($baseline.Seen.Keys|Sort-Object) "baseline tree $($dir.Name)"}catch{Fail $_.Exception.Message}};Eq @($retiredPaths|Sort-Object) @($historical|Where-Object{-not$seen.ContainsKey($_)}|Sort-Object) retired-paths}

$wp=Resolve-TargetPath ".agents/workflow.json";$w=if(Test-SafeFile $wp "workflow"){Json $wp workflow}else{Fail "missing workflow";$null}
if($null-ne$w){Eq @($w.paths.PSObject.Properties.Name|Sort-Object) @("project_state","workflow_protocol") path-fields;Eq @($w.tasks.PSObject.Properties.Name|Sort-Object) @("blocked_waiting_queued_occupy_slot","hidden_subagents_may_substitute","hub_occupies_slot","management_failure","max_active","request_key","visible_execution_required") task-fields;Eq @($w.requests.PSObject.Properties.Name|Sort-Object) @("acceptance_archive","acceptance_owner","awaiting_acceptance_occupies_slot","completion_fields","confirmation_fields","execution_task_binding","handoff_boundary","hub_post_handoff","initial_owner","initial_state","post_handoff_owner","rejection_route","request_id_assignment","scope_change_route","states") request-fields;Eq @($w.execution.PSObject.Properties.Name|Sort-Object) @("different_goal","replacement","same_task_actions","scope_change","serial","supplemental_authorization") execution-fields;Eq @($w.documents.PSObject.Properties.Name|Sort-Object) @("body_structures","default_extension","first_heading","heading_progression","review","standalone_cover","validation_scope") document-fields;Eq @($w.documents.review.PSObject.Properties.Name|Sort-Object) @("approval_evidence","approval_owner","draft_delivery","exceptions","initial_state","post_write_change","rejection","required","scope","states","write_authorization") document-review-fields;Eq @($w.documents.review.exceptions.PSObject.Properties.Name|Sort-Object) @("bootstrap_managed_markdown","non_deployment_markdown","upgrade_managed_markdown") document-review-exception-fields;Eq @($w.bootstrap.PSObject.Properties.Name|Sort-Object) @("claim_title","existing_lock","fast_path","hub_replacement","lock_acquire","lock_inspect","lock_path","lock_release","lock_schema","recovery_path","registry_path","registry_schema","stale_after_seconds","stale_recovery","title_identity","unarchive") bootstrap-fields;Eq @($w.bootstrap.hub_replacement.PSObject.Properties.Name|Sort-Object) @("authorization","commit_command","key","new_hub_state","old_hub_state","ordinary_task_create","post_cas_authority","pre_cas_authority","prepare_command","recovery","registry_token","retirement_order","third_hub") hub-replacement-fields;Eq @($w.rotation.PSObject.Properties.Name|Sort-Object) @("key","mode") rotation-fields;Eq @($w.upgrade.PSObject.Properties.Name|Sort-Object) @("attempt_deadline_seconds","barrier","barrier_owner","coordinator_claim","discovery","observe","post_handoff_owner","protocol","reconcile","request_key","transaction_key","transaction_task_role","zero_active_fast_path") upgrade-fields;Eq @($w.upgrade.discovery.PSObject.Properties.Name|Sort-Object) @("fallback","history","listing") discovery-fields;Eq @($w.upgrade.reconcile.PSObject.Properties.Name|Sort-Object) @("active_snapshot") reconcile-fields;Eq @($w.upgrade.barrier.PSObject.Properties.Name|Sort-Object) @("active","cancelled","creation_gate","provisional","released") barrier-fields;Eq @($w.upgrade.observe.PSObject.Properties.Name|Sort-Object) @("include_outputs","poll_delays_seconds","poll_scan_latest_turns","stable_terminal_snapshots") observe-fields}
if($null-ne$w){Eq([int]$w.schema_version)11 workflow-schema;Eq @($w.PSObject.Properties.Name|Sort-Object) @("bootstrap","documents","execution","paths","project","requests","rotation","schema_version","tasks","upgrade") workflow-fields;Eq([string]$w.paths.project_state)"docs/PROJECT_STATE.md" project-state;Eq([string]$w.paths.workflow_protocol)".agents/WORKFLOW_PROTOCOL.md" workflow-protocol;Eq([int]$w.tasks.max_active)5 max-active;Eq([bool]$w.tasks.hub_occupies_slot)$false hub-slot;Eq([bool]$w.tasks.blocked_waiting_queued_occupy_slot)$true blocked-slot;Eq([bool]$w.tasks.visible_execution_required)$true visible-task;Eq([bool]$w.tasks.hidden_subagents_may_substitute)$false hidden-task;Eq([string]$w.tasks.management_failure)"stop" management-failure;Eq([string]$w.tasks.request_key)"[codex-project-flow:request:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; requestId=<exactRequestId>; generation=1" request-key;Eq([string]$w.requests.request_id_assignment)"hub_before_first_work_output" request-id-assignment;Eq @($w.requests.states) @("awaiting_authorization","queued","active","awaiting_acceptance","revision_pending","accepted_archived") request-states;Eq([string]$w.requests.initial_state)"awaiting_authorization" request-initial-state;Eq @($w.requests.confirmation_fields) @("understanding","execution_items") request-confirmation-fields;Eq @($w.requests.completion_fields) @("changes","verification","uncovered","risk") request-completion-fields;Eq([string]$w.requests.initial_owner)"hub" request-initial-owner;Eq([string]$w.requests.handoff_boundary)"exact_or_queued_execution_task_identity_established" request-handoff-boundary;Eq([string]$w.requests.post_handoff_owner)"execution_task" request-post-handoff-owner;Eq([string]$w.requests.hub_post_handoff)"no_participation_for_same_request" request-hub-post-handoff;Eq([string]$w.requests.execution_task_binding)"one_exact_visible_task_per_request" request-task-binding;Eq([string]$w.requests.acceptance_owner)"execution_task" request-acceptance-owner;Eq([string]$w.requests.acceptance_archive)"exact_self_archive_success_and_matching_archived_task_id_required" request-acceptance-archive;Eq([string]$w.requests.rejection_route)"execution_task_reconfirm_in_place" request-rejection-route;Eq([string]$w.requests.scope_change_route)"execution_task_reconfirm_in_place" request-scope-change-route;Eq([bool]$w.requests.awaiting_acceptance_occupies_slot)$true request-acceptance-slot;Eq @($w.execution.same_task_actions) @("inspect","modify","build","test","self_check","evidence","documentation","commit","push","external") same-task-actions;Eq([string]$w.execution.supplemental_authorization)"continue_original_task" supplemental-authorization;Eq([string]$w.execution.different_goal)"parallel_when_disjoint_and_slot_available_else_queue" different-goal;Eq([string]$w.execution.scope_change)"pause_for_execution_task_confirmation_then_continue_original_task" scope-change;Eq([string]$w.execution.replacement)"explicit_user_authorization" replacement;Eq @($w.execution.serial) @("same_request","overlapping_paths","upgrade_file_transaction") execution-serial;Eq([string]$w.documents.default_extension)".md" document-extension;Eq([bool]$w.documents.standalone_cover)$false document-cover;Eq([string]$w.documents.first_heading)"#" document-first-heading;Eq([string]$w.documents.heading_progression)"no_skipped_levels" document-heading-progression;Eq @($w.documents.body_structures) @("paragraphs","lists","tables","code_blocks") document-body-structures;Eq([string]$w.documents.validation_scope)"created_or_updated_delivery_documents" document-validation-scope;Eq([bool]$w.documents.review.required)$true document-review-required;Eq([string]$w.documents.review.scope)"all_new_or_modified_non_deployment_markdown_documents" document-review-scope;Eq([string]$w.documents.review.draft_delivery)"complete_plain_text_in_chat_before_write" document-review-draft;Eq @($w.documents.review.states) @("draft_pending_review","approved_for_write","revision_required","written") document-review-states;Eq([string]$w.documents.review.initial_state)"draft_pending_review" document-review-initial-state;Eq([string]$w.documents.review.approval_owner)"user" document-review-owner;Eq([string]$w.documents.review.approval_evidence)"explicit_user_chat_approval_bound_to_exact_path_and_content_sha256" document-review-evidence;Eq([string]$w.documents.review.write_authorization)"approved_exact_content_only" document-review-write;Eq([string]$w.documents.review.rejection)"revise_complete_draft_and_resubmit" document-review-rejection;Eq([string]$w.documents.review.post_write_change)"return_to_draft_pending_review" document-review-post-write;Eq([string]$w.documents.review.exceptions.bootstrap_managed_markdown)"no_draft_review_for_install_or_recovery" bootstrap-markdown-review-exception;Eq([string]$w.documents.review.exceptions.upgrade_managed_markdown)"no_draft_review_for_apply_resume_or_rollback" upgrade-markdown-review-exception;Eq([string]$w.documents.review.exceptions.non_deployment_markdown)"normal_review_required" non-deployment-markdown-review;Eq([string]$w.bootstrap.registry_path)".project-flow/hub.json" bootstrap-registry-path;Eq([string]$w.bootstrap.lock_path)".project-flow/bootstrap.lock" bootstrap-lock-path;Eq([int]$w.bootstrap.registry_schema)1 bootstrap-registry-schema;Eq([int]$w.bootstrap.lock_schema)2 bootstrap-lock-schema;Eq([int]$w.bootstrap.stale_after_seconds)300 bootstrap-stale-after;Eq([string]$w.bootstrap.fast_path)"registry_targeted_read" bootstrap-fast-path;Eq([string]$w.bootstrap.recovery_path)"exhaustive_metadata_on_exception" bootstrap-recovery-path;Eq([string]$w.bootstrap.title_identity)"saved_project_binding_plus_mutation_thread" bootstrap-title-identity;Eq([string]$w.bootstrap.unarchive)"only_when_explicitly_archived" bootstrap-unarchive;Eq([string]$w.bootstrap.lock_acquire)"atomic_create_new" bootstrap-lock-acquire;Eq([string]$w.bootstrap.lock_inspect)"validated_read_only" bootstrap-lock-inspect;Eq([string]$w.bootstrap.existing_lock)"inspect_then_recover_or_stop" bootstrap-existing-lock;Eq([string]$w.bootstrap.lock_release)"owner_claim_and_replacement_retirement_confirmation" bootstrap-lock-release;Eq([string]$w.bootstrap.stale_recovery)"exact_token_cas_same_thread_or_install_orphan" bootstrap-stale-recovery;Eq([string]$w.bootstrap.claim_title)"[cpf-claim] <shortClaimId>" bootstrap-claim-title;Eq([string]$w.bootstrap.hub_replacement.authorization)"explicit_current_task_replaces_exact_registry_hub" hub-replacement-authorization;Eq([string]$w.bootstrap.hub_replacement.registry_token)"sha256_raw_bytes" hub-replacement-token;Eq([string]$w.bootstrap.hub_replacement.prepare_command)"hub-replacement-prepare" hub-replacement-prepare;Eq([string]$w.bootstrap.hub_replacement.commit_command)"hub-replacement-commit" hub-replacement-commit;Eq([string]$w.bootstrap.hub_replacement.pre_cas_authority)"exact_registry_old_hub" hub-replacement-pre-cas;Eq([string]$w.bootstrap.hub_replacement.post_cas_authority)"exact_registry_new_hub" hub-replacement-post-cas;Eq([string]$w.bootstrap.hub_replacement.old_hub_state)"accessible_and_inactive" hub-replacement-old-state;Eq([string]$w.bootstrap.hub_replacement.new_hub_state)"current_task_exact_id" hub-replacement-new-state;Eq([bool]$w.bootstrap.hub_replacement.ordinary_task_create)$false hub-replacement-create;Eq @($w.bootstrap.hub_replacement.retirement_order) @("versioned_retired_title","unpin","archive") hub-replacement-retirement;Eq([string]$w.bootstrap.hub_replacement.recovery)"registry_authority_plus_lock_evidence" hub-replacement-recovery;Eq([string]$w.bootstrap.hub_replacement.third_hub)"forbidden" hub-replacement-third-hub;Eq([string]$w.bootstrap.hub_replacement.key)"[codex-project-flow:hub-replacement:v1] projectId=<exactProjectId>; expectedOldHubThreadId=<exactOldHubThreadId>; newHubThreadId=<exactCurrentThreadId>; expectedRegistryToken=<exactRegistryToken>; ownerId=<exactOwnerId>" hub-replacement-key;Eq([string]$w.rotation.mode)"explicit_user_authorization_only" rotation-mode;Eq([string]$w.rotation.key)"[codex-project-flow:execution:v3] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; requestId=<exactRequestId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>" rotation-key;Eq([int]$w.upgrade.protocol)4 upgrade-protocol;Eq([string]$w.upgrade.transaction_task_role)"visible_coordinator_executor" transaction-task-role;Eq([string]$w.upgrade.post_handoff_owner)"transaction_task" upgrade-post-handoff-owner;Eq([string]$w.upgrade.barrier_owner)"transaction_task" upgrade-barrier-owner;Eq([string]$w.upgrade.request_key)"[codex-project-flow:upgrade-request:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; requestId=<exactRequestId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>" upgrade-request-key;Eq([string]$w.upgrade.discovery.listing)"exhaustive_metadata" discovery-listing;Eq([string]$w.upgrade.discovery.history)"targeted" discovery-history;Eq([string]$w.upgrade.discovery.fallback)"full_on_ambiguity" discovery-fallback;if($w.upgrade.zero_active_fast_path-isnot[bool]){Fail "zero-active-fast-path must be boolean"}else{Eq $w.upgrade.zero_active_fast_path $true zero-active-fast-path};Eq([string]$w.upgrade.reconcile.active_snapshot)"empty_required_before_file_transaction_fail_closed" reconcile-active-snapshot;Eq([string]$w.upgrade.barrier.creation_gate)"hub_exhaustive_check_blocks_on_provisional_and_active_before_every_creation" upgrade-creation-gate;Eq([string]$w.upgrade.barrier.provisional)"[codex-project-flow:upgrade-barrier:v1] state=provisional; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>" provisional-barrier;Eq([string]$w.upgrade.barrier.active)"[codex-project-flow:upgrade-barrier:v1] state=active; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>" active-barrier;Eq([string]$w.upgrade.barrier.released)"[codex-project-flow:upgrade-barrier:v1] state=released; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>" released-barrier;Eq([string]$w.upgrade.barrier.cancelled)"[codex-project-flow:upgrade-barrier:v1] state=cancelled; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>" cancelled-barrier;Eq([string]$w.upgrade.coordinator_claim)"[codex-project-flow:upgrade-claim:v2] projectId=<exactProjectId>; requestId=<exactRequestId>; coordinatorThreadId=<exactCoordinatorThreadId>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>" coordinator-claim;Eq([string]$w.upgrade.transaction_key)"[codex-project-flow:upgrade:v1] projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>" transaction-key;Eq([int]$w.upgrade.observe.poll_scan_latest_turns)3 poll-turns;Eq([bool]$w.upgrade.observe.include_outputs)$false include-outputs;Eq([int]$w.upgrade.observe.stable_terminal_snapshots)3 stable;Eq @($w.upgrade.observe.poll_delays_seconds)@(1,2) delays;Eq([int]$w.upgrade.attempt_deadline_seconds)60 deadline;if(-not$AllowPlaceholders-and[string]$w.project.name-eq"<PROJECT_NAME>"){Fail "placeholder not rendered"}}

if(-not$Runtime){
 $skillFiles=@(Get-ChildItem -LiteralPath(Join-Path $pluginRoot skills)-Recurse -File|ForEach-Object{$_.FullName.Substring((Join-Path $pluginRoot skills).Length+1).Replace('\','/')}|Sort-Object)
 $expectedSkills=@("bootstrap-project-flow/SKILL.md","bootstrap-project-flow/agents/openai.yaml","upgrade-project-flow/SKILL.md","upgrade-project-flow/agents/openai.yaml","upgrade-project-flow/references/coordination.md","upgrade-project-flow/references/file-transaction.md")|Sort-Object
 Eq $skillFiles $expectedSkills skill-files
 $bad='任务管理(能力)?不可用时.{0,20}(回到|回退到)中枢|continue_in_hub|hub_execution_allowed|"hidden_subagents"\s*:\s*"may_substitute"'
 foreach($r in @("AGENTS.md",".agents","docs")){$p=Join-Path $targetRoot $r;$fs=if(Test-Path $p -PathType Leaf){@(Get-Item $p)}elseif(Test-Path $p -PathType Container){@(Get-ChildItem $p -Recurse -File|Where-Object Extension -in @(".md",".json"))}else{@()};foreach($f in $fs){if((Text $f.FullName)-match$bad){Fail "conflicting rule $($f.FullName)"}}}
}

foreach($e in $entries){try{$live=Resolve-TargetPath ([string]$e.path);if(-not(Test-SafeFile $live "installed $([string]$e.path)")){Fail "missing installed $([string]$e.path)"}elseif([string]$e.path-like"*.md"){Markdown $live ([string]$e.path)}}catch{Fail $_.Exception.Message}}
foreach($r in $retiredPaths){try{$retired=Resolve-TargetPath ([string]$r);if(Test-Path -LiteralPath $retired){Fail "retired file remains $r"}}catch{Fail $_.Exception.Message}}

if(-not$Runtime){foreach($relative in @("README.md","docs/TEST_CASES.md","templates/PROJECT_STATE.md","skills/bootstrap-project-flow/SKILL.md","skills/upgrade-project-flow/SKILL.md","skills/upgrade-project-flow/references/coordination.md","skills/upgrade-project-flow/references/file-transaction.md")){try{Markdown (Resolve-PluginPath $relative "delivery Markdown") $relative}catch{Fail $_.Exception.Message}}}

$mp=Resolve-TargetPath ".project-flow/manifest.json" -AllowControl
if(Test-SafeFile $mp "manifest"){$mi=Json $mp manifest;if($null-ne$mi){Eq([int]$mi.schema_version)1 manifest-schema;Eq([string]$mi.workflow_version)$version manifest-version;Eq @($mi.files.path)$paths manifest-paths;$name=[string]$mi.project_name;if([string]::IsNullOrWhiteSpace($name)-or$name-eq"<PROJECT_NAME>"){Fail "bad project name"};foreach($e in $entries){$r=@($mi.files|Where-Object path -ceq $e.path);if($r.Count-ne1){continue};if($r[0].source-cne$e.source-or$r[0].policy-cne$e.policy){Fail "manifest metadata $($e.path)"};$expected=Hash(Render(Text(Join-Path $pluginRoot([string]$e.source)))([string]$e.render)$name);if($r[0].baseline_hash-cne$expected){Fail "manifest hash $($e.path)"}}}}

if($errors.Count){$errors|ForEach-Object{Write-Error $_ -ErrorAction Continue};return $false};Write-Host "Validation passed for $targetRoot";return $true
}

function Invoke-Rollback {
    [CmdletBinding()]
    param([string]$Target = ".", [Parameter(Mandatory)][string]$TransactionId)
    return Invoke-Upgrade -Target $Target -Rollback $TransactionId
}

if($Command-eq"probe"){try{Invoke-Probe -Target $Target;exit 0}catch{Write-Error $_ -ErrorAction Continue;exit 1}}
try{$code=switch($Command){"install"{Invoke-Install -Target $Target -ProjectName $ProjectName -Force:$Force -DryRun:$DryRun}"upgrade"{Invoke-Upgrade -Target $Target -Plan:$Plan -Apply:$Apply -Rollback $Rollback -AdoptFrom $AdoptFrom -ProjectName $ProjectName -AcceptLocal $AcceptLocal}"plan"{Invoke-Upgrade -Target $Target -Plan -AdoptFrom $AdoptFrom -ProjectName $ProjectName}"apply"{Invoke-Upgrade -Target $Target -Apply -AdoptFrom $AdoptFrom -ProjectName $ProjectName -AcceptLocal $AcceptLocal}"rollback"{if([string]::IsNullOrWhiteSpace($Rollback)){throw "rollback command requires -Rollback <transaction-id>"};Invoke-Rollback -Target $Target -TransactionId $Rollback}"validate"{if(Invoke-Validation -Target $Target -AllowPlaceholders:$AllowPlaceholders -Runtime:$Runtime){0}else{1}}"hub-read"{Invoke-HubRead -Target $Target -ProjectId $ProjectId}"hub-write"{Invoke-HubWrite -Target $Target -ProjectId $ProjectId -HubThreadId $HubThreadId -HubTitle $HubTitle -OwnerId $OwnerId}"hub-replacement-prepare"{Invoke-HubReplacementPrepare -Target $Target -ProjectId $ProjectId -OwnerId $OwnerId -ExpectedHubThreadId $ExpectedHubThreadId -ExpectedRegistryToken $ExpectedRegistryToken -NewHubThreadId $NewHubThreadId -HubTitle $HubTitle -LeaseSeconds $LeaseSeconds -ConfirmedOldHubInactive:$ConfirmedOldHubInactive}"hub-replacement-commit"{Invoke-HubReplacementCommit -Target $Target -ProjectId $ProjectId -OwnerId $OwnerId}"bootstrap-lock-inspect"{Invoke-BootstrapInspect -Target $Target -ProjectId $ProjectId}"bootstrap-lock-acquire"{Invoke-BootstrapAcquire -Target $Target -ProjectId $ProjectId -OwnerId $OwnerId -ThreadId $ThreadId -Phase $Phase -LeaseSeconds $LeaseSeconds}"bootstrap-lock-renew"{Invoke-BootstrapRenew -Target $Target -ProjectId $ProjectId -OwnerId $OwnerId -ThreadId $ThreadId -Phase $Phase -LeaseSeconds $LeaseSeconds}"bootstrap-lock-release"{Invoke-BootstrapRelease -Target $Target -ProjectId $ProjectId -OwnerId $OwnerId -ConfirmedReplacementRetired:$ConfirmedReplacementRetired}"bootstrap-lock-recover"{Invoke-BootstrapRecover -Target $Target -ProjectId $ProjectId -OwnerId $OwnerId -ThreadId $ThreadId -Phase $Phase -ExpectedOwnerId $ExpectedOwnerId -ExpectedRenewedAt $ExpectedRenewedAt -LeaseSeconds $LeaseSeconds -ConfirmedOwnerInactive:$ConfirmedOwnerInactive -ConfirmedOrphanedClaim:$ConfirmedOrphanedClaim}};if($null-eq$code){$code=0};exit([int]$code)}catch{Write-Error $_ -ErrorAction Continue;exit 1}
