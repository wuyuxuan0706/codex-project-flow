#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
temp_base=${TMPDIR:-/tmp}
test_root=$(mktemp -d "$temp_base/codex-project-flow.XXXXXX")
python_cmd=${PYTHON:-python3}

cleanup() {
    case "$test_root" in
        "$temp_base"/codex-project-flow.*) rm -rf "$test_root" ;;
        *) echo "Refusing to remove unexpected test path: $test_root" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

empty_target="$test_root/empty-project"
existing_target="$test_root/existing-project"
legacy_target="$test_root/legacy-project"
versioned_target="$test_root/versioned-project"
upgrade_target="$test_root/upgrade-project"
conflict_target="$test_root/conflict-project"
noop_invalid_target="$test_root/noop-invalid-project"
control_target="$test_root/control-project"
link_target="$test_root/link-project"
outside_target="$test_root/outside-project"
midwrite_target="$test_root/midwrite-project"
plugin_link_target="$test_root/plugin-link-project"
fake_handoff_target="$test_root/fake-handoff-project"
special_project_name='Quote "value" Backslash \ Ampersand & Pipe |'
mkdir -p \
    "$empty_target" \
    "$existing_target" \
    "$legacy_target" \
    "$versioned_target" \
    "$upgrade_target" \
    "$conflict_target" \
    "$noop_invalid_target" \
    "$control_target" \
    "$link_target" \
    "$midwrite_target" \
    "$plugin_link_target" \
    "$fake_handoff_target" \
    "$outside_target"

assert_manifest_contract() {
    manifest_target=$1
    manifest_project_name=$2
    "$python_cmd" - "$repo_root" "$manifest_target/.project-flow/manifest.json" "$manifest_project_name" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys

repo = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
project_name = sys.argv[3]

def load_json(path):
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)

def normalized_text(path):
    data = path.read_bytes()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    return data.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")

managed = load_json(repo / "managed-files.json")
manifest = load_json(manifest_path)
assert managed["workflow_version"] == "0.3.1"
assert manifest["schema_version"] == 1
assert manifest["workflow_version"] == managed["workflow_version"]
assert manifest["project_name"] == project_name
assert isinstance(manifest.get("installed_at_utc"), str) and manifest["installed_at_utc"]
assert "last_transaction" in manifest
last_transaction = manifest.get("last_transaction")
assert last_transaction is None or (
    isinstance(last_transaction, str) and
    re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", last_transaction)
)

expected = [(item["path"], item["source"], item["policy"]) for item in managed["files"]]
actual = [(item["path"], item["source"], item["policy"]) for item in manifest["files"]]
assert actual == expected, (actual, expected)
assert len({item["path"] for item in manifest["files"]}) == len(expected)
assert ".agents/prompts/09_execution_handoff.md" in {item["path"] for item in manifest["files"]}

for managed_item, manifest_item in zip(managed["files"], manifest["files"]):
    text = normalized_text(repo / managed_item["source"])
    if managed_item["render"] == "project_name_json":
        text = text.replace('"<PROJECT_NAME>"', json.dumps(project_name, ensure_ascii=False))
    else:
        text = text.replace("<PROJECT_NAME>", project_name)
    expected_hash = "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()
    assert re.fullmatch(r"sha256:[0-9a-f]{64}", manifest_item["baseline_hash"])
    assert manifest_item["baseline_hash"] == expected_hash
PY
}

create_legacy_fixture() {
    fixture_target=$1
    fixture_project_name=$2
    "$python_cmd" - "$repo_root/baselines/0.2.0" "$fixture_target" "$fixture_project_name" <<'PY'
import json
from pathlib import Path
import sys

baseline = Path(sys.argv[1])
target = Path(sys.argv[2])
project_name = sys.argv[3]
for source in sorted(baseline.rglob("*")):
    if not source.is_file():
        continue
    relative = source.relative_to(baseline)
    destination = target / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    text = source.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
    if relative.as_posix() == ".agents/workflow.json":
        text = text.replace('"<PROJECT_NAME>"', json.dumps(project_name, ensure_ascii=False))
    else:
        text = text.replace("<PROJECT_NAME>", project_name)
    destination.write_text(text, encoding="utf-8", newline="")
PY
}

create_versioned_fixture() {
    fixture_target=$1
    fixture_project_name=$2
    "$python_cmd" - "$repo_root" "$fixture_target" "$fixture_project_name" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

repo = Path(sys.argv[1])
target = Path(sys.argv[2])
project_name = sys.argv[3]
managed = json.loads((repo / "managed-files.json").read_text(encoding="utf-8-sig"))
files = []
for item in managed["files"]:
    relative = Path(item["path"])
    source = repo / "baselines/0.3.0" / relative
    destination = target / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    text = source.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
    if item["render"] == "project_name_json":
        text = text.replace('"<PROJECT_NAME>"', json.dumps(project_name, ensure_ascii=False))
    else:
        text = text.replace("<PROJECT_NAME>", project_name)
    destination.write_text(text, encoding="utf-8", newline="")
    files.append({
        "path": item["path"],
        "source": item["source"],
        "policy": item["policy"],
        "baseline_hash": "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest(),
    })
manifest = {
    "schema_version": 1,
    "workflow_version": "0.3.0",
    "project_name": project_name,
    "installed_at_utc": "2026-08-22T00:00:00Z",
    "last_transaction": None,
    "files": files,
}
manifest_path = target / ".project-flow/manifest.json"
manifest_path.parent.mkdir(parents=True, exist_ok=True)
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="")
PY
}

