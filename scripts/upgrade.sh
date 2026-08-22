#!/bin/sh
set -eu

script_root=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
plugin_root=$(CDPATH= cd -P "$script_root/.." && pwd -P)

command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required by upgrade.sh" >&2
    exit 3
}

exec python3 - "$plugin_root" "$@" <<'PY'
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import uuid

plugin_root = Path(sys.argv[1]).resolve()
argv = sys.argv[2:]

parser = argparse.ArgumentParser(description="Safely upgrade an installed codex-project-flow project.")
parser.add_argument("target_positional", nargs="?")
parser.add_argument("--target", default=None)
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--plan", action="store_true")
mode.add_argument("--apply", action="store_true")
mode.add_argument("--rollback", metavar="TRANSACTION")
parser.add_argument("--adopt-from", metavar="VERSION")
parser.add_argument("--project-name")
parser.add_argument("--accept-local", action="append", default=[], metavar="PATH")
args = parser.parse_args(argv)

if args.accept_local and not args.apply:
    parser.error("--accept-local requires --apply")

target_arg = args.target or args.target_positional or "."
target_lexical = Path(os.path.abspath(target_arg))
if not target_lexical.is_dir():
    raise SystemExit("Target directory does not exist: " + str(target_lexical))
if target_lexical.is_symlink():
    raise SystemExit("Target directory must not be a symbolic link: " + str(target_lexical))
target_root = Path(os.path.realpath(target_lexical))

CONTROL = ".project-flow"
MANIFEST_REL = ".project-flow/manifest.json"
VALID_POLICIES = {"seed_once", "merge_manual", "structured_manual", "replace_if_unmodified"}

def fail(message, code=3):
    print("ERROR " + message, file=sys.stderr)
    raise SystemExit(code)

def safe_relative(value):
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        fail("Unsafe relative path: " + repr(value))
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        fail("Unsafe relative path: " + value)
    if re.match(r"^[A-Za-z]:", value) or path.parts[0] == CONTROL:
        fail("Unsafe or reserved managed path: " + value)
    return path

def plugin_input(relative, label, allow_missing_tail=False):
    rel = safe_relative(relative)
    current = plugin_root
    missing = False
    for part in rel.parts:
        current = current / part
        if missing:
            continue
        try:
            item = current.lstat()
        except FileNotFoundError:
            if allow_missing_tail:
                missing = True
                continue
            fail(label + " is missing or unsafe: " + str(rel))
        if stat.S_ISLNK(item.st_mode):
            fail(label + " path uses a symbolic link: " + str(rel))
    result = plugin_root.joinpath(*rel.parts)
    if not missing:
        try:
            final_item = result.lstat()
        except FileNotFoundError:
            fail(label + " is missing or unsafe: " + str(rel))
        if not stat.S_ISREG(final_item.st_mode):
            fail(label + " is not a regular file: " + str(rel))
    return result

def destination(relative, allow_control=False):
    if allow_control:
        if not isinstance(relative, str) or not relative or "\\" in relative or "\x00" in relative:
            fail("Unsafe control path: " + repr(relative))
        rel = PurePosixPath(relative)
        if rel.is_absolute() or any(part in ("", ".", "..") for part in rel.parts):
            fail("Unsafe control path: " + relative)
    else:
        rel = safe_relative(relative)
    current = target_root
    for part in rel.parts:
        current = current / part
        try:
            item = current.lstat()
        except FileNotFoundError:
            break
        if stat.S_ISLNK(item.st_mode):
            fail("Refusing path through a symbolic link: " + str(current))
    return target_root.joinpath(*rel.parts)

def ensure_directory(path):
    try:
        relative = path.relative_to(target_root)
    except ValueError:
        fail("Refusing directory outside target: " + str(path))
    current = target_root
    for part in relative.parts:
        current = current / part
        try:
            item = current.lstat()
        except FileNotFoundError:
            os.mkdir(current)
            continue
        if stat.S_ISLNK(item.st_mode) or not stat.S_ISDIR(item.st_mode):
            fail("Directory path is not a real directory: " + str(current))

def normalize_text_bytes(data, label):
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(label + " is not UTF-8 text: " + str(exc))
    return text.replace("\r\n", "\n").replace("\r", "\n")

def read_normalized(path, label=None):
    if not path.is_file():
        fail((label or str(path)) + " is missing or is not a regular file")
    if path.is_symlink():
        fail((label or str(path)) + " must not be a symbolic link")
    return normalize_text_bytes(path.read_bytes(), label or str(path))

def digest_text(text):
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()

