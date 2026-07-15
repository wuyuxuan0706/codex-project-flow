#!/bin/sh
set -eu

target="."
project_name=""
force=0
dry_run=0
target_set=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            [ "$#" -ge 2 ] || { echo "--target requires a value" >&2; exit 2; }
            target=$2
            target_set=1
            shift 2
            ;;
        --project-name)
            [ "$#" -ge 2 ] || { echo "--project-name requires a value" >&2; exit 2; }
            project_name=$2
            shift 2
            ;;
        --force)
            force=1
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [target] [project-name] [--force] [--dry-run]"
            exit 0
            ;;
        *)
            if [ "$target_set" -eq 0 ]; then
                target=$1
                target_set=1
            elif [ -z "$project_name" ]; then
                project_name=$1
            else
                echo "Unexpected argument: $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

[ -d "$target" ] || { echo "Target directory does not exist: $target" >&2; exit 2; }

script_root=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
template_root=$(CDPATH= cd -P "$script_root/.." && pwd -P)
target_root=$(CDPATH= cd -P "$target" && pwd -P)

if [ -z "$project_name" ]; then
    project_name=$(basename "$target_root")
fi
case "$project_name" in
    *'\n'*|*'\r'*) echo "Project name must be a single line." >&2; exit 2 ;;
esac

backup_stamp=$(date '+%Y%m%d-%H%M%S')
backup_root="$target_root/.project-flow-backup/$backup_stamp"
project_escaped=$(printf '%s' "$project_name" | sed 's/[&|\\]/\\&/g')

install_file() {
    source_file=$1
    relative=$2
    destination="$target_root/$relative"

    case "$relative" in
        /*|../*|*/../*|*'/..') echo "Refusing path outside target: $relative" >&2; exit 3 ;;
    esac

    if [ -f "$destination" ] && [ "$force" -eq 0 ]; then
        echo "SKIP  $relative (already exists)"
        return
    fi

    if [ "$dry_run" -eq 1 ]; then
        if [ -f "$destination" ]; then echo "REPLACE $relative"; else echo "CREATE  $relative"; fi
        return
    fi

    destination_dir=$(dirname "$destination")
    mkdir -p "$destination_dir"
    if [ -f "$destination" ]; then
        backup="$backup_root/$relative"
        mkdir -p "$(dirname "$backup")"
        cp "$destination" "$backup"
    fi

    temporary="$destination.project-flow-tmp-$$"
    sed "s|<PROJECT_NAME>|$project_escaped|g" "$source_file" > "$temporary"
    mv "$temporary" "$destination"
    echo "WRITE $relative"
}

install_file "$template_root/AGENTS.md" "AGENTS.md"

for source_base in "$template_root/.agents" "$template_root/docs"; do
    find "$source_base" -type f -print | sort | while IFS= read -r source_file; do
        relative=${source_file#"$template_root/"}
        install_file "$source_file" "$relative"
    done
done

if [ "$dry_run" -eq 1 ]; then
    echo "Dry run complete; no files changed."
    exit 0
fi

if [ "$force" -eq 1 ] && [ -d "$backup_root" ]; then
    echo "Backups: $backup_root"
fi

sh "$script_root/validate.sh" "$target_root"
