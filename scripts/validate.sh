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

require_file() {
    [ -f "$target_root/$1" ] || error "Missing $1"
}

require_file ".agents/workflow.json"
require_file "AGENTS.md"
require_file ".agents/skills/manage-project-workflow/SKILL.md"
require_file ".agents/skills/manage-project-workflow/agents/openai.yaml"
require_file ".agents/skills/manage-project-workflow/references/document-contracts.md"

index=1
while [ "$index" -le 6 ]; do
    padded=$(printf '%02d' "$index")
    count=$(find "$target_root/.agents/prompts" -maxdepth 1 -type f -name "${padded}_*.md" 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -eq 1 ] || error "Expected one prompt matching .agents/prompts/${padded}_*.md"
    index=$((index + 1))
done

config="$target_root/.agents/workflow.json"
if [ -f "$config" ]; then
    grep -Eq '"schema_version"[[:space:]]*:[[:space:]]*1' "$config" || error "Unsupported or missing schema_version"
    for role in project_state module_index current_task periodic_log; do
        path=$(sed -n "s/.*\"$role\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$config" | head -n 1)
        if [ -z "$path" ]; then
            error "Missing document role: $role"
            continue
        fi
        case "$path" in
            /*|../*|*/../*|*'/..'|?:*) error "Configured path escapes target: $path" ;;
            *) [ -f "$target_root/$path" ] || error "Configured document is missing: $path" ;;
        esac
    done
    required_paths=$(sed -n '/"required_context"[[:space:]]*:/,/][[:space:]]*,[[:space:]]*$/ {
        s/^[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p
    }' "$config")
    old_ifs=$IFS
    IFS='
'
    for path in $required_paths; do
        [ -n "$path" ] || continue
        case "$path" in
            /*|../*|*/../*|*'/..'|?:*) error "required_context path escapes target: $path" ;;
            *) [ -f "$target_root/$path" ] || error "required_context path is missing: $path" ;;
        esac
    done
    IFS=$old_ifs
    grep -q '<AUTO_DISCOVER>' "$config" && warn "Source roots use automatic discovery; confirm the module index."
fi

skill="$target_root/.agents/skills/manage-project-workflow/SKILL.md"
if [ -f "$skill" ]; then
    first=$(sed -n '1p' "$skill")
    second=$(sed -n '2p' "$skill")
    fourth=$(sed -n '4p' "$skill")
    [ "$first" = "---" ] && [ "$second" = "name: manage-project-workflow" ] && [ "$fourth" = "---" ] || error "Skill frontmatter is invalid or mismatched."
fi

if grep -R -l '<PROJECT_NAME>' "$target_root/AGENTS.md" "$target_root/.agents" "$target_root/docs" >/dev/null 2>&1; then
    if [ "$allow_placeholders" -eq 1 ]; then
        warn "Unresolved <PROJECT_NAME> placeholder."
    else
        error "Unresolved <PROJECT_NAME> placeholder."
    fi
fi

if [ "$errors" -gt 0 ]; then
    echo "Validation failed: $errors error(s), $warnings warning(s)." >&2
    exit 1
fi

echo "Validation passed: $warnings warning(s)."
