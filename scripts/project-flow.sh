#!/bin/sh
set -eu

command_name=${1-}
[ -n "$command_name" ] || {
    echo "Usage: project-flow.sh {probe|install|upgrade|plan|apply|rollback|validate|hub-read|hub-write|hub-replacement-prepare|hub-replacement-commit|bootstrap-lock-inspect|bootstrap-lock-acquire|bootstrap-lock-renew|bootstrap-lock-release|bootstrap-lock-recover} [options]" >&2
    exit 2
}
shift

script_root=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
plugin_root=$(CDPATH= cd -P "$script_root/.." && pwd -P)
python_cmd=${PYTHON-python3}
command -v "$python_cmd" >/dev/null 2>&1 || {
    echo "$python_cmd is required by project-flow.sh" >&2
    exit 3
}

exec "$python_cmd" - "$plugin_root" "$command_name" "$@" <<'PY'
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import unicodedata
import uuid


PLUGIN_ROOT = Path(sys.argv[1]).resolve()
COMMAND = sys.argv[2]
ARGV = sys.argv[3:]
CONTROL = ".project-flow"
MANIFEST_REL = ".project-flow/manifest.json"
BACKUP_ROOT_NAME = ".project-flow-backup"
BOOTSTRAP_STALE_SECONDS = 300
VALID_POLICIES = {"seed_once", "merge_manual", "structured_manual", "replace_if_unmodified"}
VALID_RENDERS = {"none", "project_name", "project_name_json"}
VALID_OWNERSHIP = {"plugin", "mixed", "project"}
VALID_RESOLUTIONS = {"upstream_wins", "preserve_markdown_sections", "preserve"}
WRITER_LOCK_HANDLES = []


class FlowFailure(SystemExit):
    def __init__(self, message, code=3):
        super().__init__(code)
        self.message = message


def fail(message, code=3):
    print("ERROR " + message, file=sys.stderr)
    raise FlowFailure(message, code)


def error_detail(exc):
    if isinstance(exc, FlowFailure):
        return exc.message
    if isinstance(exc, SystemExit):
        return "exit " + str(exc.code)
    return str(exc) or exc.__class__.__name__


def reject_control(value, label):
    if not isinstance(value, str) or any(unicodedata.category(ch) == "Cc" for ch in value):
        fail(label + " contains a control character: " + repr(value))
    return value


