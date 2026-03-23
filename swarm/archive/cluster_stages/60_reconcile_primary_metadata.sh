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

LOCAL_CLUSTER_NODE_NAME=$(ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C pvecm nodes | awk '\$4 == \"(local)\" {print \$3; exit}'")
if [[ -n "$LOCAL_CLUSTER_NODE_NAME" && "$LOCAL_CLUSTER_NODE_NAME" != "$DESIRED_PRIMARY_HOSTNAME" ]]; then
  log "Reconciling primary cluster node name from '$LOCAL_CLUSTER_NODE_NAME' to '$DESIRED_PRIMARY_HOSTNAME'"
  ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C set -euo pipefail; \
    old_name='$LOCAL_CLUSTER_NODE_NAME'; new_name='$DESIRED_PRIMARY_HOSTNAME'; \
    ts=\$(date +%s); \
    cp /etc/pve/corosync.conf /etc/pve/corosync.conf.bak.\$ts; \
    sed -i \"s/name: \$old_name/name: \$new_name/g\" /etc/pve/corosync.conf; \
    awk '{if(\$1==\"config_version:\"){print \"  config_version: \" \$2+1}else{print}}' /etc/pve/corosync.conf > /etc/pve/corosync.conf.tmp; \
    mv /etc/pve/corosync.conf.tmp /etc/pve/corosync.conf; \
    if [[ -d /etc/pve/nodes/\$old_name && ! -d /etc/pve/nodes/\$new_name ]]; then mv /etc/pve/nodes/\$old_name /etc/pve/nodes/\$new_name; fi; \
    pvecm updatecerts --force >/dev/null 2>&1 || true"
fi

EXPECTED_NODE_NAMES_CSV=$(IFS=,; echo "${EXPECTED_NODE_NAMES[*]}")
ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C bash -s -- '$DESIRED_PRIMARY_HOSTNAME' '$EXPECTED_NODE_NAMES_CSV'" <<'EOF'
set -euo pipefail
primary_name="$1"
expected_csv="$2"
IFS=',' read -r -a expected_names <<< "$expected_csv"

is_expected() {
  local candidate="$1"
  for n in "${expected_names[@]}"; do
    if [[ "$n" == "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

mkdir -p "/etc/pve/nodes/$primary_name/qemu-server" "/etc/pve/nodes/$primary_name/lxc"
backup_root="/root/pve-stale-node-backup-$(date +%s)"
mkdir -p "$backup_root"

for dir in /etc/pve/nodes/*; do
  [[ -d "$dir" ]] || continue
  node_name="$(basename "$dir")"

  if is_expected "$node_name"; then
    continue
  fi

  cp -a "$dir" "$backup_root/" 2>/dev/null || true

  if ls "$dir"/qemu-server/*.conf >/dev/null 2>&1; then
    mv -f "$dir"/qemu-server/*.conf "/etc/pve/nodes/$primary_name/qemu-server/"
  fi
  if ls "$dir"/lxc/*.conf >/dev/null 2>&1; then
    mv -f "$dir"/lxc/*.conf "/etc/pve/nodes/$primary_name/lxc/"
  fi

  for f in lrm_status openvz pve-ssl.key pve-ssl.pem ssh_known_hosts; do
    if [[ -e "$dir/$f" && ! -e "/etc/pve/nodes/$primary_name/$f" ]]; then
      mv "$dir/$f" "/etc/pve/nodes/$primary_name/$f"
    fi
  done
  if [[ -d "$dir/priv" && ! -d "/etc/pve/nodes/$primary_name/priv" ]]; then
    mv "$dir/priv" "/etc/pve/nodes/$primary_name/priv"
  fi

  rm -rf "$dir"
done
EOF

until ssh_node -n "${LAB_SSH_USER}@$FIRST_NODE_ACCESS_ADDRESS" "LC_ALL=C LANG=C pvecm status | grep 'Quorate'"; do
  log "Waiting for the first node to be ready..."
  sleep 5
done
