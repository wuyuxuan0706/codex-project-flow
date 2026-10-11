"""Deployed policy checks, not evidence of native Codex model selection.

The workflow creates chats through agent instructions, not a bundled API client.
These tests verify that those instructions leave model choice to Codex. They do
not synthesize an API payload or claim that hidden agents read the app setting.
"""

import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CREATION_RULES = [
    "AGENTS.md",
    ".agents/WORKFLOW_PROTOCOL.md",
    "skills/bootstrap-project-flow/SKILL.md",
    "skills/upgrade-project-flow/SKILL.md",
]


class ModelDefaultsContractTests(unittest.TestCase):
    def test_creation_policy_leaves_model_and_reasoning_to_platform(self):
        tasks = json.loads(
            (ROOT / ".agents/workflow.json").read_text(encoding="utf-8-sig")
        )["tasks"]
        self.assertEqual(tasks.get("model_policy"), "codex_default_no_overrides")
        self.assertEqual(tasks.get("creation_omit_fields"), ["model", "thinking"])
        self.assertEqual(
            tasks.get("hidden_agents_omit_fields"), ["model", "reasoning_effort"]
        )

    def test_current_creation_rules_do_not_assign_a_named_model(self):
        # Historical migration baselines remain immutable and are not runtime
        # creation rules. Model numbers in them must not make this check fail.
        for relative in CREATION_RULES:
            with self.subTest(path=relative):
                self.assertIsNone(
                    re.search(
                        r"\bgpt-\d[\w.-]*",
                        (ROOT / relative).read_text(encoding="utf-8-sig"), re.I,
                    )
                )

    def test_each_creation_entrypoint_documents_omitted_visible_model_fields(self):
        # Hub requests and successors use the common protocol; initialization,
        # planning, and upgrades additionally enter through their two Skills.
        for relative in CREATION_RULES:
            with self.subTest(path=relative):
                text = (ROOT / relative).read_text(encoding="utf-8-sig")
                for field in ("model", "thinking"):
                    self.assertTrue(
                        re.search(rf"`{field}`", text),
                        f"{relative} must document omitted `{field}`",
                    )

    def test_common_rules_distinguish_hidden_agent_platform_inheritance(self):
        for relative in ("AGENTS.md", ".agents/WORKFLOW_PROTOCOL.md"):
            with self.subTest(path=relative):
                text = (ROOT / relative).read_text(encoding="utf-8-sig")
                self.assertTrue("reasoning_effort" in text, relative)
                self.assertTrue("继承" in text, relative)

    @unittest.skipUnless(shutil.which("sh"), "POSIX engine unavailable")
    def test_validator_rejects_missing_or_overridden_model_policy(self):
        # Real public disk-validation boundary, not a mock of chat creation.
        with tempfile.TemporaryDirectory(prefix="codex-flow-model-policy-") as directory:
            target = Path(directory)
            entries = json.loads(
                (ROOT / "managed-files.json").read_text(encoding="utf-8-sig")
            )["files"]
            for entry in entries:
                destination = target / entry["path"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / entry["source"], destination)
            path = target / ".agents/workflow.json"
            original = json.loads(path.read_text(encoding="utf-8-sig"))

            def validate():
                return subprocess.run(
                    ["sh", str(ROOT / "scripts/project-flow.sh"), "validate",
                     "--target", str(target), "--allow-placeholders", "--runtime"],
                    capture_output=True, text=True,
                )

            clean = validate()
            self.assertEqual(clean.returncode, 0, clean.stderr)
            for field, value, reason in (
                ("model_policy", "force_named_model", "task model policy"),
                ("creation_omit_fields", ["thinking"], "task model omission"),
                ("hidden_agents_omit_fields", ["model"], "hidden agent model omission"),
            ):
                with self.subTest(field=field):
                    mutated = json.loads(json.dumps(original))
                    mutated["tasks"][field] = value
                    path.write_text(json.dumps(mutated), encoding="utf-8")
                    result = validate()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(reason, result.stderr)
            original["tasks"].pop("model_policy")
            path.write_text(json.dumps(original), encoding="utf-8")
            missing = validate()
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("tasks fields are invalid", missing.stderr)


if __name__ == "__main__":
    unittest.main()