def is_reparse(item):
    return stat.S_ISLNK(item.st_mode) or bool(
        getattr(item, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
    )


def normalized_bytes(data, label):
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(label + " is not UTF-8 text: " + str(exc))
    return text.replace("\r\n", "\n").replace("\r", "\n")


def read_text(path, label=None):
    label = label or str(path)
    try:
        item = path.lstat()
    except FileNotFoundError:
        fail(label + " is missing")
    if is_reparse(item) or not stat.S_ISREG(item.st_mode):
        fail(label + " is not a safe regular file")
    return normalized_bytes(path.read_bytes(), label)


def parse_json(text, label):
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        fail(label + " is invalid JSON: " + str(exc))
    if not isinstance(value, dict):
        fail(label + " JSON root must be an object")
    return value


def load_json(path, label=None):
    label = label or str(path)
    return parse_json(read_text(path, label), label)


def digest_text(text):
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def digest_file(path, label=None):
    return digest_text(read_text(path, label))


def safe_relative(value, label="relative path", allow_control=False):
    reject_control(value, label)
    if not value or "\\" in value:
        fail("Unsafe " + label + ": " + repr(value))
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        fail("Unsafe " + label + ": " + value)
    if re.match(r"^[A-Za-z]:", value):
        fail("Unsafe " + label + ": " + value)
    if not allow_control and path.parts[0] in (CONTROL, BACKUP_ROOT_NAME):
        fail("Reserved " + label + ": " + value)
    return path


def plugin_input(relative, label, allow_missing=False):
    rel = safe_relative(relative, label, allow_control=True)
    current = PLUGIN_ROOT
    missing = False
    for part in rel.parts:
        current = current / part
        if missing:
            continue
        try:
            item = current.lstat()
        except FileNotFoundError:
            if allow_missing:
                missing = True
                continue
            fail(label + " is missing: " + str(rel))
        if is_reparse(item):
            fail(label + " path uses a symbolic link: " + str(rel))
    result = PLUGIN_ROOT.joinpath(*rel.parts)
    if not missing:
        try:
            final = result.lstat()
        except FileNotFoundError:
            fail(label + " is missing: " + str(rel))
        if not stat.S_ISREG(final.st_mode):
            fail(label + " is not a regular file: " + str(rel))
    return result


def render(text, mode, project_name):
    if mode == "none":
        return text
    if mode == "project_name_json":
        return text.replace('"<PROJECT_NAME>"', json.dumps(project_name, ensure_ascii=False))
    return text.replace("<PROJECT_NAME>", project_name)


def validate_project_name(value):
    reject_control(value, "Project name")
    if not value.strip():
        fail("Project name must be non-empty")
    return value


def identity_value(value, label):
    reject_control(value, label)
    if not value.strip():
        fail(label + " must be non-empty")
    return value


def identifier(value, label):
    identity_value(value, label)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", value):
        fail(label + " contains an illegal identifier")
    return value


def utc_text(value=None):
    value = value or datetime.datetime.now(datetime.timezone.utc)
    return value.astimezone(datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_utc(value, label):
    reject_control(value, label)
    try:
        parsed = datetime.datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    except ValueError:
        fail(label + " must be a UTC timestamp")
    if parsed.tzinfo is None or parsed.utcoffset() != datetime.timedelta(0):
        fail(label + " must be a UTC timestamp")
    return parsed.astimezone(datetime.timezone.utc)


def same_project_path(actual, expected):
    identity_value(actual, "Project path")
    if os.name == "nt":
        return os.path.normcase(os.path.normpath(actual)) == os.path.normcase(os.path.normpath(expected))
    return actual == expected


def exact_object(value, expected, label):
    if not isinstance(value, dict) or set(value) != set(expected):
        fail(label + " has unexpected fields")
    return value


class Target:
    def __init__(self, argument):
        reject_control(argument, "Target path")
        lexical = Path(os.path.abspath(argument))
        if not lexical.is_dir():
            fail("Target directory does not exist: " + str(lexical), 2)
        if is_reparse(lexical.lstat()):
            fail("Target directory must not be a symbolic link: " + str(lexical))
        self.root = Path(os.path.realpath(lexical))

    def path(self, relative, allow_control=False):
        rel = safe_relative(relative, "target path", allow_control=allow_control)
        current = self.root
        for part in rel.parts:
            current = current / part
            try:
                item = current.lstat()
            except FileNotFoundError:
                break
            if is_reparse(item):
                fail("Refusing target path through a symbolic link: " + str(current))
        return self.root.joinpath(*rel.parts)

    def regular_exists(self, path, label="Destination"):
        try:
            item = path.lstat()
        except FileNotFoundError:
            return False
        if is_reparse(item) or not stat.S_ISREG(item.st_mode):
            fail(label + " exists and is not a safe regular file: " + str(path))
        return True

    def ensure_directory(self, path):
        try:
            relative = path.relative_to(self.root)
        except ValueError:
            fail("Refusing directory outside target: " + str(path))
        current = self.root
        for part in relative.parts:
            current = current / part
            try:
                item = current.lstat()
            except FileNotFoundError:
                os.mkdir(current)
                continue
            if is_reparse(item) or not stat.S_ISDIR(item.st_mode):
                fail("Directory path is not a real directory: " + str(current))

    def atomic_bytes(self, path, data):
        self.ensure_directory(path.parent)
        if path.exists() and (is_reparse(path.lstat()) or not path.is_file()):
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

    def atomic_text(self, path, text):
        self.atomic_bytes(path, text.encode("utf-8"))


def acquire_writer_lock(target):
    lock_path = target.path(CONTROL + "/transaction.lock", allow_control=True)
    target.ensure_directory(lock_path.parent)
    try:
        item = lock_path.lstat()
    except FileNotFoundError:
        item = None
    if item is not None and (is_reparse(item) or not stat.S_ISREG(item.st_mode)):
        fail("Writer lock path is not a safe regular file", 5)
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(lock_path, flags, 0o600)
        handle = os.fdopen(descriptor, "r+b", buffering=0)
    except OSError as exc:
        fail("Writer lock is busy or unavailable: " + str(exc), 5)
    try:
        if os.fstat(handle.fileno()).st_size == 0:
            handle.write(b"\0")
            handle.flush()
            os.fsync(handle.fileno())
        handle.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        handle.close()
        fail("Writer lock is busy: " + str(exc), 5)
    WRITER_LOCK_HANDLES.append(handle)
    return lock_path


def bootstrap_lock_path(target):
    return target.path(CONTROL + "/bootstrap.lock", allow_control=True)


def close_bootstrap_lock(handle):
    try:
        handle.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


def write_bootstrap_lock(handle, record):
    data = (json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    handle.seek(0)
    handle.truncate(0)
    handle.write(data)
    handle.flush()
    os.fsync(handle.fileno())


def hub_path(target):
    return target.path(CONTROL + "/hub.json", allow_control=True)


def new_bootstrap_lock_record(target, project_id, owner_id, thread_id, phase, lease_seconds, replacement=None):
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp = utc_text(now)
    bound_thread = identifier(thread_id, "ThreadId") if thread_id else None
    return {"schemaVersion": 2, "projectId": identifier(project_id, "ProjectId"), "projectPath": str(target.root), "ownerId": identifier(owner_id, "OwnerId"), "threadId": bound_thread, "phase": identity_value(phase, "Phase"), "createdAt": stamp, "renewedAt": stamp, "expiresAt": utc_text(now + datetime.timedelta(seconds=lease_seconds)), "replacement": replacement}


def validate_bootstrap_lock(record, target, project_id):
    common = ("schemaVersion", "projectId", "projectPath", "ownerId", "threadId", "phase", "createdAt", "renewedAt", "expiresAt")
    if record.get("schemaVersion") == 1:
        exact_object(record, common, "Bootstrap lock")
        record["replacement"] = None
    elif record.get("schemaVersion") == 2:
        exact_object(record, common + ("replacement",), "Bootstrap lock")
    else:
        fail("Bootstrap lock schema is invalid")
    identifier(record["projectId"], "Bootstrap lock projectId")
    identity_value(record["projectPath"], "Bootstrap lock projectPath")
    identifier(record["ownerId"], "Bootstrap lock ownerId")
    identity_value(record["phase"], "Bootstrap lock phase")
    if record["threadId"] is not None:
        identifier(record["threadId"], "Bootstrap lock threadId")
    replacement = record["replacement"]
    if replacement is not None:
        exact_object(replacement, ("expectedHubThreadId", "expectedRegistryToken", "newHubThreadId", "newHubTitle"), "Bootstrap lock replacement")
        identifier(replacement["expectedHubThreadId"], "ExpectedHubThreadId")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", replacement["expectedRegistryToken"]): fail("ExpectedRegistryToken must be a lowercase raw SHA-256 token")
        identifier(replacement["newHubThreadId"], "NewHubThreadId")
        identity_value(replacement["newHubTitle"], "NewHubTitle")
        if record["threadId"] != replacement["newHubThreadId"]: fail("Bootstrap replacement evidence does not match the bound current task")
    if record["projectId"] != identifier(project_id, "ProjectId"):
        fail("Bootstrap lock projectId does not match the expected project")
    if not same_project_path(record["projectPath"], str(target.root)):
        fail("Bootstrap lock project path does not match this target")
    created = parse_utc(record["createdAt"], "Bootstrap lock createdAt")
    renewed = parse_utc(record["renewedAt"], "Bootstrap lock renewedAt")
    expires = parse_utc(record["expiresAt"], "Bootstrap lock expiresAt")
    if renewed < created or expires <= renewed:
        fail("Bootstrap lock timestamps are inconsistent")
    return record


def open_existing_bootstrap_lock(target):
    path = bootstrap_lock_path(target)
    if not target.regular_exists(path, "Bootstrap lock"):
        fail("Bootstrap lock is missing: " + str(path))
    flags = os.O_RDWR | (getattr(os, "O_BINARY", 0)) | (getattr(os, "O_NOFOLLOW", 0))
    try:
        if os.name == "nt":
            import ctypes
            import msvcrt
            create_file = ctypes.windll.kernel32.CreateFileW
            create_file.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
            create_file.restype = ctypes.c_void_p
            raw = create_file(str(path), 0x80000000 | 0x40000000, 0x00000001 | 0x00000002 | 0x00000004, None, 3, 0x00000080 | 0x00200000, None)
            if raw in (None, ctypes.c_void_p(-1).value):
                raise OSError(ctypes.get_last_error(), "CreateFileW failed")
            handle = os.fdopen(msvcrt.open_osfhandle(raw, flags), "r+b", buffering=0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            handle = os.fdopen(os.open(path, flags), "r+b", buffering=0)
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return path, handle
    except OSError as exc:
        try: handle.close()
        except UnboundLocalError: pass
        fail("Bootstrap lock is busy or unavailable: " + str(exc), 1)


def read_bootstrap_lock(handle, target, project_id):
    handle.seek(0)
    return validate_bootstrap_lock(parse_json(normalized_bytes(handle.read(), CONTROL + "/bootstrap.lock"), CONTROL + "/bootstrap.lock"), target, project_id)


def bootstrap_stale_at(record):
    renewed = parse_utc(record["renewedAt"], "Bootstrap lock renewedAt")
    expires = parse_utc(record["expiresAt"], "Bootstrap lock expiresAt")
    return max(expires, renewed + datetime.timedelta(seconds=BOOTSTRAP_STALE_SECONDS))


def bootstrap_inspect_command(argv):
    parser = argparse.ArgumentParser(description="Read and validate the project-local bootstrap lock without changing it.")
    parser.add_argument("--target", default=".")
    parser.add_argument("--project-id", required=True)
    args = parser.parse_args(argv)
    target = Target(args.target); _, handle = open_existing_bootstrap_lock(target)
    try:
        record = read_bootstrap_lock(handle, target, args.project_id)
        stale_at = bootstrap_stale_at(record)
        result = dict(record); result["staleAt"] = utc_text(stale_at); result["isStale"] = datetime.datetime.now(datetime.timezone.utc) >= stale_at
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    finally: close_bootstrap_lock(handle)


def bootstrap_parser(description, owner=True, expected=False):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--target", default=".")
    parser.add_argument("--project-id", required=True)
    if owner: parser.add_argument("--owner-id", required=True)
    parser.add_argument("--thread-id")
    parser.add_argument("--phase", required=True)
    parser.add_argument("--lease-seconds", type=int, default=300)
    if expected:
        parser.add_argument("--expected-owner-id", required=True)
        parser.add_argument("--expected-renewed-at", required=True)
        parser.add_argument("--confirmed-owner-inactive", action="store_true")
        parser.add_argument("--confirmed-orphaned-claim", action="store_true")
    return parser


def bootstrap_acquire_command(argv):
    args = bootstrap_parser("Atomically create the project-local bootstrap lock.").parse_args(argv)
    if not 1 <= args.lease_seconds <= 3600: raise SystemExit("--lease-seconds must be between 1 and 3600")
    target = Target(args.target); path = bootstrap_lock_path(target); target.ensure_directory(path.parent)
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        handle = os.fdopen(os.open(path, flags, 0o600), "w+b", buffering=0)
    except FileExistsError:
        fail("Bootstrap lock already exists; normal acquire never takes over an active lock", 1)
    try:
        if os.name == "nt":
            import msvcrt; handle.write(b"\0"); handle.flush(); os.fsync(handle.fileno()); handle.seek(0); msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl; fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        record = new_bootstrap_lock_record(target, args.project_id, args.owner_id, args.thread_id, args.phase, args.lease_seconds); write_bootstrap_lock(handle, record); print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
    finally: close_bootstrap_lock(handle)


def bootstrap_recover_command(argv):
    args = bootstrap_parser("Recover only a verified stale bootstrap lock.", expected=True).parse_args(argv)
    target = Target(args.target); _, handle = open_existing_bootstrap_lock(target)
    try:
        old = read_bootstrap_lock(handle, target, args.project_id)
        if old["ownerId"] != identifier(args.expected_owner_id, "ExpectedOwnerId"): fail("Bootstrap lock owner does not match expected stale owner")
        parse_utc(args.expected_renewed_at, "ExpectedRenewedAt")
        if old["renewedAt"] != args.expected_renewed_at: fail("Bootstrap lock changed after inspection; refusing stale recovery")
        stale_at = bootstrap_stale_at(old)
        if datetime.datetime.now(datetime.timezone.utc) < stale_at: fail("Bootstrap lock is not stale enough to recover")
        requested = identifier(args.thread_id, "ThreadId") if args.thread_id else None
        if old["threadId"] is not None:
            if not args.confirmed_owner_inactive: fail("Bound bootstrap recovery requires --confirmed-owner-inactive")
            if args.confirmed_orphaned_claim: fail("A bound bootstrap lock cannot use orphan recovery")
            if requested != old["threadId"]: fail("A bound bootstrap lock must recover the same thread")
        elif requested is None:
            if not args.confirmed_orphaned_claim: fail("Unbound zero-candidate recovery requires --confirmed-orphaned-claim")
            if old["phase"] not in ("install", "installing"): fail("Only an unpublished install-phase lock can use orphan recovery")
            if args.phase != "installing": fail("Orphan recovery must preserve the recoverable installing phase until the current task is bound")
            if hub_path(target).exists(): fail("Hub registry exists; refusing orphan recovery")
        else:
            if not args.confirmed_owner_inactive: fail("Discovered claim recovery requires --confirmed-owner-inactive")
            if args.confirmed_orphaned_claim: fail("A discovered claim thread must not use orphan recovery")
        record = new_bootstrap_lock_record(target, args.project_id, args.owner_id, requested, args.phase, args.lease_seconds, old["replacement"]); write_bootstrap_lock(handle, record); print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
    finally: close_bootstrap_lock(handle)


def bootstrap_renew_command(argv):
    args = bootstrap_parser("Renew and owner-authenticate the bootstrap lock thread/phase binding.").parse_args(argv)
    target = Target(args.target); _, handle = open_existing_bootstrap_lock(target)
    try:
        record = read_bootstrap_lock(handle, target, args.project_id)
        bound_thread = identifier(args.thread_id, "ThreadId") if args.thread_id else record["threadId"]
        if record["ownerId"] != identifier(args.owner_id, "OwnerId") or (record["threadId"] is not None and record["threadId"] != bound_thread): fail("Bootstrap lock owner or thread does not match; refusing renewal")
        now = datetime.datetime.now(datetime.timezone.utc); record["schemaVersion"] = 2; record["threadId"] = bound_thread; record["phase"] = identity_value(args.phase, "Phase"); record["renewedAt"] = utc_text(now); record["expiresAt"] = utc_text(now + datetime.timedelta(seconds=args.lease_seconds)); write_bootstrap_lock(handle, record); print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
    finally: close_bootstrap_lock(handle)


def bootstrap_release_command(argv):
    parser = argparse.ArgumentParser(description="Release only the exact bootstrap lock owner."); parser.add_argument("--target", default="."); parser.add_argument("--project-id", required=True); parser.add_argument("--owner-id", required=True); parser.add_argument("--confirmed-replacement-retired", action="store_true"); args = parser.parse_args(argv)
    target = Target(args.target); path, handle = open_existing_bootstrap_lock(target)
    try:
        record = read_bootstrap_lock(handle, target, args.project_id)
        if record["ownerId"] != identifier(args.owner_id, "OwnerId"): fail("Bootstrap lock owner does not match; refusing release")
        if record["replacement"] is not None:
            if record["phase"] != "hub_replacement_retiring_old": fail("Hub replacement lock cannot be released before registry commit")
            if not args.confirmed_replacement_retired: fail("Hub replacement release requires explicit confirmation that the exact old hub is retired")
        path.unlink(); print('{"released":true}')
    finally: close_bootstrap_lock(handle)


def hub_snapshot(target, project_id):
    path = hub_path(target)
    if not target.regular_exists(path, "Hub registry"): fail("Hub registry is missing: " + str(path))
    raw = path.read_bytes()
    record = parse_json(normalized_bytes(raw, CONTROL + "/hub.json"), CONTROL + "/hub.json"); exact_object(record, ("schemaVersion", "projectId", "projectPath", "threadId", "hubTitle", "updatedAt"), "Hub registry")
    identifier(record["projectId"], "Hub registry projectId")
    identity_value(record["projectPath"], "Hub registry projectPath")
    identifier(record["threadId"], "Hub registry threadId")
    identity_value(record["hubTitle"], "Hub registry hubTitle")
    if record["schemaVersion"] != 1 or record["projectId"] != identifier(project_id, "ProjectId") or not same_project_path(record["projectPath"], str(target.root)): fail("Hub registry binding is invalid")
    parse_utc(record["updatedAt"], "Hub registry updatedAt")
    return record, "sha256:" + hashlib.sha256(raw).hexdigest()


def read_hub_registry(target, project_id):
    return hub_snapshot(target, project_id)[0]


def hub_result(snapshot, switched=False, already_committed=False):
    record, token = snapshot
    result = dict(record); result["registryToken"] = token; result["switched"] = switched; result["alreadyCommitted"] = already_committed
    return result


def hub_read_command(argv):
    parser = argparse.ArgumentParser(description="Read and verify project hub registry."); parser.add_argument("--target", default="."); parser.add_argument("--project-id", required=True); args = parser.parse_args(argv)
    print(json.dumps(hub_result(hub_snapshot(Target(args.target), args.project_id)), ensure_ascii=False, separators=(",", ":")))


def hub_write_command(argv):
    parser = argparse.ArgumentParser(description="Create a hub registry once, or return the identical thread binding."); parser.add_argument("--target", default="."); parser.add_argument("--project-id", required=True); parser.add_argument("--owner-id", required=True); parser.add_argument("--hub-thread-id", required=True); parser.add_argument("--hub-title", required=True); args = parser.parse_args(argv)
    target = Target(args.target); _, handle = open_existing_bootstrap_lock(target)
    try:
        lease = read_bootstrap_lock(handle, target, args.project_id)
        thread_id = identifier(args.hub_thread_id, "HubThreadId")
        if lease["ownerId"] != identifier(args.owner_id, "OwnerId") or lease["threadId"] != thread_id or parse_utc(lease["expiresAt"], "Bootstrap lock expiresAt") < datetime.datetime.now(datetime.timezone.utc): fail("An active owner bootstrap lock bound to the hub thread is required to write the hub registry")
        path = hub_path(target); record = {"schemaVersion":1,"projectId":identifier(args.project_id,"ProjectId"),"projectPath":str(target.root),"threadId":thread_id,"hubTitle":identity_value(args.hub_title,"HubTitle"),"updatedAt":utc_text()}
        if path.exists():
            existing = read_hub_registry(target, args.project_id)
            if existing.get("threadId") != thread_id: fail("Hub registry already binds a different thread; refusing overwrite")
            target.atomic_text(path, json.dumps(record,ensure_ascii=False,separators=(",",":"))+"\n")
            print(json.dumps(read_hub_registry(target, args.project_id), ensure_ascii=False, separators=(",", ":")))
            return
        target.ensure_directory(path.parent)
        temporary = path.with_name(path.name + ".project-flow-tmp-" + str(os.getpid()) + "-" + uuid.uuid4().hex[:8])
        try:
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os,"O_BINARY",0) | getattr(os,"O_NOFOLLOW",0), 0o600)
            with os.fdopen(fd, "wb") as output: output.write((json.dumps(record,ensure_ascii=False,separators=(",",":"))+"\n").encode("utf-8")); output.flush(); os.fsync(output.fileno())
            try: os.link(temporary, path)
            except FileExistsError: fail("Hub registry appeared during atomic create; retry only to verify its existing thread binding", 1)
        finally:
            try: temporary.unlink()
            except FileNotFoundError: pass
        print(json.dumps(read_hub_registry(target, args.project_id), ensure_ascii=False, separators=(",", ":")))
    finally: close_bootstrap_lock(handle)


def hub_replacement_prepare_command(argv):
    parser = argparse.ArgumentParser(description="Prepare an explicitly authorized current-task replacement of the exact inactive registered hub.")
    parser.add_argument("--target", default="."); parser.add_argument("--project-id", required=True); parser.add_argument("--owner-id", required=True)
    parser.add_argument("--expected-hub-thread-id", required=True); parser.add_argument("--expected-registry-token", required=True); parser.add_argument("--new-hub-thread-id", required=True); parser.add_argument("--hub-title", required=True)
    parser.add_argument("--confirmed-old-hub-inactive", action="store_true"); parser.add_argument("--lease-seconds", type=int, default=300)
    args = parser.parse_args(argv)
    if not args.confirmed_old_hub_inactive: fail("Hub replacement prepare requires explicit confirmed inactive old hub evidence", 1)
    if not 1 <= args.lease_seconds <= 3600: raise SystemExit("--lease-seconds must be between 1 and 3600")
    target = Target(args.target); old = identifier(args.expected_hub_thread_id, "ExpectedHubThreadId"); new = identifier(args.new_hub_thread_id, "NewHubThreadId")
    if old == new: fail("Replacement hub must differ from the registered old hub", 1)
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", args.expected_registry_token): fail("ExpectedRegistryToken must be a lowercase raw SHA-256 token", 1)
    title = identity_value(args.hub_title, "HubTitle"); path = bootstrap_lock_path(target); target.ensure_directory(path.parent)
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: handle = os.fdopen(os.open(path, flags, 0o600), "w+b", buffering=0)
    except FileExistsError: fail("Bootstrap lock already exists; hub replacement never bypasses lock ownership", 1)
    published = False
    try:
        if os.name == "nt":
            import msvcrt; handle.write(b"\0"); handle.flush(); os.fsync(handle.fileno()); handle.seek(0); msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl; fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        snapshot = hub_snapshot(target, args.project_id)
        if snapshot[0]["threadId"] != old or snapshot[1] != args.expected_registry_token: fail("Hub registry changed after authorization; refusing replacement prepare", 1)
        evidence = {"expectedHubThreadId":old,"expectedRegistryToken":args.expected_registry_token,"newHubThreadId":new,"newHubTitle":title}
        record = new_bootstrap_lock_record(target, args.project_id, args.owner_id, new, "hub_replacement_prepared", args.lease_seconds, evidence)
        write_bootstrap_lock(handle, record); published = True; print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
    except BaseException:
        if not published:
            try: path.unlink()
            except FileNotFoundError: pass
        raise
    finally: close_bootstrap_lock(handle)


def hub_replacement_commit_command(argv):
    parser = argparse.ArgumentParser(description="Atomically replace only the exact registry token recorded by the replacement owner lock.")
    parser.add_argument("--target", default="."); parser.add_argument("--project-id", required=True); parser.add_argument("--owner-id", required=True); args = parser.parse_args(argv)
    target = Target(args.target); _, handle = open_existing_bootstrap_lock(target)
    try:
        lease = read_bootstrap_lock(handle, target, args.project_id)
        if lease["ownerId"] != identifier(args.owner_id, "OwnerId"): fail("Bootstrap lock owner does not match; refusing hub replacement commit", 1)
        evidence = lease["replacement"]
        if evidence is None or lease["phase"] not in ("hub_replacement_prepared", "hub_replacement_retiring_old"): fail("Bootstrap lock does not contain a recoverable hub replacement", 1)
        if parse_utc(lease["expiresAt"], "Bootstrap lock expiresAt") < datetime.datetime.now(datetime.timezone.utc): fail("Bootstrap lock expired; renew the exact replacement owner before commit", 1)
        snapshot = hub_snapshot(target, args.project_id); already = False
        if snapshot[0]["threadId"] == evidence["newHubThreadId"]:
            already = True
        elif snapshot[0]["threadId"] != evidence["expectedHubThreadId"] or snapshot[1] != evidence["expectedRegistryToken"]:
            fail("Hub registry token or old hub changed; refusing replacement commit", 1)
        else:
            record = {"schemaVersion":1,"projectId":identifier(args.project_id,"ProjectId"),"projectPath":str(target.root),"threadId":identifier(evidence["newHubThreadId"],"NewHubThreadId"),"hubTitle":identity_value(evidence["newHubTitle"],"NewHubTitle"),"updatedAt":utc_text()}
            target.atomic_text(hub_path(target), json.dumps(record,ensure_ascii=False,separators=(",",":"))+"\n")
            snapshot = hub_snapshot(target, args.project_id)
            if snapshot[0]["threadId"] != evidence["newHubThreadId"]: fail("Hub replacement commit did not persist the exact new hub", 1)
        now = datetime.datetime.now(datetime.timezone.utc); lease["schemaVersion"] = 2; lease["phase"] = "hub_replacement_retiring_old"; lease["renewedAt"] = utc_text(now); lease["expiresAt"] = utc_text(now + datetime.timedelta(seconds=300)); write_bootstrap_lock(handle, lease)
        print(json.dumps(hub_result(snapshot, not already, already), ensure_ascii=False, separators=(",", ":")))
    finally: close_bootstrap_lock(handle)


def current_contract():
    version = read_text(plugin_input("VERSION", "VERSION"), "VERSION").strip()
    reject_control(version, "VERSION")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        fail("VERSION must contain one SemVer version")
    managed = load_json(plugin_input("managed-files.json", "managed-files.json"), "managed-files.json")
    if managed.get("schema_version") != 1 or managed.get("workflow_version") != version or not isinstance(managed.get("retired_paths"), list):
        fail("managed-files.json schema or workflow_version does not match VERSION")
    entries = checked_entries(managed.get("files"), "managed-files.json", current=True)
    current_paths = {item["path"] for item in entries}
    retired = []
    retired_seen = set()
    for raw in managed["retired_paths"]:
        relative = str(safe_relative(raw, "retired path"))
        if relative in current_paths or relative in retired_seen:
            fail("Retired path is active or duplicated: " + relative)
        retired_seen.add(relative)
        retired.append(relative)
    return version, entries, managed


def checked_entries(raw_entries, label, current=False):
    if not isinstance(raw_entries, list) or not raw_entries:
        fail(label + " files must be a non-empty array")
    entries = []
    seen = set()
    for raw in raw_entries:
        if not isinstance(raw, dict):
            fail(label + " contains a non-object entry")
        relative = str(safe_relative(raw.get("path"), "managed path"))
        source = str(safe_relative(raw.get("source"), "managed source", allow_control=True))
        if relative in seen:
            fail("Duplicate managed path: " + relative)
        seen.add(relative)
        if raw.get("policy") not in VALID_POLICIES or raw.get("render") not in VALID_RENDERS:
            fail("Unsupported policy or render mode for " + relative)
        if current:
            ownership = raw.get("ownership")
            resolution = raw.get("conflict_resolution")
            if ownership not in VALID_OWNERSHIP or resolution not in VALID_RESOLUTIONS:
                fail("Unsupported ownership or conflict resolution for " + relative)
            if resolution == "upstream_wins" and ownership != "plugin":
                fail("upstream_wins requires plugin ownership for " + relative)
            if resolution == "preserve" and ownership != "project":
                fail("preserve requires project ownership for " + relative)
            if resolution == "preserve_markdown_sections":
                sections = raw.get("preserve_sections")
                if ownership != "mixed" or not isinstance(sections, list) or not sections:
                    fail("preserve_markdown_sections requires mixed ownership and preserve_sections for " + relative)
                for section in sections:
                    reject_control(section, "Protected Markdown section")
            elif "preserve_sections" in raw:
                fail("preserve_sections is valid only with preserve_markdown_sections for " + relative)
            plugin_input(source, "managed source")
        entries.append(dict(raw, path=relative, source=source))
    if current:
        required_paths = [
            "AGENTS.md",
            ".agents/workflow.json",
            ".agents/WORKFLOW_PROTOCOL.md",
            ".agents/skills/project-workflow-manager/SKILL.md",
            ".agents/skills/project-workflow-manager/agents/openai.yaml",
            "docs/PROJECT_STATE.md",
            "docs/PROJECT_PLAN.md",
            ".agents/skills/project-workflow-manager/scripts/project-memory.py",
        ]
        if [item["path"] for item in entries] != required_paths:
            fail("managed-files.json must contain exactly the eight expected managed paths")
        by_path = {item["path"]: item for item in entries}
        plan = by_path.get("docs/PROJECT_PLAN.md", {})
        state = by_path.get("docs/PROJECT_STATE.md", {})
        memory = by_path.get(".agents/skills/project-workflow-manager/scripts/project-memory.py", {})
        agents = by_path.get("AGENTS.md", {})
        if (plan.get("policy"), plan.get("ownership"), plan.get("conflict_resolution")) != ("seed_once", "project", "preserve"):
            fail("docs/PROJECT_PLAN.md must be project-owned and preserved")
        if (state.get("policy"), state.get("ownership"), state.get("conflict_resolution")) != ("seed_once", "project", "preserve"):
            fail("docs/PROJECT_STATE.md must be project-owned and preserved")
        if (memory.get("policy"), memory.get("ownership"), memory.get("conflict_resolution")) != ("replace_if_unmodified", "plugin", "upstream_wins"):
            fail("project-memory.py must be plugin-owned and upstream-wins")
        if (agents.get("ownership"), agents.get("conflict_resolution"), agents.get("preserve_sections")) != ("mixed", "preserve_markdown_sections", ["项目事实"]):
            fail("AGENTS.md must preserve the 项目事实 project-content section")
    return entries


def baseline_contract(version):
    reject_control(version, "Workflow version")
    path = plugin_input("baselines/" + version + "/managed-files.json", "baseline managed-files metadata", allow_missing=True)
    if not path.is_file():
        fail("No supported migration from " + version)
    data = load_json(path, "baseline managed-files metadata")
    if data.get("schema_version") != 1 or data.get("kind") != "managed_files_baseline" or data.get("workflow_version") != version:
        fail("Baseline managed-files metadata does not match " + version)
    entries = checked_entries(data.get("files"), "baseline " + version)
    for item in entries:
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(item.get("content_hash", ""))):
            fail("Baseline metadata hash is invalid for " + item["path"])
        path = plugin_input("baselines/" + version + "/" + item["path"], "baseline " + item["path"])
        if digest_file(path, "baseline " + item["path"]) != item["content_hash"]:
            fail("Baseline content hash mismatch for " + item["path"])
    return entries


def probe_command(argv):
    parser = argparse.ArgumentParser(description="Read only the project-flow manifest entrypoint.")
    parser.add_argument("target_positional", nargs="?")
    parser.add_argument("--target")
    args = parser.parse_args(argv)
    target = Target(args.target or args.target_positional or ".")
    manifest_path = target.path(MANIFEST_REL, allow_control=True)
    if not manifest_path.exists():
        print('{"managed":false}')
        return
    manifest = load_json(manifest_path, MANIFEST_REL)
    version = manifest.get("workflow_version")
    project_name = manifest.get("project_name")
    files = manifest.get("files")
    if manifest.get("schema_version") != 1 or not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version) or not isinstance(project_name, str) or not project_name.strip() or not isinstance(files, list):
        fail("Manifest probe contract is invalid")
    reject_control(project_name, "Manifest project name")
    print(json.dumps({"managed": True, "workflow_version": version, "project_name": project_name, "managed_files": len(files), "last_transaction": manifest.get("last_transaction")}, ensure_ascii=False, separators=(",", ":")))


