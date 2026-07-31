#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
temp_base=${TMPDIR:-/tmp}
test_root=$(mktemp -d "$temp_base/codex-project-flow.XXXXXX")

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
control_target="$test_root/control-project"
link_target="$test_root/link-project"
outside_target="$test_root/outside-project"
special_project_name='Quote "value" Backslash \ Ampersand & Pipe |'
mkdir -p \
    "$empty_target" \
    "$existing_target" \
    "$legacy_target" \
    "$control_target" \
    "$link_target" \
    "$outside_target"

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
    printf '%s\n' "$bootstrap_description" | grep -Eiq '(create|reuse)' &&
    printf '%s\n' "$bootstrap_description" | grep -Eiq 'user-visible.*project hub' || {
        echo "Bootstrap Skill description does not cover import and user-visible project hub creation or reuse." >&2
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

mkdir -p "$legacy_target/.agents/prompts"
printf '# Legacy prompt\n' > "$legacy_target/.agents/prompts/01_start_project.md"
sh "$repo_root/scripts/install.sh" "$legacy_target" "Legacy Project"
[ -f "$legacy_target/.agents/prompts/01_start_project.md" ] || {
    echo "Installer destructively removed a legacy prompt." >&2
    exit 1
}

echo "All POSIX shell tests passed."
