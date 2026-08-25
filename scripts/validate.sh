#!/bin/sh
set -eu

target=${1:-.}
allow_placeholders=${ALLOW_PLACEHOLDERS:-0}

[ -d "$target" ] || { echo "Target directory does not exist: $target" >&2; exit 2; }
target_root=$(CDPATH= cd -P "$target" && pwd -P)
errors=0
warnings=0

error() {
    echo "ERROR $1" >&2
    errors=$((errors + 1))
}

warn() {
    echo "WARN  $1"
    warnings=$((warnings + 1))
}

legacy_notice() {
    if [ "$allow_placeholders" -eq 1 ]; then
        error "$1"
    else
        warn "$1"
    fi
}

require_file() {
    [ -f "$target_root/$1" ] || error "Missing $1"
}

safe_relative_path() {
    case "$1" in
        ""|/*|\\*|[A-Za-z]:*|..|../*|*/../*|*/..|..\\*|*\\..\\*|*\\..)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

for required in \
    "AGENTS.md" \
    ".agents/workflow.json" \
    ".agents/prompts/00_project_hub.md" \
    ".agents/prompts/08_result_handoff.md" \
    ".agents/prompts/09_execution_handoff.md" \
    ".agents/skills/project-workflow-manager/SKILL.md" \
    ".agents/skills/project-workflow-manager/agents/openai.yaml" \
    ".agents/snippets/AGENTS.integration.md" \
    "docs/PROJECT_STATE.md" \
    "docs/DEVELOPMENT_SOP.md" \
    "docs/WORKFLOW_GUIDE.md"
do
    require_file "$required"
done
if [ "$allow_placeholders" -eq 1 ]; then
    require_file "README.md"
    require_file "VERSION"
    require_file "templates/PROJECT_STATE.md"
    require_file ".codex-plugin/plugin.json"
    require_file "managed-files.json"
    require_file "migrations/0.2.0-to-0.3.0.json"
    require_file "migrations/0.2.0-to-0.3.1.json"
    require_file "migrations/0.3.0-to-0.3.1.json"
    require_file "baselines/0.2.0/AGENTS.md"
    require_file "baselines/0.3.0/AGENTS.md"
    require_file "baselines/0.3.0/.agents/workflow.json"
    require_file "baselines/0.3.0/.agents/prompts/00_project_hub.md"
    require_file "baselines/0.3.0/.agents/prompts/08_result_handoff.md"
    require_file "baselines/0.3.0/.agents/prompts/09_execution_handoff.md"
    require_file "baselines/0.3.0/.agents/skills/project-workflow-manager/SKILL.md"
    require_file "baselines/0.3.0/.agents/skills/project-workflow-manager/agents/openai.yaml"
    require_file "baselines/0.3.0/.agents/snippets/AGENTS.integration.md"
    require_file "baselines/0.3.0/docs/DEVELOPMENT_SOP.md"
    require_file "baselines/0.3.0/docs/PROJECT_STATE.md"
    require_file "baselines/0.3.0/docs/WORKFLOW_GUIDE.md"
    require_file "scripts/upgrade.sh"
    require_file "scripts/upgrade.ps1"
    require_file "skills/bootstrap-project-flow/SKILL.md"
    require_file "skills/bootstrap-project-flow/agents/openai.yaml"
    require_file "skills/upgrade-project-flow/SKILL.md"
    require_file "skills/upgrade-project-flow/agents/openai.yaml"
    require_file "skills/upgrade-project-flow/references/upgrade-contract.md"
fi

for prefix in 00 08 09; do
    count=$(find "$target_root/.agents/prompts" -maxdepth 1 -type f -name "${prefix}_*.md" 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -eq 1 ] || error "Expected exactly one ${prefix}_*.md prompt."
done
rotation_key_format='[codex-project-flow:execution:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>'
for rotation_identity_path in \
    ".agents/workflow.json" \
    ".agents/prompts/00_project_hub.md" \
    ".agents/prompts/09_execution_handoff.md"
do
    [ ! -f "$target_root/$rotation_identity_path" ] ||
        grep -Fq "$rotation_key_format" "$target_root/$rotation_identity_path" ||
        error "Missing the complete v1 execution rotation key format in $rotation_identity_path"
done

hub_prompt="$target_root/.agents/prompts/00_project_hub.md"
if [ -f "$hub_prompt" ]; then
    for required_recovery_text in \
        'list_threads' \
        'read_thread' \
        'pinnedThreads' \
        'codexDelegation.input' \
        '无法证明穷尽' \
        '零个匹配继续等待' \
        '多个匹配停止并报告歧义'
    do
        grep -Fq "$required_recovery_text" "$hub_prompt" ||
            error "Project hub prompt is missing queued-recovery semantics: $required_recovery_text"
    done
fi

handoff_prompt="$target_root/.agents/prompts/09_execution_handoff.md"
if [ -f "$handoff_prompt" ]; then
    for required_handoff_text in \
        '当前代次与继任代次' \
        '前任任务 ID' \
        '目标、范围、不做项、环境、验收标准' \
        '已授权动作' \
        '已完成修改及实际工作区状态' \
        '历史验证' \
        '剩余步骤、已知风险与下一安全点' \
        '不可轮换' \
        '中枢确认内容完整并 ACK'
    do
        grep -Fq "$required_handoff_text" "$handoff_prompt" ||
            error "Execution handoff prompt is missing required protocol text: $required_handoff_text"
    done
fi

for legacy in \
    ".agents/skills/manage-project-workflow" \
    "docs/MODULE_INDEX.md" \
    "docs/NEXT_TASK.md" \
    "docs/RISKS.md" \
    "docs/DECISIONS.md" \
    "docs/WEEKLY_LOG.md"
do
    [ ! -e "$target_root/$legacy" ] || legacy_notice "Legacy path remains: $legacy"