def validate_markdown(path, label):
    if path.suffix != ".md":
        fail(label + " must use .md", 1)
    first = None
    previous = 0
    fence = None
    for line in read_text(path, label).split("\n"):
        marker = re.match(r"^\s*(```|~~~)", line)
        if marker:
            token = marker.group(1)
            fence = token if fence is None else None if fence == token else fence
            continue
        if fence is not None:
            continue
        heading = re.match(r"^(#{1,6})[ \t]+\S", line)
        if not heading:
            continue
        level = len(heading.group(1))
        if first is None:
            first = level
            if level != 1:
                fail(label + " first heading must be #", 1)
        elif level > previous + 1:
            fail(label + " heading levels must not skip", 1)
        previous = level
    if first is None:
        fail(label + " must contain a heading", 1)


def validate_installation(target, allow_placeholders=False, quiet=False, runtime=False):
    version, entries, managed = current_contract()
    plugin = load_json(plugin_input(".codex-plugin/plugin.json", "plugin manifest"), "plugin manifest")
    plugin_version = str(plugin.get("version", ""))
    if plugin_version != version and not plugin_version.startswith(version + "+codex."):
        fail("Plugin version does not match VERSION", 1)
    expected_paths = [item["path"] for item in entries]
    required_paths = [
        "AGENTS.md",
        ".agents/workflow.json",
        ".agents/WORKFLOW_PROTOCOL.md",
        ".agents/skills/project-workflow-manager/SKILL.md",
        ".agents/skills/project-workflow-manager/agents/openai.yaml",
        "docs/PROJECT_STATE.md",
        "docs/PROJECT_PLAN.md",
        ".agents/skills/project-workflow-manager/scripts/project-memory.py",
    ]
    if expected_paths != required_paths or len(set(expected_paths)) != 8:
        fail("Current contract must contain exactly the eight expected managed files", 1)

    retired_paths = set(managed["retired_paths"])
    historical = set()
    if not runtime:
        baseline_root = PLUGIN_ROOT / "baselines"
        for directory in sorted(baseline_root.iterdir()):
            if not directory.is_dir():
                continue
            data = load_json(directory / "managed-files.json", "baseline " + directory.name)
            if data.get("schema_version") != 1 or data.get("kind") != "managed_files_baseline" or data.get("workflow_version") != directory.name:
                fail("Invalid baseline contract: " + directory.name, 1)
            old_entries = checked_entries(data.get("files"), "baseline " + directory.name)
            old_paths = set()
            for item in old_entries:
                relative = item["path"]
                historical.add(relative)
                old_paths.add(relative)
                source = directory / relative
                if not source.is_file() or is_reparse(source.lstat()):
                    fail("Missing baseline file: " + directory.name + "/" + relative, 1)
                if digest_file(source) != item.get("content_hash"):
                    fail("Baseline hash mismatch: " + directory.name + "/" + relative, 1)
            actual = {path.relative_to(directory).as_posix() for path in directory.rglob("*") if path.is_file()} - {"managed-files.json"}
            if actual != old_paths:
                fail("Baseline tree does not match metadata: " + directory.name, 1)
        if historical - set(expected_paths) != retired_paths:
            fail("retired_paths does not match immutable baselines", 1)

    workflow_path = target.path(".agents/workflow.json")
    workflow = load_json(workflow_path, ".agents/workflow.json")
    if set(workflow) != {"schema_version", "project", "paths", "tasks", "requests", "execution", "documents", "project_memory", "planning", "bootstrap", "rotation", "upgrade"}:
        fail("workflow fields are invalid", 1)
    project = workflow.get("project")
    if not isinstance(project, dict) or set(project) != {"name"}:
        fail("project fields are invalid", 1)
    project_name = project.get("name")
    if not isinstance(project_name, str) or not project_name.strip():
        fail("workflow project name is invalid", 1)
    reject_control(project_name, "Workflow project name")
    if project_name == "<PROJECT_NAME>" and not allow_placeholders:
        fail("workflow project placeholder was not rendered", 1)
    expected_fields = {
        "paths": {"project_plan", "project_state", "project_memory", "workflow_protocol"},
        "tasks": {"max_active", "hub_occupies_slot", "blocked_waiting_queued_occupy_slot", "visible_execution_required", "hidden_subagents_may_substitute", "management_failure", "request_key", "model_policy", "creation_omit_fields", "hidden_agents_omit_fields"},
        "requests": {"request_id_assignment", "states", "initial_state", "confirmation_fields", "completion_fields", "initial_owner", "handoff_boundary", "post_handoff_owner", "hub_post_handoff", "execution_task_binding", "acceptance_owner", "acceptance_archive", "rejection_route", "scope_change_route", "awaiting_acceptance_occupies_slot"},
        "execution": {"same_task_actions", "supplemental_authorization", "different_goal", "scope_change", "replacement", "serial"},
        "documents": {"default_extension", "standalone_cover", "first_heading", "heading_progression", "body_structures", "validation_scope"},
        "project_memory": {"startup_read", "plan_sections", "step_format", "step_completion", "progress", "plan_changes", "state_content", "save_triggers", "routine_sync", "write_failure", "historical_verification"},
        "planning": {"role", "automatic_on_bootstrap", "registry_path", "creation", "unknown_creation", "plan_initial_status", "interview", "interview_rules", "interview_memory", "interview_completion", "continuation_request_id", "continuation_key", "upgrade", "key"},
        "bootstrap": {"registry_path", "lock_path", "registry_schema", "lock_schema", "stale_after_seconds", "fast_path", "recovery_path", "title_identity", "unarchive", "lock_acquire", "lock_inspect", "existing_lock", "lock_release", "stale_recovery", "claim_title", "hub_replacement"},
        "rotation": {"mode", "context_threshold", "ambiguous_archive", "pause", "continue", "next_step", "ui_archive_hook", "successor_gate", "capacity", "key"},
        "upgrade": {"protocol", "transaction_task_role", "post_handoff_owner", "barrier_owner", "request_key", "discovery", "zero_active_fast_path", "reconcile", "barrier", "coordinator_claim", "transaction_key", "observe", "attempt_deadline_seconds", "hub_refresh"},
    }
    for section, expected in expected_fields.items():
        if not isinstance(workflow.get(section), dict) or set(workflow[section]) != expected:
            fail(section + " fields are invalid", 1)
    if set(workflow["upgrade"].get("observe", {})) != {"poll_scan_latest_turns", "include_outputs", "stable_terminal_snapshots", "poll_delays_seconds"}:
        fail("observe fields are invalid", 1)
    if not isinstance(workflow["upgrade"].get("discovery"), dict) or set(workflow["upgrade"]["discovery"]) != {"listing", "history", "fallback"}:
        fail("discovery fields are invalid", 1)
    if not isinstance(workflow["upgrade"].get("reconcile"), dict) or set(workflow["upgrade"]["reconcile"]) != {"active_snapshot"}:
        fail("reconcile fields are invalid", 1)
    if not isinstance(workflow["upgrade"].get("barrier"), dict) or set(workflow["upgrade"]["barrier"]) != {"creation_gate", "provisional", "active", "released", "cancelled"}:
        fail("barrier fields are invalid", 1)
    if not isinstance(workflow["upgrade"].get("zero_active_fast_path"), bool):
        fail("zero active fast path must be boolean", 1)
    if not isinstance(workflow["bootstrap"].get("hub_replacement"), dict) or set(workflow["bootstrap"]["hub_replacement"]) != {"authorization", "registry_token", "prepare_command", "commit_command", "pre_cas_authority", "post_cas_authority", "old_hub_state", "new_hub_state", "ordinary_task_create", "retirement_order", "recovery", "third_hub", "key"}:
        fail("hub replacement fields are invalid", 1)
    refresh_expected = {
        "authorization": "apply_includes_one_exact_inactive_registered_hub_refresh",
        "intent_path": ".project-flow/upgrade-hub.json",
        "creation": "durable_intent_one_cold_start_hub_bind_or_recover_never_recreate",
        "barrier_exception": "one_intent_bound_hub_only_dispatch_blocked_until_released",
        "executor": "same_upgrade_task_not_promoted_hub",
        "retirement": "verified_new_title_pin_registry_then_exact_old_title_unpin_archive",
        "planning": "rebind_same_root_token_identity_and_lineage",
        "completion": "verified_refresh_reconciliation_then_release_barrier",
        "plan_and_rollback": "no_hub_refresh",
        "key": "[codex-project-flow:upgrade-hub:v1] projectId=<exactProjectId>; upgradeThreadId=<exactUpgradeThreadId>; requestId=<exactRequestId>; claimId=<exactClaimId>; oldHubThreadId=<exactOldHubThreadId>; expectedRegistryToken=<exactRegistryToken>; targetVersion=<exactTargetVersion>; creationToken=<exactCreationToken>",
    }
    if workflow["upgrade"].get("hub_refresh") != refresh_expected:
        fail("upgrade hub refresh contract is invalid", 1)
    checks = [
        (workflow["tasks"].get("model_policy"), "codex_default_no_overrides", "task model policy"),
        (workflow["tasks"].get("creation_omit_fields"), ["model", "thinking"], "task model omission"),
        (workflow["tasks"].get("hidden_agents_omit_fields"), ["model", "reasoning_effort"], "hidden agent model omission"),
        (workflow.get("schema_version"), 13, "workflow schema"),
        (workflow.get("paths", {}).get("project_plan"), "docs/PROJECT_PLAN.md", "project plan path"),
        (workflow.get("paths", {}).get("project_state"), "docs/PROJECT_STATE.md", "project state path"),
        (workflow.get("paths", {}).get("project_memory"), ".agents/skills/project-workflow-manager/scripts/project-memory.py", "project memory path"),
        (workflow.get("paths", {}).get("workflow_protocol"), ".agents/WORKFLOW_PROTOCOL.md", "protocol path"),
        (workflow.get("tasks", {}).get("max_active"), 5, "active task limit"),
        (workflow.get("tasks", {}).get("hub_occupies_slot"), False, "hub slot"),
        (workflow.get("tasks", {}).get("blocked_waiting_queued_occupy_slot"), True, "blocked task slot"),
        (workflow.get("tasks", {}).get("visible_execution_required"), True, "visible execution"),
        (workflow.get("tasks", {}).get("hidden_subagents_may_substitute"), False, "hidden substitute"),
        (workflow.get("tasks", {}).get("management_failure"), "stop", "management failure"),
        (workflow.get("tasks", {}).get("request_key"), "[codex-project-flow:request:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; requestId=<exactRequestId>; generation=1", "request key"),
        (workflow.get("requests", {}).get("request_id_assignment"), "hub_before_first_work_output", "request ID assignment"),
        (workflow.get("requests", {}).get("states"), ["awaiting_authorization", "queued", "active", "awaiting_acceptance", "revision_pending", "accepted_archived", "paused_archived", "continued_archived"], "request states"),
        (workflow.get("requests", {}).get("initial_state"), "awaiting_authorization", "request initial state"),
        (workflow.get("requests", {}).get("confirmation_fields"), ["understanding", "execution_items"], "request confirmation fields"),
        (workflow.get("requests", {}).get("completion_fields"), ["changes", "verification", "uncovered", "risk"], "request completion fields"),
        (workflow.get("requests", {}).get("initial_owner"), "hub", "request initial owner"),
        (workflow.get("requests", {}).get("handoff_boundary"), "exact_or_queued_execution_task_identity_established", "request handoff boundary"),
        (workflow.get("requests", {}).get("post_handoff_owner"), "execution_task", "request post-handoff owner"),
        (workflow.get("requests", {}).get("hub_post_handoff"), "no_participation_for_same_request", "request hub post-handoff"),
        (workflow.get("requests", {}).get("execution_task_binding"), "one_current_visible_task_per_request_with_authorized_successor", "request task binding"),
        (workflow.get("requests", {}).get("acceptance_owner"), "execution_task", "request acceptance owner"),
        (workflow.get("requests", {}).get("acceptance_archive"), "sync_explicitly_mapped_step_or_state_only_then_exact_self_archive_without_next_step", "request acceptance archive"),
        (workflow.get("requests", {}).get("rejection_route"), "execution_task_reconfirm_in_place", "request rejection route"),
        (workflow.get("requests", {}).get("scope_change_route"), "execution_task_reconfirm_in_place", "request scope-change route"),
        (workflow.get("requests", {}).get("awaiting_acceptance_occupies_slot"), True, "request acceptance slot"),
        (workflow.get("execution", {}).get("same_task_actions"), ["inspect", "modify", "build", "test", "self_check", "evidence", "documentation", "commit", "push", "external"], "same task actions"),
        (workflow.get("execution", {}).get("supplemental_authorization"), "continue_original_task", "supplemental authorization"),
        (workflow.get("execution", {}).get("different_goal"), "parallel_when_disjoint_and_slot_available_else_queue", "different goal"),
        (workflow.get("execution", {}).get("scope_change"), "pause_for_execution_task_confirmation_then_continue_original_task", "scope change"),
        (workflow.get("execution", {}).get("replacement"), "explicit_user_authorization", "replacement"),
        (workflow.get("execution", {}).get("serial"), ["same_request", "overlapping_paths", "upgrade_file_transaction"], "serial execution"),
        (workflow.get("documents", {}).get("default_extension"), ".md", "document extension"),
        (workflow.get("documents", {}).get("standalone_cover"), False, "document cover"),
        (workflow.get("documents", {}).get("first_heading"), "#", "document first heading"),
        (workflow.get("documents", {}).get("heading_progression"), "no_skipped_levels", "document heading progression"),
        (workflow.get("documents", {}).get("body_structures"), ["paragraphs", "lists", "tables", "code_blocks"], "document body structures"),
        (workflow.get("documents", {}).get("validation_scope"), "created_or_updated_delivery_documents", "document validation scope"),
        (workflow.get("project_memory", {}).get("startup_read"), ["project_plan", "project_state"], "project memory startup read"),
        (workflow.get("project_memory", {}).get("plan_sections"), ["目标", "总体进度", "任务步骤"], "project memory plan sections"),
        (workflow.get("project_memory", {}).get("step_format"), "- [ ] S01 | 步骤内容", "project memory step format"),
        (workflow.get("project_memory", {}).get("step_completion"), "explicit_user_acceptance_only", "project memory step completion"),
        (workflow.get("project_memory", {}).get("progress"), "accepted_steps_over_total_steps", "project memory progress"),
        (workflow.get("project_memory", {}).get("plan_changes"), "user_confirms_goal_and_steps_not_per_file_drafts", "project memory plan changes"),
        (workflow.get("project_memory", {}).get("state_content"), ["goal_context", "current_step", "decisions", "work_and_results", "verification", "blockers", "pending_acceptance", "unfinished_work", "next_actions", "continuation_identity"], "project memory state content"),
        (workflow.get("project_memory", {}).get("save_triggers"), ["meaningful_progress", "user_acceptance", "before_archive", "before_successor"], "project memory save triggers"),
        (workflow.get("project_memory", {}).get("routine_sync"), "authorized_by_workflow_within_confirmed_scope", "project memory routine sync"),
        (workflow.get("project_memory", {}).get("write_failure"), "stop_before_archive_or_creation", "project memory write failure"),
        (workflow.get("project_memory", {}).get("historical_verification"), "reread_and_reverify_in_successor", "project memory historical verification"),
        (workflow.get("planning", {}).get("role"), "separate_user_visible_planning_chat", "planning role"),
        (workflow.get("planning", {}).get("automatic_on_bootstrap"), True, "planning automatic bootstrap"),
        (workflow.get("planning", {}).get("registry_path"), ".project-flow/planning.json", "planning registry path"),
        (workflow.get("planning", {}).get("creation"), "durable_intent_then_one_create_and_bind_exact_or_queued_identity", "planning creation"),
        (workflow.get("planning", {}).get("unknown_creation"), "recover_original_identity_never_recreate", "planning unknown creation"),
        (workflow.get("planning", {}).get("plan_initial_status"), "draft_until_user_confirmation", "planning initial status"),
        (workflow.get("planning", {}).get("interview"), "grilling_proactive_dependency_frontier_rounds", "planning interview"),
        (workflow.get("planning", {}).get("interview_rules"), ".agents/WORKFLOW_PROTOCOL.md#grilling-主动访谈", "planning interview rules"),
        (workflow.get("planning", {}).get("interview_memory"), "state_decisions_dependencies_unanswered_questions_next_frontier", "planning interview memory"),
        (workflow.get("planning", {}).get("interview_completion"), "all_relevant_boundaries_settled_then_explicit_user_confirmation", "planning interview completion"),
        (workflow.get("planning", {}).get("continuation_request_id"), "root_creation_token", "planning continuation request id"),
        (workflow.get("planning", {}).get("continuation_key"), "[codex-project-flow:planning-continuation:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; creationToken=<rootCreationToken>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>; rotationToken=<exactRotationToken>", "planning continuation key"),
        (workflow.get("planning", {}).get("upgrade"), "preserve_existing_plan_and_state_then_discuss_unknowns", "planning upgrade"),
        (workflow.get("planning", {}).get("key"), "[codex-project-flow:planning:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; creationToken=<exactCreationToken>", "planning key"),
        (workflow.get("bootstrap", {}).get("registry_path"), ".project-flow/hub.json", "bootstrap registry path"),
        (workflow.get("bootstrap", {}).get("lock_path"), ".project-flow/bootstrap.lock", "bootstrap lock path"),
        (workflow.get("bootstrap", {}).get("registry_schema"), 1, "bootstrap registry schema"),
        (workflow.get("bootstrap", {}).get("lock_schema"), 2, "bootstrap lock schema"),
        (workflow.get("bootstrap", {}).get("stale_after_seconds"), 300, "bootstrap stale threshold"),
        (workflow.get("bootstrap", {}).get("fast_path"), "registry_targeted_read", "bootstrap fast path"),
        (workflow.get("bootstrap", {}).get("recovery_path"), "exhaustive_metadata_on_exception", "bootstrap recovery path"),
        (workflow.get("bootstrap", {}).get("title_identity"), "saved_project_binding_plus_mutation_thread", "bootstrap title identity"),
        (workflow.get("bootstrap", {}).get("unarchive"), "only_when_explicitly_archived", "bootstrap unarchive rule"),
        (workflow.get("bootstrap", {}).get("lock_acquire"), "atomic_create_new", "bootstrap lock acquire"),
        (workflow.get("bootstrap", {}).get("lock_inspect"), "validated_read_only", "bootstrap lock inspect"),
        (workflow.get("bootstrap", {}).get("existing_lock"), "inspect_then_recover_or_stop", "bootstrap existing lock routing"),
        (workflow.get("bootstrap", {}).get("lock_release"), "owner_claim_and_replacement_retirement_confirmation", "bootstrap lock release"),
        (workflow.get("bootstrap", {}).get("stale_recovery"), "exact_token_cas_same_thread_or_install_orphan", "bootstrap stale recovery"),
        (workflow.get("bootstrap", {}).get("claim_title"), "[cpf-claim] <shortClaimId>", "bootstrap claim title"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("authorization"), "explicit_current_task_replaces_exact_registry_hub", "hub replacement authorization"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("registry_token"), "sha256_raw_bytes", "hub replacement token"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("prepare_command"), "hub-replacement-prepare", "hub replacement prepare"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("commit_command"), "hub-replacement-commit", "hub replacement commit"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("pre_cas_authority"), "exact_registry_old_hub", "hub replacement pre-CAS authority"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("post_cas_authority"), "exact_registry_new_hub", "hub replacement post-CAS authority"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("old_hub_state"), "accessible_and_inactive", "hub replacement old state"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("new_hub_state"), "current_task_exact_id", "hub replacement new state"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("ordinary_task_create"), False, "hub replacement task creation"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("retirement_order"), ["versioned_retired_title", "unpin", "archive"], "hub replacement retirement"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("recovery"), "registry_authority_plus_lock_evidence", "hub replacement recovery"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("third_hub"), "forbidden", "hub replacement third hub"),
        (workflow.get("bootstrap", {}).get("hub_replacement", {}).get("key"), "[codex-project-flow:hub-replacement:v1] projectId=<exactProjectId>; expectedOldHubThreadId=<exactOldHubThreadId>; newHubThreadId=<exactCurrentThreadId>; expectedRegistryToken=<exactRegistryToken>; ownerId=<exactOwnerId>", "hub replacement key"),
        (workflow.get("rotation", {}).get("mode"), "manual_natural_language_continue_or_pause", "rotation mode"),
        (workflow.get("rotation", {}).get("context_threshold"), None, "rotation context threshold"),
        (workflow.get("rotation", {}).get("ambiguous_archive"), "save_then_ask_continue_or_pause_without_archiving", "rotation ambiguous archive"),
        (workflow.get("rotation", {}).get("pause"), "save_then_archive_without_successor_or_acceptance", "rotation pause"),
        (workflow.get("rotation", {}).get("continue"), "save_then_create_gated_successor_then_archive_predecessor", "rotation continue"),
        (workflow.get("rotation", {}).get("next_step"), "explicit_user_request_only", "rotation next step"),
        (workflow.get("rotation", {}).get("ui_archive_hook"), False, "rotation UI archive hook"),
        (workflow.get("rotation", {}).get("successor_gate"), "wait_for_matching_predecessor_archive_before_work", "rotation successor gate"),
        (workflow.get("rotation", {}).get("capacity"), "reserve_one_slot_before_create_never_exceed_max_active", "rotation capacity"),
        (workflow.get("rotation", {}).get("key"), "[codex-project-flow:execution:v3] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; requestId=<exactRequestId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>", "rotation key"),
        (workflow.get("upgrade", {}).get("protocol"), 4, "upgrade protocol"),
        (workflow.get("upgrade", {}).get("transaction_task_role"), "visible_coordinator_executor", "transaction task role"),
        (workflow.get("upgrade", {}).get("post_handoff_owner"), "transaction_task", "upgrade post-handoff owner"),
        (workflow.get("upgrade", {}).get("barrier_owner"), "transaction_task", "upgrade barrier owner"),
        (workflow.get("upgrade", {}).get("request_key"), "[codex-project-flow:upgrade-request:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; requestId=<exactRequestId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>", "upgrade request key"),
        (workflow.get("upgrade", {}).get("discovery", {}).get("listing"), "exhaustive_metadata", "discovery listing"),
        (workflow.get("upgrade", {}).get("discovery", {}).get("history"), "targeted", "discovery history"),
        (workflow.get("upgrade", {}).get("discovery", {}).get("fallback"), "full_on_ambiguity", "discovery fallback"),
        (workflow.get("upgrade", {}).get("zero_active_fast_path"), True, "zero active fast path"),
        (workflow.get("upgrade", {}).get("reconcile", {}).get("active_snapshot"), "empty_required_before_file_transaction_fail_closed", "active snapshot"),
        (workflow.get("upgrade", {}).get("barrier", {}).get("creation_gate"), "hub_exhaustive_check_blocks_on_provisional_and_active_before_every_creation", "upgrade creation gate"),
        (workflow.get("upgrade", {}).get("barrier", {}).get("provisional"), "[codex-project-flow:upgrade-barrier:v1] state=provisional; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>", "provisional barrier"),
        (workflow.get("upgrade", {}).get("barrier", {}).get("active"), "[codex-project-flow:upgrade-barrier:v1] state=active; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>", "active barrier"),
        (workflow.get("upgrade", {}).get("barrier", {}).get("released"), "[codex-project-flow:upgrade-barrier:v1] state=released; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>", "released barrier"),
        (workflow.get("upgrade", {}).get("barrier", {}).get("cancelled"), "[codex-project-flow:upgrade-barrier:v1] state=cancelled; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>", "cancelled barrier"),
        (workflow.get("upgrade", {}).get("coordinator_claim"), "[codex-project-flow:upgrade-claim:v2] projectId=<exactProjectId>; requestId=<exactRequestId>; coordinatorThreadId=<exactCoordinatorThreadId>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>", "coordinator claim"),
        (workflow.get("upgrade", {}).get("transaction_key"), "[codex-project-flow:upgrade:v1] projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>", "transaction key"),
        (workflow.get("upgrade", {}).get("observe", {}).get("poll_scan_latest_turns"), 3, "poll scan"),
        (workflow.get("upgrade", {}).get("observe", {}).get("include_outputs"), False, "tool output"),
        (workflow.get("upgrade", {}).get("observe", {}).get("stable_terminal_snapshots"), 3, "terminal snapshots"),
        (workflow.get("upgrade", {}).get("observe", {}).get("poll_delays_seconds"), [1, 2], "poll delays"),
        (workflow.get("upgrade", {}).get("attempt_deadline_seconds"), 60, "attempt deadline"),
    ]
    for actual, expected, label in checks:
        if actual != expected:
            fail(label + " is invalid: " + repr(actual), 1)

    if not runtime:
        expected_skills = sorted([
            "bootstrap-project-flow/SKILL.md",
            "bootstrap-project-flow/agents/openai.yaml",
            "upgrade-project-flow/SKILL.md",
            "upgrade-project-flow/agents/openai.yaml",
            "upgrade-project-flow/references/coordination.md",
            "upgrade-project-flow/references/file-transaction.md",
            "upgrade-project-flow/references/hub-refresh.md",
        ])
        actual_skills = sorted(path.relative_to(PLUGIN_ROOT / "skills").as_posix() for path in (PLUGIN_ROOT / "skills").rglob("*") if path.is_file())
        if actual_skills != expected_skills:
            fail("Plugin must contain exactly the seven expected Skill files", 1)

        conflict_pattern = re.compile(r'任务管理(能力)?不可用时.{0,20}(回到|回退到)中枢|continue_in_hub|hub_execution_allowed|"hidden_subagents"\s*:\s*"may_substitute"', re.DOTALL)
        for relative in ("AGENTS.md", ".agents", "docs"):
            root = target.root / relative
            files = [root] if root.is_file() else list(root.rglob("*")) if root.is_dir() else []
            for path in files:
                if path.is_file() and path.suffix in (".md", ".json") and conflict_pattern.search(read_text(path)):
                    fail("Conflicting workflow rule: " + str(path), 1)

    for entry in entries:
        live = target.path(entry["path"])
        if not live.is_file() or is_reparse(live.lstat()):
            fail("Installed managed file is missing or unsafe: " + entry["path"], 1)
        if entry["path"].endswith(".md"):
            validate_markdown(live, entry["path"])
    if not runtime:
        for relative in ("README.md", "docs/TEST_CASES.md", "templates/PROJECT_PLAN.md", "templates/PROJECT_STATE.md", "skills/bootstrap-project-flow/SKILL.md", "skills/upgrade-project-flow/SKILL.md", "skills/upgrade-project-flow/references/coordination.md", "skills/upgrade-project-flow/references/file-transaction.md"):
            validate_markdown(plugin_input(relative, "delivery Markdown"), relative)
    for relative in retired_paths:
        if target.path(relative).exists():
            fail("Retired managed file remains: " + relative, 1)

    manifest_path = target.path(MANIFEST_REL, allow_control=True)
    if manifest_path.is_file():
        manifest = load_json(manifest_path, "manifest")
        if manifest.get("schema_version") != 1 or manifest.get("workflow_version") != version:
            fail("Manifest schema or version is invalid", 1)
        records = manifest.get("files")
        if not isinstance(records, list) or [item.get("path") for item in records if isinstance(item, dict)] != expected_paths:
            fail("Manifest paths do not match current contract", 1)
        name = manifest.get("project_name")
        if not isinstance(name, str) or not name.strip() or name == "<PROJECT_NAME>":
            fail("Manifest project_name is invalid", 1)
        reject_control(name, "Manifest project name")
        if project_name != name:
            fail("Workflow and manifest project names do not match", 1)
        record_map = {item["path"]: item for item in records}
        for entry in entries:
            relative = entry["path"]
            record = record_map[relative]
            if (record.get("source"), record.get("policy")) != (entry["source"], entry["policy"]):
                fail("Manifest metadata mismatch for " + relative, 1)
            expected_hash = digest_text(render(read_text(plugin_input(entry["source"], "managed source")), entry["render"], name))
            if record.get("baseline_hash") != expected_hash:
                fail("Manifest baseline hash mismatch for " + relative, 1)
    if not quiet:
        print("Validation passed for " + str(target.root))


