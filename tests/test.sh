#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python_cmd=${PYTHON-python3}
engine="$repo/scripts/project-flow.sh"
current_version=$("$python_cmd" -c 'import pathlib,sys;print(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8-sig").strip())' "$repo/VERSION")
tmp=$(mktemp -d "${TMPDIR-/tmp}/codex-project-flow-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

fixture() {
  version=$1
  name=$2
  no_manifest=${3-false}
  root="$tmp/$name"
  "$python_cmd" - "$repo" "$root" "$version" "$name" "$no_manifest" <<'PY'
import hashlib,json,pathlib,shutil,sys
repo,path,version,name,no_manifest=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3],sys.argv[4],sys.argv[5]=="true"
path.mkdir(parents=True)
items=json.loads((repo/"baselines"/version/"managed-files.json").read_text(encoding="utf-8-sig"))["files"]
records=[]
for item in items:
 source=repo/"baselines"/version/item["path"]
 destination=path/item["path"]
 destination.parent.mkdir(parents=True,exist_ok=True)
 shutil.copyfile(source,destination)
 raw=source.read_text(encoding="utf-8-sig").replace("\r\n","\n").replace("\r","\n")
 rendered=raw.replace("<PROJECT_NAME>",name)
 records.append({"path":item["path"],"source":item["source"],"policy":item["policy"],"baseline_hash":"sha256:"+hashlib.sha256(rendered.encode()).hexdigest()})
if not no_manifest:
 manifest={"schema_version":1,"workflow_version":version,"project_name":name,"installed_at_utc":"2026-01-01T00:00:00Z","last_transaction":None,"files":records}
 destination=path/".project-flow/manifest.json"
 destination.parent.mkdir(parents=True,exist_ok=True)
 destination.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
lock=path/".project-flow/transaction.lock";lock.parent.mkdir(parents=True,exist_ok=True);lock.write_bytes(b"\0")
PY
}

