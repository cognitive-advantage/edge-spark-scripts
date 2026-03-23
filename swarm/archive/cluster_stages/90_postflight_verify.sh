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

wait_for_management_ready() {
  local node_address="$1"
  local expected_hostname="$2"
  local retries=30
  local sleep_seconds=5

  while (( retries > 0 )); do
    if ssh_node -n "${LAB_SSH_USER}@$node_address" "LC_ALL=C LANG=C test \"\$(hostname -s)\" = \"$expected_hostname\" && for svc in pve-cluster pvedaemon pveproxy pvestatd; do systemctl is-active --quiet \"\$svc\" || exit 1; done"; then
      return 0
    fi

    retries=$((retries - 1))
    sleep "$sleep_seconds"
  done

  die "node $node_address did not become ready as '$expected_hostname' after rename/service restart"
}

log "Refreshing Proxmox management services"
# shellcheck disable=SC2153
for i in "${!NODE_ADDRESSES[@]}"; do
  NODE_ADDRESS="${NODE_ADDRESSES[$i]}"
  EXPECTED_HOSTNAME="${EXPECTED_NODE_NAMES[$i]}"
  ssh_node -n "${LAB_SSH_USER}@$NODE_ADDRESS" "LC_ALL=C LANG=C systemctl restart pvestatd pvedaemon pveproxy"
  wait_for_management_ready "$NODE_ADDRESS" "$EXPECTED_HOSTNAME"
done

log "Postflight: validating core services on all configured nodes"
for NODE_ADDRESS in "${NODE_ADDRESSES[@]}"; do
  ssh_node -n "${LAB_SSH_USER}@$NODE_ADDRESS" "LC_ALL=C LANG=C systemctl is-active corosync pve-cluster pvedaemon pveproxy >/dev/null" \
    || die "one or more required services are not active on $NODE_ADDRESS"
done

EXPECTED_NODE_COUNT="${#NODE_ADDRESSES[@]}"
ACTUAL_NODE_COUNT=$(ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C pvecm status | awk -F': *' '/^Nodes:/{print \$2; exit}'")
if [[ "$ACTUAL_NODE_COUNT" -ne "$EXPECTED_NODE_COUNT" ]]; then
  die "cluster node count mismatch (expected $EXPECTED_NODE_COUNT, got $ACTUAL_NODE_COUNT)"
fi

log "Cluster converge complete. Membership summary:"
ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C pvecm nodes"

mapfile -t EXPECTED_NODE_NAMES_SORTED < <(printf '%s\n' "${EXPECTED_NODE_NAMES[@]}" | sort)
mapfile -t ACTUAL_NODE_NAMES_SORTED < <(ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C pvecm nodes | awk '\$1 ~ /^[0-9]+$/ {print \$3}'" | sort)

if [[ "${EXPECTED_NODE_NAMES_SORTED[*]}" != "${ACTUAL_NODE_NAMES_SORTED[*]}" ]]; then
  echo "Expected node names: ${EXPECTED_NODE_NAMES_SORTED[*]}" >&2
  echo "Actual node names:   ${ACTUAL_NODE_NAMES_SORTED[*]}" >&2
  die "cluster membership names do not match config after reconciliation"
fi
