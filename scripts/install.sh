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

target_link_check=$target
while [ "$target_link_check" != "/" ] && [ "${target_link_check%/}" != "$target_link_check" ]; do
    target_link_check=${target_link_check%/}
done
[ ! -L "$target_link_check" ] || {
    echo "Target directory must not be a symbolic link: $target" >&2
    exit 2
}
[ -d "$target" ] || { echo "Target directory does not exist: $target" >&2; exit 2; }

script_root=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
template_root=$(CDPATH= cd -P "$script_root/.." && pwd -P)
target_root=$(CDPATH= cd -P "$target" && pwd -P)

if [ -z "$project_name" ]; then
    project_name=$(basename "$target_root")
fi
newline='
'
carriage_return=$(printf '\r')
case "$project_name" in
    *"$newline"*|*"$carriage_return"*)
        echo "Project name must not contain control characters." >&2
        exit 2
        ;;
esac
if printf '%s' "$project_name" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo "Project name must not contain control characters." >&2
    exit 2
fi

assert_no_symlink_path() {
    relative_path=$1
    current_path=$target_root
    remaining_path=$relative_path

    while [ -n "$remaining_path" ]; do
        case "$remaining_path" in
            */*)
                component=${remaining_path%%/*}
                remaining_path=${remaining_path#*/}
                ;;
            *)
                component=$remaining_path
                remaining_path=""
                ;;
        esac
        [ -n "$component" ] || continue
        current_path="$current_path/$component"
        if [ -L "$current_path" ]; then
            echo "Refusing target path through a symbolic link: $current_path" >&2
            exit 3
        fi
        if [ ! -e "$current_path" ]; then
            break
        fi
    done
}

backup_stamp=$(date '+%Y%m%d-%H%M%S')
backup_root="$target_root/.project-flow-backup/$backup_stamp"
backup_suffix=0
assert_no_symlink_path ".project-flow-backup/$backup_stamp"
while [ -e "$backup_root" ] || [ -L "$backup_root" ]; do
    backup_suffix=$((backup_suffix + 1))
    backup_root="$target_root/.project-flow-backup/$backup_stamp-$backup_suffix"
    assert_no_symlink_path ".project-flow-backup/$backup_stamp-$backup_suffix"
done
project_escaped=$(printf '%s' "$project_name" | sed 's/[&|\\]/\\&/g')
project_json_inner=$(printf '%s' "$project_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
project_json_replacement=$(printf '"%s"' "$project_json_inner" | sed 's/[&|\\]/\\&/g')

install_file() {
    source_file=$1
    relative=$2
    destination="$target_root/$relative"

    case "$relative" in
        /*|../*|*/../*|*'/..'|\\*|[A-Za-z]:*)
            echo "Refusing path outside target: $relative" >&2
            exit 3
            ;;
    esac

    assert_no_symlink_path "$relative"

    if [ -e "$destination" ] && [ ! -f "$destination" ]; then
        echo "Destination exists and is not a file: $destination" >&2
        exit 3
    fi

    if [ -f "$destination" ] && [ "$force" -eq 0 ]; then
        echo "SKIP  $relative (already exists)"
        return
    fi

    if [ "$dry_run" -eq 1 ]; then
        if [ -f "$destination" ]; then
            echo "REPLACE $relative"
        else
            echo "CREATE  $relative"
        fi
        return
    fi

    destination_dir=$(dirname "$destination")
    mkdir -p "$destination_dir"
    if [ -f "$destination" ]; then
        backup="$backup_root/$relative"
        assert_no_symlink_path ".project-flow-backup/${backup_root##*/}/$relative"
        mkdir -p "$(dirname "$backup")"
        cp "$destination" "$backup"
    fi

    temporary="$destination.project-flow-tmp-$$"
    if [ "$relative" = ".agents/workflow.json" ]; then
        sed "s|\"<PROJECT_NAME>\"|$project_json_replacement|g" "$source_file" > "$temporary"
    else
        sed "s|<PROJECT_NAME>|$project_escaped|g" "$source_file" > "$temporary"
    fi
    mv "$temporary" "$destination"
    echo "WRITE $relative"
}

assert_no_symlink_path "AGENTS.md"
if [ "$force" -eq 1 ] && [ -f "$target_root/AGENTS.md" ]; then
    assert_no_symlink_path ".project-flow-backup/${backup_root##*/}/AGENTS.md"
fi
for source_base in "$template_root/.agents" "$template_root/docs"; do
    find "$source_base" -type f -print | sort | while IFS= read -r source_file; do
        relative=${source_file#"$template_root/"}
        assert_no_symlink_path "$relative"
        if [ "$force" -eq 1 ] && [ -f "$target_root/$relative" ]; then
            assert_no_symlink_path ".project-flow-backup/${backup_root##*/}/$relative"
        fi
    done
done

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
