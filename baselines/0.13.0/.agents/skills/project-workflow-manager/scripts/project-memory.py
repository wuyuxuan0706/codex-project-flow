#!/usr/bin/env python3
"""Fail-closed local persistence for project plan and state Markdown files."""

from __future__ import annotations

import argparse
import contextlib
import datetime as _datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import unicodedata
import uuid


CONTROL = ".project-flow"
LOCK_REL = ".project-flow/transaction.lock"
JOURNAL_REL = ".project-flow/project-memory.journal.json"
HASH_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")
STEP_RE = re.compile(r"- \[([ x])\] (S[0-9]{2,}) \| (\S(?:.*\S)?)\Z")
PROGRESS_RE = re.compile(r"- 已验收：[0-9]+ / [0-9]+ 个步骤。\Z")
HEADING_RE = re.compile(r"(#{1,6})[ \t]+(.+?)\s*\Z")


class MemoryError(RuntimeError):
    """A user-correctable, fail-closed contract error."""


def _fail(message: str) -> None:
    raise MemoryError(message)


def _is_reparse(info: os.stat_result) -> bool:
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, "st_file_attributes", 0)
        & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
    )


def _sha(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _utc_now() -> str:
    return (
        _datetime.datetime.now(_datetime.timezone.utc)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z")
    )


def _json_line(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _safe_relative(value: object, label: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\\" in value:
        _fail(f"{label} must be a non-empty portable relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        _fail(f"{label} escapes the project: {value!r}")
    if re.match(r"^[A-Za-z]:", value):
        _fail(f"{label} escapes the project: {value!r}")
    return path


def _check_chain(path: Path, *, final_kind: str | None = None) -> None:
    """Reject links/reparse points in every existing component of an absolute path."""
    path = Path(os.path.abspath(os.fspath(path)))
    parts = path.parts
    if not parts:
        _fail(f"Invalid path: {path}")
    current = Path(parts[0])
    start = 1
    if os.name == "nt" and len(parts) > 1 and parts[0].endswith("\\"):
        current = Path(parts[0])
    for index, part in enumerate(parts[start:], start=start):
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            if index != len(parts) - 1:
                _fail(f"Path parent is missing: {current}")
            return
        if _is_reparse(info):
            _fail(f"Path uses a symbolic link or reparse point: {current}")
        if index < len(parts) - 1 and not stat.S_ISDIR(info.st_mode):
            _fail(f"Path parent is not a directory: {current}")
    if final_kind is not None:
        info = path.lstat()
        if final_kind == "directory" and not stat.S_ISDIR(info.st_mode):
            _fail(f"Expected a directory: {path}")
        if final_kind == "file" and not stat.S_ISREG(info.st_mode):
            _fail(f"Expected a regular file: {path}")


def _read_bytes(path: Path, label: str, *, missing_ok: bool = False) -> bytes | None:
    try:
        _check_chain(path, final_kind="file")
    except FileNotFoundError:
        if missing_ok:
            return None
        raise
    except MemoryError:
        if missing_ok and not path.exists():
            return None
        raise
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        if missing_ok:
            return None
        _fail(f"{label} is missing: {path}")
    except OSError as exc:
        _fail(f"Cannot safely open {label}: {exc}")
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            _fail(f"{label} is not a regular file: {path}")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            data = handle.read()
        current = path.lstat()
        if _is_reparse(current) or not stat.S_ISREG(current.st_mode):
            _fail(f"{label} changed to an unsafe file while reading")
        if opened.st_dev != current.st_dev or opened.st_ino != current.st_ino:
            _fail(f"{label} changed while reading")
        return data
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _decode(data: bytes, label: str) -> str:
    if data.startswith(b"\xef\xbb\xbf"):
        _fail(f"{label} must be UTF-8 without a byte-order mark")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail(f"{label} is not UTF-8: {exc}")


def _load_object(path: Path, label: str, *, missing_ok: bool = False) -> dict | None:
    raw = _read_bytes(path, label, missing_ok=missing_ok)
    if raw is None:
        return None
    try:
        value = json.loads(_decode(raw, label))
    except json.JSONDecodeError as exc:
        _fail(f"{label} is invalid JSON: {exc}")
    if not isinstance(value, dict):
        _fail(f"{label} JSON root must be an object")
    return value


def _ensure_directory(path: Path, root: Path) -> None:
    try:
        relative = path.relative_to(root)
    except ValueError:
        _fail(f"Refusing to create a directory outside the project: {path}")
    current = root
    for part in relative.parts:
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            try:
                os.mkdir(current, 0o700)
            except FileExistsError:
                pass
            info = current.lstat()
        if _is_reparse(info) or not stat.S_ISDIR(info.st_mode):
            _fail(f"Directory path is not a real directory: {current}")


def _fsync_directory(path: Path) -> None:
    if os.name == "nt":
        return
    try:
        descriptor = os.open(path, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError:
        # The file fsync is authoritative where directory fsync is unsupported.
        pass


def _write_exclusive(path: Path, data: bytes, root: Path) -> None:
    _ensure_directory(path.parent, root)
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_BINARY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as exc:
        _fail(f"Cannot create transaction file {path}: {exc}")
    try:
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _install_temp(temporary: Path, target: Path) -> None:
    os.replace(temporary, target)
    _fsync_directory(target.parent)


def _atomic_write(path: Path, data: bytes, root: Path) -> None:
    _ensure_directory(path.parent, root)
    try:
        info = path.lstat()
    except FileNotFoundError:
        info = None
    if info is not None and (_is_reparse(info) or not stat.S_ISREG(info.st_mode)):
        _fail(f"Refusing to replace an unsafe target: {path}")
    temporary = path.with_name(path.name + ".memory-tmp-" + uuid.uuid4().hex)
    try:
        _write_exclusive(temporary, data, root)
        _install_temp(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


class Project:
    def __init__(self, root_value: str):
        supplied_root = Path(os.path.abspath(root_value))
        _check_chain(supplied_root, final_kind="directory")
        self.root = Path(os.path.realpath(supplied_root))
        _check_chain(self.root, final_kind="directory")
        workflow_path = self.root / ".agents" / "workflow.json"
        workflow = _load_object(workflow_path, "workflow configuration")
        if workflow.get("schema_version") != 12:
            _fail("workflow configuration must use schema_version 12")
        paths = workflow.get("paths")
        planning = workflow.get("planning")
        memory = workflow.get("project_memory")
        if not isinstance(paths, dict) or not isinstance(planning, dict) or not isinstance(memory, dict):
            _fail("workflow configuration is missing project memory or planning fields")
        if memory.get("step_format") != "- [ ] S01 | 步骤内容":
            _fail("workflow project_memory.step_format is unknown")
        if memory.get("step_completion") != "explicit_user_acceptance_only":
            _fail("workflow project_memory.step_completion is unknown")
        fixed_paths = {
            "project_plan": "docs/PROJECT_PLAN.md",
            "project_state": "docs/PROJECT_STATE.md",
            "project_memory": ".agents/skills/project-workflow-manager/scripts/project-memory.py",
        }
        for key, fixed in fixed_paths.items():
            if paths.get(key) != fixed:
                _fail(f"workflow paths.{key} must be exactly {fixed!r}")
        if planning.get("registry_path") != ".project-flow/planning.json":
            _fail("workflow planning.registry_path must be exactly '.project-flow/planning.json'")
        self.plan_rel = _safe_relative(paths.get("project_plan"), "project plan path")
        self.state_rel = _safe_relative(paths.get("project_state"), "project state path")
        self.planning_rel = _safe_relative(planning.get("registry_path"), "planning registry path")
        if self.plan_rel == self.state_rel:
            _fail("project plan and state paths must differ")
        if self.planning_rel.parts[0] != CONTROL:
            _fail("planning registry must be inside .project-flow")
        self.plan_path = self._path(self.plan_rel)
        self.state_path = self._path(self.state_rel)
        self.planning_path = self._path(self.planning_rel)
        self.lock_path = self._path(_safe_relative(LOCK_REL, "transaction lock path"))
        self.journal_path = self._path(_safe_relative(JOURNAL_REL, "memory journal path"))

    def _path(self, relative: PurePosixPath) -> Path:
        result = self.root.joinpath(*relative.parts)
        try:
            if os.path.commonpath((str(self.root), str(result))) != str(self.root):
                _fail(f"Configured path escapes the project: {relative}")
        except ValueError:
            _fail(f"Configured path escapes the project: {relative}")
        _check_chain(result)
        return result


@contextlib.contextmanager
def _locked(project: Project):
    _ensure_directory(project.lock_path.parent, project.root)
    try:
        info = project.lock_path.lstat()
    except FileNotFoundError:
        info = None
    if info is not None and (_is_reparse(info) or not stat.S_ISREG(info.st_mode)):
        _fail("Transaction lock is not a safe regular file")
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(project.lock_path, flags, 0o600)
        handle = os.fdopen(descriptor, "r+b", buffering=0)
    except OSError as exc:
        _fail(f"Transaction lock is unavailable: {exc}")
    try:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            _fail("Transaction lock is not a regular file")
        if os.fstat(handle.fileno()).st_size == 0:
            handle.write(b"\0")
            handle.flush()
            os.fsync(handle.fileno())
        handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            _fail(f"Transaction lock is busy: {exc}")
        try:
            yield
        finally:
            handle.seek(0)
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


def _headings(text: str, label: str) -> list[tuple[int, str, int]]:
    first_nonempty = next((line for line in text.splitlines() if line.strip()), None)
    if first_nonempty is None or HEADING_RE.fullmatch(first_nonempty) is None:
        _fail(f"{label} first non-empty line must be a heading")
    result: list[tuple[int, str, int]] = []
    in_fence = False
    for index, line in enumerate(text.splitlines()):
        if re.match(r"^[ \t]*(```|~~~)", line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        match = HEADING_RE.fullmatch(line)
        if match:
            result.append((len(match.group(1)), match.group(2), index))
    if not result or result[0][0] != 1:
        _fail(f"{label} first non-empty heading must be level 1")
    previous = 0
    for level, _, _ in result:
        if previous and level > previous + 1:
            _fail(f"{label} skips a heading level")
        previous = level
    return result


def _validate_state(text: str) -> None:
    headings = _headings(text, "project state")
    if headings[0][1] != "项目状态":
        _fail("project state must begin with '# 项目状态'")
    if sum(1 for level, title, _ in headings if level == 2 and title == "验收记录") > 1:
        _fail("project state has duplicate 验收记录 sections")


def _plan_details(text: str, *, exact_sections: bool = False) -> dict:
    headings = _headings(text, "project plan")
    if headings[0][1] not in {"项目计划", "项目计划书"}:
        _fail("project plan must begin with '# 项目计划书' (or legacy '# 项目计划')")
    required = ["目标", "总体进度", "任务步骤"]
    h2 = [(title, line) for level, title, line in headings if level == 2]
    if exact_sections and [title for title, _ in h2] != required:
        _fail("candidate project plan must contain only 目标, 总体进度, 任务步骤 H2 sections")
    for title in required:
        if sum(1 for candidate, _ in h2 if candidate == title) != 1:
            _fail(f"project plan must contain exactly one '## {title}' section")
    positions = [next(line for title, line in h2 if title == required_title) for required_title in required]
    if positions != sorted(positions):
        _fail("project plan sections must be ordered as 目标, 总体进度, 任务步骤")
    lines = text.splitlines(keepends=True)
    step_start = positions[2] + 1
    step_end = next((line for title, line in h2 if line > positions[2]), len(lines))
    steps = []
    seen = set()
    for index in range(step_start, step_end):
        value = lines[index].rstrip("\r\n")
        match = STEP_RE.fullmatch(value)
        if match:
            step_id = match.group(2)
            if step_id in seen:
                _fail(f"project plan has duplicate step {step_id}")
            seen.add(step_id)
            steps.append({
                "id": step_id,
                "accepted": match.group(1) == "x",
                "content": match.group(3),
                "line": index,
            })
        elif re.match(r"^- \[[^]]*\]", value):
            _fail(f"project plan has an invalid step at line {index + 1}")
    return {
        "lines": lines,
        "steps": steps,
        "progressLine": positions[1],
        "progressEnd": positions[2],
    }


def _derive_progress(text: str, *, exact_sections: bool = False) -> str:
    details = _plan_details(text, exact_sections=exact_sections)
    lines = details["lines"]
    start = details["progressLine"] + 1
    end = details["progressEnd"]
    indexes = [index for index in range(start, end) if PROGRESS_RE.fullmatch(lines[index].rstrip("\r\n"))]
    if len(indexes) > 1:
        _fail("project plan has duplicate derived progress lines")
    accepted = sum(1 for step in details["steps"] if step["accepted"])
    progress = f"- 已验收：{accepted} / {len(details['steps'])} 个步骤。\n"
    if indexes:
        lines[indexes[0]] = progress
    else:
        insertion = start
        while insertion < end and not lines[insertion].strip():
            insertion += 1
        lines.insert(insertion, progress)
    return "".join(lines)


def _accept_step(text: str, step_id: str) -> tuple[str, bool]:
    if not re.fullmatch(r"S[0-9]{2,}", step_id):
        _fail("--step must use the S01 form")
    details = _plan_details(text, exact_sections=True)
    matching = [step for step in details["steps"] if step["id"] == step_id]
    if not matching:
        _fail(f"project plan does not contain step {step_id}")
    step = matching[0]
    already = step["accepted"]
    lines = details["lines"]
    if not already:
        lines[step["line"]] = lines[step["line"]].replace("- [ ] ", "- [x] ", 1)
    return _derive_progress("".join(lines), exact_sections=True), already


def _record_acceptance(text: str, step_id: str, acceptance: str) -> tuple[str, bool]:
    if not acceptance.strip():
        _fail("--user-acceptance must contain the exact, non-empty human acceptance text")
    _validate_state(text)
    record_prefix = f"- {step_id} | 用户验收："
    record = record_prefix + json.dumps(acceptance, ensure_ascii=False) + "\n"
    lines = text.splitlines(keepends=True)
    existing = [line.rstrip("\r\n") for line in lines if line.startswith(record_prefix)]
    if existing:
        if record.rstrip("\n") in existing:
            return text, True
        _fail(f"project state already records different acceptance text for {step_id}")
    headings = _headings(text, "project state")
    acceptance_heading = next(
        (line for level, title, line in headings if level == 2 and title == "验收记录"), None
    )
    if acceptance_heading is None:
        result = text
        if result and not result.endswith("\n"):
            result += "\n"
        if result and not result.endswith("\n\n"):
            result += "\n"
        result += "## 验收记录\n\n" + record
        return result, False
    end = next(
        (line for level, _, line in headings if level == 2 and line > acceptance_heading), len(lines)
    )
    insertion = end
    while insertion > acceptance_heading + 1 and not lines[insertion - 1].strip():
        insertion -= 1
    lines.insert(insertion, record)
    return "".join(lines), False


def _assert_hash(value: str, label: str) -> None:
    if not HASH_RE.fullmatch(value):
        _fail(f"{label} must be a lowercase sha256:<64 hex> value")


def _journal_exists(project: Project) -> bool:
    try:
        info = project.journal_path.lstat()
    except FileNotFoundError:
        return False
    if _is_reparse(info) or not stat.S_ISREG(info.st_mode):
        _fail("Project memory journal is not a safe regular file")
    return True


def _require_no_journal(project: Project) -> None:
    if _journal_exists(project):
        _fail("Project memory has a pending pair transaction; run recover before any other operation")


def _relative_string(project: Project, path: Path) -> str:
    return path.relative_to(project.root).as_posix()


def _pair_write(project: Project, plan: bytes, state: bytes, old_plan: bytes, old_state: bytes) -> None:
    token = str(uuid.uuid4())
    temporary_plan = project.plan_path.with_name(project.plan_path.name + f".memory-{token}.tmp")
    temporary_state = project.state_path.with_name(project.state_path.name + f".memory-{token}.tmp")
    records = [
        {
            "role": "plan",
            "path": project.plan_rel.as_posix(),
            "temporaryPath": _relative_string(project, temporary_plan),
            "oldSha256": _sha(old_plan),
            "newSha256": _sha(plan),
        },
        {
            "role": "state",
            "path": project.state_rel.as_posix(),
            "temporaryPath": _relative_string(project, temporary_state),
            "oldSha256": _sha(old_state),
            "newSha256": _sha(state),
        },
    ]
    journal = {
        "schemaVersion": 1,
        "kind": "project-memory-pair",
        "transactionId": token,
        "projectPath": str(project.root),
        "state": "prepared",
        "files": records,
    }
    created = []
    journal_written = False
    try:
        _write_exclusive(temporary_plan, plan, project.root)
        created.append(temporary_plan)
        _write_exclusive(temporary_state, state, project.root)
        created.append(temporary_state)
        _atomic_write(
            project.journal_path, (_json_line(journal) + "\n").encode("utf-8"), project.root
        )
        journal_written = True
        _fsync_directory(project.journal_path.parent)
        _install_temp(temporary_plan, project.plan_path)
        _install_temp(temporary_state, project.state_path)
        if _sha(_read_bytes(project.plan_path, "project plan")) != records[0]["newSha256"]:
            _fail("Project plan verification failed after pair write")
        if _sha(_read_bytes(project.state_path, "project state")) != records[1]["newSha256"]:
            _fail("Project state verification failed after pair write")
        project.journal_path.unlink()
        _fsync_directory(project.journal_path.parent)
    except BaseException as exc:
        if journal_written or _journal_exists(project):
            raise MemoryError(
                f"Pair transaction is incomplete ({exc}); run recover and do not archive or create a task"
            ) from exc
        for path in created:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        raise


def _validate_journal(project: Project, value: dict) -> list[dict]:
    expected = {"schemaVersion", "kind", "transactionId", "projectPath", "state", "files"}
    if set(value) != expected or value.get("schemaVersion") != 1:
        _fail("Project memory journal has an unknown schema")
    if value.get("kind") != "project-memory-pair" or value.get("state") != "prepared":
        _fail("Project memory journal has an unknown transaction state")
    token = value.get("transactionId")
    try:
        if str(uuid.UUID(str(token))) != token:
            raise ValueError
    except (ValueError, AttributeError):
        _fail("Project memory journal transactionId is invalid")
    if value.get("projectPath") != str(project.root):
        _fail("Project memory journal belongs to a different project path")
    files = value.get("files")
    if not isinstance(files, list) or len(files) != 2:
        _fail("Project memory journal must describe exactly two files")
    expected_roles = {"plan": project.plan_rel.as_posix(), "state": project.state_rel.as_posix()}
    seen = set()
    for item in files:
        if not isinstance(item, dict) or set(item) != {
            "role", "path", "temporaryPath", "oldSha256", "newSha256"
        }:
            _fail("Project memory journal file record has an unknown schema")
        role = item.get("role")
        if role in seen or expected_roles.get(role) != item.get("path"):
            _fail("Project memory journal file binding is invalid")
        seen.add(role)
        _assert_hash(item.get("oldSha256"), "journal old hash")
        _assert_hash(item.get("newSha256"), "journal new hash")
        temporary = _safe_relative(item.get("temporaryPath"), "journal temporary path")
        expected_target = project.plan_path if role == "plan" else project.state_path
        expected_name = expected_target.name + f".memory-{token}.tmp"
        if temporary.parent.as_posix() != PurePosixPath(item["path"]).parent.as_posix() or temporary.name != expected_name:
            _fail("Project memory journal temporary path is invalid")
    return files


def recover(project: Project) -> dict:
    with _locked(project):
        if not _journal_exists(project):
            return {"action": "none", "recovered": False}
        journal = _load_object(project.journal_path, "project memory journal")
        files = _validate_journal(project, journal)
        for item in files:
            target = project._path(_safe_relative(item["path"], "journal target path"))
            temporary = project._path(
                _safe_relative(item["temporaryPath"], "journal temporary path")
            )
            current = _read_bytes(target, f"journal {item['role']} target")
            current_hash = _sha(current)
            if current_hash == item["newSha256"]:
                continue
            if current_hash != item["oldSha256"]:
                _fail(
                    f"Cannot recover {item['role']}: target matches neither journal old nor new hash"
                )
            staged = _read_bytes(temporary, f"journal {item['role']} temporary")
            if _sha(staged) != item["newSha256"]:
                _fail(f"Cannot recover {item['role']}: staged content hash differs")
            _install_temp(temporary, target)
        for item in files:
            target = project._path(_safe_relative(item["path"], "journal target path"))
            if _sha(_read_bytes(target, f"recovered {item['role']}")) != item["newSha256"]:
                _fail(f"Recovered {item['role']} failed verification")
            temporary = project._path(
                _safe_relative(item["temporaryPath"], "journal temporary path")
            )
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
        project.journal_path.unlink()
        _fsync_directory(project.journal_path.parent)
        return {"action": "recovered", "recovered": True}


def _canonical_uuid(value: str, label: str) -> str:
    try:
        parsed = str(uuid.UUID(value))
    except (ValueError, AttributeError):
        _fail(f"{label} must be a canonical UUID")
    if parsed != value:
        _fail(f"{label} must be a canonical lowercase UUID")
    return value


def _opaque_identifier(value: str, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(f"{label} must be a non-empty opaque identifier")
    if any(unicodedata.category(character) == "Cc" for character in value):
        _fail(f"{label} contains a control character")
    return value


def _current_hub(project: Project) -> dict:
    path = project.root / CONTROL / "hub.json"
    value = _load_object(path, "hub registry")
    if set(value) != {"schemaVersion", "projectId", "projectPath", "threadId", "hubTitle", "updatedAt"}:
        _fail("hub registry has an unknown schema")
    if value.get("schemaVersion") != 1:
        _fail("hub registry schemaVersion must be 1")
    if value.get("projectPath") != str(project.root):
        _fail("hub registry does not match the exact project path")
    _opaque_identifier(value.get("projectId"), "hub registry projectId")
    _canonical_uuid(value.get("threadId"), "hub registry threadId")
    return value


def _hub(project: Project, project_id: str, hub_thread_id: str) -> dict:
    value = _current_hub(project)
    if value.get("projectId") != project_id or value.get("threadId") != hub_thread_id:
        _fail("hub registry does not match the exact project and hub binding")
    return value


def _validate_planning(project: Project, value: dict) -> dict:
    legacy_fields = {
        "schemaVersion", "projectId", "projectPath", "hubThreadId", "creationToken",
        "state", "threadId", "clientThreadId", "reboundFromHubThreadId",
        "createdAt", "updatedAt",
    }
    current_fields = legacy_fields | {"generation", "continuations"}
    if set(value) == legacy_fields:
        value = dict(value)
        value["generation"] = 1
        value["continuations"] = []
    elif set(value) != current_fields:
        _fail("planning registry has an unknown schema")
    if value.get("schemaVersion") != 1:
        _fail("planning registry has an unknown schema")
    _opaque_identifier(value.get("projectId"), "planning projectId")
    _canonical_uuid(value.get("hubThreadId"), "planning hubThreadId")
    _canonical_uuid(value.get("creationToken"), "planning creationToken")
    if value.get("projectPath") != str(project.root):
        _fail("planning registry belongs to a different project path")
    state = value.get("state")
    thread_id = value.get("threadId")
    client_id = value.get("clientThreadId")
    rebound_from = value.get("reboundFromHubThreadId")
    if thread_id is not None:
        _canonical_uuid(thread_id, "planning threadId")
    if client_id is not None:
        _canonical_uuid(client_id, "planning clientThreadId")
    if rebound_from is not None:
        _canonical_uuid(rebound_from, "planning reboundFromHubThreadId")
    if state == "creating" and (thread_id is not None or client_id is not None):
        _fail("creating planning registry must not have an identity")
    if state == "queued" and (thread_id is not None or client_id is None):
        _fail("queued planning registry must have only clientThreadId")
    if state == "bound" and thread_id is None:
        _fail("bound planning registry must have threadId")
    if state not in {"creating", "queued", "bound"}:
        _fail("planning registry state is unknown")
    if not isinstance(value.get("createdAt"), str) or not isinstance(value.get("updatedAt"), str):
        _fail("planning registry timestamps are invalid")
    generation = value.get("generation")
    continuations = value.get("continuations")
    if isinstance(generation, bool) or not isinstance(generation, int) or generation < 1:
        _fail("planning registry generation must be a positive integer")
    if not isinstance(continuations, list) or len(continuations) != generation - 1:
        _fail("planning registry continuation lineage does not match generation")
    previous = None
    seen_real_identities = set()
    rotation_tokens = set()
    continuation_fields = {
        "generation", "predecessorThreadId", "hubThreadId", "rotationRequest", "rotationToken",
        "intent", "threadId", "clientThreadId", "createdAt",
    }
    for expected_generation, continuation in enumerate(continuations, start=2):
        if not isinstance(continuation, dict) or set(continuation) != continuation_fields:
            _fail("planning continuation has an unknown schema")
        if continuation.get("generation") != expected_generation:
            _fail("planning continuation generations are not contiguous")
        predecessor = _canonical_uuid(
            continuation.get("predecessorThreadId"), "planning continuation predecessorThreadId"
        )
        seen_real_identities.add(predecessor)
        continuation_hub = _canonical_uuid(
            continuation.get("hubThreadId"), "planning continuation hubThreadId"
        )
        rotation_request = _opaque_identifier(
            continuation.get("rotationRequest"), "planning continuation rotationRequest"
        )
        expected_rotation_request = (
            "[codex-project-flow:execution:v3] "
            f"projectId={value['projectId']}; hubThreadId={continuation_hub}; "
            f"requestId={value['creationToken']}; predecessorThreadId={predecessor}; "
            f"generation={expected_generation}"
        )
        if rotation_request != expected_rotation_request:
            _fail("stored planning continuation rotationRequest is invalid")
        rotation_token = _canonical_uuid(
            continuation.get("rotationToken"), "planning continuation rotationToken"
        )
        if rotation_token in rotation_tokens:
            _fail("planning continuation rotationToken is duplicated")
        rotation_tokens.add(rotation_token)
        continuation_thread = continuation.get("threadId")
        continuation_client = continuation.get("clientThreadId")
        if continuation_thread is not None:
            _canonical_uuid(continuation_thread, "planning continuation threadId")
            if continuation_thread in seen_real_identities:
                _fail("planning continuation real identity creates a predecessor cycle")
        if continuation_client is not None:
            _canonical_uuid(continuation_client, "planning continuation clientThreadId")
        intent = continuation.get("intent")
        if intent == "real":
            if continuation_thread is None or continuation_client is not None:
                _fail("real planning continuation must have only threadId")
        elif intent == "queued":
            if continuation_client is None:
                _fail("queued planning continuation must retain clientThreadId")
        else:
            _fail("planning continuation intent is unknown")
        if not isinstance(continuation.get("createdAt"), str):
            _fail("planning continuation createdAt is invalid")
        if previous is not None:
            if previous.get("threadId") is None or predecessor != previous["threadId"]:
                _fail("planning continuation predecessor lineage is broken")
        previous = continuation
        if continuation_thread is not None:
            seen_real_identities.add(continuation_thread)
    if generation == 1:
        if continuations:
            raise AssertionError("generation-one planning registry has lineage")
    else:
        if state == "creating":
            _fail("continued planning registry cannot return to creating")
        last = continuations[-1]
        if client_id != last["clientThreadId"] or thread_id != last["threadId"]:
            _fail("current planning identity does not match continuation lineage")
        if state == "queued" and (last["intent"] != "queued" or last["threadId"] is not None):
            _fail("queued planning state does not match continuation intent")
    return value


def _planning_result(action: str, value: dict) -> dict:
    result = dict(value)
    result["action"] = action
    return result


def planning_begin(project: Project, project_id: str, hub_thread_id: str) -> dict:
    project_id = _opaque_identifier(project_id, "--project-id")
    hub_thread_id = _canonical_uuid(hub_thread_id, "--hub-thread-id")
    with _locked(project):
        _require_no_journal(project)
        _hub(project, project_id, hub_thread_id)
        current = _load_object(project.planning_path, "planning registry", missing_ok=True)
        if current is not None:
            current = _validate_planning(project, current)
            if current["projectId"] != project_id or current["hubThreadId"] != hub_thread_id:
                _fail("planning registry is bound to a different project or hub")
            action = "recover" if current["state"] == "creating" else "reuse"
            return _planning_result(action, current)
        now = _utc_now()
        value = {
            "schemaVersion": 1,
            "projectId": project_id,
            "projectPath": str(project.root),
            "hubThreadId": hub_thread_id,
            "creationToken": str(uuid.uuid4()),
            "state": "creating",
            "threadId": None,
            "clientThreadId": None,
            "reboundFromHubThreadId": None,
            "generation": 1,
            "continuations": [],
            "createdAt": now,
            "updatedAt": now,
        }
        _atomic_write(project.planning_path, (_json_line(value) + "\n").encode(), project.root)
        return _planning_result("create", value)


def planning_bind(
    project: Project, token: str, *, thread_id: str | None, client_thread_id: str | None
) -> dict:
    token = _canonical_uuid(token, "--token")
    if (thread_id is None) == (client_thread_id is None):
        _fail("planning-bind requires exactly one of --thread-id or --client-thread-id")
    if thread_id is not None:
        thread_id = _canonical_uuid(thread_id, "--thread-id")
    if client_thread_id is not None:
        client_thread_id = _canonical_uuid(client_thread_id, "--client-thread-id")
    with _locked(project):
        _require_no_journal(project)
        value = _validate_planning(
            project, _load_object(project.planning_path, "planning registry")
        )
        _hub(project, value["projectId"], value["hubThreadId"])
        if value["creationToken"] != token:
            _fail("planning creation token does not match")
        if value["state"] == "creating":
            value["threadId"] = thread_id
            value["clientThreadId"] = client_thread_id
            value["state"] = "bound" if thread_id else "queued"
            value["updatedAt"] = _utc_now()
            _atomic_write(project.planning_path, (_json_line(value) + "\n").encode(), project.root)
            return _planning_result("bound" if thread_id else "queued", value)
        if thread_id is not None and value["threadId"] == thread_id:
            return _planning_result("reuse", value)
        if client_thread_id is not None and value["clientThreadId"] == client_thread_id:
            return _planning_result("reuse", value)
        _fail("planning registry already has a different identity; refusing duplicate bind")


def planning_resolve(
    project: Project, token: str, client_thread_id: str, thread_id: str
) -> dict:
    token = _canonical_uuid(token, "--token")
    client_thread_id = _canonical_uuid(client_thread_id, "--client-thread-id")
    thread_id = _canonical_uuid(thread_id, "--thread-id")
    with _locked(project):
        _require_no_journal(project)
        value = _validate_planning(
            project, _load_object(project.planning_path, "planning registry")
        )
        _hub(project, value["projectId"], value["hubThreadId"])
        if value["creationToken"] != token:
            _fail("planning creation token does not match")
        if value["state"] == "bound" and value["clientThreadId"] == client_thread_id and value["threadId"] == thread_id:
            return _planning_result("reuse", value)
        if value["state"] != "queued" or value["clientThreadId"] != client_thread_id:
            _fail("planning-resolve requires the exact queued token and clientThreadId")
        if value["generation"] > 1:
            continuation = value["continuations"][-1]
            if (
                continuation["intent"] != "queued"
                or continuation["clientThreadId"] != client_thread_id
                or continuation["threadId"] is not None
            ):
                _fail("queued planning continuation does not match current identity")
            used_real_identities = {
                item["predecessorThreadId"] for item in value["continuations"]
            }
            used_real_identities.update(
                item["threadId"]
                for item in value["continuations"]
                if item["threadId"] is not None
            )
            if thread_id in used_real_identities:
                _fail("planning-resolve real identity would create a predecessor cycle")
            continuation["threadId"] = thread_id
        value["threadId"] = thread_id
        value["state"] = "bound"
        value["updatedAt"] = _utc_now()
        _atomic_write(project.planning_path, (_json_line(value) + "\n").encode(), project.root)
        return _planning_result("resolved", value)


def planning_continue(
    project: Project,
    token: str,
    expected_predecessor_thread_id: str,
    expected_generation: int,
    rotation_token: str,
    rotation_request: str,
    *,
    thread_id: str | None,
    client_thread_id: str | None,
) -> dict:
    token = _canonical_uuid(token, "--token")
    expected_predecessor_thread_id = _canonical_uuid(
        expected_predecessor_thread_id, "--expected-predecessor-thread-id"
    )
    if isinstance(expected_generation, bool) or expected_generation < 1:
        _fail("--expected-generation must be a positive integer")
    rotation_token = _canonical_uuid(rotation_token, "--rotation-token")
    rotation_request = _opaque_identifier(rotation_request, "--rotation-request")
    if (thread_id is None) == (client_thread_id is None):
        _fail("planning-continue requires exactly one of --thread-id or --client-thread-id")
    if thread_id is not None:
        thread_id = _canonical_uuid(thread_id, "--thread-id")
    if client_thread_id is not None:
        client_thread_id = _canonical_uuid(client_thread_id, "--client-thread-id")
    requested_identity = thread_id if thread_id is not None else client_thread_id
    if requested_identity == expected_predecessor_thread_id:
        _fail("planning successor identity must differ from its predecessor")
    with _locked(project):
        _require_no_journal(project)
        value = _validate_planning(
            project, _load_object(project.planning_path, "planning registry")
        )
        _hub(project, value["projectId"], value["hubThreadId"])
        if value["creationToken"] != token:
            _fail("planning creation token does not match")
        if value["generation"] == expected_generation + 1 and value["continuations"]:
            last = value["continuations"][-1]
            identity_matches = (
                last["threadId"] == thread_id
                if thread_id is not None
                else last["clientThreadId"] == client_thread_id
            )
            if (
                last["generation"] == expected_generation + 1
                and last["predecessorThreadId"] == expected_predecessor_thread_id
                and last["rotationRequest"] == rotation_request
                and last["rotationToken"] == rotation_token
                and last["intent"] == ("real" if thread_id is not None else "queued")
                and identity_matches
            ):
                return _planning_result("reuse", value)
        if value["generation"] != expected_generation:
            _fail("planning generation changed; refusing continuation")
        if value["state"] != "bound" or value["threadId"] != expected_predecessor_thread_id:
            _fail("planning continuation requires the exact current bound real predecessor")
        expected_rotation_request = (
            "[codex-project-flow:execution:v3] "
            f"projectId={value['projectId']}; hubThreadId={value['hubThreadId']}; "
            f"requestId={value['creationToken']}; "
            f"predecessorThreadId={expected_predecessor_thread_id}; "
            f"generation={expected_generation + 1}"
        )
        if rotation_request != expected_rotation_request:
            _fail("--rotation-request does not exactly match the current machine rotation.key")
        used_identities = {value["threadId"]}
        if value["clientThreadId"] is not None:
            used_identities.add(value["clientThreadId"])
        used_rotation_tokens = set()
        for continuation in value["continuations"]:
            used_identities.add(continuation["predecessorThreadId"])
            if continuation["threadId"] is not None:
                used_identities.add(continuation["threadId"])
            if continuation["clientThreadId"] is not None:
                used_identities.add(continuation["clientThreadId"])
            used_rotation_tokens.add(continuation["rotationToken"])
        if requested_identity in used_identities:
            _fail("planning successor identity was already used in this lineage")
        if rotation_token in used_rotation_tokens:
            _fail("planning rotation token was already used")
        now = _utc_now()
        successor_generation = expected_generation + 1
        continuation = {
            "generation": successor_generation,
            "predecessorThreadId": expected_predecessor_thread_id,
            "hubThreadId": value["hubThreadId"],
            "rotationRequest": rotation_request,
            "rotationToken": rotation_token,
            "intent": "real" if thread_id is not None else "queued",
            "threadId": thread_id,
            "clientThreadId": client_thread_id,
            "createdAt": now,
        }
        value["continuations"].append(continuation)
        value["generation"] = successor_generation
        value["state"] = "bound" if thread_id is not None else "queued"
        value["threadId"] = thread_id
        value["clientThreadId"] = client_thread_id
        value["updatedAt"] = now
        _atomic_write(project.planning_path, (_json_line(value) + "\n").encode(), project.root)
        return _planning_result("continued", value)


def planning_rebind(
    project: Project, token: str, expected_old_hub_thread_id: str, hub_thread_id: str
) -> dict:
    token = _canonical_uuid(token, "--token")
    expected_old_hub_thread_id = _canonical_uuid(
        expected_old_hub_thread_id, "--expected-old-hub-thread-id"
    )
    hub_thread_id = _canonical_uuid(hub_thread_id, "--hub-thread-id")
    if expected_old_hub_thread_id == hub_thread_id:
        _fail("planning-rebind requires different old and new hub thread IDs")
    with _locked(project):
        _require_no_journal(project)
        value = _validate_planning(
            project, _load_object(project.planning_path, "planning registry")
        )
        if value["creationToken"] != token:
            _fail("planning creation token does not match")
        _hub(project, value["projectId"], hub_thread_id)
        if value["hubThreadId"] == hub_thread_id:
            if value["reboundFromHubThreadId"] != expected_old_hub_thread_id:
                _fail("planning registry was not rebound from the expected old hub")
            return _planning_result("reuse", value)
        if value["hubThreadId"] != expected_old_hub_thread_id:
            _fail("planning registry does not match the expected old hub")
        identity = (
            value["creationToken"], value["threadId"], value["clientThreadId"], value["state"]
        )
        value["hubThreadId"] = hub_thread_id
        value["reboundFromHubThreadId"] = expected_old_hub_thread_id
        value["updatedAt"] = _utc_now()
        if identity != (
            value["creationToken"], value["threadId"], value["clientThreadId"], value["state"]
        ):
            raise AssertionError("planning identity changed during rebind")
        _atomic_write(project.planning_path, (_json_line(value) + "\n").encode(), project.root)
        return _planning_result("rebound", value)


def read_memory(project: Project) -> dict:
    with _locked(project):
        _require_no_journal(project)
        plan = _read_bytes(project.plan_path, "project plan")
        state = _read_bytes(project.state_path, "project state")
        plan_text = _decode(plan, "project plan")
        state_text = _decode(state, "project state")
        plan_format_supported = True
        plan_warning = None
        try:
            _plan_details(plan_text, exact_sections=True)
        except MemoryError as exc:
            plan_format_supported = False
            plan_warning = (
                "project plan is preserved as raw Markdown but its format is unsupported: "
                f"{exc}; use save-plan with explicit human confirmation to normalize it"
            )
        _validate_state(state_text)
        planning = _load_object(project.planning_path, "planning registry", missing_ok=True)
        planning_status = {"bindingMismatch": False, "warning": None}
        if planning is not None:
            planning = _validate_planning(project, planning)
            hub = _current_hub(project)
            if hub["projectId"] != planning["projectId"] or hub["threadId"] != planning["hubThreadId"]:
                planning_status = {
                    "bindingMismatch": True,
                    "warning": (
                        "planning registry does not match the current hub; preserve its identity "
                        "and use planning-rebind only after a formally completed hub replacement"
                    ),
                }
        return {
            "plan": {"path": project.plan_rel.as_posix(), "sha256": _sha(plan), "content": plan_text},
            "state": {"path": project.state_rel.as_posix(), "sha256": _sha(state), "content": state_text},
            "planFormatSupported": plan_format_supported,
            "planWarning": plan_warning,
            "planning": planning,
            "planningStatus": planning_status,
        }


def save_state(project: Project, state_file: str, expected_state: str) -> dict:
    _assert_hash(expected_state, "--expected-state")
    source = _input_bytes(state_file, "state input file")
    _validate_state(_decode(source, "state input file"))
    with _locked(project):
        _require_no_journal(project)
        current = _read_bytes(project.state_path, "project state")
        if _sha(current) != expected_state:
            _fail("project state hash conflict; zero files were written")
        if source != current:
            _atomic_write(project.state_path, source, project.root)
        return {
            "saved": source != current,
            "state": {"path": project.state_rel.as_posix(), "sha256": _sha(source)},
        }


def _input_bytes(value: str, label: str) -> bytes:
    supplied = Path(os.path.abspath(value))
    _check_chain(supplied, final_kind="file")
    return _read_bytes(Path(os.path.realpath(supplied)), label)


def save_plan(
    project: Project,
    plan_file: str,
    state_file: str,
    user_confirmation: str,
    expected_plan: str,
    expected_state: str,
) -> dict:
    _assert_hash(expected_plan, "--expected-plan")
    _assert_hash(expected_state, "--expected-state")
    if not user_confirmation.strip():
        _fail("--user-confirmation must contain the exact, non-empty human confirmation text")
    candidate_plan_text = _decode(_input_bytes(plan_file, "plan input file"), "plan input file")
    _plan_details(candidate_plan_text, exact_sections=True)
    candidate_plan_text = _derive_progress(candidate_plan_text, exact_sections=True)
    candidate_details = _plan_details(candidate_plan_text, exact_sections=True)
    candidate_plan = candidate_plan_text.encode("utf-8")
    candidate_state = _input_bytes(state_file, "state input file")
    _validate_state(_decode(candidate_state, "state input file"))
    with _locked(project):
        _require_no_journal(project)
        old_plan = _read_bytes(project.plan_path, "project plan")
        old_state = _read_bytes(project.state_path, "project state")
        if _sha(old_plan) != expected_plan or _sha(old_state) != expected_state:
            _fail("project plan or state hash conflict; zero files were written")
        try:
            old_details = _plan_details(_decode(old_plan, "project plan"), exact_sections=True)
        except MemoryError:
            old_details = None
        candidate_accepted = {
            step["id"]: step["content"]
            for step in candidate_details["steps"]
            if step["accepted"]
        }
        if old_details is None:
            if candidate_accepted:
                _fail("normalized candidate cannot infer accepted steps from an unsupported legacy plan")
        else:
            old_accepted = {
                step["id"]: step["content"]
                for step in old_details["steps"]
                if step["accepted"]
            }
            if candidate_accepted != old_accepted:
                _fail(
                    "candidate must preserve every accepted step ID, content, and checked state "
                    "and must not add newly checked steps"
                )
        changed = candidate_plan != old_plan or candidate_state != old_state
        if changed:
            _pair_write(project, candidate_plan, candidate_state, old_plan, old_state)
        return {
            "saved": changed,
            "confirmationAuthority": "caller-supplied-not-authenticated",
            "planSha256": _sha(candidate_plan),
            "stateSha256": _sha(candidate_state),
            "planFormatSupported": True,
        }


def accept_step(
    project: Project, step_id: str, acceptance: str, expected_plan: str, expected_state: str
) -> dict:
    _assert_hash(expected_plan, "--expected-plan")
    _assert_hash(expected_state, "--expected-state")
    with _locked(project):
        _require_no_journal(project)
        old_plan = _read_bytes(project.plan_path, "project plan")
        old_state = _read_bytes(project.state_path, "project state")
        if _sha(old_plan) != expected_plan or _sha(old_state) != expected_state:
            _fail("project plan or state hash conflict; zero files were written")
        new_plan_text, was_checked = _accept_step(_decode(old_plan, "project plan"), step_id)
        new_state_text, had_record = _record_acceptance(
            _decode(old_state, "project state"), step_id, acceptance
        )
        new_plan = new_plan_text.encode("utf-8")
        new_state = new_state_text.encode("utf-8")
        changed = new_plan != old_plan or new_state != old_state
        if changed:
            _pair_write(project, new_plan, new_state, old_plan, old_state)
        return {
            "accepted": True,
            "changed": changed,
            "alreadyAccepted": was_checked and had_record,
            "step": step_id,
            "acceptanceAuthority": "caller-supplied-not-authenticated",
            "planSha256": _sha(new_plan),
            "stateSha256": _sha(new_state),
        }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Local CAS persistence for project plan/state; it does not call chat APIs or schedule tasks.",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    read = sub.add_parser("read", help="read both business documents and planning registry")
    read.add_argument("--project", required=True)
    save = sub.add_parser("save", help="CAS-save a caller-prepared project state document")
    save.add_argument("--project", required=True)
    save.add_argument("--state-file", required=True)
    save.add_argument("--expected-state", required=True)
    save_plan_parser = sub.add_parser(
        "save-plan",
        help="CAS-save a human-confirmed canonical plan and state as one recoverable pair",
        description=(
            "Save one canonical project plan/state pair after the human confirms the goal and steps. "
            "This is not per-file approval, and this helper cannot authenticate a real user. The "
            "caller MUST pass the exact human confirmation text. Accepted steps can only originate "
            "from the existing canonical plan and remain unchanged."
        ),
    )
    save_plan_parser.add_argument("--project", required=True)
    save_plan_parser.add_argument("--plan-file", required=True)
    save_plan_parser.add_argument("--state-file", required=True)
    save_plan_parser.add_argument("--user-confirmation", required=True)
    save_plan_parser.add_argument("--expected-plan", required=True)
    save_plan_parser.add_argument("--expected-state", required=True)
    accept = sub.add_parser(
        "accept",
        help="record an explicit human acceptance supplied by the caller",
        description=(
            "Record one accepted plan step. This helper cannot authenticate a real user. "
            "The caller MUST invoke it only after receiving explicit human acceptance and MUST "
            "pass the exact human text. A failed or pending transaction forbids archive/task creation."
        ),
    )
    accept.add_argument("--project", required=True)
    accept.add_argument("--step", required=True)
    accept.add_argument("--user-acceptance", required=True)
    accept.add_argument("--expected-plan", required=True)
    accept.add_argument("--expected-state", required=True)
    recover_parser = sub.add_parser(
        "recover", help="finish a journaled plan/state pair before further work"
    )
    recover_parser.add_argument("--project", required=True)
    begin = sub.add_parser("planning-begin", help="durably reserve one planning-chat creation")
    begin.add_argument("--project", required=True)
    begin.add_argument("--project-id", required=True)
    begin.add_argument("--hub-thread-id", required=True)
    bind = sub.add_parser("planning-bind", help="bind the one exact real or queued planning identity")
    bind.add_argument("--project", required=True)
    bind.add_argument("--token", required=True)
    identity = bind.add_mutually_exclusive_group(required=True)
    identity.add_argument("--thread-id")
    identity.add_argument("--client-thread-id")
    resolve = sub.add_parser("planning-resolve", help="upgrade an exact queued identity to its real task id")
    resolve.add_argument("--project", required=True)
    resolve.add_argument("--token", required=True)
    resolve.add_argument("--client-thread-id", required=True)
    resolve.add_argument("--thread-id", required=True)
    continue_parser = sub.add_parser(
        "planning-continue",
        help="CAS-register one already-created real or queued planning successor",
        description=(
            "Register exactly one planning successor after the caller saved durable intent and the "
            "successor identity in project state. --rotation-request is the exact existing machine "
            "rotation.key first line, not a paraphrase or user description. --rotation-token is the "
            "UUID already included in the successor's planning-continuation key. This helper does "
            "not create or archive chats; only a successful continued/reuse result permits the "
            "caller to proceed with separately authorized predecessor archival."
        ),
    )
    continue_parser.add_argument("--project", required=True)
    continue_parser.add_argument("--token", required=True)
    continue_parser.add_argument("--expected-predecessor-thread-id", required=True)
    continue_parser.add_argument("--expected-generation", required=True, type=int)
    continue_parser.add_argument("--rotation-token", required=True)
    continue_parser.add_argument("--rotation-request", required=True)
    continuation_identity = continue_parser.add_mutually_exclusive_group(required=True)
    continuation_identity.add_argument("--thread-id")
    continuation_identity.add_argument("--client-thread-id")
    rebind = sub.add_parser(
        "planning-rebind",
        help="CAS-rebind the same planning identity after a completed formal hub replacement",
        description=(
            "Rebind an existing planning registry to the current replacement hub without creating "
            "or changing the planning identity. The caller MUST use this only after the formal hub "
            "replacement and retirement sequence completed successfully."
        ),
    )
    rebind.add_argument("--project", required=True)
    rebind.add_argument("--token", required=True)
    rebind.add_argument("--expected-old-hub-thread-id", required=True)
    rebind.add_argument("--hub-thread-id", required=True)
    return parser


def run(arguments: list[str]) -> dict:
    args = _parser().parse_args(arguments)
    project = Project(args.project)
    if args.command == "read":
        return read_memory(project)
    if args.command == "save":
        return save_state(project, args.state_file, args.expected_state)
    if args.command == "save-plan":
        return save_plan(
            project, args.plan_file, args.state_file, args.user_confirmation,
            args.expected_plan, args.expected_state,
        )
    if args.command == "accept":
        return accept_step(
            project, args.step, args.user_acceptance, args.expected_plan, args.expected_state
        )
    if args.command == "recover":
        return recover(project)
    if args.command == "planning-begin":
        return planning_begin(project, args.project_id, args.hub_thread_id)
    if args.command == "planning-bind":
        return planning_bind(
            project, args.token, thread_id=args.thread_id, client_thread_id=args.client_thread_id
        )
    if args.command == "planning-resolve":
        return planning_resolve(
            project, args.token, args.client_thread_id, args.thread_id
        )
    if args.command == "planning-continue":
        return planning_continue(
            project, args.token, args.expected_predecessor_thread_id,
            args.expected_generation, args.rotation_token, args.rotation_request,
            thread_id=args.thread_id, client_thread_id=args.client_thread_id,
        )
    if args.command == "planning-rebind":
        return planning_rebind(
            project, args.token, args.expected_old_hub_thread_id, args.hub_thread_id
        )
    raise AssertionError(args.command)


def main() -> int:
    try:
        print(_json_line(run(sys.argv[1:])))
        return 0
    except MemoryError as exc:
        print("ERROR " + str(exc), file=sys.stderr)
        print(
            "ACTION REQUIRED: resolve the error (and run recover when requested) before archive or task creation.",
            file=sys.stderr,
        )
        return 3
    except KeyboardInterrupt:
        print(
            "ERROR interrupted; if a project-memory journal exists, run recover before archive or task creation",
            file=sys.stderr,
        )
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
