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

PRIMARY_HOSTNAME_BEFORE_RENAME=""

log "Normalizing hostnames"
# shellcheck disable=SC2153
for i in "${!NODE_ADDRESSES[@]}"; do
  NODE_ADDRESS="${NODE_ADDRESSES[$i]}"
  NODE_CLUSTER_ADDRESS="${CLUSTER_NODE_ADDRESSES[$i]}"
  DESIRED_HOSTNAME="${CLUSTER_NAME}-${NODE_KEYS[$i]}"
  CURRENT_HOSTNAME=$(ssh_node -n "${LAB_SSH_USER}@$NODE_ADDRESS" "LC_ALL=C LANG=C hostname -s")

  if [[ "$i" -eq 0 ]]; then
    PRIMARY_HOSTNAME_BEFORE_RENAME="$CURRENT_HOSTNAME"
  fi

  if [[ "$CURRENT_HOSTNAME" != "$DESIRED_HOSTNAME" ]]; then
    echo "Renaming $NODE_ADDRESS hostname from '$CURRENT_HOSTNAME' to '$DESIRED_HOSTNAME'."
    ssh_node -n "${LAB_SSH_USER}@$NODE_ADDRESS" "LC_ALL=C LANG=C hostnamectl set-hostname '$DESIRED_HOSTNAME'"
  fi

  ssh_node -n "${LAB_SSH_USER}@$NODE_ADDRESS" "LC_ALL=C LANG=C tmp_hosts=\$(mktemp) && grep -vE '[[:space:]]$DESIRED_HOSTNAME([[:space:]]|$)' /etc/hosts > \$tmp_hosts && echo '$NODE_CLUSTER_ADDRESS $DESIRED_HOSTNAME' >> \$tmp_hosts && cat \$tmp_hosts > /etc/hosts && rm -f \$tmp_hosts"
  ssh_node -n "${LAB_SSH_USER}@$NODE_ADDRESS" "LC_ALL=C LANG=C systemctl restart pve-cluster pvestatd"

  VERIFIED_HOSTNAME=$(ssh_node -n "${LAB_SSH_USER}@$NODE_ADDRESS" "LC_ALL=C LANG=C hostname -s")
  if [[ "$VERIFIED_HOSTNAME" != "$DESIRED_HOSTNAME" ]]; then
    die "hostname verification failed on $NODE_ADDRESS (expected $DESIRED_HOSTNAME, got $VERIFIED_HOSTNAME)"
  fi

  wait_for_management_ready "$NODE_ADDRESS" "$DESIRED_HOSTNAME"
done

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
} > "$STATE_FILE"