apply_race() {
  root=$1
  kind=$2
  "$python_cmd" - "$engine" "$root" "$kind" <<'PY'
import pathlib,subprocess,sys,time
engine=pathlib.Path(sys.argv[1]);root=pathlib.Path(sys.argv[2]);kind=sys.argv[3]
def files():
 return {path.relative_to(root).as_posix():path.read_bytes() for path in root.rglob("*") if path.is_file()}
state=root/"docs/PROJECT_STATE.md";state.write_bytes(state.read_bytes()+b"RACE-PADDING\n"+(b"P"*(4*1024*1024)))
before=files();relative="AGENTS.md" if kind=="live" else ".project-flow/manifest.json";marker=b"RACE-LIVE\n" if kind=="live" else b"\n"
process=subprocess.Popen(["sh",str(engine),"apply","--target",str(root)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
changed=False;output=[]
for line in process.stdout:
 output.append(line)
 if not changed and line.startswith("TARGET "):
  transactions=root/".project-flow/transactions";deadline=time.monotonic()+5
  while not transactions.exists() and time.monotonic()<deadline:time.sleep(0.001)
  assert transactions.exists(),"race hook did not reach the prepared-transaction window"
  path=root/relative;path.write_bytes(path.read_bytes()+marker);changed=True
error=process.stderr.read();process.wait()
assert changed,"race hook did not observe TARGET"
assert process.returncode!=0,(kind,"apply unexpectedly succeeded","".join(output),error)
expected=dict(before);expected[relative]=before[relative]+marker
assert files()==expected,(kind,"engine changed files after failed precondition")
assert not (root/".project-flow/transactions").exists(),(kind,"failed precondition left a transaction")
assert not (root/".project-flow/staging").exists(),(kind,"failed precondition left staging")
reason="Managed file changed" if kind=="live" else "Manifest changed"
assert reason in error,(kind,"missing failure reason",error)
PY
}

# The full regression exercises the shared engine directly.
"$engine" validate --allow-placeholders "$repo"
[ ! -e "$repo/.project-flow/transaction.lock" ]
if "$engine" validate "$repo" >/dev/null 2>&1; then
  echo "validator accepted an unrendered source workflow without --allow-placeholders" >&2
  exit 1
fi
clean="$tmp/clean"
mkdir "$clean"
"$engine" install --target "$clean" --project-name Clean
"$engine" validate --target "$clean"
"$python_cmd" - "$clean" "$repo/VERSION" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
manifest=json.loads((root/".project-flow/manifest.json").read_text())
assert manifest["workflow_version"]==pathlib.Path(sys.argv[2]).read_text(encoding="utf-8-sig").strip() and len(manifest["files"])==6
for relative in [".agents/prompts/08_result_handoff.md",".agents/snippets/AGENTS.integration.md","docs/WORKFLOW_GUIDE.md","docs/DEVELOPMENT_SOP.md"]:
 assert not (root/relative).exists()
PY
workflow="$clean/.agents/workflow.json"
manifest="$clean/.project-flow/manifest.json"
cp "$workflow" "$tmp/workflow-original"
cp "$manifest" "$tmp/manifest-original"
"$python_cmd" - "$workflow" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value["project"]["name"]="<PROJECT_NAME>";path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
PY
if "$engine" validate --allow-placeholders "$clean" >/dev/null 2>&1; then
  echo "validator accepted a placeholder identity that disagrees with the installed manifest" >&2
  exit 1
fi
cp "$tmp/workflow-original" "$workflow"
"$python_cmd" - "$manifest" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value["project_name"]="<PROJECT_NAME>";path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
PY
if "$engine" validate --allow-placeholders "$clean" >/dev/null 2>&1; then
  echo "validator accepted a placeholder in an installed manifest" >&2
  exit 1
fi
printf '[]\n' > "$manifest"
set +e
json_error=$("$engine" validate "$clean" 2>&1)
json_status=$?
set -e
[ "$json_status" -ne 0 ]
printf '%s\n' "$json_error" | grep -Fq 'ERROR manifest JSON root must be an object'
if printf '%s\n' "$json_error" | grep -Fq 'Traceback'; then
  echo "non-object JSON leaked a traceback" >&2
  exit 1
fi
cp "$tmp/manifest-original" "$manifest"
"$python_cmd" - "$workflow" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value["tasks"]["max_active"]=1;path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
PY
if "$engine" validate "$clean" >/dev/null 2>&1; then
  echo "validator accepted max_active 1" >&2
  exit 1
fi
cp "$tmp/workflow-original" "$workflow"

mv "$manifest" "$tmp/contract-manifest"
reject_contract_mutation() {
  mutation=$1
  expected=$2
  cp "$tmp/workflow-original" "$workflow"
  "$python_cmd" - "$workflow" "$mutation" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));kind=sys.argv[2]
mutations={
 "role":lambda: value["upgrade"].__setitem__("transaction_task_role","coordinator_only"),
 "fast":lambda: value["upgrade"].__setitem__("zero_active_fast_path",False),
 "listing":lambda: value["upgrade"]["discovery"].__setitem__("listing","full_history"),
 "history":lambda: value["upgrade"]["discovery"].__setitem__("history","exhaustive"),
 "fallback":lambda: value["upgrade"]["discovery"].__setitem__("fallback","never"),
 "parallel":lambda: value["upgrade"]["reconcile"].__setitem__("independent_pairs","serial"),
 "order":lambda: value["upgrade"]["reconcile"].__setitem__("pair_order",["create_successor","archive_predecessor","verify_handshake"]),
 "barrier":lambda: value["upgrade"]["barrier"].__setitem__("active",value["upgrade"]["barrier"]["active"].replace("state=active","state=provisional")),
}
mutations[kind]();path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
PY
  set +e
  contract_error=$("$engine" validate "$clean" 2>&1)
  contract_status=$?
  set -e
  if [ "$contract_status" -eq 0 ]; then
    echo "validator accepted invalid workflow contract: $mutation" >&2
    exit 1
  fi
  printf '%s\n' "$contract_error" | grep -Fq "$expected"
}
reject_contract_mutation role 'transaction task role'
reject_contract_mutation fast 'zero active fast path'
reject_contract_mutation listing 'discovery listing'
reject_contract_mutation history 'discovery history'
reject_contract_mutation fallback 'discovery fallback'
reject_contract_mutation parallel 'independent reconciliation'
reject_contract_mutation order 'reconciliation pair order'
reject_contract_mutation barrier 'active barrier'
cp "$tmp/workflow-original" "$workflow"
mv "$tmp/contract-manifest" "$manifest"

