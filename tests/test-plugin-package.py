"""Exercise real plugin validators against isolated package copies.

This establishes discoverable bundled files and metadata, not native Codex skill
selection or the quality of the interactive interview.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUNDLED_SKILLS = ("grilling", "grill-me", "drawio-review", "guided-coding")
parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--engine", choices=("powershell", "posix"),
                    default="powershell" if os.name == "nt" else "posix")
OPTIONS, UNITTEST_ARGS = parser.parse_known_args()
SHELL = shutil.which("pwsh" if OPTIONS.engine == "powershell" else "sh")
if not SHELL and OPTIONS.engine == "posix" and os.name == "nt":
    git_shell = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/sh.exe"
    if git_shell.is_file():
        SHELL = str(git_shell)


class PluginPackageTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(SHELL, f"{OPTIONS.engine} shell is required")
        temporary = tempfile.TemporaryDirectory(prefix="codex-flow-package-")
        self.addCleanup(temporary.cleanup)
        self.package = Path(temporary.name) / "plugin"
        self.package.mkdir()
        for relative in (".agents", ".codex-plugin", "baselines", "docs", "scripts",
                         "skills", "templates", "third_party", "AGENTS.md",
                         "README.md", "VERSION", "managed-files.json"):
            source = ROOT / relative
            destination = self.package / relative
            if source.is_dir():
                shutil.copytree(source, destination, ignore=shutil.ignore_patterns("__pycache__"))
            else:
                shutil.copyfile(source, destination)

    def validate(self):
        if OPTIONS.engine == "powershell":
            command = [SHELL, "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                       str(self.package / "scripts/project-flow.ps1"), "validate",
                       "-Target", str(self.package), "-AllowPlaceholders"]
        else:
            command = [SHELL, str(self.package / "scripts/project-flow.sh"),
                       "validate", "--target", str(self.package), "--allow-placeholders"]
        environment = dict(os.environ, PYTHON=sys.executable, PYTHONIOENCODING="utf-8")
        return subprocess.run(command, cwd=self.package, env=environment,
                              capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=90)

    def require_rejected(self, expected):
        result = self.validate()
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn(expected, output)

    def test_complete_package_is_valid(self):
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_upstream_provenance_matches_bundled_bytes(self):
        provenance = json.loads((self.package / "third_party/mattpocock-skills/provenance.json").read_text(encoding="utf-8"))
        self.assertEqual(provenance["repository"], "https://github.com/mattpocock/skills")
        self.assertEqual(provenance["commit"], "49dd158d1076134a641b33efb035946536778336")
        records = {item["bundled_path"]: item for item in provenance["files"]}
        expected = {f"skills/{skill}/{file}" for skill in ("grilling", "grill-me")
                    for file in ("SKILL.md", "agents/openai.yaml")}
        expected.add("third_party/mattpocock-skills/LICENSE")
        self.assertEqual(set(records), expected)
        for relative, record in records.items():
            with self.subTest(path=relative):
                digest = hashlib.sha256((self.package / relative).read_bytes()).hexdigest()
                self.assertEqual(digest, record["bundled_sha256"])
                if relative != "skills/grill-me/SKILL.md":
                    self.assertEqual(digest, record["upstream_sha256"])
        # Pin the unmodified upstream behavior, independently of editable metadata.
        self.assertEqual(records["skills/grilling/SKILL.md"]["upstream_sha256"],
                         "befdff1e27a1dfe2a294d5871169ac1afe16d983911daa4f32627514a48c1e15")

    def test_each_bundled_skill_is_required(self):
        for skill in BUNDLED_SKILLS:
            with self.subTest(skill=skill):
                path = self.package / "skills" / skill / "SKILL.md"
                original = path.read_bytes()
                path.unlink()
                try:
                    self.require_rejected("skill-files" if OPTIONS.engine == "powershell" else "expected Skill files")
                finally:
                    path.write_bytes(original)

    def test_native_tools_reference_is_required(self):
        path = self.package / "skills/bootstrap-project-flow/references/native-tools.md"
        path.unlink()
        self.require_rejected("skill-files" if OPTIONS.engine == "powershell" else "expected Skill files")

    def test_each_bundled_skill_name_must_match_its_invocation(self):
        for skill in BUNDLED_SKILLS:
            with self.subTest(skill=skill):
                path = self.package / "skills" / skill / "SKILL.md"
                original = path.read_bytes()
                text = original.decode("utf-8")
                changed, count = re.subn(r"(?m)^name:.*$", "name: unrelated-skill", text, count=1)
                self.assertEqual(count, 1)
                path.write_text(changed, encoding="utf-8")
                try:
                    self.require_rejected(f"{skill} Skill name must be {skill}")
                finally:
                    path.write_bytes(original)

    def test_empty_description_is_rejected(self):
        for skill in BUNDLED_SKILLS:
            with self.subTest(skill=skill):
                path = self.package / "skills" / skill / "SKILL.md"
                original = path.read_bytes()
                text, count = re.subn(r"(?m)^description:.*$", 'description: ""',
                                     original.decode("utf-8"), count=1)
                self.assertEqual(count, 1)
                path.write_text(text, encoding="utf-8")
                try:
                    self.require_rejected(f"{skill} Skill description must be a nonempty")
                finally:
                    path.write_bytes(original)

    def test_manifest_must_expose_bundled_skills(self):
        path = self.package / ".codex-plugin/plugin.json"
        manifest = json.loads(path.read_text(encoding="utf-8-sig"))
        manifest["skills"] = "./missing-skills/"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        self.require_rejected("plugin-skills" if OPTIONS.engine == "powershell" else "Plugin skills must expose")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *UNITTEST_ARGS], verbosity=2)
