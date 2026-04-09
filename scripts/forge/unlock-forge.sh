#!/usr/bin/env bash
set -euo pipefail

# unlock-forge.sh — open LUKS volume, mount /forge, start docker stacks
# Install to /usr/local/bin/unlock-forge.sh

FORGE_IMG="/forge.img"
FORGE_MAPPER="forge"
FORGE_MOUNT="/forge"
STACKS_DIR="${FORGE_MOUNT}/stacks"
NTFY_TOPIC="${MESA_NTFY_TOPIC:-}"

# Ordered stacks to bring up first; remainder brought up after
ORDERED_STACKS=(caddy-dns ergo gitea clide)

# --- helpers ---

log() { echo "[unlock-forge] $*"; }
err() { echo "[unlock-forge] ERROR: $*" >&2; }

ntfy_send() {
    local msg="$1"
    if [[ -n "${NTFY_TOPIC}" ]]; then
        curl -s -o /dev/null --max-time 10 \
            -d "${msg}" \
            "https://ntfy.sh/${NTFY_TOPIC}" || true
    else
        log "(ntfy skipped — MESA_NTFY_TOPIC not set)"
    fi
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "must be run as root"
        exit 1
    fi
}

# --- main ---

require_root

# Idempotent: if already mounted, nothing to do
if mountpoint -q "${FORGE_MOUNT}"; then
    log "/forge is already mounted — nothing to do"
    exit 0
fi

# Open LUKS volume if not already open
if [[ ! -e "/dev/mapper/${FORGE_MAPPER}" ]]; then
    log "Opening LUKS volume ${FORGE_IMG} ..."
    cryptsetup luksOpen "${FORGE_IMG}" "${FORGE_MAPPER}"
else
    log "/dev/mapper/${FORGE_MAPPER} already open"
fi

# Mount
log "Mounting /dev/mapper/${FORGE_MAPPER} at ${FORGE_MOUNT} ..."
mount "/dev/mapper/${FORGE_MAPPER}" "${FORGE_MOUNT}"

# Verify mount succeeded
if ! mountpoint -q "${FORGE_MOUNT}"; then
    err "mount failed — /forge is not a mountpoint after mount attempt"
    exit 1
fi

log "/forge mounted successfully"

# Start ordered stacks first
for stack_name in "${ORDERED_STACKS[@]}"; do
    compose_file="${STACKS_DIR}/${stack_name}/docker-compose.yml"
    if [[ -f "${compose_file}" ]]; then
        log "Starting stack (ordered): ${stack_name}"
        docker compose -f "${compose_file}" up -d
    else
        log "Ordered stack not found, skipping: ${stack_name}"
    fi
done

# Start all remaining stacks (skip already-started ordered ones)
declare -A started_stacks
for s in "${ORDERED_STACKS[@]}"; do started_stacks["${s}"]=1; done

for compose_file in "${STACKS_DIR}"/*/docker-compose.yml; do
    [[ -f "${compose_file}" ]] || continue
    stack_dir="$(dirname "${compose_file}")"
    stack_name="$(basename "${stack_dir}")"
    if [[ -z "${started_stacks[${stack_name}]+_}" ]]; then
        log "Starting stack: ${stack_name}"
        docker compose -f "${compose_file}" up -d
    fi
done

# Notify
ntfy_send "forge unlocked, stacks online"

# Summary
log "Done. Running containers:"
docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Image}}"
