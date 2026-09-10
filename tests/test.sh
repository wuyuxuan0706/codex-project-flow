#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python_cmd=${PYTHON-python3}
export PYTHONIOENCODING=utf-8
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
import hashlib,json,pathlib,sys
repo,path,version,name,no_manifest=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3],sys.argv[4],sys.argv[5]=="true"
path.mkdir(parents=True)
items=json.loads((repo/"baselines"/version/"managed-files.json").read_text(encoding="utf-8-sig"))["files"]
records=[]
for item in items:
 source=repo/"baselines"/version/item["path"]
 destination=path/item["path"]
 destination.parent.mkdir(parents=True,exist_ok=True)
 raw=source.read_text(encoding="utf-8-sig").replace("\r\n","\n").replace("\r","\n")
 rendered=raw.replace("<PROJECT_NAME>",name)
 destination.write_text(rendered,encoding="utf-8")
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
probe_json=$("$engine" probe --target "$clean")
"$python_cmd" -c 'import json,sys; value=json.loads(sys.argv[1]); assert value["managed"] and value["managed_files"]==6' "$probe_json"
"$engine" validate --target "$clean"
"$python_cmd" - "$clean" "$repo/VERSION" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
manifest=json.loads((root/".project-flow/manifest.json").read_text())
assert manifest["workflow_version"]==pathlib.Path(sys.argv[2]).read_text(encoding="utf-8-sig").strip() and len(manifest["files"])==6
for relative in [".agents/prompts/08_result_handoff.md",".agents/snippets/AGENTS.integration.md","docs/WORKFLOW_GUIDE.md","docs/DEVELOPMENT_SOP.md"]:
 assert not (root/relative).exists()
PY
bounded="$tmp/bounded"
mkdir -p "$bounded/docs/unrelated"
printf '%s\n' '任务管理不可用时回到中枢' > "$bounded/docs/unrelated/conflict.md"
probe_json=$("$engine" probe --target "$bounded")
"$python_cmd" -c 'import json,sys; value=json.loads(sys.argv[1]); assert not value["managed"]' "$probe_json"
"$engine" install --target "$bounded" --project-name Bounded
"$engine" validate --runtime --target "$bounded"
"$engine" apply --target "$bounded"
if "$engine" validate --target "$bounded" >/dev/null 2>&1; then
  echo "package audit ignored conflicting project docs" >&2
  exit 1
fi
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
 "upgrade_owner":lambda: value["upgrade"].__setitem__("post_handoff_owner","hub"),
 "barrier_owner":lambda: value["upgrade"].__setitem__("barrier_owner","hub"),
 "fast":lambda: value["upgrade"].__setitem__("zero_active_fast_path",False),
 "listing":lambda: value["upgrade"]["discovery"].__setitem__("listing","full_history"),
 "history":lambda: value["upgrade"]["discovery"].__setitem__("history","exhaustive"),
 "fallback":lambda: value["upgrade"]["discovery"].__setitem__("fallback","never"),
 "request":lambda: value["tasks"].__setitem__("request_key",value["tasks"]["request_key"].replace("requestId=<exactRequestId>; ","")),
 "request_timing":lambda: value["requests"].__setitem__("request_id_assignment","after_task_creation"),
 "initial_owner":lambda: value["requests"].__setitem__("initial_owner","execution_task"),
 "handoff_boundary":lambda: value["requests"].__setitem__("handoff_boundary","after_completion"),
 "post_handoff_owner":lambda: value["requests"].__setitem__("post_handoff_owner","hub"),
 "hub_post_handoff":lambda: value["requests"].__setitem__("hub_post_handoff","route_messages"),
 "acceptance_owner":lambda: value["requests"].__setitem__("acceptance_owner","coordinator"),
 "rejection_route":lambda: value["requests"].__setitem__("rejection_route","create_new_task"),
 "scope_change_route":lambda: value["requests"].__setitem__("scope_change_route","return_to_hub"),
 "acceptance_slot":lambda: value["requests"].__setitem__("awaiting_acceptance_occupies_slot",False),
 "supplemental":lambda: value["execution"].__setitem__("supplemental_authorization","create_new_task"),
 "goal":lambda: value["execution"].__setitem__("different_goal","parallel"),
 "scope":lambda: value["execution"].__setitem__("scope_change","create_successor"),
 "replacement":lambda: value["execution"].__setitem__("replacement","automatic"),
 "serial":lambda: value["execution"].__setitem__("serial",["high_risk"]),
 "document":lambda: value["documents"].__setitem__("default_extension",".docx"),
 "document_review":lambda: value["documents"]["review"].__setitem__("required",False),
 "document_evidence":lambda: value["documents"]["review"].__setitem__("approval_evidence","unbound_chat_approval"),
 "bootstrap_markdown_exception":lambda: value["documents"]["review"]["exceptions"].__setitem__("bootstrap_managed_markdown","review_required"),
 "upgrade_markdown_exception":lambda: value["documents"]["review"]["exceptions"].__setitem__("upgrade_managed_markdown","review_required"),
 "rotation":lambda: value["rotation"].__setitem__("mode","automatic"),
 "snapshot":lambda: value["upgrade"]["reconcile"].__setitem__("active_snapshot","automatic"),
 "successor":lambda: value["upgrade"]["reconcile"].__setitem__("successor_creation","parallel"),
 "order":lambda: value["upgrade"]["reconcile"].__setitem__("pair_order",["archive_predecessor","queue_successor"]),
 "compensation":lambda: value["upgrade"].__setitem__("recovery",{"compensating_successors":1}),
 "successor_key":lambda: value["upgrade"].__setitem__("successor_key","retired"),
 "task_handshake":lambda: value["upgrade"].__setitem__("task_handshake","retired"),
 "barrier":lambda: value["upgrade"]["barrier"].__setitem__("active",value["upgrade"]["barrier"]["active"].replace("state=active","state=provisional")),
 "creation_gate":lambda: value["upgrade"]["barrier"].__setitem__("creation_gate","active_only"),
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
reject_contract_mutation upgrade_owner 'upgrade post-handoff owner'
reject_contract_mutation barrier_owner 'upgrade barrier owner'
reject_contract_mutation fast 'zero active fast path'
reject_contract_mutation listing 'discovery listing'
reject_contract_mutation history 'discovery history'
reject_contract_mutation fallback 'discovery fallback'
reject_contract_mutation request 'request key'
reject_contract_mutation request_timing 'request ID assignment'
reject_contract_mutation initial_owner 'request initial owner'
reject_contract_mutation handoff_boundary 'request handoff boundary'
reject_contract_mutation post_handoff_owner 'request post-handoff owner'
reject_contract_mutation hub_post_handoff 'request hub post-handoff'
reject_contract_mutation acceptance_owner 'request acceptance owner'
reject_contract_mutation rejection_route 'request rejection route'
reject_contract_mutation scope_change_route 'request scope-change route'
reject_contract_mutation acceptance_slot 'request acceptance slot'
reject_contract_mutation supplemental 'supplemental authorization'
reject_contract_mutation goal 'different goal'
reject_contract_mutation scope 'scope change'
reject_contract_mutation replacement 'replacement'
reject_contract_mutation serial 'serial execution'
reject_contract_mutation document 'document extension'
reject_contract_mutation document_review 'document review required'
reject_contract_mutation document_evidence 'document review evidence'
reject_contract_mutation bootstrap_markdown_exception 'bootstrap Markdown review exception'
reject_contract_mutation upgrade_markdown_exception 'upgrade Markdown review exception'
reject_contract_mutation rotation 'rotation mode'
reject_contract_mutation snapshot 'active snapshot'
reject_contract_mutation successor 'reconcile fields are invalid'
reject_contract_mutation order 'reconcile fields are invalid'
reject_contract_mutation compensation 'upgrade fields are invalid'
reject_contract_mutation successor_key 'upgrade fields are invalid'
reject_contract_mutation task_handshake 'upgrade fields are invalid'
reject_contract_mutation barrier 'active barrier'
reject_contract_mutation creation_gate 'upgrade creation gate'
cp "$tmp/workflow-original" "$workflow"
mv "$tmp/contract-manifest" "$manifest"