def digest_file(path, label=None):
    return digest_text(read_normalized(path, label))

def atomic_write_bytes(path, data):
    ensure_directory(path.parent)
    if path.exists() and (path.is_symlink() or not path.is_file()):
        fail("Refusing to replace a non-file: " + str(path))
    temporary = path.with_name(path.name + ".project-flow-tmp-" + str(os.getpid()) + "-" + uuid.uuid4().hex[:8])
    try:
        with open(temporary, "xb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass

def atomic_write(path, text):
    atomic_write_bytes(path, text.encode("utf-8"))

def load_json(path, label):
    try:
        return json.loads(read_normalized(path, label))
    except json.JSONDecodeError as exc:
        fail(label + " is invalid JSON: " + str(exc))

managed_path = plugin_input("managed-files.json", "managed-files.json")
managed = load_json(managed_path, "managed-files.json")
if managed.get("schema_version") != 1 or not isinstance(managed.get("workflow_version"), str):
    fail("Unsupported managed-files.json schema")
new_version = managed["workflow_version"]
entries = managed.get("files")
if not isinstance(entries, list) or not entries:
    fail("managed-files.json files must be a non-empty array")

seen = set()
for entry in entries:
    if not isinstance(entry, dict):
        fail("Every managed file entry must be an object")
    rel = str(safe_relative(entry.get("path")))
    source_rel = str(safe_relative(entry.get("source")))
    if rel in seen:
        fail("Duplicate managed path: " + rel)
    seen.add(rel)
    if entry.get("policy") not in VALID_POLICIES:
        fail("Unsupported policy for " + rel)
    if entry.get("render") not in ("project_name", "project_name_json"):
        fail("Unsupported render mode for " + rel)
    plugin_input(source_rel, "managed source")

if "docs/PROJECT_STATE.md" not in seen:
    fail("docs/PROJECT_STATE.md must be managed")
state_entry = next(item for item in entries if item["path"] == "docs/PROJECT_STATE.md")
if state_entry.get("policy") != "seed_once":
    fail("docs/PROJECT_STATE.md must use seed_once")

def render(text, render_mode, project_name):
    if render_mode == "project_name_json":
        replacement = json.dumps(project_name, ensure_ascii=False)
        return text.replace('"<PROJECT_NAME>"', replacement)
    return text.replace("<PROJECT_NAME>", project_name)

def validate_project_name(name):
    if not isinstance(name, str) or not name.strip() or any(ord(ch) < 32 or ord(ch) == 127 for ch in name):
        fail("Project name must be a non-empty string without control characters")
    return name

manifest_path = destination(MANIFEST_REL, allow_control=True)
manifest = None
if manifest_path.exists():
    manifest = load_json(manifest_path, MANIFEST_REL)
    if manifest.get("schema_version") != 1:
        fail("Unsupported manifest schema")
    if args.adopt_from:
        fail("--adopt-from is only valid when the target has no manifest")
elif not args.rollback and args.adopt_from != "0.2.0":
    fail("Missing .project-flow/manifest.json; explicitly pass --adopt-from 0.2.0 for a confirmed legacy deployment")

def infer_project_name():
    if args.project_name is not None:
        return validate_project_name(args.project_name)
    if manifest is not None:
        value = manifest.get("project_name")
        if value is None and isinstance(manifest.get("project"), dict):
            value = manifest["project"].get("name")
        return validate_project_name(value)
    workflow = destination(".agents/workflow.json")
    if workflow.is_file():
        data = load_json(workflow, ".agents/workflow.json")
        if isinstance(data.get("project"), dict) and data["project"].get("name") != "<PROJECT_NAME>":
            return validate_project_name(data["project"].get("name"))
    return validate_project_name(target_root.name)

def transaction_id():
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return stamp + "-" + str(os.getpid()) + "-" + uuid.uuid4().hex[:8]

def transaction_root(identifier):
    if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", identifier):
        fail("Invalid transaction identifier")
    return destination(CONTROL + "/transactions/" + identifier, allow_control=True)

def transaction_json_path(identifier):
    return transaction_root(identifier) / "transaction.json"

def remove_empty_parents(path):
    current = path.parent
    while current != target_root and current.name != CONTROL:
        try:
            current.rmdir()
        except OSError:
            break
        current = current.parent

def rollback(identifier, automatic=False):
    root = transaction_root(identifier)
    meta_path = root / "transaction.json"
    if not root.is_dir() or root.is_symlink():
        fail("Transaction does not exist or is unsafe: " + identifier)
    meta = load_json(meta_path, "transaction.json")
    if meta.get("schema_version") != 1 or meta.get("transaction_id") != identifier:
        fail("Invalid transaction metadata")
    if meta.get("target") != str(target_root):
        fail("Transaction belongs to a different target")
    if meta.get("state") == "rolled_back":
        print("NOOP transaction already rolled back: " + identifier)
        return
    if meta.get("state") not in ("prepared", "validating", "applied"):
        fail("Transaction is not rollback-eligible: " + str(meta.get("state")))

    raw_records = meta.get("files")
    if not isinstance(raw_records, list):
        fail("Transaction files must be an array")
    decisions = []
    record_paths = set()
    for record in raw_records:
        if not isinstance(record, dict) or record.get("path") not in seen or record.get("path") in record_paths:
            fail("Transaction contains an invalid or duplicate managed path")
        record_paths.add(record["path"])
        rel = record.get("path")
        live = destination(rel)
        if not record.get("changed"):
            continue
        if live.exists() and (live.is_symlink() or not live.is_file()):
            fail("Rollback target is not a regular file: " + rel)
        current_hash = digest_file(live, rel) if live.is_file() else None
        if current_hash == record.get("applied_hash"):
            decisions.append((record, live, "restore"))
        elif current_hash == record.get("original_hash"):
            decisions.append((record, live, "unchanged"))
        else:
            fail("Refusing rollback because a live file changed after apply: " + rel)

    manifest_current = digest_file(manifest_path, MANIFEST_REL) if manifest_path.is_file() else None
    if manifest_current == meta.get("new_manifest_hash"):
        manifest_decision = "restore"
    elif manifest_current == meta.get("old_manifest_hash"):
        manifest_decision = "unchanged"
    else:
        fail("Refusing rollback because the manifest changed after apply")

    for record, live, decision in decisions:
        if decision == "unchanged":
            continue
        if record.get("existed"):
            backup = destination(CONTROL + "/transactions/" + identifier + "/backup/" + record["path"], allow_control=True)
            text = read_normalized(backup, "backup for " + record["path"])
            if digest_text(text) != record.get("original_hash"):
                fail("Backup hash mismatch for " + record["path"])
            atomic_write_bytes(live, backup.read_bytes())
        elif live.exists():
            live.unlink()
            remove_empty_parents(live)

    if manifest_decision == "restore":
        if meta.get("old_manifest_hash") is None:
            if manifest_path.exists():
                manifest_path.unlink()
        else:
            backup_manifest = destination(CONTROL + "/transactions/" + identifier + "/backup/" + CONTROL + "/manifest.json", allow_control=True)
            text = read_normalized(backup_manifest, "manifest backup")
            if digest_text(text) != meta.get("old_manifest_hash"):
                fail("Manifest backup hash mismatch")
            atomic_write_bytes(manifest_path, backup_manifest.read_bytes())

    meta["state"] = "rolled_back"
    meta["rolled_back_at_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    meta["automatic_rollback"] = bool(automatic)
    atomic_write(meta_path, json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    print("ROLLED_BACK " + identifier)

if args.rollback:
    if args.adopt_from or args.project_name:
        fail("Rollback does not accept adoption or project-name options")
    rollback(args.rollback)
    raise SystemExit(0)

project_name = infer_project_name()
installed_version = args.adopt_from if manifest is None else manifest.get("workflow_version")
if not isinstance(installed_version, str) or not installed_version:
    fail("Manifest workflow_version is missing")
if installed_version not in ("0.2.0", new_version):
    fail("No supported migration from " + installed_version + " to " + new_version)

introduced = set()
if installed_version == "0.2.0" and installed_version != new_version:
    migration_path = plugin_input(
        "migrations/" + installed_version + "-to-" + new_version + ".json",
        "migration descriptor",
    )
    migration = load_json(migration_path, "migration descriptor")
    if migration.get("from_version") != installed_version or migration.get("to_version") != new_version:
        fail("Migration descriptor does not match requested versions")
    introduced_raw = migration.get("introduced_files", [])
    if not isinstance(introduced_raw, list):
        fail("Migration introduced_files must be an array")
    for rel in introduced_raw:
        rel = str(safe_relative(rel))
        if rel not in seen:
            fail("Migration introduces an unmanaged path: " + rel)
        if rel in introduced:
            fail("Migration contains a duplicate introduced path: " + rel)
        introduced.add(rel)
        baseline_candidate = plugin_input(
            "baselines/" + installed_version + "/" + rel,
            "introduced-file baseline candidate",
            allow_missing_tail=True,
        )
        if baseline_candidate.exists():
            fail("Introduced path must not have an old-version baseline: " + rel)

manifest_entries = {}
if manifest is not None:
    raw_entries = manifest.get("files", manifest.get("managed_files", []))
    if isinstance(raw_entries, dict):
        raw_entries = [dict(value, path=key) for key, value in raw_entries.items() if isinstance(value, dict)]
    if not isinstance(raw_entries, list):
        fail("Manifest files must be an array or object")
    for item in raw_entries:
        if isinstance(item, dict) and isinstance(item.get("path"), str):
            if item["path"] in manifest_entries:
                fail("Manifest contains a duplicate path: " + item["path"])
            manifest_entries[item["path"]] = item
    expected_manifest_paths = seen if installed_version == new_version else seen - introduced
    if set(manifest_entries) != expected_manifest_paths:
        fail("Manifest managed paths do not match managed-files.json")
    for rel, item in manifest_entries.items():
        if not isinstance(item.get("baseline_hash"), str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", item["baseline_hash"]):
            fail("Manifest baseline_hash is missing or invalid for " + rel)
        managed_entry = next(entry for entry in entries if entry["path"] == rel)
        if item.get("source") != managed_entry["source"] or item.get("policy") != managed_entry["policy"]:
            fail("Manifest source or policy does not match managed-files.json for " + rel)

plans = []
for entry in entries:
    rel = entry["path"]
    live = destination(rel)
    if live.exists() and (live.is_symlink() or not live.is_file()):
        fail("Managed target is not a regular file: " + rel)
    source_text = read_normalized(plugin_input(entry["source"], "managed source"), entry["source"])
    new_text = render(source_text, entry["render"], project_name)
    new_hash = digest_text(new_text)

    if installed_version == new_version:
        base_text = new_text
    elif rel in introduced:
        base_text = None
    else:
        baseline_path = plugin_input(
            "baselines/" + installed_version + "/" + rel,
            "baseline " + rel,
        )
        base_text = render(read_normalized(baseline_path, "baseline " + rel), entry["render"], project_name)
    base_hash = digest_text(base_text) if base_text is not None else None
    recorded = manifest_entries.get(rel, {}).get("baseline_hash")
    if recorded is not None and recorded != base_hash:
        fail("Manifest baseline hash does not match the immutable baseline for " + rel)

    live_text = read_normalized(live, rel) if live.is_file() else None
    live_hash = digest_text(live_text) if live_text is not None else None
    policy = entry["policy"]
    if live_text is None:
        action = "CREATE"
    elif base_text is None:
        action = "NOOP" if live_hash == new_hash else "CONFLICT"
    elif policy == "seed_once":
        action = "NOOP" if live_hash == new_hash else "PRESERVE"
    elif live_hash == new_hash:
        action = "NOOP"
    elif live_hash == base_hash:
        action = "REPLACE"
    elif base_hash == new_hash:
        action = "PRESERVE"
    else:
        action = "CONFLICT"
    plans.append({
        "path": rel,
        "source": entry["source"],
        "policy": policy,
        "action": action,
        "base_hash": base_hash,
        "live_hash": live_hash,
        "new_hash": new_hash,
        "base_text": base_text,
        "live_text": live_text,
        "new_text": new_text,
    })

accepted_local = set()
plans_by_path = {item["path"]: item for item in plans}
for raw_path in args.accept_local:
    rel = str(safe_relative(raw_path))
    if rel in accepted_local:
        fail("Duplicate --accept-local path: " + rel)
    accepted_local.add(rel)
    item = plans_by_path.get(rel)
    if item is None:
        fail("--accept-local path is not managed: " + rel)
    if item["action"] != "CONFLICT":
        fail("--accept-local is valid only for a current conflict: " + rel)
    item["action"] = "ACCEPT"

print("UPGRADE " + installed_version + " -> " + new_version)
print("TARGET " + str(target_root))
for item in plans:
    print("%-8s %-22s %s" % (item["action"], item["policy"], item["path"]))

conflicts = [item for item in plans if item["action"] == "CONFLICT"]
changes = [item for item in plans if item["action"] in ("CREATE", "REPLACE")]
if not args.apply:
    print("PLAN changes=%d conflicts=%d" % (len(changes), len(conflicts)))
    raise SystemExit(0)

if conflicts:
    identifier = transaction_id()
    staging = destination(CONTROL + "/staging/" + identifier, allow_control=True)
    if staging.exists():
        fail("Staging transaction already exists: " + identifier)
    ensure_directory(staging)
    public_plan = {
        "schema_version": 1,
        "transaction_id": identifier,
        "from_version": installed_version,
        "to_version": new_version,
        "conflicts": [{key: item[key] for key in ("path", "policy", "base_hash", "live_hash", "new_hash")} for item in conflicts],
    }
    atomic_write(staging / "plan.json", json.dumps(public_plan, ensure_ascii=False, indent=2) + "\n")
    for item in conflicts:
        bundle = staging / "conflicts" / Path(*PurePosixPath(item["path"]).parts)
        ensure_directory(bundle)
        if item["base_text"] is not None:
            atomic_write(bundle / "base", item["base_text"])
        if item["live_text"] is not None:
            atomic_write(bundle / "local", item["live_text"])
        atomic_write(bundle / "upstream", item["new_text"])
    print("CONFLICTS " + str(staging / "conflicts"), file=sys.stderr)
    print("Live managed files and manifest were not changed.", file=sys.stderr)
    raise SystemExit(4)

if not changes and installed_version == new_version and manifest is not None:
    validator = plugin_root / "scripts" / "validate.sh"
    completed = subprocess.run(["sh", str(validator), str(target_root)], cwd=str(target_root))
    if completed.returncode != 0:
        fail("Current installation failed validation; refusing NOOP", completed.returncode or 5)
    print("NOOP already up to date")
    raise SystemExit(0)

identifier = transaction_id()
root = transaction_root(identifier)
if root.exists():
    fail("Transaction already exists: " + identifier)
backup_root = root / "backup"
ensure_directory(backup_root)
records = []
for item in plans:
    live = destination(item["path"])
    existed = live.is_file()
    record = {
        "path": item["path"],
        "existed": existed,
        "changed": item["action"] in ("CREATE", "REPLACE"),
        "original_hash": item["live_hash"],
        "applied_hash": item["new_hash"] if item["action"] in ("CREATE", "REPLACE") else item["live_hash"],
    }
    records.append(record)
    if existed:
        backup = backup_root / Path(*PurePosixPath(item["path"]).parts)
        ensure_directory(backup.parent)
        atomic_write_bytes(backup, live.read_bytes())

old_manifest_text = read_normalized(manifest_path, MANIFEST_REL) if manifest_path.is_file() else None
old_manifest_hash = digest_text(old_manifest_text) if old_manifest_text is not None else None
if old_manifest_text is not None:
    backup_manifest = backup_root / CONTROL / "manifest.json"
    ensure_directory(backup_manifest.parent)
    atomic_write_bytes(backup_manifest, manifest_path.read_bytes())

now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
new_manifest = {
    "schema_version": 1,
    "workflow_version": new_version,
    "project_name": project_name,
    "installed_at_utc": now,
    "last_transaction": identifier,
    "files": [
        {
            "path": item["path"],
            "source": item["source"],
            "policy": item["policy"],
            "baseline_hash": item["new_hash"],
        }
        for item in plans
    ],
}
new_manifest_text = json.dumps(new_manifest, ensure_ascii=False, indent=2) + "\n"
meta = {
    "schema_version": 1,
    "transaction_id": identifier,
    "target": str(target_root),
    "from_version": installed_version,
    "to_version": new_version,
    "state": "prepared",
    "created_at_utc": now,
    "old_manifest_hash": old_manifest_hash,
    "new_manifest_hash": digest_text(new_manifest_text),
    "accepted_local": sorted(accepted_local),
    "files": records,
}
meta_path = root / "transaction.json"
atomic_write(meta_path, json.dumps(meta, ensure_ascii=False, indent=2) + "\n")

try:
    for item in changes:
        atomic_write(destination(item["path"]), item["new_text"])
    atomic_write(manifest_path, new_manifest_text)
    meta["state"] = "validating"
    atomic_write(meta_path, json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    validator = plugin_root / "scripts" / "validate.sh"
    completed = subprocess.run(["sh", str(validator), str(target_root)], cwd=str(target_root))
    if completed.returncode != 0:
        print("ERROR post-upgrade validation failed; rolling back " + identifier, file=sys.stderr)
        rollback(identifier, automatic=True)
        raise SystemExit(completed.returncode or 5)
    meta["state"] = "applied"
    meta["validated_at_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    atomic_write(meta_path, json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
except SystemExit:
    raise
except Exception as exc:
    print("ERROR apply failed; attempting automatic rollback: " + str(exc), file=sys.stderr)
    rollback(identifier, automatic=True)
    raise SystemExit(5)

print("APPLIED " + identifier)
print("VALIDATION passed")
PY
