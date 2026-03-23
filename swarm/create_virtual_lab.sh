#!/bin/bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: create_virtual_lab.sh <config_file>

Creates lab VMs from template using values from YAML.
EOF
}

if [[ "$#" -ne 1 ]]; then
  usage
  exit 1
fi

CONFIG_FILE="$1"
[[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"

command -v yq >/dev/null 2>&1 || die "yq is required"
command -v sshpass >/dev/null 2>&1 || die "sshpass is required"

CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"

CLUSTER_NAME="$(yq e -r '.swarm.name' "$CONFIG_FILE")"
PROXMOX_HOST="$(yq e -r '.swarm.lab_host[] | select(has("host")) | .host' "$CONFIG_FILE")"
PROXMOX_TARGET_NODE="$(yq e -r '.swarm.lab_host[] | select(has("host_node")) | .host_node' "$CONFIG_FILE")"
TEMPLATE_ID="$(yq e -r '.swarm.lab_host[] | select(has("template")) | .template' "$CONFIG_FILE")"
PROXMOX_SECRETS_PATH="$(yq e -r '.swarm.lab_host[] | select(has("secrets")) | .secrets' "$CONFIG_FILE")"
LAB_SECRETS_PATH="$(yq e -r '.swarm.lab_swarm.secrets' "$CONFIG_FILE")"

ROUTABLE_VLAN_TAG="$(yq e -r '.swarm.lab_host[] | select(has("vlan")) | .vlan[] | select(has("routable")) | .routable[] | select(has("tag")) | .tag' "$CONFIG_FILE")"
CLUSTER_VLAN_TAG="$(yq e -r '.swarm.lab_host[] | select(has("vlan")) | .vlan[] | select(has("cluster")) | .cluster[] | select(has("tag")) | .tag' "$CONFIG_FILE")"

mapfile -t CLUSTER_NODE_IPS < <(yq e -r '.swarm.lab_host[] | select(has("vlan")) | .vlan[] | select(has("cluster")) | .cluster[] | select(has("nodes")) | .nodes[]' "$CONFIG_FILE")

[[ -n "$CLUSTER_NAME" && "$CLUSTER_NAME" != "null" ]] || die "missing swarm.name"
[[ -n "$PROXMOX_HOST" && "$PROXMOX_HOST" != "null" ]] || die "missing swarm.lab_host[].host"
[[ -n "$PROXMOX_TARGET_NODE" && "$PROXMOX_TARGET_NODE" != "null" ]] || die "missing swarm.lab_host[].host_node"
[[ -n "$TEMPLATE_ID" && "$TEMPLATE_ID" != "null" ]] || die "missing swarm.lab_host[].template"
[[ -n "$ROUTABLE_VLAN_TAG" && "$ROUTABLE_VLAN_TAG" != "null" ]] || die "missing swarm.lab_host[].vlan[].routable[].tag"
[[ -n "$CLUSTER_VLAN_TAG" && "$CLUSTER_VLAN_TAG" != "null" ]] || die "missing swarm.lab_host[].vlan[].cluster[].tag"
[[ "${#CLUSTER_NODE_IPS[@]}" -gt 0 ]] || die "missing swarm.lab_host[].vlan[].cluster[].nodes[]"

[[ -n "$PROXMOX_SECRETS_PATH" && "$PROXMOX_SECRETS_PATH" != "null" ]] || die "missing swarm.lab_host[].secrets"
[[ -n "$LAB_SECRETS_PATH" && "$LAB_SECRETS_PATH" != "null" ]] || die "missing swarm.lab_swarm.secrets"

if [[ "$PROXMOX_SECRETS_PATH" != /* ]]; then
  PROXMOX_SECRETS_PATH="$CONFIG_DIR/$PROXMOX_SECRETS_PATH"
fi
if [[ "$LAB_SECRETS_PATH" != /* ]]; then
  LAB_SECRETS_PATH="$CONFIG_DIR/$LAB_SECRETS_PATH"
fi

[[ -f "$PROXMOX_SECRETS_PATH" ]] || die "proxmox secrets file not found: $PROXMOX_SECRETS_PATH"
[[ -f "$LAB_SECRETS_PATH" ]] || die "lab secrets file not found: $LAB_SECRETS_PATH"

PROXMOX_LINE="$(head -n 1 "$PROXMOX_SECRETS_PATH" | tr -d '\r')"
[[ "$PROXMOX_LINE" == *:* ]] || die "invalid proxmox secrets format in $PROXMOX_SECRETS_PATH (expected user:password)"
PROXMOX_USER="${PROXMOX_LINE%%:*}"
PROXMOX_PASS="${PROXMOX_LINE#*:}"

LAB_LINE="$(head -n 1 "$LAB_SECRETS_PATH" | tr -d '\r')"
[[ "$LAB_LINE" == *:* ]] || die "invalid lab secrets format in $LAB_SECRETS_PATH (expected user:password)"
LAB_USER="${LAB_LINE%%:*}"
LAB_PASS="${LAB_LINE#*:}"

[[ -n "$PROXMOX_USER" && -n "$PROXMOX_PASS" ]] || die "invalid proxmox secrets values"
[[ -n "$LAB_USER" && -n "$LAB_PASS" ]] || die "invalid lab secrets values"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=no -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no)

remote_ssh() {
  sshpass -p "$PROXMOX_PASS" ssh -n "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "LC_ALL=C LANG=C $*"
}

wait_for_guest_agent() {
  local vmid="$1"
  local retries=36
  while (( retries > 0 )); do
    if remote_ssh "pvesh create /nodes/${PROXMOX_TARGET_NODE}/qemu/${vmid}/agent/ping >/dev/null 2>&1"; then
      return 0
    fi
    retries=$((retries - 1))
    sleep 5
  done
  die "guest agent did not become ready for VM ${vmid}"
}

guest_exec() {
  :
}

log "Preflight checks on ${PROXMOX_HOST}/${PROXMOX_TARGET_NODE}"
remote_ssh "command -v qm >/dev/null" || die "qm command not found on ${PROXMOX_HOST}"
remote_ssh "command -v pvesh >/dev/null" || die "pvesh command not found on ${PROXMOX_HOST}"
remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/status >/dev/null 2>&1" || die "target node '${PROXMOX_TARGET_NODE}' not found"
remote_ssh "qm config ${TEMPLATE_ID} >/dev/null 2>&1" || die "template VM ${TEMPLATE_ID} not found"
remote_ssh "qm config ${TEMPLATE_ID} | grep -q '^template: 1'" || die "VM ${TEMPLATE_ID} is not a template"
remote_ssh "qm config ${TEMPLATE_ID} | grep -q '^ide2:.*cloudinit'" || die "template ${TEMPLATE_ID} must include cloud-init drive"

declare -A SEEN_VMIDS=()
for NODE_IP in "${CLUSTER_NODE_IPS[@]}"; do
  [[ "$NODE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "invalid node IP: $NODE_IP"
  IFS='.' read -r o1 o2 o3 o4 <<< "$NODE_IP"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    (( octet >= 0 && octet <= 255 )) || die "invalid node IP: $NODE_IP"
  done

  VMID="${o3}${o4}"
  if [[ -n "${SEEN_VMIDS[$VMID]:-}" ]]; then
    die "duplicate derived VMID ${VMID} from cluster node IPs"
  fi
  SEEN_VMIDS[$VMID]=1
done

for NODE_IP in "${CLUSTER_NODE_IPS[@]}"; do
  IFS='.' read -r _ _ o3 o4 <<< "$NODE_IP"
  VMID="${o3}${o4}"
  HOSTNAME="${CLUSTER_NAME}-${o3}-${o4}"

  NET0="virtio,bridge=vmbr0,tag=${ROUTABLE_VLAN_TAG}"
  NET1="virtio,bridge=vmbr0,tag=${CLUSTER_VLAN_TAG}"
  IPCONFIG0="ip=dhcp"
  IPCONFIG1="ip=${NODE_IP}/24"

  log "Provisioning ${HOSTNAME} (VMID ${VMID})"

  if remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/status/current >/dev/null 2>&1"; then
    EXISTING_NAME="$(remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/config --output-format json" | yq e -r '.name // ""' -)"
    if [[ -z "$EXISTING_NAME" ]]; then
      remote_ssh "qm set ${VMID} --name ${HOSTNAME}"
      EXISTING_NAME="$HOSTNAME"
    fi
    [[ "$EXISTING_NAME" == "$HOSTNAME" ]] || die "VMID ${VMID} already exists as '${EXISTING_NAME}', expected '${HOSTNAME}'"
    log "VM ${VMID} already exists as ${HOSTNAME}; ensuring config and identity"
  else
    remote_ssh "qm clone ${TEMPLATE_ID} ${VMID} --name ${HOSTNAME} --target ${PROXMOX_TARGET_NODE} --full 0"
  fi

  remote_ssh "pvesh set /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/config --net0 '${NET0}' --net1 '${NET1}'"
  remote_ssh "pvesh set /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/config --ipconfig0 '${IPCONFIG0}' --ipconfig1 '${IPCONFIG1}'"
  remote_ssh "pvesh set /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/config --onboot 1"

  STATUS_JSON="$(remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/status/current --output-format json")"
  VM_STATUS="$(printf '%s\n' "$STATUS_JSON" | yq e -r '.status // ""' -)"
  if [[ "$VM_STATUS" != "running" ]]; then
    remote_ssh "pvesh create /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/status/start"
  fi

  wait_for_guest_agent "$VMID"

  log "VM ${VMID} (${HOSTNAME}) ready for cluster stage"
done

log "Lab VM provisioning complete"