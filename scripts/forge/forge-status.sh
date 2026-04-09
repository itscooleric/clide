#!/usr/bin/env bash
set -euo pipefail

# forge-status.sh — show state of LUKS volume, mount, and docker stacks
# Install to /usr/local/bin/forge-status.sh

FORGE_IMG="/forge.img"
FORGE_MAPPER="forge"
FORGE_MOUNT="/forge"

# --- helpers ---

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: must be run as root" >&2
        exit 1
    fi
}

section() { echo; echo "=== $* ==="; }

# --- main ---

require_root

section "Mount state"
if mountpoint -q "${FORGE_MOUNT}"; then
    echo "  ${FORGE_MOUNT}  MOUNTED"
    mount | grep " on ${FORGE_MOUNT} " || true
else
    echo "  ${FORGE_MOUNT}  NOT MOUNTED"
fi

section "LUKS state"
if [[ -e "/dev/mapper/${FORGE_MAPPER}" ]]; then
    echo "  /dev/mapper/${FORGE_MAPPER}  OPEN"
    cryptsetup status "${FORGE_MAPPER}" | sed 's/^/  /'
else
    echo "  /dev/mapper/${FORGE_MAPPER}  CLOSED"
fi

if [[ -f "${FORGE_IMG}" ]]; then
    img_size="$(du -sh "${FORGE_IMG}" 2>/dev/null | cut -f1)"
    echo "  Image file: ${FORGE_IMG}  (${img_size})"
else
    echo "  Image file: ${FORGE_IMG}  NOT FOUND"
fi

section "Running containers"
running="$(docker ps -q 2>/dev/null | wc -l)"
if [[ "${running}" -gt 0 ]]; then
    docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Image}}"
else
    echo "  (no containers running)"
fi

section "Disk usage"
if mountpoint -q "${FORGE_MOUNT}"; then
    df -h "${FORGE_MOUNT}" | sed 's/^/  /'
    echo
    echo "  Top-level directory sizes:"
    du -sh "${FORGE_MOUNT}"/*/ 2>/dev/null | sort -rh | head -20 | sed 's/^/  /' || true
else
    echo "  (not mounted — no disk usage available)"
fi

echo