def install_command(argv):
    parser = argparse.ArgumentParser(description="Install codex-project-flow into a local project.")
    parser.add_argument("target_positional", nargs="?")
    parser.add_argument("project_name_positional", nargs="?")
    parser.add_argument("--target")
    parser.add_argument("--project-name")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    target = Target(args.target or args.target_positional or ".")
    if not args.dry_run:
        acquire_writer_lock(target)
    project_name = args.project_name if args.project_name is not None else args.project_name_positional
    project_name = validate_project_name(project_name if project_name is not None and project_name.strip() else target.root.name)
    version, entries, _ = current_contract()
    rendered = []
    for entry in entries:
        source = plugin_input(entry["source"], "managed source")
        rendered.append(dict(entry, rendered=render(read_text(source), entry["render"], project_name)))

    manifest_path = target.path(MANIFEST_REL, allow_control=True)
    manifest_existed = target.regular_exists(manifest_path, "Manifest")
    existing_managed = any(target.regular_exists(target.path(entry["path"])) for entry in entries)
    legacy = not args.force and not manifest_existed and existing_managed
    if legacy and not args.dry_run:
        print("NOTICE Existing managed files were found without a manifest.")
        print("NOTICE Files retain normal non-force skip behavior; manifest-free adoption is not supported.")

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_relative = BACKUP_ROOT_NAME + "/" + stamp
    backup_root = target.path(backup_relative, allow_control=True)
    suffix = 0
    while backup_root.exists():
        suffix += 1
        backup_relative = BACKUP_ROOT_NAME + "/" + stamp + "-" + str(suffix)
        backup_root = target.path(backup_relative, allow_control=True)
    writes = []
    manifest_changed = False
    manifest_backed_up = False

    def backup(source, relative):
        destination = target.path(backup_relative + "/" + relative, allow_control=True)
        target.ensure_directory(destination.parent)
        shutil.copyfile(source, destination)

    def restore():
        nonlocal manifest_changed
        for relative, existed in reversed(writes):
            destination = target.path(relative)
            if existed:
                saved = target.path(backup_relative + "/" + relative, allow_control=True)
                target.atomic_bytes(destination, saved.read_bytes())
            elif destination.is_file():
                destination.unlink()
        if manifest_changed:
            if manifest_existed:
                saved = target.path(backup_relative + "/" + MANIFEST_REL, allow_control=True)
                target.atomic_bytes(manifest_path, saved.read_bytes())
            elif manifest_path.is_file():
                manifest_path.unlink()
            manifest_changed = False
        print("RESTORED install changes after validation failure.", file=sys.stderr)

    if args.force and manifest_existed and not args.dry_run:
        backup(manifest_path, MANIFEST_REL)
        manifest_backed_up = True
    created = replaced = skipped = written = 0
    try:
        for entry in rendered:
            relative = entry["path"]
            destination = target.path(relative)
            exists = target.regular_exists(destination)
            if exists and not args.force:
                print("SKIP  " + relative + " (already exists)")
                skipped += 1
                continue
            if args.dry_run:
                print(("REPLACE " if exists else "CREATE  ") + relative)
                continue
            if exists:
                backup(destination, relative)
                replaced += 1
            else:
                created += 1
            writes.append((relative, exists))
            target.atomic_text(destination, entry["rendered"])
            written += 1
            print("WRITE " + relative)
    except BaseException:
        if not args.dry_run:
            restore()
        raise

    if args.dry_run:
        print("Dry run complete; no files changed and the manifest was not created or replaced.")
        return
    print("Installed: created=%d replaced=%d skipped=%d" % (created, replaced, skipped))
    if backup_root.is_dir():
        print("Backups: " + str(backup_root))
    if not args.force:
        try:
            validate_installation(target, quiet=True, runtime=True)
        except SystemExit:
            restore()
            raise

    initialize = args.force or (not manifest_existed and not legacy)
    if manifest_existed and not args.force:
        print("PRESERVE " + MANIFEST_REL + " (already exists)")
    elif legacy:
        print("MANIFEST NOT INITIALIZED; manifest-free adoption is not supported.")
    if initialize:
        if written != len(entries):
            restore()
            fail("Install did not render every managed file; manifest was preserved")
        records = []
        for entry in rendered:
            live = read_text(target.path(entry["path"]), entry["path"])
            baseline_hash = digest_text(entry["rendered"])
            if digest_text(live) != baseline_hash:
                restore()
                fail("Installed file does not match its rendered baseline: " + entry["path"])
            records.append({"path": entry["path"], "source": entry["source"], "policy": entry["policy"], "baseline_hash": baseline_hash})
        manifest = {
            "schema_version": 1,
            "workflow_version": version,
            "project_name": project_name,
            "installed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "last_transaction": None,
            "files": records,
        }
        if manifest_existed and not manifest_backed_up:
            restore()
            fail("Refusing to replace a manifest that was not backed up")
        try:
            target.atomic_text(manifest_path, json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
            manifest_changed = True
            validate_installation(target, quiet=True, runtime=True)
        except BaseException:
            restore()
            raise
        print(("RESET " if manifest_existed else "WRITE ") + MANIFEST_REL)


def merge_sections(live, upstream, names, relative):
    merged = upstream
    for name in names:
        reject_control(name, "Protected Markdown section")
        if not name.strip():
            fail("Invalid protected Markdown section for " + relative)
        pattern = re.compile(r"^##[ \t]+" + re.escape(name) + r"[ \t]*\n.*?(?=^##[ \t]+|\Z)", re.MULTILINE | re.DOTALL)
        local_matches = list(pattern.finditer(live))
        upstream_matches = list(pattern.finditer(merged))
        if len(local_matches) != 1 or len(upstream_matches) != 1:
            fail("Protected Markdown section '" + name + "' must appear exactly once in local and upstream " + relative)
        match = upstream_matches[0]
        merged = merged[:match.start()] + local_matches[0].group(0) + merged[match.end():]
    return merged


class Upgrade:
    def __init__(self, args):
        self.args = args
        self.target = Target(args.target or args.target_positional or ".")
        if args.apply or args.rollback:
            acquire_writer_lock(self.target)
        self.version, self.entries, _ = current_contract()
        self.current_paths = {item["path"] for item in self.entries}
        self.manifest_path = self.target.path(MANIFEST_REL, allow_control=True)
        self.manifest = load_json(self.manifest_path, MANIFEST_REL) if self.manifest_path.exists() else None
        if self.manifest is not None:
            if self.manifest.get("schema_version") != 1:
                fail("Unsupported manifest schema")
            if args.adopt_from:
                fail("--adopt-from is only valid when the target has no manifest")
        elif not args.rollback:
            if args.adopt_from:
                fail("Manifest-free adoption is no longer supported; the minimum supported upgrade is 0.8.3 with a valid manifest")
            fail("Missing .project-flow/manifest.json; the minimum supported upgrade is 0.8.3 with a valid manifest")

    def path_set(self, version):
        return self.current_paths if version == self.version else {item["path"] for item in baseline_contract(version)}

    def transaction_root(self, identifier):
        reject_control(identifier, "Transaction identifier")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", identifier):
            fail("Invalid transaction identifier")
        return self.target.path(CONTROL + "/transactions/" + identifier, allow_control=True)

    def remove_empty_parents(self, path):
        current = path.parent
        while current != self.target.root and current.name != CONTROL:
            try:
                current.rmdir()
            except OSError:
                break
            current = current.parent

    def rollback(self, identifier, automatic=False):
        root = self.transaction_root(identifier)
        if not root.is_dir() or is_reparse(root.lstat()):
            fail("Transaction does not exist or is unsafe: " + identifier)
        meta_path = root / "transaction.json"
        meta_text = read_text(meta_path, "transaction.json")
        meta_hash = digest_text(meta_text)
        meta = parse_json(meta_text, "transaction.json")
        if meta.get("schema_version") != 1 or meta.get("transaction_id") != identifier or meta.get("target") != str(self.target.root):
            fail("Invalid transaction metadata")
        if meta.get("state") == "rolled_back":
            print("NOOP transaction already rolled back: " + identifier)
            return
        if meta.get("state") not in ("prepared", "validating", "applied"):
            fail("Transaction is not rollback-eligible: " + str(meta.get("state")))
        from_paths = self.path_set(meta.get("from_version"))
        to_paths = self.path_set(meta.get("to_version"))
        allowed = from_paths | to_paths
        removed = meta.get("removed_files", [])
        if not isinstance(removed, list):
            fail("Transaction removed_files must be an array")
        actual_removed = {str(safe_relative(item, "removed managed path")) for item in removed}
        if len(actual_removed) != len(removed) or actual_removed != from_paths - to_paths:
            fail("Transaction removed_files do not match version contracts")
        raw_records = meta.get("files")
        if not isinstance(raw_records, list):
            fail("Transaction files must be an array")
        decisions = []
        record_paths = set()
        for record in raw_records:
            if not isinstance(record, dict) or record.get("path") not in allowed or record.get("path") in record_paths:
                fail("Transaction contains an invalid or duplicate managed path")
            relative = record["path"]
            record_paths.add(relative)
            if not isinstance(record.get("changed"), bool) or not isinstance(record.get("existed"), bool):
                fail("Transaction contains invalid changed/existed metadata: " + relative)
            live = self.target.path(relative)
            if not record.get("changed"):
                continue
            if live.exists() and (is_reparse(live.lstat()) or not live.is_file()):
                fail("Rollback target is not a regular file: " + relative)
            current_hash = digest_file(live, relative) if live.is_file() else None
            if current_hash == record.get("applied_hash"):
                decisions.append({"record": record, "live": live, "decision": "restore", "expected_live_hash": current_hash, "backup_bytes": None})
            elif current_hash == record.get("original_hash"):
                decisions.append({"record": record, "live": live, "decision": "unchanged", "expected_live_hash": current_hash, "backup_bytes": None})
            else:
                fail("Refusing rollback because a live file changed after apply: " + relative)
        if record_paths != allowed:
            fail("Transaction file records do not match version contracts")
        manifest_hash = digest_file(self.manifest_path, MANIFEST_REL) if self.manifest_path.is_file() else None
        if manifest_hash == meta.get("new_manifest_hash"):
            restore_manifest = True
        elif manifest_hash == meta.get("old_manifest_hash"):
            restore_manifest = False
        else:
            fail("Refusing rollback because the manifest changed after apply")

        # Phase 1: authenticate every backup and all live/metadata preconditions.
        for item in decisions:
            record = item["record"]
            if item["decision"] != "restore" or not record.get("existed"):
                continue
            backup = self.target.path(CONTROL + "/transactions/" + identifier + "/backup/" + record["path"], allow_control=True)
            backup_bytes = backup.read_bytes() if backup.is_file() and not is_reparse(backup.lstat()) else fail("Backup is missing or unsafe for " + record["path"])
            if digest_text(normalized_bytes(backup_bytes, "backup for " + record["path"])) != record.get("original_hash"):
                fail("Backup hash mismatch for " + record["path"])
            item["backup_bytes"] = backup_bytes
        manifest_backup_bytes = None
        if restore_manifest:
            if meta.get("old_manifest_hash") is not None:
                backup = self.target.path(CONTROL + "/transactions/" + identifier + "/backup/" + CONTROL + "/manifest.json", allow_control=True)
                manifest_backup_bytes = backup.read_bytes() if backup.is_file() and not is_reparse(backup.lstat()) else fail("Manifest backup is missing or unsafe")
                if digest_text(normalized_bytes(manifest_backup_bytes, "manifest backup")) != meta.get("old_manifest_hash"):
                    fail("Manifest backup hash mismatch")
        if digest_file(meta_path, "transaction.json") != meta_hash:
            fail("Transaction metadata changed during rollback preflight")

        # Phase 2: recheck each live precondition immediately before its restore.
        for item in decisions:
            if item["decision"] == "unchanged":
                continue
            record = item["record"]
            live = item["live"]
            if self.observed_hash(live, record["path"]) != item["expected_live_hash"]:
                fail("Rollback target changed after preflight: " + record["path"])
            if record.get("existed"):
                self.target.atomic_bytes(live, item["backup_bytes"])
            elif live.exists():
                live.unlink()
                self.remove_empty_parents(live)
        if restore_manifest:
            if self.observed_hash(self.manifest_path, MANIFEST_REL) != manifest_hash:
                fail("Manifest changed after rollback preflight")
            if meta.get("old_manifest_hash") is None:
                if self.manifest_path.exists():
                    self.manifest_path.unlink()
            else:
                self.target.atomic_bytes(self.manifest_path, manifest_backup_bytes)
        meta["state"] = "rolled_back"
        meta["rolled_back_at_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        meta["automatic_rollback"] = bool(automatic)
        self.target.atomic_text(meta_path, json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
        print("ROLLED_BACK " + identifier)

    def project_name(self):
        if self.args.project_name is not None:
            return validate_project_name(self.args.project_name)
        value = self.manifest.get("project_name")
        if value is None and isinstance(self.manifest.get("project"), dict):
            value = self.manifest["project"].get("name")
        return validate_project_name(value)

    def run(self):
        if self.args.rollback:
            if self.args.adopt_from or self.args.project_name:
                fail("Rollback does not accept adoption or project-name options")
            self.rollback(self.args.rollback)
            return
        project_name = self.project_name()
        installed_version = self.manifest.get("workflow_version")
        reject_control(installed_version, "Installed workflow version")
        if not installed_version:
            fail("Manifest workflow_version is missing")
        old_entries = self.entries if installed_version == self.version else baseline_contract(installed_version)
        old_by_path = {item["path"]: item for item in old_entries}
        introduced = self.current_paths - set(old_by_path)
        removed = {path: item for path, item in old_by_path.items() if path not in self.current_paths}
        manifest_entries = {}
        if self.manifest is not None:
            raw = self.manifest.get("files", self.manifest.get("managed_files", []))
            if isinstance(raw, dict):
                raw = [dict(value, path=key) for key, value in raw.items() if isinstance(value, dict)]
            if not isinstance(raw, list):
                fail("Manifest files must be an array or object")
            for item in raw:
                if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                    fail("Manifest contains an invalid file record")
                path = str(safe_relative(item["path"], "manifest path"))
                if path in manifest_entries:
                    fail("Manifest contains a duplicate path: " + path)
                manifest_entries[path] = item
            if set(manifest_entries) != set(old_by_path):
                fail("Manifest managed paths do not match version contract")
            for path, item in manifest_entries.items():
                contract = old_by_path[path]
                if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(item.get("baseline_hash", ""))):
                    fail("Manifest baseline_hash is invalid for " + path)
                if (item.get("source"), item.get("policy")) != (contract["source"], contract["policy"]):
                    fail("Manifest source or policy mismatch for " + path)
                if installed_version != self.version:
                    baseline = plugin_input("baselines/" + installed_version + "/" + path, "baseline " + path)
                    expected = digest_text(render(read_text(baseline), contract["render"], project_name))
                    if item["baseline_hash"] != expected:
                        fail("Manifest baseline hash mismatch for " + path)

        plans = []
        for entry in self.entries:
            relative = entry["path"]
            live = self.target.path(relative)
            if live.exists() and (is_reparse(live.lstat()) or not live.is_file()):
                fail("Managed target is not a regular file: " + relative)
            new_text = render(read_text(plugin_input(entry["source"], "managed source")), entry["render"], project_name)
            new_hash = digest_text(new_text)
            if installed_version == self.version:
                base_text = new_text
            elif relative in introduced:
                base_text = None
            else:
                old = old_by_path[relative]
                baseline = plugin_input("baselines/" + installed_version + "/" + relative, "baseline " + relative)
                base_text = render(read_text(baseline), old["render"], project_name)
            base_hash = digest_text(base_text) if base_text is not None else None
            if manifest_entries.get(relative, {}).get("baseline_hash") not in (None, base_hash):
                fail("Manifest baseline hash does not match immutable baseline for " + relative)
            live_text = read_text(live, relative) if live.is_file() else None
            live_hash = digest_text(live_text) if live_text is not None else None
            applied = live_text
            if live_text is None:
                action, applied = "CREATE", new_text
            elif entry["policy"] == "seed_once":
                action = "NOOP" if live_hash == new_hash else "PRESERVE"
            elif base_text is None:
                action = "NOOP" if live_hash == new_hash else "CONFLICT"
            elif live_hash == new_hash:
                action = "NOOP"
            elif live_hash == base_hash:
                action, applied = "REPLACE", new_text
            elif base_hash == new_hash:
                action = "PRESERVE"
            elif entry["conflict_resolution"] == "upstream_wins":
                action, applied = "UPSTREAM", new_text
            elif entry["conflict_resolution"] == "preserve_markdown_sections":
                action, applied = "MERGE", merge_sections(live_text, new_text, entry["preserve_sections"], relative)
            elif entry["conflict_resolution"] == "preserve":
                action = "PRESERVE"
            else:
                action = "CONFLICT"
            plans.append(dict(entry, action=action, base_hash=base_hash, live_hash=live_hash, new_hash=new_hash, base_text=base_text, live_text=live_text, new_text=new_text, applied_text=applied, is_removed=False))
        for relative in sorted(removed):
            entry = removed[relative]
            live = self.target.path(relative)
            if live.exists() and (is_reparse(live.lstat()) or not live.is_file()):
                fail("Retired target is not a regular file: " + relative)
            baseline = plugin_input("baselines/" + installed_version + "/" + relative, "removed baseline")
            base_text = render(read_text(baseline), entry["render"], project_name)
            live_text = read_text(live, relative) if live.is_file() else None
            plans.append(dict(entry, ownership="plugin", conflict_resolution="retire", action="DELETE" if live.is_file() else "REMOVE_NOOP", base_hash=digest_text(base_text), live_hash=digest_text(live_text) if live_text is not None else None, new_hash=None, base_text=base_text, live_text=live_text, new_text=None, applied_text=None, is_removed=True))
        by_path = {item["path"]: item for item in plans}
        accepted = set()
        for raw_path in self.args.accept_local:
            relative = str(safe_relative(raw_path, "accepted local path"))
            if relative in accepted:
                fail("Duplicate --accept-local path: " + relative)
            accepted.add(relative)
            item = by_path.get(relative)
            if item is None or item["action"] != "CONFLICT":
                fail("--accept-local requires a current managed conflict: " + relative)
            item["action"] = "ACCEPT"
            item["applied_text"] = item["live_text"]
        print("UPGRADE " + installed_version + " -> " + self.version)
        print("TARGET " + str(self.target.root), flush=True)
        for item in plans:
            print("%-8s %-22s %s" % (item["action"], item["policy"], item["path"]))
        conflicts = [item for item in plans if item["action"] == "CONFLICT"]
        changes = [item for item in plans if item["action"] in ("CREATE", "REPLACE", "UPSTREAM", "MERGE", "DELETE")]
        if not self.args.apply:
            print("PLAN changes=%d conflicts=%d" % (len(changes), len(conflicts)))
            return
        if conflicts:
            identifier = self.new_identifier()
            staging = self.target.path(CONTROL + "/staging/" + identifier, allow_control=True)
            if staging.exists():
                fail("Staging transaction already exists: " + identifier)
            self.target.ensure_directory(staging)
            public = {"schema_version": 1, "transaction_id": identifier, "from_version": installed_version, "to_version": self.version, "conflicts": [{key: item[key] for key in ("path", "policy", "ownership", "conflict_resolution", "base_hash", "live_hash", "new_hash")} for item in conflicts]}
            self.target.atomic_text(staging / "plan.json", json.dumps(public, ensure_ascii=False, indent=2) + "\n")
            for item in conflicts:
                bundle = staging / "conflicts" / Path(*PurePosixPath(item["path"]).parts)
                self.target.ensure_directory(bundle)
                if item["base_text"] is not None:
                    self.target.atomic_text(bundle / "base", item["base_text"])
                if item["live_text"] is not None:
                    self.target.atomic_text(bundle / "local", item["live_text"])
                self.target.atomic_text(bundle / "upstream", item["new_text"])
            print("CONFLICTS " + str(staging / "conflicts"), file=sys.stderr)
            print("Live managed files and manifest were not changed.", file=sys.stderr)
            raise SystemExit(4)
        if not changes and installed_version == self.version and self.manifest is not None:
            validate_installation(self.target, quiet=True, runtime=True)
            print("NOOP already up to date")
            return
        self.apply(plans, changes, removed, accepted, installed_version, project_name)

    def new_identifier(self):
        return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + str(os.getpid()) + "-" + uuid.uuid4().hex[:8]

    def observed_hash(self, path, label):
        try:
            item = path.lstat()
        except FileNotFoundError:
            return None
        if is_reparse(item) or not stat.S_ISREG(item.st_mode):
            fail(label + " is not a safe regular file")
        return digest_file(path, label)

    def assert_preconditions(self, plans, manifest_hash):
        for item in plans:
            current = self.observed_hash(self.target.path(item["path"]), item["path"])
            if current != item["live_hash"]:
                fail("Managed file changed after planning: " + item["path"], 5)
        if self.observed_hash(self.manifest_path, MANIFEST_REL) != manifest_hash:
            fail("Manifest changed after planning", 5)

    def discard_prepared_transaction(self, root):
        transactions = self.target.path(CONTROL + "/transactions", allow_control=True)
        if root.parent != transactions:
            fail("Refusing to discard a transaction outside the transaction root", 5)
        if not root.exists():
            return
        if is_reparse(root.lstat()) or not root.is_dir():
            fail("Refusing to discard an unsafe prepared transaction", 5)
        shutil.rmtree(root)
        self.remove_empty_parents(root)

    def apply(self, plans, changes, removed, accepted, installed_version, project_name):
        old_manifest_text = read_text(self.manifest_path, MANIFEST_REL) if self.manifest_path.is_file() else None
        old_manifest_hash = digest_text(old_manifest_text) if old_manifest_text is not None else None
        self.assert_preconditions(plans, old_manifest_hash)
        identifier = self.new_identifier()
        root = self.transaction_root(identifier)
        if root.exists():
            fail("Transaction already exists: " + identifier)
        try:
            backup_root = root / "backup"
            self.target.ensure_directory(backup_root)
            records = []
            for item in plans:
                live = self.target.path(item["path"])
                existed = item["live_text"] is not None
                changed = item["action"] in ("CREATE", "REPLACE", "UPSTREAM", "MERGE", "DELETE")
                records.append({"path": item["path"], "existed": existed, "changed": changed, "original_hash": item["live_hash"], "applied_hash": None if item["action"] == "DELETE" else digest_text(item["applied_text"]) if changed else item["live_hash"], "resolution": item["action"]})
                if existed:
                    backup = backup_root / Path(*PurePosixPath(item["path"]).parts)
                    self.target.ensure_directory(backup.parent)
                    backup_bytes = live.read_bytes()
                    if digest_text(normalized_bytes(backup_bytes, item["path"])) != item["live_hash"]:
                        fail("Managed file changed while creating its backup: " + item["path"], 5)
                    self.target.atomic_bytes(backup, backup_bytes)
            if old_manifest_text is not None:
                backup = backup_root / CONTROL / "manifest.json"
                self.target.ensure_directory(backup.parent)
                backup_bytes = self.manifest_path.read_bytes()
                if digest_text(normalized_bytes(backup_bytes, MANIFEST_REL)) != old_manifest_hash:
                    fail("Manifest changed while creating its backup", 5)
                self.target.atomic_bytes(backup, backup_bytes)
            now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
            new_manifest = {"schema_version": 1, "workflow_version": self.version, "project_name": project_name, "installed_at_utc": now, "last_transaction": identifier, "files": [{"path": item["path"], "source": item["source"], "policy": item["policy"], "baseline_hash": item["new_hash"]} for item in plans if not item["is_removed"]]}
            new_manifest_text = json.dumps(new_manifest, ensure_ascii=False, indent=2) + "\n"
            meta = {"schema_version": 1, "transaction_id": identifier, "target": str(self.target.root), "from_version": installed_version, "to_version": self.version, "state": "prepared", "created_at_utc": now, "old_manifest_hash": old_manifest_hash, "new_manifest_hash": digest_text(new_manifest_text), "accepted_local": sorted(accepted), "upstream_resolved": sorted(item["path"] for item in plans if item["action"] == "UPSTREAM"), "merged": sorted(item["path"] for item in plans if item["action"] == "MERGE"), "removed_files": sorted(removed), "files": records}
            meta_path = root / "transaction.json"
            self.target.atomic_text(meta_path, json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
            self.assert_preconditions(plans, old_manifest_hash)
        except BaseException as exc:
            original = error_detail(exc)
            try:
                self.discard_prepared_transaction(root)
            except BaseException as cleanup_exc:
                fail("Preparation failed (" + original + ") and prepared-transaction cleanup also failed (" + error_detail(cleanup_exc) + ")", 5)
            raise

        project_write_started = False
        try:
            for item in changes:
                live = self.target.path(item["path"])
                if self.observed_hash(live, item["path"]) != item["live_hash"]:
                    fail("Managed file changed immediately before apply: " + item["path"], 5)
                project_write_started = True
                if item["action"] == "DELETE":
                    live.unlink()
                    self.remove_empty_parents(live)
                else:
                    self.target.atomic_text(live, item["applied_text"])
            if self.observed_hash(self.manifest_path, MANIFEST_REL) != old_manifest_hash:
                fail("Manifest changed immediately before apply", 5)
            self.target.atomic_text(self.manifest_path, new_manifest_text)
            if digest_file(self.manifest_path, MANIFEST_REL) != meta["new_manifest_hash"]:
                fail("Written manifest hash does not match the prepared transaction", 5)
            written_manifest = load_json(self.manifest_path, MANIFEST_REL)
            if written_manifest.get("last_transaction") != identifier:
                fail("Written manifest last_transaction does not match the prepared transaction", 5)
            meta["state"] = "validating"
            self.target.atomic_text(meta_path, json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
            validate_installation(self.target, quiet=True, runtime=True)
            meta["state"] = "applied"
            meta["validated_at_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
            self.target.atomic_text(meta_path, json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
        except BaseException as exc:
            original = error_detail(exc)
            if not project_write_started:
                try:
                    self.discard_prepared_transaction(root)
                except BaseException as cleanup_exc:
                    fail("Apply precondition failed (" + original + ") and prepared-transaction cleanup also failed (" + error_detail(cleanup_exc) + ")", 5)
                raise
            print("ERROR apply failed; attempting automatic rollback: " + original, file=sys.stderr)
            try:
                self.rollback(identifier, automatic=True)
            except BaseException as rollback_exc:
                fail("Apply failed (" + original + ") and automatic rollback also failed (" + error_detail(rollback_exc) + ")", 5)
            code = exc.code if isinstance(exc, SystemExit) and isinstance(exc.code, int) and exc.code else 5
            raise SystemExit(code)
        print("APPLIED " + identifier)
        print("VALIDATION passed")


def upgrade_command(argv):
    parser = argparse.ArgumentParser(description="Safely upgrade an installed codex-project-flow project.")
    parser.add_argument("target_positional", nargs="?")
    parser.add_argument("--target")
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
    Upgrade(args).run()


def validate_command(argv):
    parser = argparse.ArgumentParser(description="Validate codex-project-flow source and an installed project.")
    parser.add_argument("target_positional", nargs="?")
    parser.add_argument("--target")
    parser.add_argument("--allow-placeholders", action="store_true")
    parser.add_argument("--runtime", action="store_true", help="Validate only the installed contract and its declared paths")
    args = parser.parse_args(argv)
    validate_installation(Target(args.target or args.target_positional or "."), args.allow_placeholders, runtime=args.runtime)


try:
    reject_control(COMMAND, "Command")
    if COMMAND == "probe":
        probe_command(ARGV)
    elif COMMAND == "hub-read":
        hub_read_command(ARGV)
    elif COMMAND == "hub-write":
        hub_write_command(ARGV)
    elif COMMAND == "hub-replacement-prepare":
        hub_replacement_prepare_command(ARGV)
    elif COMMAND == "hub-replacement-commit":
        hub_replacement_commit_command(ARGV)
    elif COMMAND == "bootstrap-lock-inspect":
        bootstrap_inspect_command(ARGV)
    elif COMMAND == "bootstrap-lock-acquire":
        bootstrap_acquire_command(ARGV)
    elif COMMAND == "bootstrap-lock-renew":
        bootstrap_renew_command(ARGV)
    elif COMMAND == "bootstrap-lock-release":
        bootstrap_release_command(ARGV)
    elif COMMAND == "bootstrap-lock-recover":
        bootstrap_recover_command(ARGV)
    elif COMMAND == "install":
        install_command(ARGV)
    elif COMMAND == "upgrade":
        upgrade_command(ARGV)
    elif COMMAND == "plan":
        upgrade_command(["--plan"] + ARGV)
    elif COMMAND == "apply":
        upgrade_command(["--apply"] + ARGV)
    elif COMMAND == "rollback":
        upgrade_command(ARGV)
    elif COMMAND == "validate":
        validate_command(ARGV)
    else:
        fail("Unknown command: " + COMMAND, 2)
except FlowFailure:
    raise
except SystemExit:
    raise
except KeyboardInterrupt:
    fail("Interrupted", 130)
except Exception as exc:
    fail("Unhandled engine failure: " + error_detail(exc), 1)
PY