versions=$(
  "$python_cmd" - "$repo" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1])/"baselines"
print(" ".join(sorted((p.name for p in root.iterdir() if p.is_dir()),key=lambda x:tuple(map(int,x.split("."))))))
PY
)
for version in $versions; do
  root="$tmp/plan-$version"
  fixture "$version" "plan-$version"
  output=$("$engine" upgrade --target "$root" --plan)
  printf '%s\n' "$output" | grep -Fq "UPGRADE $version -> $current_version"
done

patch_upgrade="$tmp/patch-upgrade"
fixture 0.7.0 patch-upgrade
cp -R "$patch_upgrade" "$tmp/patch-before"
patch_plan=$("$engine" plan --target "$patch_upgrade")
printf '%s\n' "$patch_plan" | grep -Fq "UPGRADE 0.7.0 -> $current_version"
patch_deletes=$(printf '%s\n' "$patch_plan" | grep -c '^DELETE' || true)
[ "$patch_deletes" -eq 0 ]
"$engine" apply --target "$patch_upgrade"
"$engine" validate --target "$patch_upgrade"
patch_txn=$("$python_cmd" - "$patch_upgrade" "$repo/VERSION" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);version=pathlib.Path(sys.argv[2]).read_text(encoding="utf-8-sig").strip()
manifest=json.loads((root/".project-flow/manifest.json").read_text(encoding="utf-8"))
assert manifest["workflow_version"]==version and len(manifest["files"])==6
print(manifest["last_transaction"])
PY
)
"$engine" rollback --target "$patch_upgrade" --rollback "$patch_txn"
"$python_cmd" - "$tmp/patch-before" "$patch_upgrade" <<'PY'
import hashlib,pathlib,sys
before,after=map(pathlib.Path,sys.argv[1:])
def files(root):
 return {p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file() and ".project-flow/transactions" not in p.as_posix()}
assert files(before)==files(after)
PY

live_race="$tmp/live-race"
fixture 0.6.0 live-race
apply_race "$live_race" live
manifest_race="$tmp/manifest-race"
fixture 0.6.0 manifest-race
apply_race "$manifest_race" manifest

concurrent="$tmp/concurrent-apply"
fixture 0.6.0 concurrent-apply
"$python_cmd" - "$engine" "$concurrent" <<'PY'
import json,pathlib,subprocess,sys,time
engine=pathlib.Path(sys.argv[1]);root=pathlib.Path(sys.argv[2]);state=root/"docs/PROJECT_STATE.md";state.write_bytes(state.read_bytes()+(b"L"*(128*1024*1024)))
command=["sh",str(engine),"apply","--target",str(root)]
first=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
transactions=root/".project-flow/transactions";deadline=time.monotonic()+20
while time.monotonic()<deadline:
 backup_seen=transactions.exists() and any(path.is_file() and "backup" in path.parts for path in transactions.rglob("*"))
 if backup_seen and first.poll() is None:break
 if first.poll() is not None:
  out,err=first.communicate();raise AssertionError(("first apply exited before lock-overlap signal",first.returncode,out,err))
 time.sleep(0.001)
else:
 first.terminate();out,err=first.communicate();raise AssertionError(("first apply did not reach lock-overlap signal",out,err))
second=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
first_out,first_err=first.communicate()
assert first.returncode==0,(first.returncode,first_out,first_err)
assert second.returncode!=0 and "Writer lock is busy" in second.stderr,(second.returncode,second.stdout,second.stderr)
manifest=json.loads((root/".project-flow/manifest.json").read_text());transactions=root/".project-flow/transactions"
assert manifest["last_transaction"] and len([path for path in transactions.iterdir() if path.is_dir()])==1
PY
"$engine" validate "$concurrent" >/dev/null