done
for prefix in 01 02 03 04 05 06; do
    legacy_count=$(find "$target_root/.agents/prompts" -maxdepth 1 -type f -name "${prefix}_*.md" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$legacy_count" -gt 0 ]; then
        legacy_notice "Legacy prompt pattern remains: .agents/prompts/${prefix}_*.md ($legacy_count file(s))"
    fi
done

install_manifest="$target_root/.project-flow/manifest.json"
if [ -e "$install_manifest" ] && [ ! -f "$install_manifest" ]; then
    error ".project-flow/manifest.json exists and is not a regular file."
elif [ -f "$install_manifest" ]; then
    python_cmd=${PYTHON:-python3}
    if ! command -v "$python_cmd" >/dev/null 2>&1; then
        error "$python_cmd is required to validate .project-flow/manifest.json."
    elif ! "$python_cmd" - "$install_manifest" "$target_root/.agents/workflow.json" <<'PY'
import json
from pathlib import Path, PurePosixPath
import re
import sys

expected = {
    "AGENTS.md": ("AGENTS.md", "merge_manual"),
    ".agents/workflow.json": (".agents/workflow.json", "structured_manual"),
    ".agents/prompts/00_project_hub.md": (".agents/prompts/00_project_hub.md", "replace_if_unmodified"),
    ".agents/prompts/08_result_handoff.md": (".agents/prompts/08_result_handoff.md", "replace_if_unmodified"),
    ".agents/prompts/09_execution_handoff.md": (".agents/prompts/09_execution_handoff.md", "replace_if_unmodified"),
    ".agents/skills/project-workflow-manager/SKILL.md": (".agents/skills/project-workflow-manager/SKILL.md", "replace_if_unmodified"),
    ".agents/skills/project-workflow-manager/agents/openai.yaml": (".agents/skills/project-workflow-manager/agents/openai.yaml", "replace_if_unmodified"),
    ".agents/snippets/AGENTS.integration.md": (".agents/snippets/AGENTS.integration.md", "replace_if_unmodified"),
    "docs/DEVELOPMENT_SOP.md": ("docs/DEVELOPMENT_SOP.md", "merge_manual"),
    "docs/PROJECT_STATE.md": ("templates/PROJECT_STATE.md", "seed_once"),
    "docs/WORKFLOW_GUIDE.md": ("docs/WORKFLOW_GUIDE.md", "replace_if_unmodified"),
}

def load(path):
    data = Path(path).read_bytes()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    return json.loads(data.decode("utf-8"))

try:
    manifest = load(sys.argv[1])
    workflow = load(sys.argv[2])
    assert isinstance(manifest, dict) and manifest.get("schema_version") == 1
    assert manifest.get("workflow_version") == "0.3.1"
    name = manifest.get("project_name")
    assert isinstance(name, str) and name.strip() and not any(ord(ch) < 32 or ord(ch) == 127 for ch in name)
    assert workflow.get("project", {}).get("name") == name
    assert isinstance(manifest.get("installed_at_utc"), str) and manifest["installed_at_utc"].strip()
    transaction = manifest.get("last_transaction")
    assert transaction is None or (isinstance(transaction, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", transaction))
    files = manifest.get("files")
    assert isinstance(files, list) and len(files) == len(expected)
    observed = {}
    for item in files:
        assert isinstance(item, dict)
        path = item.get("path")
        assert isinstance(path, str) and path not in observed
        rel = PurePosixPath(path)
        assert not rel.is_absolute() and all(part not in ("", ".", "..") for part in rel.parts)
        observed[path] = (item.get("source"), item.get("policy"))
        assert isinstance(item.get("baseline_hash"), str)
        assert re.fullmatch(r"sha256:[0-9a-f]{64}", item["baseline_hash"])
    assert observed == expected
except Exception as exc:
    print("manifest contract check failed: " + str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
    then
        error ".project-flow/manifest.json does not satisfy the 0.3.1 install contract."
    fi
fi

config="$target_root/.agents/workflow.json"
json_meta=""
json_valid=0
if [ -f "$config" ]; then
    if json_meta=$(awk '
        function skip_ws() {
            while (pos <= length(text) && substr(text, pos, 1) ~ /[[:space:]]/) {
                pos++
            }
        }
        function parse_string(    c, e, hex) {
            if (substr(text, pos, 1) != "\"") {
                return 0
            }
            pos++
            string_value = ""
            while (pos <= length(text)) {
                c = substr(text, pos, 1)
                pos++
                if (c == "\"") {
                    return 1
                }
                if (c ~ /[[:cntrl:]]/) {
                    return 0
                }
                if (c != "\\") {
                    string_value = string_value c
                    continue
                }
                if (pos > length(text)) {
                    return 0
                }
                e = substr(text, pos, 1)
                pos++
                if (e == "\"" || e == "\\" || e == "/") {
                    string_value = string_value e
                } else if (e == "b") {
                    string_value = string_value sprintf("%c", 8)
                } else if (e == "f") {
                    string_value = string_value sprintf("%c", 12)
                } else if (e == "n") {
                    string_value = string_value "\n"
                } else if (e == "r") {
                    string_value = string_value "\r"
                } else if (e == "t") {
                    string_value = string_value "\t"
                } else if (e == "u") {
                    hex = substr(text, pos, 4)
                    if (length(hex) != 4 || hex !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) {
                        return 0
                    }
                    string_value = string_value "\\u" hex
                    pos += 4
                } else {
                    return 0
                }
            }
            return 0
        }
        function parse_number(    rest) {
            rest = substr(text, pos)
            if (!match(rest, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
                return 0
            }
            number_value = substr(rest, RSTART, RLENGTH)
            pos += RLENGTH
            return 1
        }
        function parse_array(context,    first, child_context) {
            pos++
            if (context == "/required_context") {
                print "REQUIRED_ARRAY"
            } else if (context == "/task_policy/return_to_work_on_change") {
                print "RETURN_ARRAY"
            } else if (context == "/handoff_policy/only_when") {
                print "HANDOFF_ARRAY"
            } else if (context == "/task_policy/rotation/additional_triggers") {
                print "ROTATION_TRIGGER_ARRAY"
            } else if (context == "/task_policy/rotation/state_machine") {
                print "ROTATION_STATE_ARRAY"
            }
            skip_ws()
            if (substr(text, pos, 1) == "]") {
                pos++
                return 1
            }
            first = 1
            while (pos <= length(text)) {
                if (!first) {
                    if (substr(text, pos, 1) != ",") {
                        return 0
                    }
                    pos++
                    skip_ws()
                }
                if (context == "/required_context" && substr(text, pos, 1) != "\"") {
                    print "REQUIRED_INVALID"
                } else if (context == "/task_policy/return_to_work_on_change" && substr(text, pos, 1) != "\"") {
                    print "RETURN_INVALID"
                } else if (context == "/handoff_policy/only_when" && substr(text, pos, 1) != "\"") {
                    print "HANDOFF_INVALID"
                } else if (context == "/task_policy/rotation/additional_triggers" && substr(text, pos, 1) != "\"") {
                    print "ROTATION_TRIGGER_INVALID"
                } else if (context == "/task_policy/rotation/state_machine" && substr(text, pos, 1) != "\"") {
                    print "ROTATION_STATE_INVALID"
                }
                if (context == "/required_context") {
                    child_context = "/required_context/item"
                } else if (context == "/task_policy/return_to_work_on_change") {
                    child_context = "/task_policy/return_to_work_on_change/item"
                } else if (context == "/handoff_policy/only_when") {
                    child_context = "/handoff_policy/only_when/item"
                } else if (context == "/task_policy/rotation/additional_triggers") {
                    child_context = "/task_policy/rotation/additional_triggers/item"
                } else if (context == "/task_policy/rotation/state_machine") {
                    child_context = "/task_policy/rotation/state_machine/item"
                } else {
                    child_context = context "/item"
                }
                if (!parse_value(child_context)) {
                    return 0
                }
                skip_ws()
                if (substr(text, pos, 1) == "]") {
                    pos++
                    return 1
                }
                first = 0
            }
            return 0
        }
        function parse_object(context,    first, key, child_context) {
            if (context == "") {
                print "ROOT_OBJECT"
            }
            pos++
            skip_ws()
            if (substr(text, pos, 1) == "}") {
                pos++
                return 1
            }
            first = 1
            while (pos <= length(text)) {
                if (!first) {
                    if (substr(text, pos, 1) != ",") {
                        return 0
                    }
                    pos++
                    skip_ws()
                }
                if (!parse_string()) {
                    return 0
                }
                key = string_value
                skip_ws()
                if (substr(text, pos, 1) != ":") {
                    return 0
                }
                pos++
                child_context = context "/" key
                if (!parse_value(child_context)) {
                    return 0
                }
                skip_ws()
                if (substr(text, pos, 1) == "}") {
                    pos++
                    return 1
                }
                first = 0
            }
            return 0
        }
        function parse_value(context,    c, literal) {
            skip_ws()
            c = substr(text, pos, 1)
            if (c == "{") {
                return parse_object(context)
            }
            if (c == "[") {
                return parse_array(context)
            }
            if (c == "\"") {
                if (!parse_string()) {
                    return 0
                }
                if (context == "/required_context/item") {
                    if (string_value ~ /[\r\n]/) {
                        print "REQUIRED_INVALID"
                    } else {
                        print "REQUIRED_PATH:" string_value
                    }
                } else if (context == "/project/name") {
                    if (string_value == "<PROJECT_NAME>") {
                        print "PROJECT:placeholder"
                    } else if (string_value ~ /^[[:space:]]*$/) {
                        print "PROJECT:empty"
                    } else {
                        print "PROJECT:value"
                    }
                } else if (context == "/paths/rules") {
                    if (string_value ~ /[\r\n]/) print "CONFIG_PATH_INVALID:rules"
                    else print "CONFIG_PATH:rules:" string_value
                } else if (context == "/paths/sop") {
                    if (string_value ~ /[\r\n]/) print "CONFIG_PATH_INVALID:sop"
                    else print "CONFIG_PATH:sop:" string_value
                } else if (context == "/paths/project_state") {
                    if (string_value ~ /[\r\n]/) print "CONFIG_PATH_INVALID:project_state"
                    else print "CONFIG_PATH:project_state:" string_value
                } else if (context == "/paths/execution_handoff") {
                    if (string_value ~ /[\r\n]/) print "CONFIG_PATH_INVALID:execution_handoff"
                    else print "CONFIG_PATH:execution_handoff:" string_value
                } else if (context == "/work/mode") {
                    print ((string_value == "read_only") ? "WORK_MODE:ok" : "WORK_MODE:other")
                } else if (context == "/task_policy/max_active_tasks_applies_to") {
                    print ((string_value == "subsequent_user_visible_execution_tasks") ? "MAX_ACTIVE_TASKS_APPLIES_TO:ok" : "MAX_ACTIVE_TASKS_APPLIES_TO:other")
                } else if (context == "/task_policy/execution_task_requirement") {
                    print ((string_value == "user_visible_active_task_required") ? "EXECUTION_TASK_REQUIREMENT:ok" : "EXECUTION_TASK_REQUIREMENT:other")
                } else if (context == "/task_policy/selected_item_authorization") {
                    print ((string_value == "authorize_creation_of_corresponding_execution_task") ? "SELECTED_ITEM_AUTHORIZATION:ok" : "SELECTED_ITEM_AUTHORIZATION:other")
                } else if (context == "/task_policy/task_management_failure") {
                    print ((string_value == "stop_and_report_no_hub_fallback") ? "TASK_MANAGEMENT_FAILURE:ok" : "TASK_MANAGEMENT_FAILURE:other")
                } else if (context == "/task_policy/hidden_subagents") {
                    print ((string_value == "must_not_substitute_user_visible_execution_tasks") ? "HIDDEN_SUBAGENTS:ok" : "HIDDEN_SUBAGENTS:other")
                } else if (context == "/task_policy/project_hub_task_lifecycle") {
                    print ((string_value == "persistent") ? "PROJECT_HUB_TASK_LIFECYCLE:ok" : "PROJECT_HUB_TASK_LIFECYCLE:other")
                } else if (context == "/authorization/modify") {
                    print ((string_value == "separate") ? "AUTH:modify:ok" : "AUTH:modify:other")
                } else if (context == "/authorization/check") {
                    print ((string_value == "separate") ? "AUTH:check:ok" : "AUTH:check:other")
                } else if (context == "/authorization/build") {
                    print ((string_value == "separate") ? "AUTH:build:ok" : "AUTH:build:other")
                } else if (context == "/authorization/test") {
                    print ((string_value == "separate") ? "AUTH:test:ok" : "AUTH:test:other")
                } else if (context == "/authorization/documentation_sync") {
                    print ((string_value == "separate") ? "AUTH:documentation_sync:ok" : "AUTH:documentation_sync:other")
                } else if (context == "/authorization/commit") {
                    print ((string_value == "separate") ? "AUTH:commit:ok" : "AUTH:commit:other")
                } else if (context == "/authorization/push") {
                    print ((string_value == "separate") ? "AUTH:push:ok" : "AUTH:push:other")
                } else if (context == "/authorization/task_rotation") {
                    print ((string_value == "separate") ? "AUTH:task_rotation:ok" : "AUTH:task_rotation:other")
                } else if (context == "/task_policy/rotation/primary_trigger") {
                    print ((string_value == "milestone_boundary_or_complete_modify_verify_cycle") ? "ROTATION_PRIMARY:ok" : "ROTATION_PRIMARY:other")
                } else if (context == "/task_policy/rotation/authorization_scope") {
                    print ((string_value == "same_already_authorized_scope_only") ? "ROTATION_SCOPE:ok" : "ROTATION_SCOPE:other")
                } else if (context == "/task_policy/rotation/change_behavior") {
                    print ((string_value == "return_to_work") ? "ROTATION_CHANGE:ok" : "ROTATION_CHANGE:other")
                } else if (context == "/task_policy/rotation/create_failure_without_id") {
                    print ((string_value == "restore_predecessor") ? "ROTATION_CREATE_FAILURE:ok" : "ROTATION_CREATE_FAILURE:other")
                } else if (context == "/task_policy/rotation/queued_client_thread_id") {
                    print ((string_value == "occupies_active_task_slot_and_do_not_retry") ? "ROTATION_QUEUED:ok" : "ROTATION_QUEUED:other")
                } else if (context == "/task_policy/rotation/successor_identity") {
                    print ((string_value == "exact_rotation_key_v1_in_first_user_message") ? "ROTATION_IDENTITY:ok" : "ROTATION_IDENTITY:other")
                } else if (context == "/task_policy/rotation/queued_recovery") {
                    print ((string_value == "exhaustive_same_project_discovery_and_exact_rotation_key_match") ? "ROTATION_RECOVERY:ok" : "ROTATION_RECOVERY:other")
                } else if (context == "/task_policy/rotation/rotation_key_format") {
                    print ((string_value == "[codex-project-flow:execution:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>") ? "ROTATION_KEY:ok" : "ROTATION_KEY:other")
                } else if (context == "/task_policy/rotation/independent_worktree_requirement") {
                    print ((string_value == "authorized_transferable_code_checkpoint") ? "ROTATION_WORKTREE:ok" : "ROTATION_WORKTREE:other")
                } else if (context == "/task_policy/rotation/additional_triggers/item") {
                    if (string_value ~ /[\r\n]/) print "ROTATION_TRIGGER_INVALID"
                    else print "ROTATION_TRIGGER_ITEM:" string_value
                } else if (context == "/task_policy/rotation/state_machine/item") {
                    if (string_value ~ /[\r\n]/) print "ROTATION_STATE_INVALID"
                    else print "ROTATION_STATE_ITEM:" string_value
                } else if (context == "/execution_policy/high_risk_operations") {
                    print ((string_value == "serial") ? "EXECUTION:high_risk_operations:ok" : "EXECUTION:high_risk_operations:other")
                } else if (context == "/execution_policy/external_operations") {
                    print ((string_value == "serial") ? "EXECUTION:external_operations:ok" : "EXECUTION:external_operations:other")
                } else if (context == "/execution_policy/project_hub_role") {
                    print ((string_value == "analyze_clarify_design_number_create_wait_coordinate_and_summarize_only") ? "EXECUTION:project_hub_role:ok" : "EXECUTION:project_hub_role:other")
                } else if (context == "/execution_policy/project_hub_execution_fallback") {
                    print ((string_value == "forbidden") ? "EXECUTION:project_hub_execution_fallback:ok" : "EXECUTION:project_hub_execution_fallback:other")
                } else if (context == "/execution_policy/non_conflicting_operations") {
                    print ((string_value == "parallel_allowed") ? "EXECUTION:non_conflicting_operations:ok" : "EXECUTION:non_conflicting_operations:other")
                } else if (context == "/task_policy/return_to_work_on_change/item") {
                    if (string_value ~ /[\r\n]/) print "RETURN_INVALID"
                    else print "RETURN_ITEM:" string_value
                } else if (context == "/handoff_policy/only_when/item") {
                    if (string_value ~ /[\r\n]/) print "HANDOFF_INVALID"
                    else print "HANDOFF_ITEM:" string_value
                }
                return 1
            }
            if (c == "-" || c ~ /[0-9]/) {
                if (!parse_number()) {
                    return 0
                }
                if (context == "/schema_version" && number_value + 0 == 2) {
                    print "SCHEMA:2"
                } else if (context == "/schema_version") {
                    print "SCHEMA:other"
                } else if (context == "/task_policy/max_active_tasks" && number_value + 0 == 5) {
                    print "MAX_ACTIVE_TASKS:ok"
                } else if (context == "/task_policy/max_active_tasks") {
                    print "MAX_ACTIVE_TASKS:other"
                } else if (context == "/task_policy/rotation/review_after_substantive_turns" && number_value + 0 == 6) {
                    print "ROTATION_REVIEW:ok"
                } else if (context == "/task_policy/rotation/review_after_substantive_turns") {
                    print "ROTATION_REVIEW:other"
                } else if (context == "/task_policy/rotation/rotate_no_later_than_substantive_turns" && number_value + 0 == 10) {
                    print "ROTATION_LIMIT:ok"
                } else if (context == "/task_policy/rotation/rotate_no_later_than_substantive_turns") {
                    print "ROTATION_LIMIT:other"
                }
                return 1
            }
            literal = substr(text, pos, 4)
            if (literal == "true") {
                if (context == "/task_policy/blocked_waiting_or_queued_occupies_slot") {
                    print "BLOCKED_WAITING:ok"
                } else if (context == "/task_policy/project_hub_occupies_active_task_slot") {
                    print "PROJECT_HUB_OCCUPIES_ACTIVE_TASK_SLOT:other"
                }
                pos += 4
                return 1
            }
            if (literal == "null") {
                pos += 4
                return 1
            }
            if (substr(text, pos, 5) == "false") {
                if (context == "/task_policy/blocked_waiting_or_queued_occupies_slot") {
                    print "BLOCKED_WAITING:other"
                } else if (context == "/task_policy/project_hub_occupies_active_task_slot") {
                    print "PROJECT_HUB_OCCUPIES_ACTIVE_TASK_SLOT:ok"
                }
                pos += 5
                return 1
            }
            return 0
        }
        {
            text = text $0 "\n"
        }
        END {
            pos = 1
            if (!parse_value("")) {
                exit 1
            }
            skip_ws()
            if (pos <= length(text)) {
                exit 1
            }
        }
    ' "$config"); then
        json_valid=1
    else
        error "Invalid JSON in .agents/workflow.json"
    fi

fi

if [ "$json_valid" -eq 1 ]; then
    meta_has() {
        printf '%s\n' "$json_meta" | grep -Fqx "$1"
    }

    meta_has 'ROOT_OBJECT' || error "The JSON root in .agents/workflow.json must be an object."
    printf '%s\n' "$json_meta" | grep -qx 'SCHEMA:2' || error "Unsupported or missing schema_version."
    if ! printf '%s\n' "$json_meta" | grep -qx 'REQUIRED_ARRAY'; then
        error "required_context must be a JSON array."
    elif printf '%s\n' "$json_meta" | grep -qx 'REQUIRED_INVALID'; then
        error "Every required_context entry must be a string without line breaks."
    else
        required_paths=$(printf '%s\n' "$json_meta" | sed -n 's/^REQUIRED_PATH://p')
        if [ -z "$required_paths" ]; then
            error "required_context must not be empty."
        else
            old_ifs=$IFS
            IFS='
'
            for path in $required_paths; do
                if ! safe_relative_path "$path"; then
                    error "Configured path escapes target: $path"
                elif [ ! -f "$target_root/$path" ]; then
                    error "required_context path is missing: $path"
                fi
            done
            IFS=$old_ifs
        fi
    fi

    if [ "$allow_placeholders" -eq 1 ]; then
        printf '%s\n' "$json_meta" | grep -qx 'PROJECT:placeholder' ||
            error "Template project.name must be <PROJECT_NAME>."
    else
        printf '%s\n' "$json_meta" | grep -qx 'PROJECT:value' ||
            error "Installed project.name must be a non-empty rendered string."
    fi

    for role in rules sop project_state execution_handoff; do
        if meta_has "CONFIG_PATH_INVALID:$role"; then
            error "paths.$role must be a safe relative path string."
            continue
        fi
        configured_path=$(printf '%s\n' "$json_meta" | sed -n "s/^CONFIG_PATH:$role://p")
        if [ -z "$configured_path" ]; then
            error "paths.$role must be a relative path string."
        elif ! safe_relative_path "$configured_path"; then
            error "Configured path escapes target: paths.$role=$configured_path"
        elif [ ! -f "$target_root/$configured_path" ]; then
            error "Configured path is missing: paths.$role=$configured_path"
        fi
    done

    meta_has 'WORK_MODE:ok' || error "work.mode must be read_only."
    for field in modify check build test documentation_sync commit push task_rotation; do
        meta_has "AUTH:$field:ok" || error "authorization.$field must be separate."
    done
    meta_has 'MAX_ACTIVE_TASKS:ok' || error "task_policy.max_active_tasks must be the number 5."
    meta_has 'BLOCKED_WAITING:ok' || error "task_policy.blocked_waiting_or_queued_occupies_slot must be true."
    for marker in EXECUTION_TASK_REQUIREMENT SELECTED_ITEM_AUTHORIZATION TASK_MANAGEMENT_FAILURE HIDDEN_SUBAGENTS; do
        meta_has "$marker:ok" || error "task_policy has an unsupported or missing fail-closed value: $marker"
    done
    meta_has 'MAX_ACTIVE_TASKS_APPLIES_TO:ok' ||
        error "task_policy.max_active_tasks_applies_to must be subsequent_user_visible_execution_tasks."
    meta_has 'PROJECT_HUB_TASK_LIFECYCLE:ok' ||
        error "task_policy.project_hub_task_lifecycle must be persistent."
    meta_has 'PROJECT_HUB_OCCUPIES_ACTIVE_TASK_SLOT:ok' ||
        error "task_policy.project_hub_occupies_active_task_slot must be false."
    if ! meta_has 'RETURN_ARRAY'; then
        error "task_policy.return_to_work_on_change must be a JSON array."
    elif meta_has 'RETURN_INVALID'; then
        error "task_policy.return_to_work_on_change entries must be strings."
    else
        for required_value in requirements scope interface protocol environment acceptance_criteria; do
            meta_has "RETURN_ITEM:$required_value" ||
                error "task_policy.return_to_work_on_change is missing: $required_value"
        done
    fi
    for marker in ROTATION_PRIMARY ROTATION_SCOPE ROTATION_CHANGE ROTATION_CREATE_FAILURE ROTATION_QUEUED ROTATION_IDENTITY ROTATION_RECOVERY ROTATION_KEY ROTATION_WORKTREE ROTATION_REVIEW ROTATION_LIMIT; do
        meta_has "$marker:ok" || error "task_policy.rotation has an unsupported or missing value: $marker"
    done
    if ! meta_has 'ROTATION_TRIGGER_ARRAY'; then
        error "task_policy.rotation.additional_triggers must be a JSON array."
    elif meta_has 'ROTATION_TRIGGER_INVALID'; then
        error "task_policy.rotation.additional_triggers entries must be strings."
    else
        for required_value in context_pressure user_request; do
            meta_has "ROTATION_TRIGGER_ITEM:$required_value" ||
                error "task_policy.rotation.additional_triggers is missing: $required_value"
        done
    fi
    if ! meta_has 'ROTATION_STATE_ARRAY'; then
        error "task_policy.rotation.state_machine must be a JSON array."
    elif meta_has 'ROTATION_STATE_INVALID'; then
        error "task_policy.rotation.state_machine entries must be strings."
    else
        for required_value in prepare_handoff_package project_hub_acknowledges_complete_handoff archive_predecessor create_successor successor_rechecks_rules_and_workspace; do
            meta_has "ROTATION_STATE_ITEM:$required_value" ||
                error "task_policy.rotation.state_machine is missing: $required_value"
        done
        rotation_state=$(printf '%s\n' "$json_meta" | sed -n 's/^ROTATION_STATE_ITEM://p')
        expected_rotation_state=$(printf '%s\n' \
            prepare_handoff_package \
            project_hub_acknowledges_complete_handoff \
            archive_predecessor \
            create_successor \
            successor_rechecks_rules_and_workspace)
        [ "$rotation_state" = "$expected_rotation_state" ] ||
            error "task_policy.rotation.state_machine must contain the exact ordered five-state sequence without duplicates."
    fi
    for field in project_hub_role project_hub_execution_fallback non_conflicting_operations high_risk_operations external_operations; do
        meta_has "EXECUTION:$field:ok" || error "execution_policy.$field has an unsupported or missing value."
    done
    if ! meta_has 'HANDOFF_ARRAY'; then
        error "handoff_policy.only_when must be a JSON array."
    elif meta_has 'HANDOFF_INVALID'; then
        error "handoff_policy.only_when entries must be strings."
    else
        for required_value in coordination_required user_choice_required user_requested; do
            meta_has "HANDOFF_ITEM:$required_value" ||
                error "handoff_policy.only_when is missing: $required_value"
        done
    fi
fi

if [ "$allow_placeholders" -eq 1 ]; then
    version_file="$target_root/VERSION"
    plugin_manifest="$target_root/.codex-plugin/plugin.json"
    if [ -f "$version_file" ] && [ -f "$plugin_manifest" ]; then
        template_version=$(sed -n '1{s/[[:space:]]*$//;p;}' "$version_file")
        printf '%s\n' "$template_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
            error "VERSION must contain a strict semantic version."

        plugin_name=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$plugin_manifest" | head -n 1)
        [ "$plugin_name" = "codex-project-flow" ] ||
            error "Plugin manifest name must be codex-project-flow."

        plugin_version=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$plugin_manifest" | head -n 1)
        if [ "$plugin_version" != "$template_version" ]; then
            build_version=${plugin_version#"$template_version"+}
            if [ "$build_version" = "$plugin_version" ] ||
                ! printf '%s\n' "$build_version" | grep -Eq '^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$'; then
                error "Plugin manifest version must use VERSION as its base version."
            fi
        fi

        plugin_description=$(sed -n 's/^[[:space:]]*"description"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$plugin_manifest" | head -n 1)
        [ -n "$plugin_description" ] || error "Plugin manifest description must be non-empty."

        plugin_skills=$(sed -n 's/^[[:space:]]*"skills"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$plugin_manifest" | head -n 1)
        [ "$plugin_skills" = "./skills/" ] || error "Plugin manifest skills must be ./skills/."
    fi

    bootstrap_skill="$target_root/skills/bootstrap-project-flow/SKILL.md"
    if [ -f "$bootstrap_skill" ]; then
        first=$(sed -n '1p' "$bootstrap_skill")
        closing=$(awk 'NR >= 2 && /^---[[:space:]]*$/ { print NR; exit }' "$bootstrap_skill")
        [ "$first" = "---" ] && [ -n "$closing" ] ||
            error "Bootstrap Skill frontmatter is missing or malformed."
        if [ -n "$closing" ]; then
            frontmatter=$(sed -n "2,$((closing - 1))p" "$bootstrap_skill")
            printf '%s\n' "$frontmatter" | grep -Eq '^name:[[:space:]]*bootstrap-project-flow[[:space:]]*$' ||
                error "Bootstrap Skill frontmatter name must be bootstrap-project-flow."
            description=$(printf '%s\n' "$frontmatter" | sed -n 's/^description:[[:space:]]*//p' | head -n 1)
            case "$description" in
                ""|'""'|"''") error "Bootstrap Skill frontmatter description must be non-empty." ;;
                *)
                    printf '%s\n' "$description" | grep -Eiq '(install|import)' ||
                        error "Bootstrap Skill description must cover installing or importing the workflow."
                    printf '%s\n' "$description" | grep -Eiq '(claim|adopt|make)' ||
                        error "Bootstrap Skill description must cover making the current task the project hub."
                    printf '%s\n' "$description" | grep -Eiq 'user-visible.*project hub' ||
                        error "Bootstrap Skill description must identify a user-visible project hub task."
                    ;;
            esac
            grep -Fq 'set_thread_pinned' "$bootstrap_skill" ||
                error "Bootstrap Skill must call set_thread_pinned for a permanent project hub."
            grep -Eiq '(pinned[^[:alnum:]_[:space:]:=]?[[:space:]]*[:=][[:space:]]*\$?true|-pinned[[:space:]]+\$?true)' "$bootstrap_skill" ||
                error "Bootstrap Skill must explicitly set pinned to true."
            bootstrap_skill_flat=$(tr '\n' ' ' < "$bootstrap_skill")
            for tool_name in read_thread set_thread_archived; do
                printf '%s\n' "$bootstrap_skill_flat" |
                    grep -Eiq "(call|use).{0,30}$tool_name" ||
                    error "Bootstrap Skill must use $tool_name for project hub recovery."
            done
            grep -Eiq '(archived[^[:alnum:]_[:space:]:=]?[[:space:]]*[:=][[:space:]]*\$?false|-archived[[:space:]]+\$?false)' "$bootstrap_skill" ||
                error "Bootstrap Skill must explicitly set archived to false."
            grep -Eiq '(^|[^[:alnum:]_])hubKey([^[:alnum:]_]|$)' "$bootstrap_skill" ||
                error "Bootstrap Skill must define the stable hubKey identifier."
            printf '%s\n' "$bootstrap_skill_flat" |
                grep -Eiq '\[codex-project-flow:hub:v1\].{0,160}projectId[[:space:]]*=.{1,120};[[:space:]]*hubTitle[[:space:]]*=' ||
                error "Bootstrap Skill hubKey must use the v1 prefix, projectId, and hubTitle."
            printf '%s\n' "$bootstrap_skill_flat" |
                grep -Eiq '((full|complete).{0,30}hubKey.{0,120}(exact|verbatim)|(exact|verbatim).{0,120}(full|complete).{0,30}hubKey)' ||
                error "Bootstrap Skill recovery must compare the complete hubKey exactly."
            printf '%s\n' "$bootstrap_skill_flat" |
                grep -Eiq '\[codex-project-flow:hub-claim:v1\].{0,180}projectId[[:space:]]*=.{1,160};[[:space:]]*hubTitle[[:space:]]*=' ||
                error "Bootstrap Skill must define the interrupted current-task claim identity."
            printf '%s\n' "$bootstrap_skill_flat" |
                grep -Eiq '\[codex-project-flow:hub-retired:v1\].{0,180}projectId[[:space:]]*=.{1,160};[[:space:]]*retainedThreadId[[:space:]]*=' ||
                error "Bootstrap Skill must define a durable retired-hub tombstone."
            grep -Fq 'Archiving alone is not cleanup' "$bootstrap_skill" ||
                error "Bootstrap Skill must explain why archiving alone cannot retire a v1 recovery candidate."
            grep -Fq 'exclude a same-project entry only when its complete title exactly matches' "$bootstrap_skill" ||
                error "Bootstrap Skill must exclude only an exact retired-hub tombstone."
            grep -Fq 'separateHubMode' "$bootstrap_skill" ||
                error "Bootstrap Skill must preserve the explicit separate-hub compatibility mode."
            grep -Eiq '(omit|omitted).{0,40}threadId|threadId.{0,40}(omit|omitted)' "$bootstrap_skill" ||
                error "Bootstrap Skill must describe the implicit current-task title operation."
            grep -Eiq 'never call `?create_thread`?.{0,160}(failed|ambiguous)|failed.{0,160}never call `?create_thread`?' "$bootstrap_skill" ||
                error "Bootstrap Skill must forbid silent create_thread fallback after claim failure."
            grep -Eiq 'exhaust(ive|ively|ion)|prove exhaustion' "$bootstrap_skill" ||
                error "Bootstrap Skill must require exhaustive task discovery."
            grep -Eiq '(reaches|reached).{0,60}(requested )?limit.{0,100}stop|stop.{0,100}(reaches|reached).{0,60}(requested )?limit' "$bootstrap_skill" ||
                error "Bootstrap Skill must stop when task-list exhaustion cannot be proven."
            grep -Eiq '(queued|clientThreadId).*(do not|never|not to).*(call[[:space:]]+)?[^[:alnum:]_[:space:]]?create_thread[^[:alnum:]_[:space:]]?[[:space:]]+again' "$bootstrap_skill" ||
                error "Bootstrap Skill queued handling must forbid another create_thread call."
            grep -Eiq '(queued|clientThreadId).*(do not|never|not to).*(immediate(ly)?[[:space:]]+(re-?run|retry)|(re-?run|retry).{0,40}immediate)' "$bootstrap_skill" ||
                error "Bootstrap Skill queued handling must forbid an immediate rerun or retry."
        fi
    fi

    bootstrap_openai_yaml="$target_root/skills/bootstrap-project-flow/agents/openai.yaml"
    if [ -f "$bootstrap_openai_yaml" ]; then
        grep -Eq '^interface:[[:space:]]*(#.*)?$' "$bootstrap_openai_yaml" ||
            error "Bootstrap openai.yaml is missing the interface mapping."
        for field in display_name short_description default_prompt; do
            value=$(sed -n "s/^[[:space:]][[:space:]]*$field:[[:space:]]*//p" "$bootstrap_openai_yaml" | head -n 1)
            case "$value" in
                ""|'""'|"''") error "Bootstrap openai.yaml is missing a non-empty interface.$field." ;;
            esac
        done
        bootstrap_default_prompt=$(sed -n 's/^[[:space:]][[:space:]]*default_prompt:[[:space:]]*//p' "$bootstrap_openai_yaml" | head -n 1)
        printf '%s\n' "$bootstrap_default_prompt" | grep -Fq '$bootstrap-project-flow' ||
            error 'Bootstrap openai.yaml default_prompt must reference $bootstrap-project-flow.'
        printf '%s\n' "$bootstrap_default_prompt" | grep -Eiq '(claim|adopt).{0,80}(this|current).{0,40}(task|hub)|(this|current).{0,40}task.{0,80}(claim|adopt)' ||
            error "Bootstrap openai.yaml default_prompt must make current-task hub adoption the default."
    fi

    upgrade_skill="$target_root/skills/upgrade-project-flow/SKILL.md"
    if [ -f "$upgrade_skill" ]; then
        first=$(sed -n '1p' "$upgrade_skill")
        closing=$(awk 'NR >= 2 && /^---[[:space:]]*$/ { print NR; exit }' "$upgrade_skill")
        [ "$first" = "---" ] && [ -n "$closing" ] ||
            error "Upgrade Skill frontmatter is missing or malformed."
        if [ -n "$closing" ]; then
            frontmatter=$(sed -n "2,$((closing - 1))p" "$upgrade_skill")
            printf '%s\n' "$frontmatter" | grep -Eq '^name:[[:space:]]*upgrade-project-flow[[:space:]]*$' ||
                error "Upgrade Skill frontmatter name must be upgrade-project-flow."
            description=$(printf '%s\n' "$frontmatter" | sed -n 's/^description:[[:space:]]*//p' | head -n 1)
            printf '%s\n' "$description" | grep -Eiq '(upgrade|sync)' ||
                error "Upgrade Skill description must cover upgrading or syncing deployed projects."
        fi
        grep -Fq 'references/upgrade-contract.md' "$upgrade_skill" ||
            error "Upgrade Skill must reference the upgrade contract."
        grep -Fq -- '--adopt-from 0.2.0' "$upgrade_skill" ||
            error "Upgrade Skill must require explicit 0.2.0 legacy adoption."
        grep -Fq -- '--accept-local' "$upgrade_skill" ||
            error "Upgrade Skill must expose explicit per-path local conflict acceptance."
        grep -Eiq 'default.*(read-only|plan)|default to a read-only plan' "$upgrade_skill" ||
            error "Upgrade Skill must make read-only planning the default."
    fi

    upgrade_openai_yaml="$target_root/skills/upgrade-project-flow/agents/openai.yaml"
    if [ -f "$upgrade_openai_yaml" ]; then
        grep -Eq '^interface:[[:space:]]*(#.*)?$' "$upgrade_openai_yaml" ||
            error "Upgrade openai.yaml is missing the interface mapping."
        upgrade_default_prompt=$(sed -n 's/^[[:space:]][[:space:]]*default_prompt:[[:space:]]*//p' "$upgrade_openai_yaml" | head -n 1)
        printf '%s\n' "$upgrade_default_prompt" | grep -Fq '$upgrade-project-flow' ||
            error 'Upgrade openai.yaml default_prompt must reference $upgrade-project-flow.'
    fi
fi

skill="$target_root/.agents/skills/project-workflow-manager/SKILL.md"
if [ -f "$skill" ]; then
    first=$(sed -n '1p' "$skill")
    closing=$(awk 'NR >= 2 && /^---[[:space:]]*$/ { print NR; exit }' "$skill")
    [ "$first" = "---" ] && [ -n "$closing" ] || error "Skill frontmatter is missing or malformed."
    if [ -n "$closing" ]; then
        frontmatter=$(sed -n "2,$((closing - 1))p" "$skill")
        printf '%s\n' "$frontmatter" | grep -Eq '^name:[[:space:]]*project-workflow-manager[[:space:]]*$' ||
            error "Skill frontmatter name must be project-workflow-manager."
        description=$(printf '%s\n' "$frontmatter" | sed -n 's/^description:[[:space:]]*//p' | head -n 1)
        case "$description" in
            ""|'""'|"''") error "Skill frontmatter description must be non-empty." ;;
        esac
    fi
fi

openai_yaml="$target_root/.agents/skills/project-workflow-manager/agents/openai.yaml"
if [ -f "$openai_yaml" ]; then
    grep -Eq '^interface:[[:space:]]*(#.*)?$' "$openai_yaml" ||
        error "openai.yaml is missing the interface mapping."
    for field in display_name short_description default_prompt; do
        value=$(sed -n "s/^[[:space:]][[:space:]]*$field:[[:space:]]*//p" "$openai_yaml" | head -n 1)
        case "$value" in
            ""|'""'|"''") error "openai.yaml is missing a non-empty interface.$field." ;;
        esac
    done
    grep -Fq '$project-workflow-manager' "$openai_yaml" ||
        error 'openai.yaml default_prompt must reference $project-workflow-manager.'
fi

placeholder_files=""
for candidate in "$target_root/AGENTS.md" "$target_root/.agents" "$target_root/docs"; do
    [ -e "$candidate" ] || continue
    matches=$(grep -R -l '<PROJECT_NAME>' "$candidate" 2>/dev/null || true)
    if [ -n "$matches" ]; then
        placeholder_files="${placeholder_files}${placeholder_files:+
}${matches}"
    fi
done
if [ -n "$placeholder_files" ]; then
    if [ "$allow_placeholders" -eq 1 ]; then
        warn "Unresolved <PROJECT_NAME> placeholder is present in template files."
    else
        error "Unresolved <PROJECT_NAME> placeholder is present in installed files."
    fi
elif [ "$allow_placeholders" -eq 1 ]; then
    error "Template does not contain the required <PROJECT_NAME> placeholder."
fi

if [ "$errors" -gt 0 ]; then
    echo "Validation failed: $errors error(s), $warnings warning(s)." >&2
    exit 1
fi

echo "Validation passed: $warnings warning(s)."
