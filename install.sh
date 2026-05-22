#!/usr/bin/env bash
#
# Install opensnitch rules and lists into /etc/opensnitchd/.
# Never overwrites existing files — re-running fills in gaps only.
# To pull an updated rule from the repo, delete the corresponding file
# in /etc/opensnitchd/ first, then re-run this script.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR=/etc/opensnitchd

if [[ "$EUID" -ne 0 ]]; then
  echo "error: run as root (sudo $0)" >&2
  exit 1
fi

if [[ ! -d "$DEST_DIR" ]]; then
  echo "error: $DEST_DIR not found — is opensnitch installed?" >&2
  echo "       apt install opensnitch" >&2
  exit 1
fi

copied=0
skipped=0

install_file() {
  local src="$1" dest="$2"
  if [[ -e "$dest" ]]; then
    printf '  skip  %s\n' "$dest"
    skipped=$((skipped + 1))
  else
    install -m 0644 "$src" "$dest"
    printf '  copy  %s\n' "$dest"
    copied=$((copied + 1))
  fi
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

echo
echo "summary: $copied copied, $skipped skipped"

if (( copied > 0 )); then
  echo
  echo "next:"
  echo "  sudo systemctl restart opensnitch"
  echo "  journalctl -u opensnitch -n 50 --no-pager"
elif (( skipped > 0 )); then
  echo
  echo "note: all files already present; to update one, rm /etc/opensnitchd/<file> then re-run."
fi
