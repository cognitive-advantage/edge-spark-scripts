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

PENDING_JOIN_NODE_ADDRESSES=()
for NODE_ADDRESS in "${JOIN_NODE_ADDRESSES[@]}"; do
  NODE_CLUSTER_NAME=$(ssh_node -n "${LAB_SSH_USER}@$NODE_ADDRESS" "LC_ALL=C LANG=C pvecm status 2>/dev/null | awk -F': *' '/^Name:/{print \$2; exit}'" || true)
  if [[ -n "$NODE_CLUSTER_NAME" ]]; then
    if [[ "$NODE_CLUSTER_NAME" == "$CLUSTER_NAME" ]]; then
      echo "Node $NODE_ADDRESS is already in cluster '$CLUSTER_NAME'; skipping."
      continue
    fi

    die "node $NODE_ADDRESS already belongs to cluster '$NODE_CLUSTER_NAME', expected '$CLUSTER_NAME'"
  fi

  PENDING_JOIN_NODE_ADDRESSES+=("$NODE_ADDRESS")
done

if [[ "${#PENDING_JOIN_NODE_ADDRESSES[@]}" -eq 0 ]]; then
  log "All configured nodes are already in cluster '$CLUSTER_NAME'."
else
  for NODE_ADDRESS in "${PENDING_JOIN_NODE_ADDRESSES[@]}"; do
    log "Cleaning node $NODE_ADDRESS before join"
    # shellcheck disable=SC2016
    ssh_node -n "${LAB_SSH_USER}@$NODE_ADDRESS" '
      export LC_ALL=C LANG=C
      current_node="$(hostname -s)"

      for vmid in $(qm list | awk "NR>1 {print $1}"); do
        qm stop "$vmid" --timeout 60 >/dev/null 2>&1 || true
        qm destroy "$vmid" --purge 1
      done

      for ctid in $(pct list | awk "NR>1 {print $1}"); do
        pct shutdown "$ctid" --timeout 60 >/dev/null 2>&1 || true
        pct stop "$ctid" >/dev/null 2>&1 || true
        pct destroy "$ctid" --purge 1
      done

      for node_dir in /etc/pve/nodes/*; do
        [[ -d "$node_dir" ]] || continue
        node_name="$(basename "$node_dir")"
        if [[ "$node_name" == "$current_node" ]]; then
          continue
        fi

        rm -f "$node_dir"/qemu-server/*.conf >/dev/null 2>&1 || true
        rm -f "$node_dir"/lxc/*.conf >/dev/null 2>&1 || true
      done

      remaining_qm="$(qm list | awk "NR>1 {print $1}")"
      remaining_pct="$(pct list | awk "NR>1 {print $1}")"
      if [[ -n "$remaining_qm" || -n "$remaining_pct" ]]; then
        echo "Remaining guests after cleanup on $current_node:" >&2
        [[ -n "$remaining_qm" ]] && echo "VMs: $remaining_qm" >&2
        [[ -n "$remaining_pct" ]] && echo "CTs: $remaining_pct" >&2
        exit 1
      fi
    '
  done
fi

# shellcheck disable=SC2153
{
  declare -p CONFIG_FILE
  declare -p FIRST_NODE_ACCESS_OVERRIDE
  declare -p CONFIG_DIR
  declare -p CLUSTER_NAME
  declare -p CLUSTER_NODE_ADDRESSES
  declare -p NODE_KEYS
  declare -p EXPECTED_NODE_NAMES
  declare -p NODE_VMIDS
  declare -p NODE_ADDRESSES
  declare -p ROUTABLE_NODE_ADDRESSES
  declare -p LAB_SECRETS_PATH
  declare -p LAB_SSH_USER
  declare -p LAB_SSH_PASS
  declare -p PROXMOX_SECRETS_PATH
  declare -p PROXMOX_SSH_USER
  declare -p PROXMOX_SSH_PASS
  declare -p PROXMOX_DISCOVERY_HOST
  declare -p PROXMOX_DISCOVERY_NODE
  declare -p CLUSTER_IP_BY_NODE_ADDRESS
  declare -p FIRST_NODE_CLUSTER_ADDRESS
  declare -p FIRST_NODE_ACCESS_ADDRESS
  declare -p JOIN_NODE_ADDRESSES
  declare -p DESIRED_PRIMARY_HOSTNAME
  declare -p PRIMARY_HOSTNAME_BEFORE_RENAME
  declare -p PENDING_JOIN_NODE_ADDRESSES
} > "$STATE_FILE"
