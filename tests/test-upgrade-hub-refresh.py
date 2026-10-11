"""Local lifecycle and actual engine CAS tests; never call native chat APIs."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("memory_fixture", ROOT / "tests/test-project-memory.py")
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)
memory = fixture_module.memory


class UpgradeHubRefreshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fixture = fixture_module.ProjectFixture(Path(self.temp.name))
        self.project = memory.Project(str(self.fixture.root))
        self.request = str(uuid.uuid4())
        self.claim = str(uuid.uuid4())
        self.executor = str(uuid.uuid4())
        self.new = str(uuid.uuid4())
        self.token = self.engine("hub-read")["registryToken"]
        self.before = (self.fixture.plan.read_bytes(), self.fixture.state.read_bytes())

    def engine(self, command, *args, fail=False):
        result = subprocess.run(["sh", str(ROOT / "scripts/project-flow.sh"), command,
                                 "--target", str(self.fixture.root), "--project-id",
                                 self.fixture.project_id, *args], capture_output=True, text=True)
        if fail:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            return result
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def begin(self, request=None):
        return memory.upgrade_hub_begin(self.project, self.fixture.project_id,
                                       request or self.request, self.claim, self.executor,
                                       self.fixture.hub_id, self.token, "0.14.0")

    def bind(self, intent, *, real=None, client=None):
        return memory.upgrade_hub_bind(self.project, intent["creationToken"],
                                       thread_id=real, client_thread_id=client)

    def stage(self, intent, stage):
        return memory.upgrade_hub_stage(self.project, intent["creationToken"], stage, True)

    def prepare(self, intent, *, token=None, fail=False):
        return self.engine("hub-replacement-prepare", "--owner-id", intent["ownerId"],
                           "--expected-hub-thread-id", self.fixture.hub_id,
                           "--expected-registry-token", token or self.token,
                           "--new-hub-thread-id", self.new, "--hub-title", "项目中枢 · 测试",
                           "--confirmed-old-hub-inactive", fail=fail)

    def commit(self, intent):
        self.prepare(intent)
        self.engine("hub-replacement-commit", "--owner-id", intent["ownerId"])

    def release(self, intent):
        self.engine("bootstrap-lock-release", "--owner-id", intent["ownerId"],
                    "--confirmed-replacement-retired")

    def test_unknown_create_never_recreates_and_other_request_is_blocked(self):
        intent = self.begin()
        path = self.fixture.root / ".project-flow/upgrade-hub.json"
        before = path.read_bytes()
        self.assertEqual(intent["action"], "create")
        repeated = self.begin()
        self.assertEqual(repeated["action"], "recover")
        self.assertEqual(repeated["creationToken"], intent["creationToken"])
        self.assertEqual(path.read_bytes(), before)
        with self.assertRaises(memory.MemoryError):
            self.begin(str(uuid.uuid4()))
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(self.before, (self.fixture.plan.read_bytes(), self.fixture.state.read_bytes()))

    def test_queue_resolves_exact_identity_and_duplicate_bind_is_rejected(self):
        intent = self.begin()
        client = str(uuid.uuid4())
        self.assertEqual(self.bind(intent, client=client)["state"], "queued")
        with self.assertRaises(memory.MemoryError):
            self.bind(intent, real=self.new)
        with self.assertRaises(memory.MemoryError):
            memory.upgrade_hub_bind(self.project, intent["creationToken"], thread_id=self.new,
                                    client_thread_id=str(uuid.uuid4()), resolve=True)
        resolved = memory.upgrade_hub_bind(self.project, intent["creationToken"],
                                          thread_id=self.new, client_thread_id=client, resolve=True)
        self.assertEqual(resolved["state"], "bound")
        repeated = memory.upgrade_hub_bind(self.project, intent["creationToken"],
                                          thread_id=self.new, client_thread_id=client, resolve=True)
        self.assertEqual(repeated["action"], "reuse")
        with self.assertRaises(memory.MemoryError):
            self.bind(intent, real=str(uuid.uuid4()))

    def test_actual_engine_cas_gap_recovers_and_complete_requires_lock_release(self):
        intent = self.begin()
        self.bind(intent, real=self.new)
        self.commit(intent)
        # Crash window: registry new, helper still bound. Resume reads; never re-begins.
        self.assertEqual(memory._refresh_read(self.project)["state"], "bound")
        self.assertEqual(self.engine("hub-read")["threadId"], self.new)
        self.assertEqual(self.stage(intent, "committed")["state"], "committed")
        self.stage(intent, "retired")
        with self.assertRaises(memory.MemoryError):
            self.stage(intent, "complete")
        self.release(intent)
        self.assertEqual(self.stage(intent, "complete")["state"], "complete")
        self.assertEqual(self.begin()["action"], "reuse")
        self.assertEqual(self.before, (self.fixture.plan.read_bytes(), self.fixture.state.read_bytes()))

    def test_wrong_cas_token_has_zero_registry_writes_then_same_intent_recovers(self):
        intent = self.begin()
        self.bind(intent, real=self.new)
        registry = self.fixture.root / ".project-flow/hub.json"
        original = registry.read_bytes()
        self.prepare(intent, token="sha256:" + "0" * 64, fail=True)
        self.assertEqual(registry.read_bytes(), original)
        self.assertFalse((self.fixture.root / ".project-flow/bootstrap.lock").exists())
        self.assertEqual(memory._refresh_read(self.project)["creationToken"], intent["creationToken"])
        self.commit(intent)
        self.assertEqual(self.stage(intent, "committed")["state"], "committed")

    def test_planning_identity_preserved_and_complete_rejects_unrebound_planning(self):
        planning = memory.planning_begin(self.project, self.fixture.project_id, self.fixture.hub_id)
        planning_real = str(uuid.uuid4())
        memory.planning_bind(self.project, planning["creationToken"],
                             thread_id=planning_real, client_thread_id=None)
        identity = memory._planning_identity(self.project)
        intent = self.begin()
        self.bind(intent, real=self.new)
        self.commit(intent)
        self.stage(intent, "committed")
        self.stage(intent, "retired")
        self.release(intent)
        with self.assertRaises(memory.MemoryError):
            self.stage(intent, "complete")
        memory.planning_rebind(self.project, planning["creationToken"], self.fixture.hub_id, self.new)
        self.assertEqual(self.stage(intent, "complete")["state"], "complete")
        self.assertEqual(memory._planning_identity(self.project), identity)
        self.assertEqual(self.before, (self.fixture.plan.read_bytes(), self.fixture.state.read_bytes()))

    def test_wrong_identity_and_premature_stage_have_zero_intent_writes(self):
        intent = self.begin()
        path = self.fixture.root / ".project-flow/upgrade-hub.json"
        before = path.read_bytes()
        for real in (self.fixture.hub_id, self.executor):
            with self.assertRaises(memory.MemoryError):
                self.bind(intent, real=real)
        with self.assertRaises(memory.MemoryError):
            self.stage(intent, "complete")
        self.assertEqual(path.read_bytes(), before)
        self.bind(intent, real=self.new)
        with self.assertRaises(memory.MemoryError):
            self.stage(intent, "committed")


if __name__ == "__main__":
    unittest.main()
