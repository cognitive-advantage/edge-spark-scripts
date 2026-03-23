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
ssh_node() {
  sshpass -p "$LAB_SSH_PASS" "$SSH_BIN" \
    -o BatchMode=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    "$@"
}

if [[ "${#PENDING_JOIN_NODE_ADDRESSES[@]}" -eq 0 ]]; then
  log "No pending nodes to join."
  exit 0
fi

for NODE_ADDRESS in "${PENDING_JOIN_NODE_ADDRESSES[@]}"; do
  log "Joining node $NODE_ADDRESS"
  JOIN_CLUSTER_ADDRESS="${CLUSTER_IP_BY_NODE_ADDRESS[$NODE_ADDRESS]:-}"
  if [[ -z "$JOIN_CLUSTER_ADDRESS" ]]; then
    die "missing cluster link address mapping for node $NODE_ADDRESS"
  fi

  PRE_NODE_COUNT=$(ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C pvecm status | awk -F': *' '/^Nodes:/{print \$2; exit}'")
  ssh_node -n "${LAB_SSH_USER}@$NODE_ADDRESS" "LC_ALL=C LANG=C pvecm add $FIRST_NODE_CLUSTER_ADDRESS --use_ssh 1 --force --link0 address=$JOIN_CLUSTER_ADDRESS"
  POST_NODE_COUNT=$(ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C pvecm status | awk -F': *' '/^Nodes:/{print \$2; exit}'")

  if [[ "$POST_NODE_COUNT" -le "$PRE_NODE_COUNT" ]]; then
    die "node $NODE_ADDRESS did not join cluster '$CLUSTER_NAME' (node count stayed at $POST_NODE_COUNT)"
  fi
done

until ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C pvecm status | grep 'Quorate'"; do
  log "Waiting for the cluster to be healthy..."
  sleep 5
done
