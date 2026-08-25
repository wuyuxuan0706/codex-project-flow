#!/bin/sh
set -eu

script_root=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
plugin_root=$(CDPATH= cd -P "$script_root/.." && pwd -P)

python_cmd=${PYTHON:-python3}
command -v "$python_cmd" >/dev/null 2>&1 || {
    echo "$python_cmd is required by install.sh" >&2
    exit 3
}

exec "$python_cmd" - "$plugin_root" "$@" <<'PY'
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

parser = argparse.ArgumentParser(description="Install codex-project-flow into a local project.")
parser.add_argument("target_positional", nargs="?")
parser.add_argument("project_name_positional", nargs="?")
parser.add_argument("--target")
parser.add_argument("--project-name")
parser.add_argument("--force", action="store_true")
parser.add_argument("--dry-run", action="store_true")
args = parser.parse_args(argv)

target_arg = args.target or args.target_positional or "."
project_name = args.project_name if args.project_name is not None else args.project_name_positional
target_lexical = Path(os.path.abspath(target_arg))
if not target_lexical.is_dir():
    raise SystemExit("Target directory does not exist: " + str(target_lexical))
if target_lexical.is_symlink():
    raise SystemExit("Target directory must not be a symbolic link: " + str(target_lexical))
target_root = Path(os.path.realpath(target_lexical))

CONTROL = ".project-flow"
MANIFEST_REL = ".project-flow/manifest.json"
BACKUP_ROOT_NAME = ".project-flow-backup"
VALID_POLICIES = {"seed_once", "merge_manual", "structured_manual", "replace_if_unmodified"}
VALID_RENDERS = {"project_name", "project_name_json"}

def fail(message, code=3):
    print("ERROR " + message, file=sys.stderr)
    raise SystemExit(code)

def normalize_text_bytes(data, label):
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(label + " is not UTF-8 text: " + str(exc))
    return text.replace("\r\n", "\n").replace("\r", "\n")

def read_normalized(path, label):
    try:
        item = path.lstat()
    except FileNotFoundError:
        fail(label + " is missing")
    if stat.S_ISLNK(item.st_mode) or not stat.S_ISREG(item.st_mode):
        fail(label + " is not a safe regular file")
    return normalize_text_bytes(path.read_bytes(), label)

def load_json(path, label):
    try:
        return json.loads(read_normalized(path, label))
    except json.JSONDecodeError as exc:
        fail(label + " is invalid JSON: " + str(exc))

def safe_relative(value, label, allow_control=False):
    if not isinstance(value, str) or not value or "\\" in value or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        fail("Unsafe " + label + ": " + repr(value))
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts) or re.match(r"^[A-Za-z]:", value):
        fail("Unsafe " + label + ": " + value)
    if not allow_control and path.parts[0] in (CONTROL, BACKUP_ROOT_NAME):
        fail("Reserved " + label + ": " + value)
    return path

def target_path(relative, allow_control=False):
    rel = safe_relative(relative, "target path", allow_control=allow_control)
    current = target_root
    for part in rel.parts:
        current = current / part
        try:
            item = current.lstat()
        except FileNotFoundError:
            break
        if stat.S_ISLNK(item.st_mode):
            fail("Refusing target path through a symbolic link: " + str(current))
    return target_root.joinpath(*rel.parts)

def source_path(relative):
    rel = safe_relative(relative, "managed source", allow_control=True)
    current = plugin_root
    for part in rel.parts:
        current = current / part
        try:
            item = current.lstat()
        except FileNotFoundError:
            fail("Managed source is missing: " + relative)
        if stat.S_ISLNK(item.st_mode):
            fail("Managed source path uses a symbolic link: " + relative)
    if not stat.S_ISREG(current.lstat().st_mode):
        fail("Managed source is not a regular file: " + relative)
    return current

def inspect_target_file(path, label):
    try:
        item = path.lstat()
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(item.st_mode) or not stat.S_ISREG(item.st_mode):
        fail(label + " exists and is not a safe regular file: " + str(path))
    return True

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

def atomic_write_bytes(path, data):
    ensure_directory(path.parent)
    if inspect_target_file(path, "Destination"):
        pass
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

