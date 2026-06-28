#!/usr/bin/env bash
#
# Install opensnitch rules and lists into /etc/opensnitchd/.
# By default only fills in missing files (existing copies are left alone).
#   --force    overwrite existing files that differ from the repo copy
#   --dry-run  list which files would change without writing anything (no root)
#   --diff     like --dry-run, but also print the diff for each changed file
#   --service  also install observer.py as a systemd service that logs
#              connections matching no rule (continuous deny log)
# See diff.sh for a convenience wrapper around --diff.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR=/etc/opensnitchd

OBSERVER_BIN=/usr/local/bin/opensnitch-observer
UNIT_NAME=opensnitch-observer.service
UNIT_DEST=/etc/systemd/system/$UNIT_NAME

FORCE=0
DRYRUN=0
DIFF=0
SERVICE=0

usage() {
  cat <<'EOF'
usage: install.sh [--force] [--dry-run] [--diff] [--service] [--help]

  -f, --force      overwrite live files that differ from the repo copy
                   (includes default-config.json — resets any hand-tuned
                   live DefaultAction/DefaultDuration)
  -n, --dry-run    list which files would change; writes nothing, needs no
                   root. Combine with --force to preview a forced install.
  -d, --diff       like --dry-run, but also print the diff for each changed
                   file. Shows diffs whether or not --force is set.
  -s, --service    also install observer.py as a systemd service
                   (opensnitch-observer.service) that runs continuously and
                   logs every connection matching no rule to
                   /var/log/opensnitch-observer.log. Only one UI can hold the
                   daemon socket, so do not run the Qt opensnitch-ui too.
  -h, --help       show this help

Without --force, install only creates missing files; existing files that
differ are left untouched and reported as stale.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force) FORCE=1 ;;
    -n|--dry-run) DRYRUN=1 ;;
    -d|--diff) DRYRUN=1; DIFF=1 ;;
    -s|--service) SERVICE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [[ "$DRYRUN" -eq 0 && "$EUID" -ne 0 ]]; then
  echo "error: run as root (sudo $0)" >&2
  exit 1
fi

if [[ ! -d "$DEST_DIR" ]]; then
  echo "error: $DEST_DIR not found — is opensnitch installed?" >&2
  echo "       apt install opensnitch" >&2
  exit 1
fi

created=0
updated=0
unchanged=0
skipped=0

install_file() {
  local src="$1" dest="$2" mode="${3:-0644}" status
  if [[ ! -e "$dest" ]]; then
    status=create
  elif cmp -s "$src" "$dest"; then
    status=unchanged
  elif [[ "$FORCE" -eq 1 ]]; then
    status=update
  else
    status=skip
  fi

  case "$status" in
    create)
      created=$((created + 1))
      if [[ "$DRYRUN" -eq 1 ]]; then
        printf '  create  %s\n' "$dest"
      else
        install -m "$mode" "$src" "$dest"
        printf '  create  %s\n' "$dest"
      fi
      ;;
    update)
      updated=$((updated + 1))
      if [[ "$DRYRUN" -eq 1 ]]; then
        printf '  update  %s\n' "$dest"
        [[ "$DIFF" -eq 1 ]] && diff -u "$dest" "$src" | sed 's/^/      /' || true
      else
        install -m "$mode" "$src" "$dest"
        printf '  update  %s\n' "$dest"
      fi
      ;;
    skip)
      skipped=$((skipped + 1))
      printf '  differs %s (use --force to overwrite)\n' "$dest"
      [[ "$DIFF" -eq 1 ]] && diff -u "$dest" "$src" | sed 's/^/      /' || true
      ;;
    unchanged)
      unchanged=$((unchanged + 1))
      ;;
  esac
}

mkdir -p "$DEST_DIR/lists" "$DEST_DIR/rules"

echo "==> default-config.json"
install_file "$SRC_DIR/default-config.json" "$DEST_DIR/default-config.json"

echo "==> lists/"
for f in "$SRC_DIR"/lists/*.txt; do
  [[ -e "$f" ]] || continue
  install_file "$f" "$DEST_DIR/lists/$(basename "$f")"
done

echo "==> rules/"
for f in "$SRC_DIR"/rules/*.json; do
  [[ -e "$f" ]] || continue
  install_file "$f" "$DEST_DIR/rules/$(basename "$f")"
done

if [[ "$SERVICE" -eq 1 ]]; then
  echo "==> observer service"
  install_file "$SRC_DIR/observer.py" "$OBSERVER_BIN" 0755
  install_file "$SRC_DIR/systemd/$UNIT_NAME" "$UNIT_DEST"
  if [[ "$DRYRUN" -eq 1 ]]; then
    echo "  would run: systemctl daemon-reload"
    echo "  would run: systemctl enable $UNIT_NAME"
    echo "  would run: systemctl restart $UNIT_NAME"
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable "$UNIT_NAME"
    systemctl restart "$UNIT_NAME"
    echo "  enabled and (re)started $UNIT_NAME"
  else
    echo "  note: systemctl not found; unit installed but not enabled"
  fi
fi

echo
if [[ "$DRYRUN" -eq 1 ]]; then
  echo "would change: $created create, $updated update, $skipped stale (unchanged $unchanged)"
  if [[ "$skipped" -gt 0 && "$FORCE" -eq 0 ]]; then
    echo "note: re-run with --force to overwrite the stale files above."
  fi
else
  echo "summary: $created created, $updated updated, $skipped skipped (unchanged $unchanged)"
  if (( created > 0 || updated > 0 )); then
    echo
    echo "next:"
    echo "  sudo systemctl restart opensnitch"
    echo "  journalctl -u opensnitch -n 50 --no-pager"
  elif (( skipped > 0 )); then
    echo
    echo "note: stale files left untouched; re-run with --force to overwrite."
  fi
  if [[ "$SERVICE" -eq 1 ]]; then
    echo
    echo "observer log:"
    echo "  tail -f /var/log/opensnitch-observer.log"
  fi
fi
