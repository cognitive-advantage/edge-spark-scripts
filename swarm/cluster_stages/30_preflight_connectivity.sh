#!/bin/bash
set -euo pipefail

die() {
  echo "Error: $*" >&2
  exit 1
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [[ "$#" -ne 1 ]]; then
  die "usage: $0 <state_file>"
fi

STATE_FILE="$1"
[[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE"

# shellcheck source=/dev/null
source "$STATE_FILE"

SSH_BIN="$(command -v ssh)"

# shellcheck disable=SC2153
for NODE_ADDRESS in "${NODE_ADDRESSES[@]}"; do
  log "Preflight SSH check on ${LAB_SSH_USER}@${NODE_ADDRESS}"
  sshpass -p "$LAB_SSH_PASS" "$SSH_BIN" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=8 \
    -o BatchMode=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    -n "${LAB_SSH_USER}@${NODE_ADDRESS}" true \
    || die "cannot SSH to ${LAB_SSH_USER}@${NODE_ADDRESS}; verify password auth and network"

  sshpass -p "$LAB_SSH_PASS" "$SSH_BIN" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=8 \
    -o BatchMode=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    -n "${LAB_SSH_USER}@${NODE_ADDRESS}" \
    "command -v pvecm >/dev/null && command -v systemctl >/dev/null" \
    || die "required commands missing on ${NODE_ADDRESS}"
done
