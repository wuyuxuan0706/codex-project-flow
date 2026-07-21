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
mkdir -p "$empty_target" "$existing_target"

ALLOW_PLACEHOLDERS=1 sh "$repo_root/scripts/validate.sh" "$repo_root"
sh "$repo_root/scripts/install.sh" "$empty_target" "Empty Project"

grep -q '"name": "Empty Project"' "$empty_target/.agents/workflow.json" || {
    echo "Project name rendering failed." >&2
    exit 1
}
if grep -Eq '"(risks|decisions)"[[:space:]]*:' "$empty_target/.agents/workflow.json"; then
    echo "Removed document roles were installed." >&2
    exit 1
fi
for removed_document in docs/RISKS.md docs/DECISIONS.md; do
    [ ! -e "$empty_target/$removed_document" ] || {
        echo "Removed document was installed: $removed_document" >&2
        exit 1
    }
done

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
sh "$repo_root/scripts/install.sh" "$empty_target" "Empty Project"
second_digest=$(digest_tree "$empty_target")
[ "$first_digest" = "$second_digest" ] || {
    echo "Installation is not idempotent." >&2
    exit 1
}

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

echo "All POSIX shell tests passed."
