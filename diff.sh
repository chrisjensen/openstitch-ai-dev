#!/usr/bin/env bash
#
# Preview what install.sh would change, with diffs, without writing anything.
#   ./diff.sh           diffs for files a normal install would create/leave stale
#   ./diff.sh --force   diffs for files a forced install would create + update
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh" --diff "$@"