markdown_state="$clean/docs/PROJECT_STATE.md"
cp "$markdown_state" "$tmp/markdown-original"
printf '## Invalid first heading\n' > "$markdown_state"
set +e
markdown_error=$("$engine" validate --target "$clean" --runtime 2>&1)
markdown_status=$?
set -e
[ "$markdown_status" -ne 0 ]
printf '%s\n' "$markdown_error" | grep -Fq 'first heading'
printf '# Valid first heading\n\n### Skipped level\n' > "$markdown_state"
set +e
markdown_error=$("$engine" validate --target "$clean" --runtime 2>&1)
markdown_status=$?
set -e
[ "$markdown_status" -ne 0 ]
printf '%s\n' "$markdown_error" | grep -Fq 'heading levels'
cp "$tmp/markdown-original" "$markdown_state"

versions=$(
  "$python_cmd" - "$repo" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1])/"baselines"
print(" ".join(sorted((p.name for p in root.iterdir() if p.is_dir()),key=lambda x:tuple(map(int,x.split("."))))))
PY
)
[ "$versions" = "0.8.3 0.9.0 0.9.1 0.10.0 0.11.0" ]
for version in $versions; do
  root="$tmp/plan-$version"
  fixture "$version" "plan-$version"
  output=$("$engine" upgrade --target "$root" --plan)
  printf '%s\n' "$output" | grep -Fq "UPGRADE $version -> $current_version"
done

unsupported="$tmp/unsupported"
fixture 0.8.3 unsupported
"$python_cmd" - "$unsupported/.project-flow/manifest.json" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);manifest=json.loads(path.read_text(encoding="utf-8"));manifest["workflow_version"]="0.8.2";path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
PY
set +e
unsupported_error=$("$engine" plan --target "$unsupported" 2>&1)
unsupported_status=$?
set -e
[ "$unsupported_status" -ne 0 ]
printf '%s\n' "$unsupported_error" | grep -Fq 'No supported migration from 0.8.2'

for patch_version in 0.9.0 0.9.1 0.10.0 0.11.0; do
patch_upgrade="$tmp/patch-upgrade-$patch_version"
fixture "$patch_version" "patch-upgrade-$patch_version"
cp -R "$patch_upgrade" "$tmp/patch-before-$patch_version"
patch_plan=$("$engine" plan --target "$patch_upgrade")
printf '%s\n' "$patch_plan" | grep -Fq "UPGRADE $patch_version -> $current_version"
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
"$python_cmd" - "$tmp/patch-before-$patch_version" "$patch_upgrade" <<'PY'
import hashlib,pathlib,sys
before,after=map(pathlib.Path,sys.argv[1:])
def files(root):
 return {p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file() and ".project-flow/transactions" not in p.as_posix()}
