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

log "Pre-create: reconciling primary VM/template paths"
ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C bash -s -- '$DESIRED_PRIMARY_HOSTNAME' '$PRIMARY_HOSTNAME_BEFORE_RENAME'" <<'EOF'
set -euo pipefail
primary_name="$1"
legacy_primary_name="$2"

mkdir -p "/etc/pve/nodes/$primary_name/qemu-server" "/etc/pve/nodes/$primary_name/lxc"

if [[ -n "$legacy_primary_name" && "$legacy_primary_name" != "$primary_name" && -d "/etc/pve/nodes/$legacy_primary_name" ]]; then
  if ls "/etc/pve/nodes/$legacy_primary_name"/qemu-server/*.conf >/dev/null 2>&1; then
    mv -f "/etc/pve/nodes/$legacy_primary_name"/qemu-server/*.conf "/etc/pve/nodes/$primary_name/qemu-server/"
  fi
  if ls "/etc/pve/nodes/$legacy_primary_name"/lxc/*.conf >/dev/null 2>&1; then
    mv -f "/etc/pve/nodes/$legacy_primary_name"/lxc/*.conf "/etc/pve/nodes/$primary_name/lxc/"
  fi
fi
EOF

log "Pre-create: verifying primary node readiness"
wait_for_management_ready "$FIRST_NODE_ACCESS_ADDRESS" "$DESIRED_PRIMARY_HOSTNAME"

echo "Cluster Name: $CLUSTER_NAME"
echo "First Node Address: $FIRST_NODE_ACCESS_ADDRESS"
echo "Nodes to Join:"
for NODE_ADDRESS in "${JOIN_NODE_ADDRESSES[@]}"; do
  echo "  - $NODE_ADDRESS"
done

EXISTING_CLUSTER_NAME=$(ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C pvecm status 2>/dev/null | awk -F': *' '/^Name:/{print \$2; exit}'" || true)

if [[ -n "$EXISTING_CLUSTER_NAME" ]]; then
  if [[ "$EXISTING_CLUSTER_NAME" == "$CLUSTER_NAME" ]]; then
    echo "Cluster '$CLUSTER_NAME' already exists on $FIRST_NODE_ACCESS_ADDRESS; continuing from join steps."
  else
    die "first node already belongs to cluster '$EXISTING_CLUSTER_NAME', expected '$CLUSTER_NAME'"
  fi
else
  log "Creating cluster '$CLUSTER_NAME' on $FIRST_NODE_ACCESS_ADDRESS"
  create_attempts=12
  create_sleep_seconds=5
  create_ok=0
  while (( create_attempts > 0 )); do
    if ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C pvecm create $CLUSTER_NAME --link0 address=$FIRST_NODE_CLUSTER_ADDRESS"; then
      create_ok=1
      break
    fi

    create_attempts=$((create_attempts - 1))
    if (( create_attempts == 0 )); then
      break
    fi

    log "Cluster create not ready yet on $FIRST_NODE_ACCESS_ADDRESS, retrying in ${create_sleep_seconds}s"
    sleep "$create_sleep_seconds"
  done

  (( create_ok == 1 )) || die "failed to create cluster '$CLUSTER_NAME' on $FIRST_NODE_ACCESS_ADDRESS after retries"
fi