digest_deployed_tree() {
    digest_root=$1
    find "$digest_root" -type f \
        ! -path "$digest_root/.project-flow/*" \
        ! -path "$digest_root/.project-flow-backup/*" -print |
        sort |
        while IFS= read -r file; do
            relative=${file#"$digest_root/"}
            set -- $(cksum "$file")
            printf '%s=%s:%s\n' "$relative" "$1" "$2"
        done
}

ALLOW_PLACEHOLDERS=1 sh "$repo_root/scripts/validate.sh" "$repo_root"

plugin_manifest="$repo_root/.codex-plugin/plugin.json"
bootstrap_skill="$repo_root/skills/bootstrap-project-flow/SKILL.md"
bootstrap_openai_yaml="$repo_root/skills/bootstrap-project-flow/agents/openai.yaml"
for plugin_file in "$plugin_manifest" "$bootstrap_skill" "$bootstrap_openai_yaml"; do
    [ -f "$plugin_file" ] || {
        echo "Plugin packaging file is missing: $plugin_file" >&2
        exit 1
    }
done

contract_text=$(cat \
    "$repo_root/AGENTS.md" \
    "$repo_root/.agents/workflow.json" \
    "$repo_root/.agents/prompts/00_project_hub.md" \
    "$repo_root/.agents/snippets/AGENTS.integration.md" \
    "$repo_root/docs/DEVELOPMENT_SOP.md" \
    "$repo_root/docs/WORKFLOW_GUIDE.md" \
    "$repo_root/README.md" \
    "$repo_root/skills/bootstrap-project-flow/SKILL.md")
printf '%s\n' "$contract_text" | grep -Eq '默认最多(保留|维护)?一个|at most one active|在当前(中枢任务|会话)继续' && {
    echo "Workflow surfaces retain a conflicting project-hub rule." >&2
    exit 1
}
for required_rule in '五个' '禁止回退' '隐藏子代理' '无冲突' '授权创建'; do
    printf '%s\n' "$contract_text" | grep -Fq "$required_rule" || {
        echo "Workflow surfaces are missing a fail-closed rule: $required_rule" >&2
        exit 1
    }
done

base_version=$(sed -n '1{s/[[:space:]]*$//;p;}' "$repo_root/VERSION")
plugin_name=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$plugin_manifest" | head -n 1)
[ "$plugin_name" = "codex-project-flow" ] || {
    echo "Plugin manifest name is inconsistent with the repository." >&2
    exit 1
}
plugin_version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$plugin_manifest" | head -n 1)
if [ "$plugin_version" != "$base_version" ]; then
    build_version=${plugin_version#"$base_version"+}
    if [ "$build_version" = "$plugin_version" ] ||
        ! printf '%s\n' "$build_version" | grep -Eq '^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$'; then
        echo "Plugin manifest version does not use VERSION as its base version." >&2
        exit 1
    fi
fi
plugin_skills=$(sed -n 's/^[[:space:]]*"skills"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$plugin_manifest" | head -n 1)
[ "$plugin_skills" = "./skills/" ] || {
    echo "Plugin manifest skills path is not ./skills/." >&2
    exit 1
}

grep -Eq '^name:[[:space:]]*bootstrap-project-flow[[:space:]]*$' "$bootstrap_skill" || {
    echo "Bootstrap Skill name is inconsistent with its directory." >&2
    exit 1
}
bootstrap_description=$(sed -n '2,/^---[[:space:]]*$/ { s/^description:[[:space:]]*//p; }' "$bootstrap_skill" | head -n 1)
printf '%s\n' "$bootstrap_description" | grep -Eiq '(install|import)' &&
    printf '%s\n' "$bootstrap_description" | grep -Eiq '(claim|adopt|make)' &&
    printf '%s\n' "$bootstrap_description" | grep -Eiq 'user-visible.*project hub' || {
        echo "Bootstrap Skill description does not cover import and current-task project hub adoption." >&2
        exit 1
    }
grep -Fq 'set_thread_pinned' "$bootstrap_skill" || {
    echo "Bootstrap Skill does not call set_thread_pinned for the permanent project hub." >&2
    exit 1
}
grep -Eiq '(pinned[^[:alnum:]_[:space:]:=]?[[:space:]]*[:=][[:space:]]*\$?true|-pinned[[:space:]]+\$?true)' "$bootstrap_skill" || {
    echo "Bootstrap Skill does not explicitly set pinned to true." >&2
    exit 1
}
bootstrap_skill_flat=$(tr '\n' ' ' < "$bootstrap_skill")
for tool_name in read_thread set_thread_archived; do
    printf '%s\n' "$bootstrap_skill_flat" |
        grep -Eiq "(call|use).{0,30}$tool_name" || {
        echo "Bootstrap Skill does not use $tool_name for project hub recovery." >&2
        exit 1
    }
done
grep -Eiq '(archived[^[:alnum:]_[:space:]:=]?[[:space:]]*[:=][[:space:]]*\$?false|-archived[[:space:]]+\$?false)' "$bootstrap_skill" || {
    echo "Bootstrap Skill does not explicitly set archived to false." >&2
    exit 1
}
grep -Eiq '(^|[^[:alnum:]_])hubKey([^[:alnum:]_]|$)' "$bootstrap_skill" || {
    echo "Bootstrap Skill does not define the stable hubKey identifier." >&2
    exit 1
}
printf '%s\n' "$bootstrap_skill_flat" |
    grep -Eiq '\[codex-project-flow:hub:v1\].{0,160}projectId[[:space:]]*=.{1,120};[[:space:]]*hubTitle[[:space:]]*=' || {
        echo "Bootstrap Skill hubKey does not include the v1 prefix, projectId, and hubTitle." >&2
        exit 1
    }
printf '%s\n' "$bootstrap_skill_flat" |
    grep -Eiq '((full|complete).{0,30}hubKey.{0,120}(exact|verbatim)|(exact|verbatim).{0,120}(full|complete).{0,30}hubKey)' || {
        echo "Bootstrap Skill does not compare the complete hubKey exactly during recovery." >&2
        exit 1
    }
printf '%s\n' "$bootstrap_skill_flat" |
    grep -Eiq '\[codex-project-flow:hub-claim:v1\].{0,180}projectId[[:space:]]*=.{1,160};[[:space:]]*hubTitle[[:space:]]*=' || {
        echo "Bootstrap Skill does not define the interrupted current-task claim identity." >&2
        exit 1
    }
grep -Fq 'separateHubMode' "$bootstrap_skill" || {
    echo "Bootstrap Skill does not preserve the explicit separate-hub compatibility mode." >&2
    exit 1
}
grep -Eiq '(omit|omitted).{0,40}threadId|threadId.{0,40}(omit|omitted)' "$bootstrap_skill" || {
    echo "Bootstrap Skill does not describe the implicit current-task title operation." >&2
    exit 1
}
grep -Eiq 'exhaust(ive|ively|ion)|prove exhaustion' "$bootstrap_skill" &&
    grep -Eiq '(reaches|reached).{0,60}(requested )?limit.{0,100}stop|stop.{0,100}(reaches|reached).{0,60}(requested )?limit' "$bootstrap_skill" || {
        echo "Bootstrap Skill does not require exhaustive task discovery before claiming a hub." >&2
        exit 1
    }
grep -Eiq 'never call `?create_thread`?.{0,120}(failed|ambiguous)|failed.{0,120}never call `?create_thread`?' "$bootstrap_skill" || {
    echo "Bootstrap Skill does not forbid silent create_thread fallback after claim failure." >&2
    exit 1
}
grep -Eiq '(queued|clientThreadId).*(do not|never|not to).*(call[[:space:]]+)?[^[:alnum:]_[:space:]]?create_thread[^[:alnum:]_[:space:]]?[[:space:]]+again' "$bootstrap_skill" || {
        echo "Bootstrap Skill queued handling does not forbid another create_thread call." >&2
        exit 1
    }
grep -Eiq '(queued|clientThreadId).*(do not|never|not to).*(immediate(ly)?[[:space:]]+(re-?run|retry)|(re-?run|retry).{0,40}immediate)' "$bootstrap_skill" || {
        echo "Bootstrap Skill queued handling does not forbid an immediate rerun or retry." >&2
        exit 1
    }
bootstrap_default_prompt=$(sed -n 's/^[[:space:]][[:space:]]*default_prompt:[[:space:]]*//p' "$bootstrap_openai_yaml" | head -n 1)
printf '%s\n' "$bootstrap_default_prompt" | grep -Fq '$bootstrap-project-flow' || {
    echo 'Bootstrap openai.yaml default_prompt does not reference $bootstrap-project-flow.' >&2
    exit 1
}
printf '%s\n' "$bootstrap_default_prompt" | grep -Eiq '(claim|adopt).{0,80}(this|current).{0,40}(task|hub)|(this|current).{0,40}task.{0,80}(claim|adopt)' || {
    echo "Bootstrap openai.yaml default_prompt does not make current-task hub adoption the default." >&2
    exit 1
}

state_template="$repo_root/templates/PROJECT_STATE.md"
source_state="$repo_root/docs/PROJECT_STATE.md"
[ -f "$state_template" ] || {
    echo "Project-state installation template is missing." >&2
    exit 1
}
if cmp -s "$state_template" "$source_state"; then
    echo "Repository project state must remain distinct from the blank installation template." >&2
    exit 1
fi

sh "$repo_root/scripts/install.sh" "$empty_target" "$special_project_name"
assert_manifest_contract "$empty_target" "$special_project_name" || {
    echo "Clean installation did not create a valid 0.3 manifest with the exact managed paths." >&2
    exit 1
}

installed_state="$empty_target/docs/PROJECT_STATE.md"
cmp -s "$installed_state" "$state_template" || {
    echo "Installer did not source docs/PROJECT_STATE.md from the blank installation template." >&2
    exit 1
}
if cmp -s "$installed_state" "$source_state"; then
    echo "Installer copied the repository's live project state into the target project." >&2
    exit 1
fi

for plugin_only_path in .codex-plugin skills; do
    [ ! -e "$empty_target/$plugin_only_path" ] || {
        echo "Installer copied plugin-only path into the target project: $plugin_only_path" >&2
        exit 1
    }
done
sh "$repo_root/scripts/validate.sh" "$empty_target" || {
    echo "Installed-project validation incorrectly required plugin packaging files." >&2
    exit 1
}
[ -f "$empty_target/.agents/prompts/09_execution_handoff.md" ] || {
    echo "Installer did not copy the execution-task handoff prompt." >&2
    exit 1
}
rotation_key_format='[codex-project-flow:execution:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>'
for rotation_identity_file in \
    "$empty_target/.agents/workflow.json" \
    "$empty_target/.agents/prompts/00_project_hub.md" \
    "$empty_target/.agents/prompts/09_execution_handoff.md"
do
    grep -Fq "$rotation_key_format" "$rotation_identity_file" || {
        echo "Execution-task rotation identity is missing from $rotation_identity_file" >&2
        exit 1
    }
done

valid_hub_prompt=$(cat "$empty_target/.agents/prompts/00_project_hub.md")
cp "$repo_root/baselines/0.2.0/.agents/prompts/00_project_hub.md" \
    "$empty_target/.agents/prompts/00_project_hub.md"
printf '\n[codex-project-flow:execution:v1] manually merged rotation identity\n' >> \
    "$empty_target/.agents/prompts/00_project_hub.md"
if sh "$repo_root/scripts/validate.sh" "$empty_target" >/dev/null 2>&1; then
    echo "Validator accepted a legacy hub prompt with only a fake rotation marker." >&2
    exit 1
fi
printf '%s\n' "$valid_hub_prompt" > "$empty_target/.agents/prompts/00_project_hub.md"

grep -Fq '"name": "Quote \"value\" Backslash \\ Ampersand & Pipe |"' "$empty_target/.agents/workflow.json" || {
    echo "JSON project name rendering failed for special characters." >&2
    exit 1
}
grep -Fq "$special_project_name" "$empty_target/AGENTS.md" || {
    echo "Plain-text project name rendering failed." >&2
    exit 1
}
if grep -R -q '<PROJECT_NAME>' "$empty_target/AGENTS.md" "$empty_target/.agents" "$empty_target/docs"; then
    echo "Installed project still contains <PROJECT_NAME>." >&2
    exit 1
fi

valid_config=$(cat "$empty_target/.agents/workflow.json")
for invalid_root in null false 0 '[]'; do
    printf '%s\n' "$invalid_root" > "$empty_target/.agents/workflow.json"
    if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
        echo "Validator accepted non-object JSON root: $invalid_root" >&2
        exit 1
    fi
done
printf '[%s]\n' "$valid_config" > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted an array containing an otherwise valid configuration object." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"name": .*/"name": "   "/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted a whitespace-only project.name." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"acceptance_criteria"/"acceptance_criteria", 42/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted a non-string return_to_work_on_change entry." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"user_requested"/"user_requested", false/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted a non-string handoff_policy.only_when entry." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"max_active_tasks_applies_to": "subsequent_user_visible_execution_tasks"/"max_active_tasks_applies_to": "all_user_visible_tasks"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted an incorrect max_active_tasks_applies_to." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"max_active_tasks": 5/"max_active_tasks": 1/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted max_active_tasks set to 1." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"blocked_waiting_or_queued_occupies_slot": true/"blocked_waiting_or_queued_occupies_slot": false/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted queued tasks not occupying a slot." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"execution_task_requirement": "user_visible_active_task_required"/"execution_task_requirement": "hub_execution_allowed"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted a missing user-visible execution-task requirement." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"selected_item_authorization": "authorize_creation_of_corresponding_execution_task"/"selected_item_authorization": "authorize_hub_execution"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted selection authorizing hub execution." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"task_management_failure": "stop_and_report_no_hub_fallback"/"task_management_failure": "continue_in_hub"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted task-management failure allowing hub fallback." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"hidden_subagents": "must_not_substitute_user_visible_execution_tasks"/"hidden_subagents": "may_substitute"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted hidden subagents substituting for user-visible tasks." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"project_hub_role": "analyze_clarify_design_number_create_wait_coordinate_and_summarize_only"/"project_hub_role": "execute"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted a project hub allowed to execute." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"project_hub_execution_fallback": "forbidden"/"project_hub_execution_fallback": "allowed"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted project-hub execution fallback." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"non_conflicting_operations": "parallel_allowed"/"non_conflicting_operations": "serial"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted serial-only non-conflicting operations." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"project_hub_task_lifecycle": "persistent"/"project_hub_task_lifecycle": "ephemeral"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted an incorrect project_hub_task_lifecycle." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"project_hub_occupies_active_task_slot": false/"project_hub_occupies_active_task_slot": true/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted project_hub_occupies_active_task_slot set to true." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"task_rotation": "separate"/"task_rotation": "combined"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted task_rotation without separate authorization." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"review_after_substantive_turns": 6/"review_after_substantive_turns": 5/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted an incorrect execution-task rotation review threshold." >&2
    exit 1
fi
printf '%s\n' "$valid_config" |
    sed 's/"archive_predecessor"/"create_second_active_task"/' > "$empty_target/.agents/workflow.json"
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted a rotation state machine without archive_predecessor." >&2
    exit 1
fi
printf '%s\n' "$valid_config" > "$empty_target/.agents/workflow.json"
"$python_cmd" - "$empty_target/.agents/workflow.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
states = data["task_policy"]["rotation"]["state_machine"]
states[2], states[3] = states[3], states[2]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
if sh "$repo_root/scripts/validate.sh" "$empty_target"; then
    echo "Validator accepted a reordered execution-task rotation state machine." >&2
    exit 1
fi
printf '%s\n' "$valid_config" > "$empty_target/.agents/workflow.json"

digest_tree() {
    root=$1
    find "$root" -type f ! -path '*/.project-flow-backup/*' -print |
        sort |
        while IFS= read -r file; do
            relative=${file#"$root/"}
            set -- $(cksum "$file")
            printf '%s=%s:%s\n' "$relative" "$1" "$2"
        done
}

first_digest=$(digest_tree "$empty_target")
sh "$repo_root/scripts/install.sh" "$empty_target" "$special_project_name"
second_digest=$(digest_tree "$empty_target")
[ "$first_digest" = "$second_digest" ] || {
    echo "Installation is not idempotent." >&2
    exit 1
}

control_project_name=$(printf 'Bad\tName')
if sh "$repo_root/scripts/install.sh" "$control_target" "$control_project_name"; then
    echo "Installer accepted a project name containing a control character." >&2
    exit 1
fi
if find "$control_target" -mindepth 1 -print -quit | grep -q .; then
    echo "Installer wrote files before rejecting a control-character project name." >&2
    exit 1
fi
control_project_name='Bad
Name'
if sh "$repo_root/scripts/install.sh" "$control_target" "$control_project_name"; then
    echo "Installer accepted a project name containing a line feed." >&2
    exit 1
fi
if find "$control_target" -mindepth 1 -print -quit | grep -q .; then
    echo "Installer wrote files before rejecting a line-feed project name." >&2
    exit 1
fi

printf '# Original project rules\n' > "$midwrite_target/AGENTS.md"
mkdir -p "$midwrite_target/.agents"
chmod 500 "$midwrite_target/.agents"
if [ -w "$midwrite_target/.agents" ]; then
    chmod 700 "$midwrite_target/.agents"
    echo "SKIP  mid-install permission failure subtest (chmod does not block writes)"
else
    midwrite_status=0
    sh "$repo_root/scripts/install.sh" --target "$midwrite_target" --project-name "Midwrite Project" --force >/dev/null 2>&1 ||
        midwrite_status=$?
    chmod 700 "$midwrite_target/.agents"
    [ "$midwrite_status" -ne 0 ] || {
        echo "Installer unexpectedly succeeded when a later managed-file write was blocked." >&2
        exit 1
    }
    [ "$(cat "$midwrite_target/AGENTS.md")" = '# Original project rules' ] &&
        [ ! -e "$midwrite_target/.agents/workflow.json" ] &&
        [ ! -e "$midwrite_target/.project-flow/manifest.json" ] || {
            echo "Installer did not roll back files written before a mid-install failure." >&2
            exit 1
        }
fi

if ln -s "$outside_target" "$link_target/.agents" 2>/dev/null &&
    [ -L "$link_target/.agents" ]; then
    if sh "$repo_root/scripts/install.sh" "$link_target" "Linked Project"; then
        echo "Installer accepted a target containing a symbolic link." >&2
        exit 1
    fi
    if find "$outside_target" -mindepth 1 -print -quit | grep -q .; then
        echo "Installer wrote template files through a symbolic link." >&2
        exit 1
    fi
    rm "$link_target/.agents"
else
    rm -rf "$link_target/.agents"
    echo "SKIP  symbolic-link safety subtest (link creation unavailable)"
fi

if ln -s "$outside_target" "$link_target/.project-flow-backup" 2>/dev/null &&
    [ -L "$link_target/.project-flow-backup" ]; then
    if sh "$repo_root/scripts/install.sh" "$link_target" "Backup Link Project"; then
        echo "Installer accepted a symbolic link at .project-flow-backup." >&2
        exit 1
    fi
    if find "$outside_target" -mindepth 1 -print -quit | grep -q .; then
        echo "Installer wrote backup or template files through a symbolic link." >&2
        exit 1
    fi
    rm "$link_target/.project-flow-backup"
else
    rm -rf "$link_target/.project-flow-backup"
    echo "SKIP  backup symbolic-link subtest (link creation unavailable)"
fi

printf '# Existing project rules\n' > "$existing_target/AGENTS.md"
sh "$repo_root/scripts/install.sh" "$existing_target" "Existing Project"
[ "$(cat "$existing_target/AGENTS.md")" = "# Existing project rules" ] || {
    echo "Default install overwrote AGENTS.md." >&2
    exit 1
}
[ -f "$existing_target/.agents/snippets/AGENTS.integration.md" ] || {
    echo "Integration snippet was not installed." >&2
    exit 1
}

sh "$repo_root/scripts/install.sh" "$existing_target" "Existing Project" --force
backup=$(find "$existing_target/.project-flow-backup" -type f -name AGENTS.md -print | head -n 1)
[ -n "$backup" ] && grep -q '^# Existing project rules$' "$backup" || {
    echo "Forced install did not preserve the existing AGENTS.md." >&2
    exit 1
}
printf '\nlocal reset candidate\n' >> "$existing_target/AGENTS.md"
"$python_cmd" - "$existing_target/.project-flow/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["workflow_version"] = "9.9.9"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
sh "$repo_root/scripts/install.sh" "$existing_target" "Existing Project" --force
assert_manifest_contract "$existing_target" "Existing Project" || {
    echo "Forced reset did not replace a stale manifest with a valid current manifest." >&2
    exit 1
}
grep -R -q 'local reset candidate' "$existing_target/.project-flow-backup" || {
    echo "Forced reset did not back up the customized live file." >&2
    exit 1
}
grep -R -q '"workflow_version": "9.9.9"' "$existing_target/.project-flow-backup" || {
    echo "Forced reset did not back up the stale manifest." >&2
    exit 1
}

mkdir -p "$legacy_target/.agents/prompts"
printf '# Legacy prompt\n' > "$legacy_target/.agents/prompts/01_start_project.md"
sh "$repo_root/scripts/install.sh" "$legacy_target" "Legacy Project"
[ -f "$legacy_target/.agents/prompts/01_start_project.md" ] || {
    echo "Installer destructively removed a legacy prompt." >&2
    exit 1
}

sh "$repo_root/scripts/install.sh" "$noop_invalid_target" "Invalid NOOP Project"
"$python_cmd" - "$noop_invalid_target/.project-flow/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["files"][0]["policy"] = "seed_once"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
invalid_noop_status=0
sh "$repo_root/scripts/upgrade.sh" --target "$noop_invalid_target" --apply >/dev/null 2>&1 || invalid_noop_status=$?
[ "$invalid_noop_status" -ne 0 ] || {
    echo "Upgrade reported NOOP for a manifest with an invalid source/policy contract." >&2
    exit 1
}
[ ! -d "$noop_invalid_target/.project-flow/transactions" ] || {
    echo "Rejected invalid NOOP unexpectedly created a transaction." >&2
    exit 1
}

versioned_project_name="Versioned Upgrade Project"
create_versioned_fixture "$versioned_target" "$versioned_project_name"
versioned_tree_before=$(digest_deployed_tree "$versioned_target")
versioned_manifest_before=$(cksum "$versioned_target/.project-flow/manifest.json")
versioned_plan=$(sh "$repo_root/scripts/upgrade.sh" --target "$versioned_target" --plan)
printf '%s\n' "$versioned_plan" | grep -Fq 'UPGRADE 0.3.0 -> 0.3.1' || {
    echo "0.3.0 upgrade plan did not report the 0.3.1 destination." >&2
    exit 1
}
printf '%s\n' "$versioned_plan" | grep -Eq '^REPLACE[[:space:]]+structured_manual[[:space:]]+\.agents/workflow\.json$' || {
    echo "0.3.0 upgrade plan did not replace the workflow configuration." >&2
    exit 1
}
[ "$(digest_deployed_tree "$versioned_target")" = "$versioned_tree_before" ] &&
    [ "$(cksum "$versioned_target/.project-flow/manifest.json")" = "$versioned_manifest_before" ] || {
        echo "0.3.0 upgrade plan mutated the project." >&2
        exit 1
    }
versioned_apply=$(sh "$repo_root/scripts/upgrade.sh" --target "$versioned_target" --apply)
versioned_transaction=$(printf '%s\n' "$versioned_apply" | sed -n 's/^APPLIED \([A-Za-z0-9][A-Za-z0-9._-]*\)$/\1/p' | tail -n 1)
[ -n "$versioned_transaction" ] || {
    echo "0.3.0 upgrade apply did not report a transaction." >&2
    exit 1
}
assert_manifest_contract "$versioned_target" "$versioned_project_name" || {
    echo "0.3.0 upgrade did not create a valid 0.3.1 manifest." >&2
    exit 1
}
versioned_manifest_state=$("$python_cmd" -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(d["workflow_version"] + " " + d["last_transaction"])' "$versioned_target/.project-flow/manifest.json")
[ "$versioned_manifest_state" = "0.3.1 $versioned_transaction" ] || {
    echo "0.3.0 upgrade manifest metadata is incorrect." >&2
    exit 1
}
versioned_transaction_count=$(find "$versioned_target/.project-flow/transactions" -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d ' ')
versioned_noop=$(sh "$repo_root/scripts/upgrade.sh" --target "$versioned_target" --apply)
printf '%s\n' "$versioned_noop" | grep -Fq 'NOOP already up to date' || {
    echo "Second 0.3.1 apply did not report NOOP." >&2
    exit 1
}
[ "$(find "$versioned_target/.project-flow/transactions" -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d ' ')" = "$versioned_transaction_count" ] || {
    echo "Second 0.3.1 apply created an unexpected transaction." >&2
    exit 1
}
versioned_rollback=$(sh "$repo_root/scripts/upgrade.sh" --target "$versioned_target" --rollback "$versioned_transaction")
printf '%s\n' "$versioned_rollback" | grep -Fq "ROLLED_BACK $versioned_transaction" || {
    echo "0.3.0 upgrade rollback did not report success." >&2
    exit 1
}
[ "$(digest_deployed_tree "$versioned_target")" = "$versioned_tree_before" ] &&
    [ "$(cksum "$versioned_target/.project-flow/manifest.json")" = "$versioned_manifest_before" ] || {
        echo "0.3.0 upgrade rollback did not restore the original project and manifest." >&2
        exit 1
    }

legacy_project_name="Legacy Upgrade Project"
create_legacy_fixture "$upgrade_target" "$legacy_project_name"
printf '# Project state\n\nlegacy state must survive upgrade\n' > "$upgrade_target/docs/PROJECT_STATE.md"
legacy_state_before=$(cat "$upgrade_target/docs/PROJECT_STATE.md")
legacy_tree_before=$(digest_deployed_tree "$upgrade_target")

missing_adopt_status=0
missing_adopt_output=$(sh "$repo_root/scripts/upgrade.sh" --target "$upgrade_target" --plan 2>&1) || missing_adopt_status=$?
[ "$missing_adopt_status" -ne 0 ] || {
    echo "Legacy upgrade did not require explicit --adopt-from 0.2.0." >&2
    exit 1
}
[ ! -e "$upgrade_target/.project-flow/manifest.json" ] || {
    echo "Rejected legacy upgrade unexpectedly created a manifest." >&2
    exit 1
}

legacy_plan=$(sh "$repo_root/scripts/upgrade.sh" --target "$upgrade_target" --adopt-from 0.2.0 --plan)
printf '%s\n' "$legacy_plan" | grep -Fq 'UPGRADE 0.2.0 -> 0.3.1' || {
    echo "Legacy adoption plan did not report the 0.2.0 to 0.3.1 migration." >&2
    exit 1
}
printf '%s\n' "$legacy_plan" | grep -Eq '^CREATE[[:space:]]+replace_if_unmodified[[:space:]]+\.agents/prompts/09_execution_handoff\.md$' || {
    echo "Legacy adoption plan did not create the execution-task handoff prompt." >&2
    exit 1
}
printf '%s\n' "$legacy_plan" | grep -Eq '^PRESERVE[[:space:]]+seed_once[[:space:]]+docs/PROJECT_STATE\.md$' || {
    echo "Legacy adoption plan did not preserve docs/PROJECT_STATE.md." >&2
    exit 1
}
[ "$(digest_deployed_tree "$upgrade_target")" = "$legacy_tree_before" ] &&
    [ ! -e "$upgrade_target/.project-flow/manifest.json" ] || {
        echo "Legacy adoption plan mutated live files or created a manifest." >&2
        exit 1
    }

create_legacy_fixture "$fake_handoff_target" "Fake Handoff Project"
printf '%s\n' "$rotation_key_format" > \
    "$fake_handoff_target/.agents/prompts/09_execution_handoff.md"
fake_handoff_tree_before=$(digest_deployed_tree "$fake_handoff_target")
fake_handoff_status=0
sh "$repo_root/scripts/upgrade.sh" \
    --target "$fake_handoff_target" \
    --adopt-from 0.2.0 \
    --apply \
    --accept-local .agents/prompts/09_execution_handoff.md >/dev/null 2>&1 ||
    fake_handoff_status=$?
[ "$fake_handoff_status" -ne 0 ] || {
    echo "Upgrade accepted a fake local execution handoff containing only the rotation key." >&2
    exit 1
}
[ "$(digest_deployed_tree "$fake_handoff_target")" = "$fake_handoff_tree_before" ] &&
    [ ! -e "$fake_handoff_target/.project-flow/manifest.json" ] || {
        echo "Rejected fake execution handoff was not rolled back completely." >&2
        exit 1
    }

plugin_copy="$test_root/plugin-copy"
outside_baselines="$test_root/outside-baselines"
cp -R "$repo_root" "$plugin_copy"
mkdir -p "$outside_baselines/docs"
cp "$repo_root/baselines/0.2.0/docs/"*.md "$outside_baselines/docs/"
rm -rf "$plugin_copy/baselines/0.2.0/docs"
if ln -s "$outside_baselines/docs" "$plugin_copy/baselines/0.2.0/docs" 2>/dev/null &&
    [ -L "$plugin_copy/baselines/0.2.0/docs" ]; then
    create_legacy_fixture "$plugin_link_target" "Linked Baseline Project"
    linked_baseline_status=0
    sh "$plugin_copy/scripts/upgrade.sh" --target "$plugin_link_target" --adopt-from 0.2.0 --plan >/dev/null 2>&1 ||
        linked_baseline_status=$?
    [ "$linked_baseline_status" -ne 0 ] || {
        echo "Upgrade accepted an immutable baseline through a symbolic-link ancestor." >&2
        exit 1
    }
else
    echo "SKIP  baseline ancestor symbolic-link subtest (link creation unavailable)"
fi

cmp -s "$repo_root/baselines/0.2.0/.agents/prompts/00_project_hub.md" "$repo_root/.agents/prompts/00_project_hub.md" && {
    echo "Upgrade fixture cannot prove replacement because the old and new hub prompts are identical." >&2
    exit 1
}
legacy_apply=$(sh "$repo_root/scripts/upgrade.sh" --target "$upgrade_target" --adopt-from 0.2.0 --apply)
legacy_transaction=$(printf '%s\n' "$legacy_apply" | sed -n 's/^APPLIED \([A-Za-z0-9][A-Za-z0-9._-]*\)$/\1/p' | tail -n 1)
[ -n "$legacy_transaction" ] && [ -f "$upgrade_target/.project-flow/transactions/$legacy_transaction/transaction.json" ] || {
    echo "Legacy adoption apply did not report a durable transaction." >&2
    exit 1
}
cmp -s "$upgrade_target/.agents/prompts/00_project_hub.md" "$repo_root/.agents/prompts/00_project_hub.md" || {
    echo "An unchanged legacy managed file was not updated to the 0.3.1 source." >&2
    exit 1
}
cmp -s "$upgrade_target/.agents/prompts/09_execution_handoff.md" "$repo_root/.agents/prompts/09_execution_handoff.md" || {
    echo "Legacy adoption did not install the 0.3.1 execution-task handoff prompt." >&2
    exit 1
}
[ "$(cat "$upgrade_target/docs/PROJECT_STATE.md")" = "$legacy_state_before" ] || {
    echo "Legacy adoption changed docs/PROJECT_STATE.md." >&2
    exit 1
}
assert_manifest_contract "$upgrade_target" "$legacy_project_name" || {
    echo "Legacy adoption did not create a valid 0.3.1 manifest." >&2
    exit 1
}
manifest_transaction=$("$python_cmd" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["last_transaction"])' "$upgrade_target/.project-flow/manifest.json")
[ "$manifest_transaction" = "$legacy_transaction" ] || {
    echo "Legacy adoption manifest does not reference its applied transaction." >&2
    exit 1
}

transaction_count_before=$(find "$upgrade_target/.project-flow/transactions" -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d ' ')
manifest_digest_before=$(cksum "$upgrade_target/.project-flow/manifest.json")
noop_output=$(sh "$repo_root/scripts/upgrade.sh" --target "$upgrade_target" --apply)
printf '%s\n' "$noop_output" | grep -Fq 'NOOP already up to date' || {
    echo "Second upgrade apply did not report NOOP." >&2
    exit 1
}
transaction_count_after=$(find "$upgrade_target/.project-flow/transactions" -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d ' ')
[ "$transaction_count_after" = "$transaction_count_before" ] &&
    [ "$(cksum "$upgrade_target/.project-flow/manifest.json")" = "$manifest_digest_before" ] || {
        echo "NOOP apply created a transaction or changed the manifest." >&2
        exit 1
    }

rollback_output=$(sh "$repo_root/scripts/upgrade.sh" --target "$upgrade_target" --rollback "$legacy_transaction")
printf '%s\n' "$rollback_output" | grep -Fq "ROLLED_BACK $legacy_transaction" || {
    echo "Upgrade rollback did not report the restored transaction." >&2
    exit 1
}
[ "$(digest_deployed_tree "$upgrade_target")" = "$legacy_tree_before" ] || {
    echo "Rollback did not restore the complete pre-upgrade deployed state." >&2
    exit 1
}
[ ! -e "$upgrade_target/.project-flow/manifest.json" ] &&
    [ ! -e "$upgrade_target/.agents/prompts/09_execution_handoff.md" ] || {
        echo "Rollback did not restore the pre-adoption manifest and file set." >&2
        exit 1
    }

create_legacy_fixture "$conflict_target" "Conflict Upgrade Project"
printf '\nlocal project-hub customization\n' >> "$conflict_target/.agents/prompts/00_project_hub.md"
conflict_tree_before=$(digest_deployed_tree "$conflict_target")
conflict_status=0
conflict_output=$(sh "$repo_root/scripts/upgrade.sh" --target "$conflict_target" --adopt-from 0.2.0 --apply 2>&1) || conflict_status=$?
[ "$conflict_status" -eq 4 ] || {
    echo "Conflicting legacy adoption returned $conflict_status instead of 4: $conflict_output" >&2
    exit 1
}
[ "$(digest_deployed_tree "$conflict_target")" = "$conflict_tree_before" ] &&
    [ ! -e "$conflict_target/.project-flow/manifest.json" ] || {
        echo "Conflict handling changed live managed files or the manifest." >&2
        exit 1
    }
find "$conflict_target/.project-flow/staging" -type f -name plan.json -print -quit | grep -q . || {
    echo "Conflict handling did not create a reviewable staging plan." >&2
    exit 1
}

cp "$repo_root/.agents/prompts/00_project_hub.md" \
    "$conflict_target/.agents/prompts/00_project_hub.md"
printf '\nlocal project-hub customization retained after manual merge\n' >> \
    "$conflict_target/.agents/prompts/00_project_hub.md"
conflict_hub_before=$(cat "$conflict_target/.agents/prompts/00_project_hub.md")
accepted_tree_before=$(digest_deployed_tree "$conflict_target")
accepted_output=$(sh "$repo_root/scripts/upgrade.sh" \
    --target "$conflict_target" \
    --adopt-from 0.2.0 \
    --apply \
    --accept-local .agents/prompts/00_project_hub.md)
printf '%s\n' "$accepted_output" | grep -Eq '^ACCEPT[[:space:]]+replace_if_unmodified[[:space:]]+\.agents/prompts/00_project_hub\.md$' || {
    echo "Explicit local conflict acceptance was not reported in the apply plan." >&2
    exit 1
}
accepted_transaction=$(printf '%s\n' "$accepted_output" | sed -n 's/^APPLIED \([A-Za-z0-9][A-Za-z0-9._-]*\)$/\1/p' | tail -n 1)
[ -n "$accepted_transaction" ] || {
    echo "Explicit local conflict acceptance did not create a transaction." >&2
    exit 1
}
[ "$(cat "$conflict_target/.agents/prompts/00_project_hub.md")" = "$conflict_hub_before" ] || {
    echo "Explicit local conflict acceptance overwrote the reviewed live file." >&2
    exit 1
}
assert_manifest_contract "$conflict_target" "Conflict Upgrade Project" || {
    echo "Explicit local conflict acceptance did not advance to a valid 0.3.1 manifest." >&2
    exit 1
}
"$python_cmd" - "$conflict_target/.project-flow/transactions/$accepted_transaction/transaction.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["accepted_local"] == [".agents/prompts/00_project_hub.md"]
PY

sh "$repo_root/scripts/upgrade.sh" --target "$conflict_target" --rollback "$accepted_transaction" >/dev/null
[ "$(digest_deployed_tree "$conflict_target")" = "$accepted_tree_before" ] &&
    [ ! -e "$conflict_target/.project-flow/manifest.json" ] || {
        echo "Rollback after local conflict acceptance did not restore the pre-acceptance state." >&2
        exit 1
    }

echo "All POSIX shell tests passed."
