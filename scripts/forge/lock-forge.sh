#!/usr/bin/env bash
set -euo pipefail

# lock-forge.sh — stop docker stacks, unmount /forge, close LUKS volume
# Install to /usr/local/bin/lock-forge.sh

FORGE_MAPPER="forge"
FORGE_MOUNT="/forge"
STACKS_DIR="${FORGE_MOUNT}/stacks"
NTFY_TOPIC="${MESA_NTFY_TOPIC:-}"

# How long to wait for containers to stop before giving up (seconds)
CONTAINER_STOP_TIMEOUT=60

# --- helpers ---

log() { echo "[lock-forge] $*"; }
err() { echo "[lock-forge] ERROR: $*" >&2; }

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

wait_for_containers_stop() {
    local elapsed=0
    local interval=3
    log "Waiting for all containers to stop (timeout ${CONTAINER_STOP_TIMEOUT}s) ..."
    while [[ "${elapsed}" -lt "${CONTAINER_STOP_TIMEOUT}" ]]; do
        local running
        running="$(docker ps -q 2>/dev/null | wc -l)"
        if [[ "${running}" -eq 0 ]]; then
            log "All containers stopped"
            return 0
        fi
        log "  ${running} container(s) still running, waiting ..."
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
    done
    err "Timed out waiting for containers to stop. Remaining:"
    docker ps --format "  {{.Names}}\t{{.Status}}" >&2
    return 1
}

# --- main ---

require_root

# Stop all stacks
if mountpoint -q "${FORGE_MOUNT}"; then
    if [[ -d "${STACKS_DIR}" ]]; then
        for compose_file in "${STACKS_DIR}"/*/docker-compose.yml; do
            [[ -f "${compose_file}" ]] || continue
            stack_name="$(basename "$(dirname "${compose_file}")")"
            log "Stopping stack: ${stack_name}"
            docker compose -f "${compose_file}" down || {
                err "docker compose down failed for ${stack_name} — continuing"
            }
        done
    else
        log "No stacks directory found at ${STACKS_DIR}, skipping stack teardown"
    fi
else
    log "/forge is not mounted — skipping stack teardown"
fi

# Wait for all containers to stop
wait_for_containers_stop

# Unmount
if mountpoint -q "${FORGE_MOUNT}"; then
    log "Unmounting ${FORGE_MOUNT} ..."
    umount "${FORGE_MOUNT}"
else
    log "${FORGE_MOUNT} is not mounted — skipping umount"
fi

# Close LUKS
if [[ -e "/dev/mapper/${FORGE_MAPPER}" ]]; then
    log "Closing LUKS mapper ${FORGE_MAPPER} ..."
    cryptsetup luksClose "${FORGE_MAPPER}"
else
    log "/dev/mapper/${FORGE_MAPPER} is not open — skipping luksClose"
fi

# Notify
ntfy_send "forge locked"

log "Done — /forge is locked"
