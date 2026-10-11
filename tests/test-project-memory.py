import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / ".agents/skills/project-workflow-manager/scripts/project-memory.py"
SPEC = importlib.util.spec_from_file_location("project_memory", SCRIPT)
memory = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(memory)


PLAN = """# 项目计划

## 目标

- 完成本项目。

## 总体进度

- 已验收：0 / 2 个步骤。

## 任务步骤

- [ ] S01 | 完成第一步
- [ ] S02 | 完成第二步
"""

LEGACY_STATE = """# 项目状态

## 当前目标

- 完成本项目。

## 当前进展

- 尚未开始。

## 重要结论

- 暂无。

## 下一步

- 执行 S01。
"""


def digest(data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    return "sha256:" + hashlib.sha256(data).hexdigest()


class ProjectFixture:
    def __init__(self, base: Path):
        self.root = (base / "project").resolve()
        (self.root / ".agents").mkdir(parents=True)
        (self.root / ".project-flow").mkdir()
        (self.root / "docs").mkdir()
        self.project_id = str(uuid.uuid4())
        self.hub_id = str(uuid.uuid4())
        workflow = {
            "schema_version": 13,
            "paths": {
                "project_plan": "docs/PROJECT_PLAN.md",
                "project_state": "docs/PROJECT_STATE.md",
                "project_memory": ".agents/skills/project-workflow-manager/scripts/project-memory.py",
            },
            "project_memory": {
                "step_format": "- [ ] S01 | 步骤内容",
                "step_completion": "explicit_user_acceptance_only",
            },
            "planning": {"registry_path": ".project-flow/planning.json"},
        }
        (self.root / ".agents/workflow.json").write_text(
            json.dumps(workflow, ensure_ascii=False), encoding="utf-8"
        )
        self.plan = self.root / "docs/PROJECT_PLAN.md"
        self.state = self.root / "docs/PROJECT_STATE.md"
        self.plan.write_text(PLAN, encoding="utf-8")
        self.state.write_text(LEGACY_STATE, encoding="utf-8")
        hub = {
            "schemaVersion": 1,
            "projectId": self.project_id,
            "projectPath": str(self.root),
            "threadId": self.hub_id,
            "hubTitle": "Project hub",
            "updatedAt": "2026-10-09T00:00:00.000000Z",
        }
        (self.root / ".project-flow/hub.json").write_text(
            json.dumps(hub), encoding="utf-8"
        )

    def replace_hub(self, thread_id):
        path = self.root / ".project-flow/hub.json"
        hub = json.loads(path.read_text(encoding="utf-8"))
        hub["threadId"] = thread_id
        hub["updatedAt"] = "2026-10-09T01:00:00.000000Z"
        path.write_text(json.dumps(hub), encoding="utf-8")

    def command(self, *arguments):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )


class ProjectMemoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.fixture = ProjectFixture(Path(self.temporary.name))

    def tearDown(self):
        self.temporary.cleanup()

    def test_read_returns_both_documents_hashes_and_empty_planning(self):
        result = self.fixture.command("read", "--project", str(self.fixture.root))
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value["plan"]["content"], PLAN)
        self.assertEqual(value["plan"]["sha256"], digest(PLAN))
        self.assertEqual(value["state"]["content"], LEGACY_STATE)
        self.assertEqual(value["state"]["sha256"], digest(LEGACY_STATE))
        self.assertIsNone(value["planning"])
        self.assertFalse(value["planningStatus"]["bindingMismatch"])

    def test_real_project_plan_template_is_readable_after_install(self):
        template = (ROOT / "templates/PROJECT_PLAN.md").read_text(encoding="utf-8")
        self.fixture.plan.write_text(template, encoding="utf-8")
        result = self.fixture.command("read", "--project", str(self.fixture.root))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["plan"]["content"], template)

        self.fixture.plan.write_text(template + "\n## 额外章节\n\n- 非规范内容。\n", encoding="utf-8")
        unsupported = self.fixture.command("read", "--project", str(self.fixture.root))
        self.assertEqual(unsupported.returncode, 0, unsupported.stderr)
        self.assertFalse(json.loads(unsupported.stdout)["planFormatSupported"])
        rejected = self.fixture.command(
            "accept", "--project", str(self.fixture.root), "--step", "S01",
            "--user-acceptance", "验收", "--expected-plan", digest(self.fixture.plan.read_bytes()),
            "--expected-state", digest(LEGACY_STATE),
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("only", rejected.stderr)

    def test_schema_13_memory_paths_are_fixed_and_cannot_collide(self):
        workflow_path = self.fixture.root / ".agents/workflow.json"
        original = json.loads(workflow_path.read_text(encoding="utf-8"))
        cases = (
            ("paths", "project_plan", ".agents/workflow.json"),
            ("paths", "project_state", ".project-flow/project-memory.journal.json"),
            ("paths", "project_memory", "docs/PROJECT_PLAN.md"),
            ("planning", "registry_path", ".project-flow/transaction.lock"),
        )
        plan_before = self.fixture.plan.read_bytes()
        state_before = self.fixture.state.read_bytes()
        for section, key, bad_path in cases:
            with self.subTest(section=section, key=key, path=bad_path):
                changed = json.loads(json.dumps(original))
                changed[section][key] = bad_path
                workflow_path.write_text(json.dumps(changed), encoding="utf-8")
                result = self.fixture.command("read", "--project", str(self.fixture.root))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be exactly", result.stderr)
                self.assertEqual(self.fixture.plan.read_bytes(), plan_before)
                self.assertEqual(self.fixture.state.read_bytes(), state_before)
        workflow_path.write_text(json.dumps(original), encoding="utf-8")

    def test_save_is_state_only_cas_and_acceptance_is_not_claimed_authenticated(self):
        replacement = LEGACY_STATE.replace("尚未开始", "S01 已完成，等待验收")
        source = Path(self.temporary.name).resolve() / "new-state.md"
        source.write_text(replacement, encoding="utf-8")
        result = self.fixture.command(
            "save", "--project", str(self.fixture.root), "--state-file", str(source),
            "--expected-state", digest(LEGACY_STATE),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fixture.state.read_text(encoding="utf-8"), replacement)
        self.assertEqual(self.fixture.plan.read_text(encoding="utf-8"), PLAN)

        accepted = self.fixture.command(
            "accept", "--project", str(self.fixture.root), "--step", "S01",
            "--user-acceptance", "我明确验收 S01。", "--expected-plan", digest(PLAN),
            "--expected-state", digest(replacement),
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        payload = json.loads(accepted.stdout)
        self.assertEqual(payload["acceptanceAuthority"], "caller-supplied-not-authenticated")
        self.assertIn("- [x] S01 |", self.fixture.plan.read_text(encoding="utf-8"))
        self.assertIn("- 已验收：1 / 2 个步骤。", self.fixture.plan.read_text(encoding="utf-8"))
        self.assertIn('用户验收："我明确验收 S01。"', self.fixture.state.read_text(encoding="utf-8"))

        help_result = self.fixture.command("accept", "--help")
        self.assertIn("cannot authenticate", help_result.stdout)
        self.assertIn("a real user", help_result.stdout)
        self.assertIn("only after receiving explicit human acceptance", help_result.stdout)

    def test_repeated_acceptance_is_idempotent(self):
        first = self.fixture.command(
            "accept", "--project", str(self.fixture.root), "--step", "S01",
            "--user-acceptance", "接受", "--expected-plan", digest(PLAN),
            "--expected-state", digest(LEGACY_STATE),
        )
        self.assertEqual(first.returncode, 0, first.stderr)
        first_value = json.loads(first.stdout)
        plan_after = self.fixture.plan.read_bytes()
        state_after = self.fixture.state.read_bytes()
        second = self.fixture.command(
            "accept", "--project", str(self.fixture.root), "--step", "S01",
            "--user-acceptance", "接受", "--expected-plan", first_value["planSha256"],
            "--expected-state", first_value["stateSha256"],
        )
        self.assertEqual(second.returncode, 0, second.stderr)
        second_value = json.loads(second.stdout)
        self.assertTrue(second_value["alreadyAccepted"])
        self.assertFalse(second_value["changed"])
        self.assertEqual(self.fixture.plan.read_bytes(), plan_after)
        self.assertEqual(self.fixture.state.read_bytes(), state_after)
        self.assertEqual(self.fixture.state.read_text(encoding="utf-8").count("用户验收："), 1)
        different_text = self.fixture.command(
            "accept", "--project", str(self.fixture.root), "--step", "S01",
            "--user-acceptance", "另一段文字", "--expected-plan", first_value["planSha256"],
            "--expected-state", first_value["stateSha256"],
        )
        self.assertNotEqual(different_text.returncode, 0)
        self.assertIn("different acceptance text", different_text.stderr)
        self.assertEqual(self.fixture.plan.read_bytes(), plan_after)
        self.assertEqual(self.fixture.state.read_bytes(), state_after)

    def test_post_accept_reread_and_cas_save_cleans_only_that_step_status(self):
        state = LEGACY_STATE.replace(
            "## 下一步\n\n- 执行 S01。",
            "## 阻塞与待验收\n\n- S01 待验收。\n- S02 仍被外部条件阻塞。\n\n"
            "## 下一步\n\n- 等待 S01 验收。",
        )
        self.fixture.state.write_text(state, encoding="utf-8")
        accepted = self.fixture.command(
            "accept", "--project", str(self.fixture.root), "--step", "S01",
            "--user-acceptance", "S01 已明确验收。", "--expected-plan", digest(PLAN),
            "--expected-state", digest(state),
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        reread = self.fixture.command("read", "--project", str(self.fixture.root))
        self.assertEqual(reread.returncode, 0, reread.stderr)
        value = json.loads(reread.stdout)
        cleaned = value["state"]["content"].replace("- S01 待验收。\n", "").replace(
            "- 等待 S01 验收。", "- 继续处理 S02 阻塞。"
        )
        state_input = Path(self.temporary.name).resolve() / "post-accept-state.md"
        state_input.write_text(cleaned, encoding="utf-8")
        saved = self.fixture.command(
            "save", "--project", str(self.fixture.root), "--state-file", str(state_input),
            "--expected-state", value["state"]["sha256"],
        )
        self.assertEqual(saved.returncode, 0, saved.stderr)
        final = json.loads(
            self.fixture.command("read", "--project", str(self.fixture.root)).stdout
        )
        self.assertNotIn("S01 待验收", final["state"]["content"])
        self.assertIn("S02 仍被外部条件阻塞", final["state"]["content"])
        self.assertIn('S01 | 用户验收："S01 已明确验收。"', final["state"]["content"])
        self.assertIn("- [x] S01 | 完成第一步", final["plan"]["content"])
        self.assertEqual(final["state"]["content"], cleaned)

    def test_bad_step_format_or_hash_conflict_writes_nothing(self):
        before_plan = self.fixture.plan.read_bytes()
        before_state = self.fixture.state.read_bytes()
        missing = self.fixture.command(
            "accept", "--project", str(self.fixture.root), "--step", "S99",
            "--user-acceptance", "接受", "--expected-plan", digest(before_plan),
            "--expected-state", digest(before_state),
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(self.fixture.plan.read_bytes(), before_plan)
        self.assertEqual(self.fixture.state.read_bytes(), before_state)

        conflict = self.fixture.command(
            "accept", "--project", str(self.fixture.root), "--step", "S01",
            "--user-acceptance", "接受", "--expected-plan", "sha256:" + "0" * 64,
            "--expected-state", digest(before_state),
        )
        self.assertNotEqual(conflict.returncode, 0)
        self.assertIn("hash conflict", conflict.stderr)
        self.assertEqual(self.fixture.plan.read_bytes(), before_plan)
        self.assertEqual(self.fixture.state.read_bytes(), before_state)

        malformed = PLAN.replace("- [ ] S01 | 完成第一步", "- [maybe] S01 | 完成第一步")
        self.fixture.plan.write_text(malformed, encoding="utf-8")
        malformed_before = self.fixture.plan.read_bytes()
        invalid = self.fixture.command(
            "accept", "--project", str(self.fixture.root), "--step", "S01",
            "--user-acceptance", "接受", "--expected-plan", digest(malformed_before),
            "--expected-state", digest(before_state),
        )
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("invalid step", invalid.stderr)
        self.assertEqual(self.fixture.plan.read_bytes(), malformed_before)
        self.assertEqual(self.fixture.state.read_bytes(), before_state)

    def test_invalid_state_save_has_zero_writes(self):
        bad = Path(self.temporary.name).resolve() / "bad.md"
        bad.write_text("not a project state\n", encoding="utf-8")
        before = self.fixture.state.read_bytes()
        result = self.fixture.command(
            "save", "--project", str(self.fixture.root), "--state-file", str(bad),
            "--expected-state", digest(before),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.state.read_bytes(), before)

    @unittest.skipUnless(hasattr(Path, "symlink_to"), "symbolic links unavailable")
    def test_symlink_target_and_project_alias_are_rejected(self):
        outside = Path(self.temporary.name) / "outside.md"
        outside.write_text("outside", encoding="utf-8")
        self.fixture.state.unlink()
        self.fixture.state.symlink_to(outside)
        result = self.fixture.command("read", "--project", str(self.fixture.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symbolic link or reparse point", result.stderr)
        self.assertEqual(outside.read_text(encoding="utf-8"), "outside")

        alias = Path(self.temporary.name) / "alias"
        alias.symlink_to(self.fixture.root, target_is_directory=True)
        aliased = self.fixture.command("read", "--project", str(alias))
        self.assertNotEqual(aliased.returncode, 0)
        self.assertIn("symbolic link or reparse point", aliased.stderr)

        # A caller-supplied draft cannot enter through a linked parent either.
        self.fixture.state.unlink()
        self.fixture.state.write_text(LEGACY_STATE, encoding="utf-8")
        real_drafts = Path(self.temporary.name).resolve() / "real-drafts"
        real_drafts.mkdir()
        draft = real_drafts / "state.md"
        draft.write_text(LEGACY_STATE, encoding="utf-8")
        linked_drafts = Path(self.temporary.name).resolve() / "linked-drafts"
        linked_drafts.symlink_to(real_drafts, target_is_directory=True)
        linked_save = self.fixture.command(
            "save", "--project", str(self.fixture.root),
            "--state-file", str(linked_drafts / "state.md"),
            "--expected-state", digest(LEGACY_STATE),
        )
        self.assertNotEqual(linked_save.returncode, 0)
        self.assertIn("symbolic link or reparse point", linked_save.stderr)

    def test_concurrent_cas_allows_only_one_save(self):
        one = Path(self.temporary.name).resolve() / "one.md"
        two = Path(self.temporary.name).resolve() / "two.md"
        one.write_text(LEGACY_STATE.replace("尚未开始", "版本一"), encoding="utf-8")
        two.write_text(LEGACY_STATE.replace("尚未开始", "版本二"), encoding="utf-8")
        common = [
            sys.executable, str(SCRIPT), "save", "--project", str(self.fixture.root),
        ]
        first = subprocess.Popen(
            [*common, "--state-file", str(one), "--expected-state", digest(LEGACY_STATE)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        second = subprocess.Popen(
            [*common, "--state-file", str(two), "--expected-state", digest(LEGACY_STATE)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        first_out, first_err = first.communicate(timeout=10)
        second_out, second_err = second.communicate(timeout=10)
        codes = [first.returncode, second.returncode]
        self.assertEqual(codes.count(0), 1, (codes, first_out, first_err, second_out, second_err))
        self.assertEqual(sum(code != 0 for code in codes), 1)
        self.assertIn(
            self.fixture.state.read_text(encoding="utf-8"),
            (one.read_text(encoding="utf-8"), two.read_text(encoding="utf-8")),
        )

    def test_pair_failure_blocks_reads_and_explicit_recover_finishes_both(self):
        project = memory.Project(str(self.fixture.root))
        original_install = memory._install_temp
        count = 0

        def fail_second(temporary, target):
            nonlocal count
            count += 1
            if count == 3:
                raise OSError("injected pair failure")
            return original_install(temporary, target)

        with mock.patch.object(memory, "_install_temp", side_effect=fail_second):
            with self.assertRaises(memory.MemoryError):
                memory.accept_step(
                    project, "S01", "明确接受", digest(PLAN), digest(LEGACY_STATE)
                )
        self.assertTrue((self.fixture.root / ".project-flow/project-memory.journal.json").is_file())
        blocked = self.fixture.command("read", "--project", str(self.fixture.root))
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn("run recover", blocked.stderr)
        recovered = self.fixture.command("recover", "--project", str(self.fixture.root))
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertIn("- [x] S01 |", self.fixture.plan.read_text(encoding="utf-8"))
        self.assertIn("明确接受", self.fixture.state.read_text(encoding="utf-8"))
        self.assertFalse((self.fixture.root / ".project-flow/project-memory.journal.json").exists())

    def test_planning_creation_retries_do_not_duplicate(self):
        first = self.fixture.command(
            "planning-begin", "--project", str(self.fixture.root),
            "--project-id", self.fixture.project_id, "--hub-thread-id", self.fixture.hub_id,
        )
        self.assertEqual(first.returncode, 0, first.stderr)
        first_value = json.loads(first.stdout)
        self.assertEqual(first_value["action"], "create")
        retry = self.fixture.command(
            "planning-begin", "--project", str(self.fixture.root),
            "--project-id", self.fixture.project_id, "--hub-thread-id", self.fixture.hub_id,
        )
        retry_value = json.loads(retry.stdout)
        self.assertEqual(retry_value["action"], "recover")
        self.assertEqual(retry_value["creationToken"], first_value["creationToken"])

        task_id = str(uuid.uuid4())
        bound = self.fixture.command(
            "planning-bind", "--project", str(self.fixture.root),
            "--token", first_value["creationToken"], "--thread-id", task_id,
        )
        self.assertEqual(bound.returncode, 0, bound.stderr)
        reuse = self.fixture.command(
            "planning-begin", "--project", str(self.fixture.root),
            "--project-id", self.fixture.project_id, "--hub-thread-id", self.fixture.hub_id,
        )
        self.assertEqual(json.loads(reuse.stdout)["action"], "reuse")
        different = self.fixture.command(
            "planning-bind", "--project", str(self.fixture.root),
            "--token", first_value["creationToken"], "--thread-id", str(uuid.uuid4()),
        )
        self.assertNotEqual(different.returncode, 0)

    def test_planning_accepts_native_opaque_local_project_id(self):
        native_id = "local-4343f454531fc85b20fd1fe0d29fe48c"
        hub_path = self.fixture.root / ".project-flow/hub.json"
        hub = json.loads(hub_path.read_text(encoding="utf-8"))
        hub["projectId"] = native_id
        hub_path.write_text(json.dumps(hub), encoding="utf-8")
        begun = self.fixture.command(
            "planning-begin", "--project", str(self.fixture.root),
            "--project-id", native_id, "--hub-thread-id", self.fixture.hub_id,
        )
        self.assertEqual(begun.returncode, 0, begun.stderr)
        self.assertEqual(json.loads(begun.stdout)["projectId"], native_id)

    def test_legacy_raw_plan_can_be_read_then_normalized_by_pair_save(self):
        legacy_plan = """# Existing Plan

Keep this historical context and migrate it into project state.
"""
        self.fixture.plan.write_text(legacy_plan, encoding="utf-8")
        read = self.fixture.command("read", "--project", str(self.fixture.root))
        self.assertEqual(read.returncode, 0, read.stderr)
        read_value = json.loads(read.stdout)
        self.assertEqual(read_value["plan"]["content"], legacy_plan)
        self.assertEqual(read_value["plan"]["sha256"], digest(legacy_plan))
        self.assertFalse(read_value["planFormatSupported"])
        self.assertIn("save-plan", read_value["planWarning"])

        candidate_plan = """# 项目计划书

## 目标

- 新目标。

## 总体进度

- 已验收：99 / 99 个步骤。

## 任务步骤

- [ ] S01 | 执行迁移后的第一步
- [ ] S02 | 完成验证
"""
        candidate_state = LEGACY_STATE.replace(
            "- 暂无。", "- 已将 Existing Plan 的有效背景并入状态。"
        )
        plan_input = Path(self.temporary.name).resolve() / "candidate-plan.md"
        state_input = Path(self.temporary.name).resolve() / "candidate-state.md"
        plan_input.write_text(candidate_plan, encoding="utf-8")
        state_input.write_text(candidate_state, encoding="utf-8")
        saved = self.fixture.command(
            "save-plan", "--project", str(self.fixture.root),
            "--plan-file", str(plan_input), "--state-file", str(state_input),
            "--user-confirmation", "我确认新目标和两个步骤。",
            "--expected-plan", digest(legacy_plan), "--expected-state", digest(LEGACY_STATE),
        )
        self.assertEqual(saved.returncode, 0, saved.stderr)
        saved_value = json.loads(saved.stdout)
        self.assertEqual(saved_value["confirmationAuthority"], "caller-supplied-not-authenticated")
        self.assertIn("- 已验收：0 / 2 个步骤。", self.fixture.plan.read_text(encoding="utf-8"))
        self.assertEqual(self.fixture.state.read_text(encoding="utf-8"), candidate_state)
        reread = json.loads(
            self.fixture.command("read", "--project", str(self.fixture.root)).stdout
        )
        self.assertTrue(reread["planFormatSupported"])

        help_result = self.fixture.command("save-plan", "--help")
        self.assertIn("cannot authenticate", help_result.stdout)
        self.assertIn("a real user", help_result.stdout)
        self.assertIn("exact human confirmation text", help_result.stdout)

    def test_save_plan_preserves_accepted_steps_and_rejects_new_checks(self):
        accepted = self.fixture.command(
            "accept", "--project", str(self.fixture.root), "--step", "S01",
            "--user-acceptance", "验收第一步", "--expected-plan", digest(PLAN),
            "--expected-state", digest(LEGACY_STATE),
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        accepted_value = json.loads(accepted.stdout)
        accepted_plan = self.fixture.plan.read_text(encoding="utf-8")
        accepted_state = self.fixture.state.read_text(encoding="utf-8")
        revised_plan = accepted_plan.replace("完成本项目", "完成修订后的项目").replace(
            "完成第二步", "完成修订后的第二步"
        )
        plan_input = Path(self.temporary.name).resolve() / "revised-plan.md"
        state_input = Path(self.temporary.name).resolve() / "revised-state.md"
        plan_input.write_text(revised_plan, encoding="utf-8")
        state_input.write_text(accepted_state, encoding="utf-8")
        saved = self.fixture.command(
            "save-plan", "--project", str(self.fixture.root),
            "--plan-file", str(plan_input), "--state-file", str(state_input),
            "--user-confirmation", "确认修订未验收部分。",
            "--expected-plan", accepted_value["planSha256"],
            "--expected-state", accepted_value["stateSha256"],
        )
        self.assertEqual(saved.returncode, 0, saved.stderr)
        self.assertIn("- [x] S01 | 完成第一步", self.fixture.plan.read_text(encoding="utf-8"))

        stable_plan = self.fixture.plan.read_bytes()
        stable_state = self.fixture.state.read_bytes()
        for invalid_plan in (
            self.fixture.plan.read_text(encoding="utf-8").replace(
                "- [x] S01 | 完成第一步", "- [ ] S01 | 完成第一步"
            ),
            self.fixture.plan.read_text(encoding="utf-8").replace(
                "- [x] S01 | 完成第一步", "- [x] S01 | 篡改已验收内容"
            ),
            self.fixture.plan.read_text(encoding="utf-8").replace(
                "- [ ] S02 | 完成修订后的第二步", "- [x] S02 | 完成修订后的第二步"
            ),
        ):
            with self.subTest(invalid=invalid_plan):
                plan_input.write_text(invalid_plan, encoding="utf-8")
                failed = self.fixture.command(
                    "save-plan", "--project", str(self.fixture.root),
                    "--plan-file", str(plan_input), "--state-file", str(state_input),
                    "--user-confirmation", "确认", "--expected-plan", digest(stable_plan),
                    "--expected-state", digest(stable_state),
                )
                self.assertNotEqual(failed.returncode, 0)
                self.assertEqual(self.fixture.plan.read_bytes(), stable_plan)
                self.assertEqual(self.fixture.state.read_bytes(), stable_state)

    def test_save_plan_hash_conflict_and_new_check_have_zero_writes(self):
        plan_input = Path(self.temporary.name).resolve() / "checked-plan.md"
        state_input = Path(self.temporary.name).resolve() / "state.md"
        plan_input.write_text(PLAN.replace("- [ ] S01", "- [x] S01"), encoding="utf-8")
        state_input.write_text(LEGACY_STATE, encoding="utf-8")
        before_plan = self.fixture.plan.read_bytes()
        before_state = self.fixture.state.read_bytes()
        new_check = self.fixture.command(
            "save-plan", "--project", str(self.fixture.root),
            "--plan-file", str(plan_input), "--state-file", str(state_input),
            "--user-confirmation", "确认计划，但这不是步骤验收。",
            "--expected-plan", digest(before_plan), "--expected-state", digest(before_state),
        )
        self.assertNotEqual(new_check.returncode, 0)
        self.assertEqual(self.fixture.plan.read_bytes(), before_plan)
        self.assertEqual(self.fixture.state.read_bytes(), before_state)

        plan_input.write_text(PLAN.replace("完成本项目", "新的目标"), encoding="utf-8")
        conflict = self.fixture.command(
            "save-plan", "--project", str(self.fixture.root),
            "--plan-file", str(plan_input), "--state-file", str(state_input),
            "--user-confirmation", "确认新目标。", "--expected-plan", "sha256:" + "0" * 64,
            "--expected-state", digest(before_state),
        )
        self.assertNotEqual(conflict.returncode, 0)
        self.assertIn("hash conflict", conflict.stderr)
        self.assertEqual(self.fixture.plan.read_bytes(), before_plan)
        self.assertEqual(self.fixture.state.read_bytes(), before_state)

    def test_planning_rejects_wrong_binding_and_resolves_exact_queue(self):
        wrong = self.fixture.command(
            "planning-begin", "--project", str(self.fixture.root),
            "--project-id", str(uuid.uuid4()), "--hub-thread-id", self.fixture.hub_id,
        )
        self.assertNotEqual(wrong.returncode, 0)
        self.assertFalse((self.fixture.root / ".project-flow/planning.json").exists())

        begin = json.loads(
            self.fixture.command(
                "planning-begin", "--project", str(self.fixture.root),
                "--project-id", self.fixture.project_id, "--hub-thread-id", self.fixture.hub_id,
            ).stdout
        )
        client_id = str(uuid.uuid4())
        queued = self.fixture.command(
            "planning-bind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
        )
        self.assertEqual(queued.returncode, 0, queued.stderr)
        self.assertEqual(json.loads(queued.stdout)["state"], "queued")
        wrong_client = self.fixture.command(
            "planning-resolve", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", str(uuid.uuid4()),
            "--thread-id", str(uuid.uuid4()),
        )
        self.assertNotEqual(wrong_client.returncode, 0)

        thread_id = str(uuid.uuid4())
        resolved = self.fixture.command(
            "planning-resolve", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
            "--thread-id", thread_id,
        )
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        value = json.loads(resolved.stdout)
        self.assertEqual(value["action"], "resolved")
        self.assertEqual(value["threadId"], thread_id)
        repeated = self.fixture.command(
            "planning-resolve", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
            "--thread-id", thread_id,
        )
        self.assertEqual(json.loads(repeated.stdout)["action"], "reuse")

    def test_planning_continue_real_is_cas_idempotent_and_increments_generation(self):
        begin = json.loads(
            self.fixture.command(
                "planning-begin", "--project", str(self.fixture.root),
                "--project-id", self.fixture.project_id, "--hub-thread-id", self.fixture.hub_id,
            ).stdout
        )
        predecessor = str(uuid.uuid4())
        bound = self.fixture.command(
            "planning-bind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--thread-id", predecessor,
        )
        self.assertEqual(bound.returncode, 0, bound.stderr)
        # Exercise an on-disk registry created before generation/lineage fields existed.
        registry_path = self.fixture.root / ".project-flow/planning.json"
        legacy = json.loads(registry_path.read_text(encoding="utf-8"))
        legacy.pop("generation")
        legacy.pop("continuations")
        registry_path.write_text(json.dumps(legacy), encoding="utf-8")

        successor = str(uuid.uuid4())
        rotation_token = str(uuid.uuid4())
        rotation_request = (
            "[codex-project-flow:execution:v3] "
            f"projectId={self.fixture.project_id}; hubThreadId={self.fixture.hub_id}; "
            f"requestId={begin['creationToken']}; predecessorThreadId={predecessor}; generation=2"
        )
        before = registry_path.read_bytes()
        malformed_requests = (
            rotation_request.replace(f"projectId={self.fixture.project_id}", "projectId=wrong-project"),
            rotation_request.replace(f"hubThreadId={self.fixture.hub_id}", f"hubThreadId={uuid.uuid4()}"),
            rotation_request.replace(f"requestId={begin['creationToken']}", f"requestId={uuid.uuid4()}"),
            rotation_request.replace(f"predecessorThreadId={predecessor}", f"predecessorThreadId={uuid.uuid4()}"),
            rotation_request.replace("generation=2", "generation=9"),
            "please continue the planning interview",
        )
        for malformed_request in malformed_requests:
            rejected = self.fixture.command(
                "planning-continue", "--project", str(self.fixture.root),
                "--token", begin["creationToken"],
                "--expected-predecessor-thread-id", predecessor,
                "--expected-generation", "1", "--rotation-token", rotation_token,
                "--rotation-request", malformed_request, "--thread-id", successor,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("rotation.key", rejected.stderr)
            self.assertEqual(registry_path.read_bytes(), before)
        continued = self.fixture.command(
            "planning-continue", "--project", str(self.fixture.root),
            "--token", begin["creationToken"],
            "--expected-predecessor-thread-id", predecessor,
            "--expected-generation", "1", "--rotation-token", rotation_token,
            "--rotation-request", rotation_request, "--thread-id", successor,
        )
        self.assertEqual(continued.returncode, 0, continued.stderr)
        value = json.loads(continued.stdout)
        self.assertEqual(value["action"], "continued")
        self.assertEqual(value["generation"], 2)
        self.assertEqual(value["creationToken"], begin["creationToken"])
        self.assertEqual(value["threadId"], successor)
        self.assertEqual(len(value["continuations"]), 1)
        lineage = value["continuations"][0]
        self.assertEqual(lineage["generation"], 2)
        self.assertEqual(lineage["predecessorThreadId"], predecessor)
        self.assertEqual(lineage["rotationRequest"], rotation_request)
        self.assertEqual(lineage["rotationToken"], rotation_token)
        self.assertEqual(lineage["intent"], "real")
        after = registry_path.read_bytes()

        repeated = self.fixture.command(
            "planning-continue", "--project", str(self.fixture.root),
            "--token", begin["creationToken"],
            "--expected-predecessor-thread-id", predecessor,
            "--expected-generation", "1", "--rotation-token", rotation_token,
            "--rotation-request", rotation_request, "--thread-id", successor,
        )
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(json.loads(repeated.stdout)["action"], "reuse")
        self.assertEqual(registry_path.read_bytes(), after)

        failures = (
            ["--token", str(uuid.uuid4()), "--expected-predecessor-thread-id", successor,
             "--expected-generation", "2", "--rotation-token", str(uuid.uuid4()),
             "--rotation-request", rotation_request, "--thread-id", str(uuid.uuid4())],
            ["--token", begin["creationToken"], "--expected-predecessor-thread-id", successor,
             "--expected-generation", "1", "--rotation-token", str(uuid.uuid4()),
             "--rotation-request", rotation_request, "--thread-id", str(uuid.uuid4())],
            ["--token", begin["creationToken"], "--expected-predecessor-thread-id", successor,
             "--expected-generation", "2", "--rotation-token", str(uuid.uuid4()),
             "--rotation-request", rotation_request, "--thread-id", successor],
        )
        for arguments in failures:
            failed = self.fixture.command(
                "planning-continue", "--project", str(self.fixture.root), *arguments
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(registry_path.read_bytes(), after)

        third = str(uuid.uuid4())
        third_token = str(uuid.uuid4())
        third_request = rotation_request.replace(
            f"predecessorThreadId={predecessor}; generation=2",
            f"predecessorThreadId={successor}; generation=3",
        )
        continued_again = self.fixture.command(
            "planning-continue", "--project", str(self.fixture.root),
            "--token", begin["creationToken"],
            "--expected-predecessor-thread-id", successor,
            "--expected-generation", "2", "--rotation-token", third_token,
            "--rotation-request", third_request, "--thread-id", third,
        )
        self.assertEqual(continued_again.returncode, 0, continued_again.stderr)
        third_value = json.loads(continued_again.stdout)
        self.assertEqual(third_value["generation"], 3)
        self.assertEqual(len(third_value["continuations"]), 2)
        self.assertEqual(third_value["continuations"][1]["predecessorThreadId"], successor)

    def test_queued_planning_continue_survives_hub_rebind_then_resolve(self):
        begin = json.loads(
            self.fixture.command(
                "planning-begin", "--project", str(self.fixture.root),
                "--project-id", self.fixture.project_id, "--hub-thread-id", self.fixture.hub_id,
            ).stdout
        )
        predecessor = str(uuid.uuid4())
        self.assertEqual(
            self.fixture.command(
                "planning-bind", "--project", str(self.fixture.root),
                "--token", begin["creationToken"], "--thread-id", predecessor,
            ).returncode,
            0,
        )
        client_id = str(uuid.uuid4())
        rotation_token = str(uuid.uuid4())
        rotation_request = (
            "[codex-project-flow:execution:v3] "
            f"projectId={self.fixture.project_id}; hubThreadId={self.fixture.hub_id}; "
            f"requestId={begin['creationToken']}; predecessorThreadId={predecessor}; generation=2"
        )
        queued = self.fixture.command(
            "planning-continue", "--project", str(self.fixture.root),
            "--token", begin["creationToken"],
            "--expected-predecessor-thread-id", predecessor,
            "--expected-generation", "1", "--rotation-token", rotation_token,
            "--rotation-request", rotation_request, "--client-thread-id", client_id,
        )
        self.assertEqual(queued.returncode, 0, queued.stderr)
        queued_value = json.loads(queued.stdout)
        self.assertEqual(queued_value["state"], "queued")
        self.assertEqual(queued_value["generation"], 2)
        self.assertEqual(queued_value["continuations"][-1]["intent"], "queued")
        self.assertEqual(queued_value["continuations"][-1]["clientThreadId"], client_id)

        registry_path = self.fixture.root / ".project-flow/planning.json"
        old_hub = self.fixture.hub_id
        new_hub = str(uuid.uuid4())
        self.fixture.replace_hub(new_hub)
        rebound = self.fixture.command(
            "planning-rebind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--expected-old-hub-thread-id", old_hub,
            "--hub-thread-id", new_hub,
        )
        self.assertEqual(rebound.returncode, 0, rebound.stderr)
        rebound_value = json.loads(rebound.stdout)
        self.assertEqual(rebound_value["generation"], 2)
        self.assertEqual(rebound_value["continuations"][-1]["rotationToken"], rotation_token)
        before_resolve = registry_path.read_bytes()
        retry_after_rebind = self.fixture.command(
            "planning-continue", "--project", str(self.fixture.root),
            "--token", begin["creationToken"],
            "--expected-predecessor-thread-id", predecessor,
            "--expected-generation", "1", "--rotation-token", rotation_token,
            "--rotation-request", rotation_request, "--client-thread-id", client_id,
        )
        self.assertEqual(retry_after_rebind.returncode, 0, retry_after_rebind.stderr)
        self.assertEqual(json.loads(retry_after_rebind.stdout)["action"], "reuse")
        self.assertEqual(registry_path.read_bytes(), before_resolve)

        real_id = str(uuid.uuid4())
        for token, requested_client in (
            (str(uuid.uuid4()), client_id),
            (begin["creationToken"], str(uuid.uuid4())),
        ):
            failed = self.fixture.command(
                "planning-resolve", "--project", str(self.fixture.root),
                "--token", token, "--client-thread-id", requested_client,
                "--thread-id", real_id,
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(registry_path.read_bytes(), before_resolve)
        predecessor_cycle = self.fixture.command(
            "planning-resolve", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
            "--thread-id", predecessor,
        )
        self.assertNotEqual(predecessor_cycle.returncode, 0)
        self.assertIn("predecessor cycle", predecessor_cycle.stderr)
        self.assertEqual(registry_path.read_bytes(), before_resolve)

        corrupt = json.loads(before_resolve.decode("utf-8"))
        corrupt["state"] = "bound"
        corrupt["threadId"] = predecessor
        corrupt["continuations"][-1]["threadId"] = predecessor
        registry_path.write_text(json.dumps(corrupt), encoding="utf-8")
        invalid_persisted = self.fixture.command("read", "--project", str(self.fixture.root))
        self.assertNotEqual(invalid_persisted.returncode, 0)
        self.assertIn("predecessor cycle", invalid_persisted.stderr)
        registry_path.write_bytes(before_resolve)

        resolved = self.fixture.command(
            "planning-resolve", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
            "--thread-id", real_id,
        )
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        resolved_value = json.loads(resolved.stdout)
        self.assertEqual(resolved_value["state"], "bound")
        self.assertEqual(resolved_value["threadId"], real_id)
        self.assertEqual(resolved_value["clientThreadId"], client_id)
        self.assertEqual(resolved_value["continuations"][-1]["threadId"], real_id)
        self.assertEqual(resolved_value["continuations"][-1]["rotationToken"], rotation_token)
        after_resolve = registry_path.read_bytes()
        repeated = self.fixture.command(
            "planning-resolve", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
            "--thread-id", real_id,
        )
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(json.loads(repeated.stdout)["action"], "reuse")
        self.assertEqual(registry_path.read_bytes(), after_resolve)

        continued_retry = self.fixture.command(
            "planning-continue", "--project", str(self.fixture.root),
            "--token", begin["creationToken"],
            "--expected-predecessor-thread-id", predecessor,
            "--expected-generation", "1", "--rotation-token", rotation_token,
            "--rotation-request", rotation_request, "--client-thread-id", client_id,
        )
        self.assertEqual(continued_retry.returncode, 0, continued_retry.stderr)
        retry_value = json.loads(continued_retry.stdout)
        self.assertEqual(retry_value["action"], "reuse")
        self.assertEqual(retry_value["threadId"], real_id)
        self.assertEqual(retry_value["clientThreadId"], client_id)
        self.assertEqual(len(retry_value["continuations"]), 1)
        self.assertEqual(retry_value["continuations"][0]["threadId"], real_id)
        self.assertEqual(registry_path.read_bytes(), after_resolve)

        for requested_client, requested_rotation_request in (
            (str(uuid.uuid4()), rotation_request),
            (client_id, rotation_request + "; changed=true"),
        ):
            conflicting_retry = self.fixture.command(
                "planning-continue", "--project", str(self.fixture.root),
                "--token", begin["creationToken"],
                "--expected-predecessor-thread-id", predecessor,
                "--expected-generation", "1", "--rotation-token", rotation_token,
                "--rotation-request", requested_rotation_request,
                "--client-thread-id", requested_client,
            )
            self.assertNotEqual(conflicting_retry.returncode, 0)
            self.assertEqual(registry_path.read_bytes(), after_resolve)

    def test_old_hub_planning_warns_on_read_and_identity_writes_stop(self):
        begin = json.loads(
            self.fixture.command(
                "planning-begin", "--project", str(self.fixture.root),
                "--project-id", self.fixture.project_id, "--hub-thread-id", self.fixture.hub_id,
            ).stdout
        )
        client_id = str(uuid.uuid4())
        queued = self.fixture.command(
            "planning-bind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
        )
        self.assertEqual(queued.returncode, 0, queued.stderr)
        registry_path = self.fixture.root / ".project-flow/planning.json"
        before = registry_path.read_bytes()
        new_hub = str(uuid.uuid4())
        self.fixture.replace_hub(new_hub)

        read = self.fixture.command("read", "--project", str(self.fixture.root))
        self.assertEqual(read.returncode, 0, read.stderr)
        read_value = json.loads(read.stdout)
        self.assertTrue(read_value["planningStatus"]["bindingMismatch"])
        self.assertIn("planning-rebind", read_value["planningStatus"]["warning"])
        self.assertEqual(read_value["planning"]["clientThreadId"], client_id)
        self.assertEqual(read_value["plan"]["content"], PLAN)
        self.assertEqual(read_value["state"]["content"], LEGACY_STATE)

        duplicate_begin = self.fixture.command(
            "planning-begin", "--project", str(self.fixture.root),
            "--project-id", self.fixture.project_id, "--hub-thread-id", new_hub,
        )
        self.assertNotEqual(duplicate_begin.returncode, 0)
        bind_retry = self.fixture.command(
            "planning-bind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
        )
        self.assertNotEqual(bind_retry.returncode, 0)
        self.assertIn("hub registry does not match", bind_retry.stderr)
        resolve = self.fixture.command(
            "planning-resolve", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
            "--thread-id", str(uuid.uuid4()),
        )
        self.assertNotEqual(resolve.returncode, 0)
        self.assertIn("hub registry does not match", resolve.stderr)
        self.assertEqual(registry_path.read_bytes(), before)

    def test_planning_rebind_is_exact_idempotent_and_preserves_identity(self):
        begin = json.loads(
            self.fixture.command(
                "planning-begin", "--project", str(self.fixture.root),
                "--project-id", self.fixture.project_id, "--hub-thread-id", self.fixture.hub_id,
            ).stdout
        )
        planning_id = str(uuid.uuid4())
        bound = self.fixture.command(
            "planning-bind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--thread-id", planning_id,
        )
        self.assertEqual(bound.returncode, 0, bound.stderr)
        registry_path = self.fixture.root / ".project-flow/planning.json"
        old_hub = self.fixture.hub_id
        new_hub = str(uuid.uuid4())
        self.fixture.replace_hub(new_hub)
        before = registry_path.read_bytes()

        bad_arguments = (
            (str(uuid.uuid4()), old_hub, new_hub),
            (begin["creationToken"], str(uuid.uuid4()), new_hub),
            (begin["creationToken"], old_hub, str(uuid.uuid4())),
        )
        for token, expected_old, requested_new in bad_arguments:
            with self.subTest(token=token, expected_old=expected_old, requested_new=requested_new):
                failed = self.fixture.command(
                    "planning-rebind", "--project", str(self.fixture.root),
                    "--token", token, "--expected-old-hub-thread-id", expected_old,
                    "--hub-thread-id", requested_new,
                )
                self.assertNotEqual(failed.returncode, 0)
                self.assertEqual(registry_path.read_bytes(), before)

        rebound = self.fixture.command(
            "planning-rebind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--expected-old-hub-thread-id", old_hub,
            "--hub-thread-id", new_hub,
        )
        self.assertEqual(rebound.returncode, 0, rebound.stderr)
        value = json.loads(rebound.stdout)
        self.assertEqual(value["action"], "rebound")
        self.assertEqual(value["hubThreadId"], new_hub)
        self.assertEqual(value["reboundFromHubThreadId"], old_hub)
        self.assertEqual(value["creationToken"], begin["creationToken"])
        self.assertEqual(value["threadId"], planning_id)
        self.assertIsNone(value["clientThreadId"])
        after = registry_path.read_bytes()

        repeated = self.fixture.command(
            "planning-rebind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--expected-old-hub-thread-id", old_hub,
            "--hub-thread-id", new_hub,
        )
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(json.loads(repeated.stdout)["action"], "reuse")
        self.assertEqual(registry_path.read_bytes(), after)

        wrong_old_after = self.fixture.command(
            "planning-rebind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"],
            "--expected-old-hub-thread-id", str(uuid.uuid4()), "--hub-thread-id", new_hub,
        )
        self.assertNotEqual(wrong_old_after.returncode, 0)
        self.assertEqual(registry_path.read_bytes(), after)

    def test_queued_planning_rebind_then_resolve_preserves_one_identity(self):
        begin_result = self.fixture.command(
            "planning-begin", "--project", str(self.fixture.root),
            "--project-id", self.fixture.project_id, "--hub-thread-id", self.fixture.hub_id,
        )
        self.assertEqual(begin_result.returncode, 0, begin_result.stderr)
        begin = json.loads(begin_result.stdout)
        client_id = str(uuid.uuid4())
        queued_result = self.fixture.command(
            "planning-bind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
        )
        self.assertEqual(queued_result.returncode, 0, queued_result.stderr)
        queued = json.loads(queued_result.stdout)
        self.assertEqual(queued["state"], "queued")
        self.assertEqual(queued["clientThreadId"], client_id)
        self.assertIsNone(queued["threadId"])

        registry_path = self.fixture.root / ".project-flow/planning.json"
        old_hub = self.fixture.hub_id
        new_hub = str(uuid.uuid4())
        self.fixture.replace_hub(new_hub)
        before_rebind = registry_path.read_bytes()
        for token, expected_old, requested_new in (
            (str(uuid.uuid4()), old_hub, new_hub),
            (begin["creationToken"], str(uuid.uuid4()), new_hub),
            (begin["creationToken"], old_hub, str(uuid.uuid4())),
        ):
            failed = self.fixture.command(
                "planning-rebind", "--project", str(self.fixture.root),
                "--token", token, "--expected-old-hub-thread-id", expected_old,
                "--hub-thread-id", requested_new,
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(registry_path.read_bytes(), before_rebind)

        rebound_result = self.fixture.command(
            "planning-rebind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--expected-old-hub-thread-id", old_hub,
            "--hub-thread-id", new_hub,
        )
        self.assertEqual(rebound_result.returncode, 0, rebound_result.stderr)
        rebound = json.loads(rebound_result.stdout)
        self.assertEqual(rebound["state"], "queued")
        self.assertEqual(rebound["clientThreadId"], client_id)
        self.assertIsNone(rebound["threadId"])
        self.assertEqual(rebound["creationToken"], begin["creationToken"])
        after_rebind = registry_path.read_bytes()
        repeated_rebind = self.fixture.command(
            "planning-rebind", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--expected-old-hub-thread-id", old_hub,
            "--hub-thread-id", new_hub,
        )
        self.assertEqual(repeated_rebind.returncode, 0, repeated_rebind.stderr)
        self.assertEqual(json.loads(repeated_rebind.stdout)["action"], "reuse")
        self.assertEqual(registry_path.read_bytes(), after_rebind)

        real_id = str(uuid.uuid4())
        for token, requested_client in (
            (str(uuid.uuid4()), client_id),
            (begin["creationToken"], str(uuid.uuid4())),
        ):
            failed = self.fixture.command(
                "planning-resolve", "--project", str(self.fixture.root),
                "--token", token, "--client-thread-id", requested_client,
                "--thread-id", real_id,
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(registry_path.read_bytes(), after_rebind)

        resolved_result = self.fixture.command(
            "planning-resolve", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
            "--thread-id", real_id,
        )
        self.assertEqual(resolved_result.returncode, 0, resolved_result.stderr)
        resolved = json.loads(resolved_result.stdout)
        self.assertEqual(resolved["action"], "resolved")
        self.assertEqual(resolved["state"], "bound")
        self.assertEqual(resolved["clientThreadId"], client_id)
        self.assertEqual(resolved["threadId"], real_id)
        self.assertEqual(resolved["creationToken"], begin["creationToken"])
        after_resolve = registry_path.read_bytes()
        repeated_resolve = self.fixture.command(
            "planning-resolve", "--project", str(self.fixture.root),
            "--token", begin["creationToken"], "--client-thread-id", client_id,
            "--thread-id", real_id,
        )
        self.assertEqual(repeated_resolve.returncode, 0, repeated_resolve.stderr)
        self.assertEqual(json.loads(repeated_resolve.stdout)["action"], "reuse")
        self.assertEqual(registry_path.read_bytes(), after_resolve)


if __name__ == "__main__":
    unittest.main()
