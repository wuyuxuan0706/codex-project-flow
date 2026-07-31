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
sh "$repo_root/scripts/install.sh" "$empty_target" "$special_project_name"

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
