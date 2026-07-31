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
fi

for prefix in 00 08; do
    count=$(find "$target_root/.agents/prompts" -maxdepth 1 -type f -name "${prefix}_*.md" 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -eq 1 ] || error "Expected exactly one ${prefix}_*.md prompt."
done

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
                }
                if (context == "/required_context") {
                    child_context = "/required_context/item"
                } else if (context == "/task_policy/return_to_work_on_change") {
                    child_context = "/task_policy/return_to_work_on_change/item"
                } else if (context == "/handoff_policy/only_when") {
                    child_context = "/handoff_policy/only_when/item"
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
                } else if (context == "/work/mode") {
                    print ((string_value == "read_only") ? "WORK_MODE:ok" : "WORK_MODE:other")
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
                } else if (context == "/execution_policy/high_risk_operations") {
                    print ((string_value == "serial") ? "EXECUTION:high_risk_operations:ok" : "EXECUTION:high_risk_operations:other")
                } else if (context == "/execution_policy/external_operations") {
                    print ((string_value == "serial") ? "EXECUTION:external_operations:ok" : "EXECUTION:external_operations:other")
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
                if (context == "/schema_version" && number_value + 0 == 1) {
                    print "SCHEMA:1"
                } else if (context == "/schema_version") {
                    print "SCHEMA:other"
                } else if (context == "/task_policy/max_active_tasks" && number_value + 0 == 1) {
                    print "MAX_ACTIVE_TASKS:ok"
                } else if (context == "/task_policy/max_active_tasks") {
                    print "MAX_ACTIVE_TASKS:other"
                }
                return 1
            }
            literal = substr(text, pos, 4)
            if (literal == "true") {
                if (context == "/task_policy/blocked_or_waiting_occupies_slot") {
                    print "BLOCKED_WAITING:ok"
                }
                pos += 4
                return 1
            }
            if (literal == "null") {
                pos += 4
                return 1
            }
            if (substr(text, pos, 5) == "false") {
                if (context == "/task_policy/blocked_or_waiting_occupies_slot") {
                    print "BLOCKED_WAITING:other"
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
    printf '%s\n' "$json_meta" | grep -qx 'SCHEMA:1' || error "Unsupported or missing schema_version."
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

    for role in rules sop project_state; do
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
    for field in modify check build test documentation_sync commit push; do
        meta_has "AUTH:$field:ok" || error "authorization.$field must be separate."
    done
    meta_has 'MAX_ACTIVE_TASKS:ok' || error "task_policy.max_active_tasks must be the number 1."
    meta_has 'BLOCKED_WAITING:ok' || error "task_policy.blocked_or_waiting_occupies_slot must be true."
    if ! meta_has 'RETURN_ARRAY'; then
        error "task_policy.return_to_work_on_change must be a JSON array."
    elif meta_has 'RETURN_INVALID'; then
        error "task_policy.return_to_work_on_change entries must be strings."
    else
        for required_value in scope interface environment acceptance_criteria; do
            meta_has "RETURN_ITEM:$required_value" ||
                error "task_policy.return_to_work_on_change is missing: $required_value"
        done
    fi
    for field in high_risk_operations external_operations; do
        meta_has "EXECUTION:$field:ok" || error "execution_policy.$field must be serial."
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

skill="$target_root/.agents/skills/project-workflow-manager/SKILL.md"
if [ -f "$skill" ]; then
    first=$(sed -n '1p' "$skill")
    closing=$(sed -n '2,/^---[[:space:]]*$/ { /^---[[:space:]]*$/ { =; q; } }' "$skill")
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