def atomic_write_text(path, text):
    atomic_write_bytes(path, text.encode("utf-8"))

def digest_text(text):
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()

def render(text, mode):
    if mode == "project_name_json":
        return text.replace('"<PROJECT_NAME>"', json.dumps(project_name, ensure_ascii=False))
    return text.replace("<PROJECT_NAME>", project_name)

if project_name is None or not project_name.strip():
    project_name = target_root.name
if not project_name or any(ord(ch) < 32 or ord(ch) == 127 for ch in project_name):
    fail("Project name must be non-empty and must not contain control characters", 2)

version_path = plugin_root / "VERSION"
workflow_version = read_normalized(version_path, "VERSION").strip()
if not workflow_version or any(ord(ch) < 32 or ord(ch) == 127 for ch in workflow_version):
    fail("VERSION must contain one non-empty version without control characters")

managed = load_json(plugin_root / "managed-files.json", "managed-files.json")
if managed.get("schema_version") != 1 or managed.get("workflow_version") != workflow_version:
    fail("managed-files.json schema or workflow_version does not match VERSION")
raw_entries = managed.get("files")
if not isinstance(raw_entries, list) or not raw_entries:
    fail("managed-files.json files must be a non-empty array")

entries = []
seen = set()
for raw in raw_entries:
    if not isinstance(raw, dict):
        fail("Every managed file entry must be an object")
    relative = str(safe_relative(raw.get("path"), "managed path"))
    source_relative = str(safe_relative(raw.get("source"), "managed source", allow_control=True))
    if relative in seen:
        fail("Duplicate managed path: " + relative)
    seen.add(relative)
    policy = raw.get("policy")
    mode = raw.get("render")
    if policy not in VALID_POLICIES:
        fail("Unsupported policy for " + relative)
    if mode not in VALID_RENDERS:
        fail("Unsupported render mode for " + relative)
    source = source_path(source_relative)
    source_text = read_normalized(source, source_relative)
    entries.append({
        "path": relative,
        "source": source_relative,
        "policy": policy,
        "render": mode,
        "source_path": source,
        "rendered": render(source_text, mode),
    })

if "docs/PROJECT_STATE.md" not in seen:
    fail("docs/PROJECT_STATE.md must be managed")
state_entry = next(item for item in entries if item["path"] == "docs/PROJECT_STATE.md")
if state_entry["policy"] != "seed_once":
    fail("docs/PROJECT_STATE.md must use seed_once")

manifest_path = target_path(MANIFEST_REL, allow_control=True)
manifest_existed = inspect_target_file(manifest_path, "Manifest")
had_existing_managed = False
for entry in entries:
    destination = target_path(entry["path"])
    if inspect_target_file(destination, "Destination"):
        had_existing_managed = True

legacy_without_manifest = not args.force and not manifest_existed and had_existing_managed
if legacy_without_manifest and not args.dry_run:
    print("NOTICE Existing managed files were found without a manifest.")
    print("NOTICE The files will keep normal non-force skip behavior, but the manifest will not be initialized.")
    print("NOTICE Run the explicit upgrade with --adopt-from 0.2.0 to adopt this legacy installation.")

backup_stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup_relative = BACKUP_ROOT_NAME + "/" + backup_stamp
backup_root = target_path(backup_relative, allow_control=True)
suffix = 0
while backup_root.exists():
    suffix += 1
    backup_relative = BACKUP_ROOT_NAME + "/" + backup_stamp + "-" + str(suffix)
    backup_root = target_path(backup_relative, allow_control=True)

created = 0
replaced = 0
skipped = 0
written = 0
manifest_backed_up = False
manifest_changed = False
write_records = []

def backup_file(source, relative):
    backup = target_path(backup_relative + "/" + relative, allow_control=True)
    ensure_directory(backup.parent)
    shutil.copyfile(source, backup)

