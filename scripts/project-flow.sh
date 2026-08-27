#!/bin/sh
set -eu

command_name=${1-}
[ -n "$command_name" ] || {
    echo "Usage: project-flow.sh {install|upgrade|plan|apply|rollback|validate} [options]" >&2
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
    if stat.S_ISLNK(item.st_mode) or not stat.S_ISREG(item.st_mode):
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
        if stat.S_ISLNK(item.st_mode):
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


class Target:
    def __init__(self, argument):
        reject_control(argument, "Target path")
        lexical = Path(os.path.abspath(argument))
        if not lexical.is_dir():
            fail("Target directory does not exist: " + str(lexical), 2)
        if lexical.is_symlink():
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
            if stat.S_ISLNK(item.st_mode):
                fail("Refusing target path through a symbolic link: " + str(current))
        return self.root.joinpath(*rel.parts)

    def regular_exists(self, path, label="Destination"):
        try:
            item = path.lstat()
        except FileNotFoundError:
            return False
        if stat.S_ISLNK(item.st_mode) or not stat.S_ISREG(item.st_mode):
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
            if stat.S_ISLNK(item.st_mode) or not stat.S_ISDIR(item.st_mode):
                fail("Directory path is not a real directory: " + str(current))

    def atomic_bytes(self, path, data):
        self.ensure_directory(path.parent)
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

    def atomic_text(self, path, text):
        self.atomic_bytes(path, text.encode("utf-8"))


def acquire_writer_lock(target):
    lock_path = target.path(CONTROL + "/transaction.lock", allow_control=True)
    target.ensure_directory(lock_path.parent)
    try:
        item = lock_path.lstat()
    except FileNotFoundError:
        item = None
    if item is not None and (stat.S_ISLNK(item.st_mode) or not stat.S_ISREG(item.st_mode)):
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


def current_contract():
    version = read_text(plugin_input("VERSION", "VERSION"), "VERSION").strip()
    reject_control(version, "VERSION")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        fail("VERSION must contain one SemVer version")
    managed = load_json(plugin_input("managed-files.json", "managed-files.json"), "managed-files.json")
    if managed.get("schema_version") != 1 or managed.get("workflow_version") != version:
        fail("managed-files.json schema or workflow_version does not match VERSION")
    entries = checked_entries(managed.get("files"), "managed-files.json", current=True)
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
        by_path = {item["path"]: item for item in entries}
        state = by_path.get("docs/PROJECT_STATE.md", {})
        agents = by_path.get("AGENTS.md", {})
        if (state.get("policy"), state.get("ownership"), state.get("conflict_resolution")) != ("seed_once", "project", "preserve"):
            fail("docs/PROJECT_STATE.md must be project-owned and preserved")
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


def validate_installation(target, allow_placeholders=False, quiet=False):
    version, entries, managed = current_contract()
    plugin = load_json(plugin_input(".codex-plugin/plugin.json", "plugin manifest"), "plugin manifest")
    plugin_version = str(plugin.get("version", ""))
    if plugin_version != version and not plugin_version.startswith(version + "+codex."):
        fail("Plugin version does not match VERSION", 1)
    expected_paths = [item["path"] for item in entries]
    if len(expected_paths) != 6 or len(set(expected_paths)) != 6:
        fail("Current contract must contain exactly six managed files", 1)

    historical = set()
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
            if not source.is_file() or source.is_symlink():
                fail("Missing baseline file: " + directory.name + "/" + relative, 1)
            if digest_file(source) != item.get("content_hash"):
                fail("Baseline hash mismatch: " + directory.name + "/" + relative, 1)
        actual = {path.relative_to(directory).as_posix() for path in directory.rglob("*") if path.is_file()} - {"managed-files.json"}
        if actual != old_paths:
            fail("Baseline tree does not match metadata: " + directory.name, 1)

    workflow_path = target.path(".agents/workflow.json")
    workflow = load_json(workflow_path, ".agents/workflow.json")
    if set(workflow) != {"schema_version", "project", "paths", "tasks", "execution", "rotation", "upgrade"}:
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
        "paths": {"project_state", "workflow_protocol"},
        "tasks": {"max_active", "hub_occupies_slot", "blocked_waiting_queued_occupy_slot", "visible_execution_required", "hidden_subagents_may_substitute", "management_failure"},
        "execution": {"parallel", "serial"},
        "rotation": {"review_turn", "latest_turn", "key"},
        "upgrade": {"protocol", "transaction_task_role", "discovery", "zero_active_fast_path", "reconcile", "barrier", "coordinator_claim", "transaction_key", "successor_key", "task_handshake", "hub_handshake", "observe", "recovery", "attempt_deadline_seconds"},
    }
    for section, expected in expected_fields.items():
        if not isinstance(workflow.get(section), dict) or set(workflow[section]) != expected:
            fail(section + " fields are invalid", 1)
    if set(workflow["upgrade"].get("observe", {})) != {"poll_scan_latest_turns", "include_outputs", "stable_terminal_snapshots", "poll_delays_seconds"}:
        fail("observe fields are invalid", 1)
    if set(workflow["upgrade"].get("recovery", {})) != {"hub_followups", "successor_followups", "compensating_successors"}:
        fail("recovery fields are invalid", 1)
    if not isinstance(workflow["upgrade"].get("discovery"), dict) or set(workflow["upgrade"]["discovery"]) != {"listing", "history", "fallback"}:
        fail("discovery fields are invalid", 1)
    if not isinstance(workflow["upgrade"].get("reconcile"), dict) or set(workflow["upgrade"]["reconcile"]) != {"independent_pairs", "pair_order"}:
        fail("reconcile fields are invalid", 1)
    if not isinstance(workflow["upgrade"].get("barrier"), dict) or set(workflow["upgrade"]["barrier"]) != {"provisional", "active", "released", "cancelled"}:
        fail("barrier fields are invalid", 1)
    if not isinstance(workflow["upgrade"].get("zero_active_fast_path"), bool):
        fail("zero active fast path must be boolean", 1)
    checks = [
        (workflow.get("schema_version"), 6, "workflow schema"),
        (workflow.get("paths", {}).get("project_state"), "docs/PROJECT_STATE.md", "project state path"),
        (workflow.get("paths", {}).get("workflow_protocol"), ".agents/WORKFLOW_PROTOCOL.md", "protocol path"),
        (workflow.get("tasks", {}).get("max_active"), 5, "active task limit"),
        (workflow.get("tasks", {}).get("hub_occupies_slot"), False, "hub slot"),
        (workflow.get("tasks", {}).get("blocked_waiting_queued_occupy_slot"), True, "blocked task slot"),
        (workflow.get("tasks", {}).get("visible_execution_required"), True, "visible execution"),
        (workflow.get("tasks", {}).get("hidden_subagents_may_substitute"), False, "hidden substitute"),
        (workflow.get("tasks", {}).get("management_failure"), "stop", "management failure"),
        (workflow.get("execution", {}).get("parallel"), ["non_conflicting"], "parallel execution"),
        (workflow.get("execution", {}).get("serial"), ["high_risk", "external"], "serial execution"),
        (workflow.get("rotation", {}).get("review_turn"), 6, "rotation review"),
        (workflow.get("rotation", {}).get("latest_turn"), 10, "rotation latest"),
        (workflow.get("rotation", {}).get("key"), "[codex-project-flow:execution:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>", "rotation key"),
        (workflow.get("upgrade", {}).get("protocol"), 2, "upgrade protocol"),
        (workflow.get("upgrade", {}).get("transaction_task_role"), "visible_coordinator_executor", "transaction task role"),
        (workflow.get("upgrade", {}).get("discovery", {}).get("listing"), "exhaustive_metadata", "discovery listing"),
        (workflow.get("upgrade", {}).get("discovery", {}).get("history"), "targeted", "discovery history"),
        (workflow.get("upgrade", {}).get("discovery", {}).get("fallback"), "full_on_ambiguity", "discovery fallback"),
        (workflow.get("upgrade", {}).get("zero_active_fast_path"), True, "zero active fast path"),
        (workflow.get("upgrade", {}).get("reconcile", {}).get("independent_pairs"), "parallel_within_available_slots", "independent reconciliation"),
        (workflow.get("upgrade", {}).get("reconcile", {}).get("pair_order"), ["archive_predecessor", "create_successor", "verify_handshake"], "reconciliation pair order"),
        (workflow.get("upgrade", {}).get("barrier", {}).get("provisional"), "[codex-project-flow:upgrade-barrier:v1] state=provisional; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>", "provisional barrier"),
        (workflow.get("upgrade", {}).get("barrier", {}).get("active"), "[codex-project-flow:upgrade-barrier:v1] state=active; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>", "active barrier"),
        (workflow.get("upgrade", {}).get("barrier", {}).get("released"), "[codex-project-flow:upgrade-barrier:v1] state=released; projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>", "released barrier"),
        (workflow.get("upgrade", {}).get("barrier", {}).get("cancelled"), "[codex-project-flow:upgrade-barrier:v1] state=cancelled; projectId=<exactProjectId>; mode=<exactMode>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>", "cancelled barrier"),
        (workflow.get("upgrade", {}).get("coordinator_claim"), "[codex-project-flow:upgrade-claim:v1] projectId=<exactProjectId>; targetVersion=<exactTargetVersion>; claimId=<exactClaimId>", "coordinator claim"),
        (workflow.get("upgrade", {}).get("transaction_key"), "[codex-project-flow:upgrade:v1] projectId=<exactProjectId>; coordinatorThreadId=<exactCoordinatorThreadId>; sourceVersion=<exactSourceVersion>; targetVersion=<exactTargetVersion>; generation=<positiveInteger>", "transaction key"),
        (workflow.get("upgrade", {}).get("successor_key"), "[codex-project-flow:execution:v2] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>", "successor key"),
        (workflow.get("upgrade", {}).get("task_handshake"), "[codex-project-flow:handshake:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>; generation=<positiveInteger>", "task handshake"),
        (workflow.get("upgrade", {}).get("hub_handshake"), "[codex-project-flow:hub-handshake:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>", "hub handshake"),
        (workflow.get("upgrade", {}).get("observe", {}).get("poll_scan_latest_turns"), 3, "poll scan"),
        (workflow.get("upgrade", {}).get("observe", {}).get("include_outputs"), False, "tool output"),
        (workflow.get("upgrade", {}).get("observe", {}).get("stable_terminal_snapshots"), 3, "terminal snapshots"),
        (workflow.get("upgrade", {}).get("observe", {}).get("poll_delays_seconds"), [1, 2], "poll delays"),
        (workflow.get("upgrade", {}).get("recovery", {}).get("hub_followups"), 1, "hub followups"),
        (workflow.get("upgrade", {}).get("recovery", {}).get("successor_followups"), 1, "successor followups"),
        (workflow.get("upgrade", {}).get("recovery", {}).get("compensating_successors"), 1, "compensating successors"),
        (workflow.get("upgrade", {}).get("attempt_deadline_seconds"), 60, "attempt deadline"),
    ]
    for actual, expected, label in checks:
        if actual != expected:
            fail(label + " is invalid: " + repr(actual), 1)

    expected_skills = sorted([
        "bootstrap-project-flow/SKILL.md",
        "bootstrap-project-flow/agents/openai.yaml",
        "upgrade-project-flow/SKILL.md",
        "upgrade-project-flow/agents/openai.yaml",
        "upgrade-project-flow/references/coordination.md",
        "upgrade-project-flow/references/file-transaction.md",
    ])
    actual_skills = sorted(path.relative_to(PLUGIN_ROOT / "skills").as_posix() for path in (PLUGIN_ROOT / "skills").rglob("*") if path.is_file())
    if actual_skills != expected_skills:
        fail("Plugin must contain exactly the six expected Skill files", 1)

    conflict_pattern = re.compile(r'任务管理(能力)?不可用时.{0,20}(回到|回退到)中枢|continue_in_hub|hub_execution_allowed|"hidden_subagents"\s*:\s*"may_substitute"|"(max_active_tasks|max_active)"\s*:\s*1', re.DOTALL)
    for relative in ("AGENTS.md", ".agents", "docs"):
        root = target.root / relative
        files = [root] if root.is_file() else list(root.rglob("*")) if root.is_dir() else []
        for path in files:
            if path.is_file() and path.suffix in (".md", ".json") and conflict_pattern.search(read_text(path)):
                fail("Conflicting workflow rule: " + str(path), 1)

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
            live = target.path(relative)
            if not live.is_file() or live.is_symlink():
                fail("Installed managed file is missing or unsafe: " + relative, 1)
        for retired in historical - set(expected_paths):
            if target.path(retired).exists():
                fail("Retired managed file remains: " + retired, 1)
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
        print("NOTICE Files retain normal non-force skip behavior; use upgrade --adopt-from 0.2.0 to adopt them.")

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
            validate_installation(target, quiet=True)
        except SystemExit:
            restore()
            raise

    initialize = args.force or (not manifest_existed and not legacy)
    if manifest_existed and not args.force:
        print("PRESERVE " + MANIFEST_REL + " (already exists)")
    elif legacy:
        print("MANIFEST NOT INITIALIZED; run upgrade --adopt-from 0.2.0.")
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
            validate_installation(target, quiet=True)
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
        elif not args.rollback and args.adopt_from != "0.2.0":
            fail("Missing .project-flow/manifest.json; explicitly pass --adopt-from 0.2.0 for a confirmed legacy deployment")

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
        if not root.is_dir() or root.is_symlink():
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
            if live.exists() and (live.is_symlink() or not live.is_file()):
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
            backup_bytes = backup.read_bytes() if backup.is_file() and not backup.is_symlink() else fail("Backup is missing or unsafe for " + record["path"])
            if digest_text(normalized_bytes(backup_bytes, "backup for " + record["path"])) != record.get("original_hash"):
                fail("Backup hash mismatch for " + record["path"])
            item["backup_bytes"] = backup_bytes
        manifest_backup_bytes = None
        if restore_manifest:
            if meta.get("old_manifest_hash") is not None:
                backup = self.target.path(CONTROL + "/transactions/" + identifier + "/backup/" + CONTROL + "/manifest.json", allow_control=True)
                manifest_backup_bytes = backup.read_bytes() if backup.is_file() and not backup.is_symlink() else fail("Manifest backup is missing or unsafe")
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
        if self.manifest is not None:
            value = self.manifest.get("project_name")
            if value is None and isinstance(self.manifest.get("project"), dict):
                value = self.manifest["project"].get("name")
            return validate_project_name(value)
        workflow = self.target.path(".agents/workflow.json")
        if workflow.is_file():
            data = load_json(workflow, ".agents/workflow.json")
            value = data.get("project", {}).get("name") if isinstance(data.get("project"), dict) else None
            if value and value != "<PROJECT_NAME>":
                return validate_project_name(value)
        return validate_project_name(self.target.root.name)

    def run(self):
        if self.args.rollback:
            if self.args.adopt_from or self.args.project_name:
                fail("Rollback does not accept adoption or project-name options")
            self.rollback(self.args.rollback)
            return
        project_name = self.project_name()
        installed_version = self.args.adopt_from if self.manifest is None else self.manifest.get("workflow_version")
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
            if live.exists() and (live.is_symlink() or not live.is_file()):
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
            elif base_text is None:
                action = "NOOP" if live_hash == new_hash else "CONFLICT"
            elif entry["policy"] == "seed_once":
                action = "NOOP" if live_hash == new_hash else "PRESERVE"
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
            if live.exists() and (live.is_symlink() or not live.is_file()):
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
            validate_installation(self.target, quiet=True)
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
        if stat.S_ISLNK(item.st_mode) or not stat.S_ISREG(item.st_mode):
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
        if root.is_symlink() or not root.is_dir():
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
            validate_installation(self.target, quiet=True)
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
    args = parser.parse_args(argv)
    validate_installation(Target(args.target or args.target_positional or "."), args.allow_placeholders)


try:
    reject_control(COMMAND, "Command")
    if COMMAND == "install":
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
