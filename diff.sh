#!/usr/bin/env bash
#
# Preview what install.sh would change, without writing anything.
#   ./diff.sh           what a normal install would create
#   ./diff.sh --force   what a forced install would create + update (with diffs)
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh" --diff "$@"