def restore_install():
    global manifest_changed
    for relative, existed in reversed(write_records):
        destination = target_path(relative)
        if existed:
            backup = target_path(backup_relative + "/" + relative, allow_control=True)
            atomic_write_bytes(destination, backup.read_bytes())
        elif destination.is_file():
            destination.unlink()
    if manifest_changed:
        if manifest_existed:
            backup = target_path(backup_relative + "/" + MANIFEST_REL, allow_control=True)
            atomic_write_bytes(manifest_path, backup.read_bytes())
        elif manifest_path.is_file():
            manifest_path.unlink()
        manifest_changed = False
    print("RESTORED install changes after validation failure.", file=sys.stderr)

if args.force and manifest_existed and not args.dry_run:
    backup_file(manifest_path, MANIFEST_REL)
    manifest_backed_up = True

try:
    for entry in entries:
        relative = entry["path"]
        destination = target_path(relative)
        exists = inspect_target_file(destination, "Destination")
        if exists and not args.force:
            print("SKIP  " + relative + " (already exists)")
            skipped += 1
            continue
        if args.dry_run:
            print(("REPLACE " if exists else "CREATE  ") + relative)
            continue
        if exists:
            backup_file(destination, relative)
            replaced += 1
        else:
            created += 1
        write_records.append((relative, exists))
        atomic_write_text(destination, entry["rendered"])
        written += 1
        print("WRITE " + relative)
except BaseException:
    if not args.dry_run:
        restore_install()
    raise

if args.dry_run:
    if args.force:
        print("DRY RUN manifest reset was not performed.")
    elif manifest_existed:
        print("PRESERVE " + MANIFEST_REL + " (already exists; dry run)")
    elif legacy_without_manifest:
        print("MANIFEST NOT INITIALIZED; explicit upgrade with --adopt-from 0.2.0 is required.")
    else:
        print("DRY RUN manifest initialization was not performed.")
    print("Dry run complete; no files changed and the manifest was not created or replaced.")
    raise SystemExit(0)

print("Installed: created=%d replaced=%d skipped=%d" % (created, replaced, skipped))
if backup_root.is_dir():
    print("Backups: " + str(backup_root))

validator = plugin_root / "scripts" / "validate.sh"
if not args.force:
    result = subprocess.run(["sh", str(validator), str(target_root)])
    if result.returncode != 0:
        restore_install()
        fail("Post-install validation exited with " + str(result.returncode), result.returncode)

initialize_manifest = False
replace_manifest = False
if args.force:
    if written != len(entries):
        restore_install()
        fail("Force reset did not render every managed file; manifest was preserved")
    initialize_manifest = True
    replace_manifest = manifest_existed
elif manifest_existed:
    print("PRESERVE " + MANIFEST_REL + " (already exists)")
elif legacy_without_manifest:
    print("MANIFEST NOT INITIALIZED; run the explicit upgrade with --adopt-from 0.2.0.")
else:
    if written != len(entries):
        restore_install()
        fail("Clean install did not render every managed file; manifest was not initialized")
    initialize_manifest = True

if initialize_manifest:
    manifest_files = []
    for entry in entries:
        destination = target_path(entry["path"])
        live_text = read_normalized(destination, entry["path"])
        baseline_hash = digest_text(entry["rendered"])
        if digest_text(live_text) != baseline_hash:
            restore_install()
            fail("Installed file does not match its rendered baseline: " + entry["path"])
        manifest_files.append({
            "path": entry["path"],
            "source": entry["source"],
            "policy": entry["policy"],
            "baseline_hash": baseline_hash,
        })
    manifest = {
        "schema_version": 1,
        "workflow_version": workflow_version,
        "project_name": project_name,
        "installed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "last_transaction": None,
        "files": manifest_files,
    }
    if replace_manifest and not manifest_backed_up:
        restore_install()
        fail("Refusing to replace a manifest that was not backed up")
    try:
        atomic_write_text(manifest_path, json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        manifest_changed = True
    except Exception:
        restore_install()
        raise
    print(("RESET " if replace_manifest else "WRITE ") + MANIFEST_REL)
    result = subprocess.run(["sh", str(validator), str(target_root)])
    if result.returncode != 0:
        restore_install()
        fail("Post-manifest validation exited with " + str(result.returncode), result.returncode)
PY