"$python_cmd" - "$engine" "$clean" "$concurrent" <<'PY'
import json,os,pathlib,subprocess,sys
engine=pathlib.Path(sys.argv[1]);root=pathlib.Path(sys.argv[2]);rollback_root=pathlib.Path(sys.argv[3]);lock=root/".project-flow/transaction.lock"
holder=r'''
import os,sys,time
path=sys.argv[1];descriptor=os.open(path,os.O_RDWR|os.O_CREAT);handle=os.fdopen(descriptor,"r+b",buffering=0)
if os.fstat(handle.fileno()).st_size==0:handle.write(b"\0");handle.flush();os.fsync(handle.fileno())
handle.seek(0)
if os.name=="nt":
 import msvcrt;msvcrt.locking(handle.fileno(),msvcrt.LK_NBLCK,1)
else:
 import fcntl;fcntl.flock(handle.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
print("READY",flush=True);time.sleep(300)
'''
process=subprocess.Popen([sys.executable,"-c",holder,str(lock)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
 assert process.stdout.readline().strip()=="READY"
 for command in (["plan","--target",str(root)],["validate","--target",str(root)],["install","--target",str(root),"--dry-run"]):
  completed=subprocess.run(["sh",str(engine),*command],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);assert completed.returncode==0,(command,completed.stderr)
 for command in (["apply","--target",str(root)],["install","--target",str(root)]):
  blocked=subprocess.run(["sh",str(engine),*command],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  assert blocked.returncode!=0 and "Writer lock is busy" in blocked.stderr,(command,blocked.returncode,blocked.stderr)
 assert not (root/".project-flow/transactions").exists()
finally:
 process.terminate();process.wait(timeout=10)
for _ in range(2):
 completed=subprocess.run(["sh",str(engine),"apply","--target",str(root)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);assert completed.returncode==0,completed.stderr;assert "NOOP already up to date" in completed.stdout
manifest=json.loads((rollback_root/".project-flow/manifest.json").read_text());transaction=manifest["last_transaction"]
process=subprocess.Popen([sys.executable,"-c",holder,str(rollback_root/".project-flow/transaction.lock")],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
 assert process.stdout.readline().strip()=="READY"
 blocked=subprocess.run(["sh",str(engine),"rollback","--target",str(rollback_root),"--rollback",transaction],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 assert blocked.returncode!=0 and "Writer lock is busy" in blocked.stderr,(blocked.returncode,blocked.stderr)
finally:
 process.terminate();process.wait(timeout=10)
for _ in range(2):
 completed=subprocess.run(["sh",str(engine),"rollback","--target",str(rollback_root),"--rollback",transaction],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);assert completed.returncode==0,completed.stderr
PY

upgrade="$tmp/upgrade"
fixture 0.6.0 upgrade
cp -R "$upgrade" "$tmp/before"
plan=$("$engine" plan --target "$upgrade")
[ "$(printf '%s\n' "$plan" | grep -c '^DELETE')" -eq 3 ]
"$engine" apply --target "$upgrade"
"$engine" validate "$upgrade"
txn=$("$python_cmd" - "$upgrade" "$repo/VERSION" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
manifest=json.loads((root/".project-flow/manifest.json").read_text())
assert manifest["workflow_version"]==pathlib.Path(sys.argv[2]).read_text(encoding="utf-8-sig").strip() and len(manifest["files"])==6
assert (root/".agents/WORKFLOW_PROTOCOL.md").is_file()
retired=[".agents/prompts/00_project_hub.md",".agents/prompts/09_execution_handoff.md",".agents/prompts/10_upgrade_coordination.md"]
assert all(not (root/path).exists() for path in retired)
meta=json.loads((root/".project-flow/transactions"/manifest["last_transaction"]/"transaction.json").read_text())
normalized=(root/".project-flow/manifest.json").read_text(encoding="utf-8-sig").replace("\r\n","\n").replace("\r","\n")
assert "sha256:"+hashlib.sha256(normalized.encode()).hexdigest()==meta["new_manifest_hash"]
assert manifest["last_transaction"]==meta["transaction_id"]
assert meta["removed_files"]==retired
assert len([item for item in meta["files"] if item["resolution"]=="DELETE"])==3
print(manifest["last_transaction"])
PY
)
"$engine" rollback --target "$upgrade" --rollback "$txn"
"$python_cmd" - "$tmp/before" "$upgrade" <<'PY'
import hashlib,pathlib,sys
before,after=map(pathlib.Path,sys.argv[1:])
def files(root):
 return {p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file() and ".project-flow/transactions" not in p.as_posix()}
assert files(before)==files(after)
PY

corrupt="$tmp/corrupt-backup"
fixture 0.6.0 corrupt-backup
"$engine" apply --target "$corrupt" >/dev/null
corrupt_txn=$("$python_cmd" - "$corrupt" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);manifest=json.loads((root/".project-flow/manifest.json").read_text());identifier=manifest["last_transaction"]
meta=json.loads((root/".project-flow/transactions"/identifier/"transaction.json").read_text());record=[item for item in meta["files"] if item["changed"] and item["existed"]][-1]
backup=root/".project-flow/transactions"/identifier/"backup"/record["path"];backup.write_bytes(b"CORRUPTED-LATE-BACKUP\n");print(identifier)
PY
)
cp -R "$corrupt" "$tmp/corrupt-before"
set +e
corrupt_error=$("$engine" rollback --target "$corrupt" --rollback "$corrupt_txn" 2>&1)
corrupt_status=$?
set -e
[ "$corrupt_status" -ne 0 ]
printf '%s\n' "$corrupt_error" | grep -Fq 'Backup hash mismatch'
"$python_cmd" - "$tmp/corrupt-before" "$corrupt" <<'PY'
import hashlib,pathlib,sys
before,after=map(pathlib.Path,sys.argv[1:])
def files(root):return {path.relative_to(root).as_posix():hashlib.sha256(path.read_bytes()).hexdigest() for path in root.rglob("*") if path.is_file()}
assert files(before)==files(after),"rollback restored files before authenticating the later corrupt backup"
PY

custom="$tmp/custom"
fixture 0.6.0 custom
printf '\nLOCAL-CUSTOM\n' >> "$custom/.agents/prompts/10_upgrade_coordination.md"
cp "$custom/.agents/prompts/10_upgrade_coordination.md" "$tmp/custom-before"
"$engine" upgrade --target "$custom" --apply
[ ! -e "$custom/docs/DEVELOPMENT_SOP.md" ]
custom_txn=$("$python_cmd" -c 'import json,sys;print(json.load(open(sys.argv[1]))["last_transaction"])' "$custom/.project-flow/manifest.json")
"$engine" upgrade --target "$custom" --rollback "$custom_txn"
cmp "$tmp/custom-before" "$custom/.agents/prompts/10_upgrade_coordination.md"

legacy="$tmp/legacy"
fixture 0.2.0 legacy true
if "$engine" upgrade --target "$legacy" --plan >/dev/null 2>&1; then
  echo "legacy accepted without explicit adoption" >&2
  exit 1
fi
"$engine" upgrade --target "$legacy" --apply --adopt-from 0.2.0 --project-name Legacy
"$engine" validate "$legacy"

# All externally supplied strings reject the complete Unicode Cc category.
control_target="$tmp/control"
mkdir "$control_target"
control_name=$(printf 'bad\nname')
if "$engine" install --target "$control_target" --project-name "$control_name" >/dev/null 2>&1; then
  echo "installer accepted a control character" >&2
  exit 1
fi
if "$engine" upgrade --target "$legacy" --apply --accept-local "$control_name" >/dev/null 2>&1; then
  echo "upgrader accepted a control character" >&2
  exit 1
fi
c1_name=$(PYTHONIOENCODING=utf-8 "$python_cmd" -c 'import sys;sys.stdout.write("bad"+chr(0x85)+"name")')
if "$engine" install --target "$control_target" --project-name "$c1_name" --dry-run >/dev/null 2>&1; then
  echo "installer accepted a C1 control character" >&2
  exit 1
fi

# Compatibility wrappers only forward arguments and exit status.
for wrapper in install upgrade validate; do
  PYTHON="$python_cmd" "$repo/scripts/$wrapper.sh" --help >/dev/null
  set +e
  "$repo/scripts/$wrapper.sh" --definitely-invalid >/dev/null 2>&1
  wrapper_status=$?
  set -e
  if [ "$wrapper_status" -ne 2 ]; then
    echo "$wrapper wrapper lost the engine exit status: $wrapper_status" >&2
    exit 1
  fi
done
wrapper_target="$tmp/wrapper-positional"
mkdir "$wrapper_target"
PYTHON="$python_cmd" "$repo/scripts/install.sh" "$wrapper_target" Wrapper --dry-run >/dev/null
[ ! -e "$wrapper_target/AGENTS.md" ]
[ ! -e "$wrapper_target/.project-flow/transaction.lock" ]
PYTHON="$python_cmd" "$repo/scripts/validate.sh" "$repo" --allow-placeholders >/dev/null
fixture 0.6.0 wrapper-upgrade
PYTHON="$python_cmd" "$repo/scripts/upgrade.sh" "$tmp/wrapper-upgrade" --plan | grep -Fq "UPGRADE 0.6.0 -> $current_version"
plan_no_lock="$tmp/plan-no-lock"
fixture 0.6.0 plan-no-lock
rm "$plan_no_lock/.project-flow/transaction.lock"
"$engine" plan --target "$plan_no_lock" >/dev/null
[ ! -e "$plan_no_lock/.project-flow/transaction.lock" ]
if "$engine" unknown >/dev/null 2>&1; then
  echo "engine accepted an unknown command" >&2
  exit 1
fi
control_command=$(printf 'bad\ncommand')
if "$engine" "$control_command" >/dev/null 2>&1; then
  echo "engine accepted a control character in the command" >&2
  exit 1
fi

if grep -Eq 'subprocess|scripts/validate\.sh|PY_(INSTALL|UPGRADE|VALIDATE)' "$repo/scripts/project-flow.sh"; then
  echo "POSIX engine still contains subprocess validation or split Python programs" >&2
  exit 1
fi
for invariant in 'self.assert_preconditions(plans, old_manifest_hash)' 'Written manifest hash does not match the prepared transaction' 'automatic rollback also failed'; do
  grep -Fq "$invariant" "$repo/scripts/project-flow.sh"
done
grep -Fq '"schema_version": 6' "$repo/.agents/workflow.json"
for retired in '"authorization"' '"hub"' '"handoff"' '"scope"' '"snapshot"' '"fast_path"' '"failure"' '"release"';do
 if grep -Fq "$retired" "$repo/.agents/workflow.json";then echo "retired workflow field remains: $retired" >&2;exit 1;fi
done
grep -Fq '"attempt_deadline_seconds": 60' "$repo/.agents/workflow.json"
grep -Fq '"include_outputs": false' "$repo/.agents/workflow.json"
grep -Fq '"poll_scan_latest_turns": 3' "$repo/.agents/workflow.json"
grep -Fq '"transaction_task_role": "visible_coordinator_executor"' "$repo/.agents/workflow.json"
grep -Fq '"listing": "exhaustive_metadata"' "$repo/.agents/workflow.json"
grep -Fq '"history": "targeted"' "$repo/.agents/workflow.json"
grep -Fq '"fallback": "full_on_ambiguity"' "$repo/.agents/workflow.json"
grep -Fq '"zero_active_fast_path": true' "$repo/.agents/workflow.json"
grep -Fq '"independent_pairs": "parallel_within_available_slots"' "$repo/.agents/workflow.json"
grep -Fq '"pair_order": ["archive_predecessor", "create_successor", "verify_handshake"]' "$repo/.agents/workflow.json"
grep -Fq '"provisional": "[codex-project-flow:upgrade-barrier:v1] state=provisional; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>"' "$repo/.agents/workflow.json"
grep -Fq '"active": "[codex-project-flow:upgrade-barrier:v1] state=active; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>"' "$repo/.agents/workflow.json"
grep -Fq '"released": "[codex-project-flow:upgrade-barrier:v1] state=released; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>"' "$repo/.agents/workflow.json"
grep -Fq '"cancelled": "[codex-project-flow:upgrade-barrier:v1] state=cancelled; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>"' "$repo/.agents/workflow.json"
echo "All POSIX regression tests passed."