assert files(before)==files(after)
PY
done

live_race="$tmp/live-race"
fixture 0.8.3 live-race
apply_race "$live_race" live
manifest_race="$tmp/manifest-race"
fixture 0.8.3 manifest-race
apply_race "$manifest_race" manifest

concurrent="$tmp/concurrent-apply"
fixture 0.8.3 concurrent-apply
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
fixture 0.8.3 upgrade
cp -R "$upgrade" "$tmp/before"
plan=$("$engine" plan --target "$upgrade")
[ "$(printf '%s\n' "$plan" | grep -c '^DELETE' || true)" -eq 0 ]
"$engine" apply --target "$upgrade"
"$engine" validate "$upgrade"
txn=$("$python_cmd" - "$upgrade" "$repo/VERSION" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
manifest=json.loads((root/".project-flow/manifest.json").read_text())
assert manifest["workflow_version"]==pathlib.Path(sys.argv[2]).read_text(encoding="utf-8-sig").strip() and len(manifest["files"])==6
assert (root/".agents/WORKFLOW_PROTOCOL.md").is_file()
meta=json.loads((root/".project-flow/transactions"/manifest["last_transaction"]/"transaction.json").read_text())
normalized=(root/".project-flow/manifest.json").read_text(encoding="utf-8-sig").replace("\r\n","\n").replace("\r","\n")
assert "sha256:"+hashlib.sha256(normalized.encode()).hexdigest()==meta["new_manifest_hash"]
assert manifest["last_transaction"]==meta["transaction_id"]
assert meta["removed_files"]==[]
assert len([item for item in meta["files"] if item["resolution"]=="DELETE"])==0
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
fixture 0.8.3 corrupt-backup
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
fixture 0.8.3 custom
printf '\nLOCAL-CUSTOM\n' >> "$custom/.agents/WORKFLOW_PROTOCOL.md"
cp "$custom/.agents/WORKFLOW_PROTOCOL.md" "$tmp/custom-before"
"$engine" upgrade --target "$custom" --apply
! grep -Fq 'LOCAL-CUSTOM' "$custom/.agents/WORKFLOW_PROTOCOL.md"
custom_txn=$("$python_cmd" -c 'import json,sys;print(json.load(open(sys.argv[1]))["last_transaction"])' "$custom/.project-flow/manifest.json")
"$engine" upgrade --target "$custom" --rollback "$custom_txn"
cmp "$tmp/custom-before" "$custom/.agents/WORKFLOW_PROTOCOL.md"

legacy="$tmp/legacy"
fixture 0.8.3 legacy true
if "$engine" upgrade --target "$legacy" --plan >/dev/null 2>&1; then
  echo "manifest-free target was accepted" >&2
  exit 1
fi
set +e
legacy_error=$("$engine" upgrade --target "$legacy" --apply --adopt-from 0.8.3 --project-name Legacy 2>&1)
legacy_status=$?
set -e
[ "$legacy_status" -ne 0 ]
printf '%s\n' "$legacy_error" | grep -Fq 'Manifest-free adoption is no longer supported'

# All externally supplied strings reject the complete Unicode Cc category.
control_target="$tmp/control"
mkdir "$control_target"
control_name=$(printf 'bad\nname')
if "$engine" install --target "$control_target" --project-name "$control_name" >/dev/null 2>&1; then
  echo "installer accepted a control character" >&2
  exit 1
fi
if "$engine" upgrade --target "$custom" --apply --accept-local "$control_name" >/dev/null 2>&1; then
  echo "upgrader accepted a control character" >&2
  exit 1
fi
c1_name=$(PYTHONIOENCODING=utf-8 "$python_cmd" -c 'import sys;sys.stdout.write("bad"+chr(0x85)+"name")')
if "$engine" install --target "$control_target" --project-name "$c1_name" --dry-run >/dev/null 2>&1; then
  echo "installer accepted a C1 control character" >&2
  exit 1
fi

# Project-local hub registry and bootstrap lock lifecycle.
missing_inspect="$tmp/bootstrap-inspect-missing"
mkdir "$missing_inspect"
if "$engine" bootstrap-lock-inspect --target "$missing_inspect" --project-id project-bootstrap-0001 >/dev/null 2>&1; then echo 'missing bootstrap lock was inspected successfully' >&2; exit 1; fi
[ ! -e "$missing_inspect/.project-flow" ]
hub_root="$tmp/bootstrap-lifecycle"
mkdir "$hub_root"
project_id=project-bootstrap-0001
owner_a=claim-owner-0001
owner_b=claim-owner-0002
owner_c=claim-owner-0003
thread_a=thread-hub-0001
thread_b=thread-hub-0002
hub_title='项目中枢 · Bootstrap'
"$engine" bootstrap-lock-acquire --target "$hub_root" --project-id "$project_id" --owner-id "$owner_a" --phase install >"$tmp/lock.json"
"$python_cmd" -c 'import json,sys;x=json.load(open(sys.argv[1],encoding="utf-8"));assert x["projectId"]==sys.argv[2] and x["ownerId"]==sys.argv[3] and x["threadId"] is None' "$tmp/lock.json" "$project_id" "$owner_a"
lock_hash_before=$($python_cmd -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$hub_root/.project-flow/bootstrap.lock")
"$engine" bootstrap-lock-inspect --target "$hub_root" --project-id "$project_id" >"$tmp/lock-inspect.json"
"$python_cmd" -c 'import json,sys;x=json.load(open(sys.argv[1],encoding="utf-8"));assert x["ownerId"]==sys.argv[2] and x["isStale"] is False and x["staleAt"]' "$tmp/lock-inspect.json" "$owner_a"
lock_hash_after=$($python_cmd -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$hub_root/.project-flow/bootstrap.lock")
[ "$lock_hash_before" = "$lock_hash_after" ]
if "$engine" bootstrap-lock-acquire --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" --phase install >/dev/null 2>&1; then echo 'second owner acquired existing bootstrap lock' >&2; exit 1; fi
"$engine" bootstrap-lock-renew --target "$hub_root" --project-id "$project_id" --owner-id "$owner_a" --thread-id "$thread_a" --phase claim >/dev/null
"$engine" bootstrap-lock-renew --target "$hub_root" --project-id "$project_id" --owner-id "$owner_a" --phase claim >"$tmp/bound-fence.json"
"$python_cmd" -c 'import json,sys;assert json.load(open(sys.argv[1],encoding="utf-8"))["threadId"]==sys.argv[2]' "$tmp/bound-fence.json" "$thread_a"
if "$engine" bootstrap-lock-renew --target "$hub_root" --project-id "$project_id" --owner-id "$owner_a" --thread-id "$thread_b" --phase claim >/dev/null 2>&1; then echo 'ordinary renew switched existing thread binding' >&2; exit 1; fi
if "$engine" hub-write --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" --hub-thread-id "$thread_a" --hub-title "$hub_title" >/dev/null 2>&1; then echo 'non-owner wrote hub registry' >&2; exit 1; fi
"$engine" hub-write --target "$hub_root" --project-id "$project_id" --owner-id "$owner_a" --hub-thread-id "$thread_a" --hub-title "$hub_title" >/dev/null
"$engine" hub-read --target "$hub_root" --project-id "$project_id" >"$tmp/hub.json"
"$python_cmd" -c 'import json,pathlib,sys;x=json.load(open(sys.argv[1],encoding="utf-8"));assert x["schemaVersion"]==1 and x["projectId"]==sys.argv[2] and x["threadId"]==sys.argv[3] and pathlib.Path(x["projectPath"]).resolve()==pathlib.Path(sys.argv[4]).resolve()' "$tmp/hub.json" "$project_id" "$thread_a" "$hub_root"
[ -z "$(find "$hub_root/.project-flow" -maxdepth 1 -name '*.project-flow-tmp-*' -print -quit)" ]
cp "$hub_root/.project-flow/hub.json" "$tmp/hub-valid.json"
"$python_cmd" - "$hub_root/.project-flow/hub.json" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value["projectPath"]=value["projectPath"][:1].lower()+value["projectPath"][1:];path.write_text(json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n",encoding="utf-8")
PY
"$engine" hub-read --target "$hub_root" --project-id "$project_id" >/dev/null
"$python_cmd" - "$hub_root/.project-flow/hub.json" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value["unexpected"]=True;path.write_text(json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n",encoding="utf-8")
PY
if "$engine" hub-read --target "$hub_root" --project-id "$project_id" >/dev/null 2>&1; then echo 'hub registry accepted unexpected field' >&2; exit 1; fi
cp "$tmp/hub-valid.json" "$hub_root/.project-flow/hub.json"
control_title=$(printf 'bad\ntitle')
if "$engine" hub-write --target "$hub_root" --project-id "$project_id" --owner-id "$owner_a" --hub-thread-id "$thread_a" --hub-title "$control_title" >/dev/null 2>&1; then echo 'hub registry accepted control character' >&2; exit 1; fi
hub_hash_before=$($python_cmd -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$hub_root/.project-flow/hub.json")
if "$engine" hub-read --target "$hub_root" --project-id project-bootstrap-9999 >/dev/null 2>&1; then echo 'mismatched projectId read hub registry' >&2; exit 1; fi
hub_hash_after=$($python_cmd -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$hub_root/.project-flow/hub.json")
[ "$hub_hash_before" = "$hub_hash_after" ]
cp -R "$hub_root" "$tmp/copied-project"
if "$engine" hub-read --target "$tmp/copied-project" --project-id "$project_id" >/dev/null 2>&1; then echo 'copied project reused original hub registry' >&2; exit 1; fi
if "$engine" hub-read --target "$hub_root" --project-id 'bad/id' >/dev/null 2>&1; then echo 'illegal identifier was accepted' >&2; exit 1; fi
if "$engine" bootstrap-lock-release --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" >/dev/null 2>&1; then echo 'non-owner released bootstrap lock' >&2; exit 1; fi
cp "$hub_root/.project-flow/bootstrap.lock" "$tmp/lock-valid.json"
"$python_cmd" - "$hub_root/.project-flow/bootstrap.lock" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value["renewedAt"]="2025-01-01T00:00:00Z";path.write_text(json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n",encoding="utf-8")
PY
if "$engine" bootstrap-lock-release --target "$hub_root" --project-id "$project_id" --owner-id "$owner_a" >/dev/null 2>&1; then echo 'bootstrap lock accepted inconsistent timestamps' >&2; exit 1; fi
cp "$tmp/lock-valid.json" "$hub_root/.project-flow/bootstrap.lock"
"$python_cmd" - "$hub_root/.project-flow/bootstrap.lock" <<'PY'
import datetime,json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));now=datetime.datetime.now(datetime.timezone.utc);stamp=lambda seconds:(now+datetime.timedelta(seconds=seconds)).isoformat().replace("+00:00","Z");value.update(createdAt=stamp(-3),renewedAt=stamp(-2),expiresAt=stamp(-1));path.write_text(json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n",encoding="utf-8")
PY
short_renewed=$($python_cmd -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["renewedAt"])' "$hub_root/.project-flow/bootstrap.lock")
if "$engine" bootstrap-lock-recover --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" --phase recover --expected-owner-id "$owner_a" --expected-renewed-at "$short_renewed" --confirmed-owner-inactive >/dev/null 2>&1; then echo 'edited expiresAt shortened fixed stale threshold' >&2; exit 1; fi
cp "$tmp/lock-valid.json" "$hub_root/.project-flow/bootstrap.lock"
"$python_cmd" - "$hub_root/.project-flow/bootstrap.lock" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value.update(createdAt="2026-01-01T00:00:00Z",renewedAt="2026-01-01T00:00:01.0000001Z",expiresAt="2026-01-01T00:00:02Z");path.write_text(json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n",encoding="utf-8")
PY
stale_hash_before=$($python_cmd -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$hub_root/.project-flow/bootstrap.lock")
"$engine" bootstrap-lock-inspect --target "$hub_root" --project-id "$project_id" >"$tmp/stale-inspect.json"
"$python_cmd" -c 'import json,sys;x=json.load(open(sys.argv[1],encoding="utf-8"));assert x["isStale"] is True and x["ownerId"]==sys.argv[2] and x["threadId"]==sys.argv[3]' "$tmp/stale-inspect.json" "$owner_a" "$thread_a"
stale_renewed=$($python_cmd -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["renewedAt"])' "$tmp/stale-inspect.json")
if "$engine" bootstrap-lock-inspect --target "$hub_root" --project-id project-bootstrap-9999 >/dev/null 2>&1; then echo 'lock inspect accepted different projectId' >&2; exit 1; fi
stale_hash_after=$($python_cmd -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$hub_root/.project-flow/bootstrap.lock")
[ "$stale_hash_before" = "$stale_hash_after" ]
if "$engine" bootstrap-lock-acquire --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" --phase recover >/dev/null 2>&1; then echo 'normal acquire took over stale lock' >&2; exit 1; fi
if "$engine" bootstrap-lock-recover --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" --thread-id "$thread_a" --phase recover --expected-owner-id "$owner_a" --expected-renewed-at "$stale_renewed" >/dev/null 2>&1; then echo 'stale recovery omitted owner-inactive proof' >&2; exit 1; fi
if "$engine" bootstrap-lock-recover --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" --thread-id "$thread_a" --phase recover --expected-owner-id claim-owner-9999 --expected-renewed-at "$stale_renewed" --confirmed-owner-inactive >/dev/null 2>&1; then echo 'stale recovery accepted wrong previous owner' >&2; exit 1; fi
if "$engine" bootstrap-lock-recover --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" --thread-id "$thread_a" --phase recover --expected-owner-id "$owner_a" --expected-renewed-at '2026-01-01T00:00:01.0000000Z' --confirmed-owner-inactive >/dev/null 2>&1; then echo 'stale recovery accepted changed raw renewedAt token' >&2; exit 1; fi
if "$engine" bootstrap-lock-recover --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" --thread-id "$thread_b" --phase recover --expected-owner-id "$owner_a" --expected-renewed-at "$stale_renewed" --confirmed-owner-inactive >/dev/null 2>&1; then echo 'bound stale recovery switched threads' >&2; exit 1; fi
"$engine" bootstrap-lock-recover --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" --thread-id "$thread_a" --phase recover --expected-owner-id "$owner_a" --expected-renewed-at "$stale_renewed" --confirmed-owner-inactive >/dev/null
if "$engine" hub-write --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" --hub-thread-id "$thread_b" --hub-title "$hub_title" >/dev/null 2>&1; then echo 'recovered owner overwrote another registered hub' >&2; exit 1; fi
if "$engine" bootstrap-lock-release --target "$hub_root" --project-id "$project_id" --owner-id "$owner_a" >/dev/null 2>&1; then echo 'previous owner released recovered lock' >&2; exit 1; fi
"$engine" bootstrap-lock-release --target "$hub_root" --project-id "$project_id" --owner-id "$owner_b" >/dev/null
[ ! -e "$hub_root/.project-flow/bootstrap.lock" ]

orphan_root="$tmp/bootstrap-orphan"
mkdir "$orphan_root"
"$engine" bootstrap-lock-acquire --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_a" --phase installing >/dev/null
"$engine" bootstrap-lock-renew --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_a" --phase installing >"$tmp/orphan-fence.json"
"$python_cmd" -c 'import json,sys;assert json.load(open(sys.argv[1],encoding="utf-8"))["threadId"] is None' "$tmp/orphan-fence.json"
"$python_cmd" - "$orphan_root/.project-flow/bootstrap.lock" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value.update(createdAt="2026-01-01T00:00:00Z",renewedAt="2026-01-01T00:00:01Z",expiresAt="2026-01-01T00:00:02Z");path.write_text(json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n",encoding="utf-8")
PY
"$engine" bootstrap-lock-inspect --target "$orphan_root" --project-id "$project_id" >"$tmp/orphan-inspect.json"
orphan_renewed=$($python_cmd -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["renewedAt"])' "$tmp/orphan-inspect.json")
if "$engine" bootstrap-lock-recover --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_b" --phase installing --expected-owner-id "$owner_a" --expected-renewed-at "$orphan_renewed" --confirmed-owner-inactive >/dev/null 2>&1; then echo 'zero-candidate recovery omitted orphan confirmation' >&2; exit 1; fi
"$python_cmd" - "$orphan_root/.project-flow/bootstrap.lock" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value["phase"]="creating";path.write_text(json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n",encoding="utf-8")
PY
"$engine" bootstrap-lock-inspect --target "$orphan_root" --project-id "$project_id" >"$tmp/orphan-wrong-phase.json"
wrong_phase_renewed=$($python_cmd -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["renewedAt"])' "$tmp/orphan-wrong-phase.json")
if "$engine" bootstrap-lock-recover --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_b" --phase installing --expected-owner-id "$owner_a" --expected-renewed-at "$wrong_phase_renewed" --confirmed-orphaned-claim >/dev/null 2>&1; then echo 'non-install stale lock used orphan recovery' >&2; exit 1; fi
"$python_cmd" - "$orphan_root/.project-flow/bootstrap.lock" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value["phase"]="installing";path.write_text(json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n",encoding="utf-8")
PY
"$engine" bootstrap-lock-inspect --target "$orphan_root" --project-id "$project_id" >"$tmp/orphan-inspect.json"
orphan_renewed=$($python_cmd -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["renewedAt"])' "$tmp/orphan-inspect.json")
if "$engine" bootstrap-lock-recover --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_b" --phase orphan-recovery --expected-owner-id "$owner_a" --expected-renewed-at "$orphan_renewed" --confirmed-orphaned-claim >/dev/null 2>&1; then echo 'orphan recovery accepted a non-recoverable new phase' >&2; exit 1; fi
"$engine" bootstrap-lock-recover --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_b" --phase installing --expected-owner-id "$owner_a" --expected-renewed-at "$orphan_renewed" --confirmed-orphaned-claim >"$tmp/orphan-recovered.json"
"$python_cmd" -c 'import json,sys;x=json.load(open(sys.argv[1],encoding="utf-8"));assert x["ownerId"]==sys.argv[2] and x["threadId"] is None and x["phase"]=="installing"' "$tmp/orphan-recovered.json" "$owner_b"
"$python_cmd" - "$orphan_root/.project-flow/bootstrap.lock" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value.update(createdAt="2026-01-01T00:00:00Z",renewedAt="2026-01-01T00:00:03Z",expiresAt="2026-01-01T00:00:04Z");path.write_text(json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n",encoding="utf-8")
PY
"$engine" bootstrap-lock-inspect --target "$orphan_root" --project-id "$project_id" >"$tmp/orphan-second-inspect.json"
second_orphan_renewed=$($python_cmd -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["renewedAt"])' "$tmp/orphan-second-inspect.json")
"$engine" bootstrap-lock-recover --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_c" --phase installing --expected-owner-id "$owner_b" --expected-renewed-at "$second_orphan_renewed" --confirmed-orphaned-claim >"$tmp/orphan-recovered-again.json"
"$python_cmd" -c 'import json,sys;x=json.load(open(sys.argv[1],encoding="utf-8"));assert x["ownerId"]==sys.argv[2] and x["threadId"] is None and x["phase"]=="installing"' "$tmp/orphan-recovered-again.json" "$owner_c"
if "$engine" bootstrap-lock-renew --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_a" --phase claim >/dev/null 2>&1; then echo 'old orphan owner passed post-recovery fence' >&2; exit 1; fi
if "$engine" bootstrap-lock-renew --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_b" --thread-id "$thread_b" --phase claim >/dev/null 2>&1; then echo 'first orphan recovery owner passed second recovery fence' >&2; exit 1; fi
"$engine" bootstrap-lock-renew --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_c" --thread-id "$thread_b" --phase claim >/dev/null
"$engine" hub-write --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_c" --hub-thread-id "$thread_b" --hub-title "$hub_title" >/dev/null
"$engine" bootstrap-lock-release --target "$orphan_root" --project-id "$project_id" --owner-id "$owner_c" >/dev/null

orphan_race_root="$tmp/bootstrap-orphan-race"
mkdir "$orphan_race_root"
"$engine" bootstrap-lock-acquire --target "$orphan_race_root" --project-id "$project_id" --owner-id "$owner_a" --phase installing >/dev/null
"$python_cmd" - "$orphan_race_root/.project-flow/bootstrap.lock" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]);value=json.loads(path.read_text(encoding="utf-8"));value.update(createdAt="2026-01-01T00:00:00Z",renewedAt="2026-01-01T00:00:01Z",expiresAt="2026-01-01T00:00:02Z");path.write_text(json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n",encoding="utf-8")
PY
set +e
"$engine" bootstrap-lock-recover --target "$orphan_race_root" --project-id "$project_id" --owner-id "$owner_b" --phase installing --expected-owner-id "$owner_a" --expected-renewed-at '2026-01-01T00:00:01Z' --confirmed-orphaned-claim >"$tmp/orphan-race-a.out" 2>&1 & orphan_race_a=$!
"$engine" bootstrap-lock-recover --target "$orphan_race_root" --project-id "$project_id" --owner-id "$owner_c" --phase installing --expected-owner-id "$owner_a" --expected-renewed-at '2026-01-01T00:00:01Z' --confirmed-orphaned-claim >"$tmp/orphan-race-b.out" 2>&1 & orphan_race_b=$!
wait "$orphan_race_a"; orphan_code_a=$?
wait "$orphan_race_b"; orphan_code_b=$?
set -e
if ! { { [ "$orphan_code_a" -eq 0 ] && [ "$orphan_code_b" -ne 0 ]; } || { [ "$orphan_code_a" -ne 0 ] && [ "$orphan_code_b" -eq 0 ]; }; }; then echo "concurrent orphan recovery codes: $orphan_code_a,$orphan_code_b" >&2; cat "$tmp/orphan-race-a.out" "$tmp/orphan-race-b.out" >&2; exit 1; fi
orphan_race_owner=$($python_cmd -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["ownerId"])' "$orphan_race_root/.project-flow/bootstrap.lock")
"$engine" bootstrap-lock-release --target "$orphan_race_root" --project-id "$project_id" --owner-id "$orphan_race_owner" >/dev/null

race_root="$tmp/bootstrap-concurrent"
mkdir "$race_root"
set +e
"$engine" bootstrap-lock-acquire --target "$race_root" --project-id "$project_id" --owner-id "$owner_a" --phase claim >"$tmp/race-a.out" 2>&1 & race_a=$!
"$engine" bootstrap-lock-acquire --target "$race_root" --project-id "$project_id" --owner-id "$owner_b" --phase claim >"$tmp/race-b.out" 2>&1 & race_b=$!
wait "$race_a"; code_a=$?
wait "$race_b"; code_b=$?
set -e
case "$code_a,$code_b" in 0,1|1,0) ;; *) echo "concurrent bootstrap acquire codes: $code_a,$code_b" >&2; cat "$tmp/race-a.out" "$tmp/race-b.out" >&2; exit 1;; esac
race_owner=$($python_cmd -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["ownerId"])' "$race_root/.project-flow/bootstrap.lock")
"$engine" bootstrap-lock-release --target "$race_root" --project-id "$project_id" --owner-id "$race_owner" >/dev/null

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
fixture 0.8.3 wrapper-upgrade
PYTHON="$python_cmd" "$repo/scripts/upgrade.sh" "$tmp/wrapper-upgrade" --plan | grep -Fq "UPGRADE 0.8.3 -> $current_version"
plan_no_lock="$tmp/plan-no-lock"
fixture 0.8.3 plan-no-lock
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
grep -Fq '"schema_version": 11' "$repo/.agents/workflow.json"
for request_contract in '"max_active": 5' '"request_key": "[codex-project-flow:request:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; requestId=<exactRequestId>; generation=1"' '"request_id_assignment": "hub_before_first_work_output"' '"states": ["awaiting_authorization", "queued", "active", "awaiting_acceptance", "revision_pending", "accepted_archived"]' '"confirmation_fields": ["understanding", "execution_items"]' '"completion_fields": ["changes", "verification", "uncovered", "risk"]' '"initial_owner": "hub"' '"handoff_boundary": "exact_or_queued_execution_task_identity_established"' '"post_handoff_owner": "execution_task"' '"hub_post_handoff": "no_participation_for_same_request"' '"acceptance_owner": "execution_task"' '"acceptance_archive": "exact_self_archive_success_and_matching_archived_task_id_required"' '"rejection_route": "execution_task_reconfirm_in_place"' '"scope_change_route": "execution_task_reconfirm_in_place"' '"awaiting_acceptance_occupies_slot": true' '"supplemental_authorization": "continue_original_task"' '"different_goal": "parallel_when_disjoint_and_slot_available_else_queue"' '"scope_change": "pause_for_execution_task_confirmation_then_continue_original_task"' '"replacement": "explicit_user_authorization"' '"serial": ["same_request", "overlapping_paths", "upgrade_file_transaction"]';do
 grep -Fq "$request_contract" "$repo/.agents/workflow.json"
done
for document_contract in '"default_extension": ".md"' '"standalone_cover": false' '"first_heading": "#"' '"heading_progression": "no_skipped_levels"' '"validation_scope": "created_or_updated_delivery_documents"' '"required": true' '"scope": "all_new_or_modified_non_deployment_markdown_documents"' '"draft_delivery": "complete_plain_text_in_chat_before_write"' '"states": ["draft_pending_review", "approved_for_write", "revision_required", "written"]' '"approval_evidence": "explicit_user_chat_approval_bound_to_exact_path_and_content_sha256"' '"write_authorization": "approved_exact_content_only"';do
 grep -Fq "$document_contract" "$repo/.agents/workflow.json"
done
for deployment_exception in '"bootstrap_managed_markdown": "no_draft_review_for_install_or_recovery"' '"upgrade_managed_markdown": "no_draft_review_for_apply_resume_or_rollback"' '"non_deployment_markdown": "normal_review_required"'; do
 grep -Fq "$deployment_exception" "$repo/.agents/workflow.json"
done
for bootstrap_contract in '"registry_path": ".project-flow/hub.json"' '"lock_path": ".project-flow/bootstrap.lock"' '"fast_path": "registry_targeted_read"' '"recovery_path": "exhaustive_metadata_on_exception"' '"title_identity": "saved_project_binding_plus_mutation_thread"' '"unarchive": "only_when_explicitly_archived"' '"lock_inspect": "validated_read_only"' '"existing_lock": "inspect_then_recover_or_stop"' '"claim_title": "[cpf-claim] <shortClaimId>"';do
 grep -Fq "$bootstrap_contract" "$repo/.agents/workflow.json"
done
"$python_cmd" - "$repo/.agents/workflow.json" <<'PY'
import json,pathlib,sys
workflow=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
retired={"authorization","handoff","scope","snapshot","failure","release"}
unexpected=sorted(retired.intersection(workflow))
assert not unexpected, "retired top-level workflow fields remain: " + ", ".join(unexpected)
PY
grep -Fq '"attempt_deadline_seconds": 60' "$repo/.agents/workflow.json"
grep -Fq '"include_outputs": false' "$repo/.agents/workflow.json"
grep -Fq '"poll_scan_latest_turns": 3' "$repo/.agents/workflow.json"
grep -Fq '"transaction_task_role": "visible_coordinator_executor"' "$repo/.agents/workflow.json"
grep -Fq '"post_handoff_owner": "transaction_task"' "$repo/.agents/workflow.json"
grep -Fq '"barrier_owner": "transaction_task"' "$repo/.agents/workflow.json"
for retired_upgrade_contract in '"hub_handshake"' '"hub_followups"' '"successor_key"' '"task_handshake"' '"successor_creation"' '"pair_order"' '"successor_followups"' '"compensating_successors"'; do
 if grep -Fq "$retired_upgrade_contract" "$repo/.agents/workflow.json"; then echo "retired post-handoff hub contract remains: $retired_upgrade_contract" >&2; exit 1; fi
done
"$python_cmd" - "$repo/.agents/workflow.json" <<'PY'
import json,pathlib,sys
upgrade=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8-sig"))["upgrade"]
assert "recovery" not in upgrade, "retired upgrade recovery container remains"
PY
grep -Fq '"listing": "exhaustive_metadata"' "$repo/.agents/workflow.json"
grep -Fq '"history": "targeted"' "$repo/.agents/workflow.json"
grep -Fq '"fallback": "full_on_ambiguity"' "$repo/.agents/workflow.json"
grep -Fq '"zero_active_fast_path": true' "$repo/.agents/workflow.json"
grep -Fq '"mode": "explicit_user_authorization_only"' "$repo/.agents/workflow.json"
grep -Fq '"protocol": 4' "$repo/.agents/workflow.json"
grep -Fq '"active_snapshot": "empty_required_before_file_transaction_fail_closed"' "$repo/.agents/workflow.json"
grep -Fq '"creation_gate": "hub_exhaustive_check_blocks_on_provisional_and_active_before_every_creation"' "$repo/.agents/workflow.json"
"$python_cmd" - "$repo/.agents/workflow.json" <<'PY'
import json,pathlib,sys
workflow=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
occupying={"active","blocked","waiting","queued","awaiting_acceptance"}
def can_materialize(states, existing_paths, requested_paths, barrier, scan_complete=True):
    return (scan_complete and barrier not in {"provisional","active"}
            and sum(state in occupying for state in states) < workflow["tasks"]["max_active"]
            and not set(existing_paths).intersection(requested_paths))
assert can_materialize(["active","blocked","waiting","queued"],["src/a.cpp"],["src/b.cpp"],None)
assert not can_materialize(["active","blocked","waiting","queued","awaiting_acceptance"],["src/a.cpp"],["src/b.cpp"],None)
assert not can_materialize(["active"],["src/shared.cpp"],["src/shared.cpp"],None)
assert not can_materialize([],[],["src/new.cpp"],None,False), "incomplete barrier scan admitted a task"
created=0
for barrier in ("provisional","active"):
    if can_materialize([],[],["src/new.cpp"],barrier): created+=1
assert created==0, "upgrade creation barrier admitted a new execution task"
assert can_materialize([],[],["src/new.cpp"],"released"), "released barrier did not resume task creation"
PY
grep -Fq '"provisional": "[codex-project-flow:upgrade-barrier:v1] state=provisional; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>"' "$repo/.agents/workflow.json"
grep -Fq '"active": "[codex-project-flow:upgrade-barrier:v1] state=active; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>"' "$repo/.agents/workflow.json"
grep -Fq '"released": "[codex-project-flow:upgrade-barrier:v1] state=released; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>"' "$repo/.agents/workflow.json"
grep -Fq '"cancelled": "[codex-project-flow:upgrade-barrier:v1] state=cancelled; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>"' "$repo/.agents/workflow.json"
echo "All POSIX regression tests passed."
