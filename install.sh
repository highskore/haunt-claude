#!/bin/bash
# Installs or removes this adapter in Claude Code. Usage: install.sh --dry-run|--apply|--remove [--dry-run]
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
DRY=0
ACTION=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --apply) ACTION=apply ;;
        --remove) ACTION=remove ;;
        *) echo "usage: $0 --dry-run|--apply|--remove [--dry-run]" >&2; exit 2 ;;
    esac
done
# A bare --dry-run previews the install.
[ -z "$ACTION" ] && [ "$DRY" = 1 ] && ACTION=apply
[ -z "$ACTION" ] && { echo "usage: $0 --dry-run|--apply|--remove [--dry-run]" >&2; exit 2; }

run() {
    local quoted
    quoted=$(printf '%q ' "$@")
    echo "${quoted% }"
    [ "$DRY" = 1 ] || "$@"
}

if [ "$ACTION" = apply ]; then
    run claude plugin marketplace add "$REPO"
    run claude plugin install haunt@haunt
else
    run claude plugin uninstall haunt@haunt
    run claude plugin marketplace remove haunt
fi
