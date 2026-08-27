#!/bin/sh
set -eu
script_root=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
exec sh "$script_root/project-flow.sh" validate "$@"
