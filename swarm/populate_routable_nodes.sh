#!/bin/bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

if [[ "$#" -lt 1 || "$#" -gt 3 ]]; then
  die "usage: $0 <config_file> [proxmox_host] [proxmox_node]"
fi

CONFIG_FILE="$1"
PROXMOX_HOST="${2:-192.168.216.221}"
PROXMOX_NODE="${3:-pve-4}"

[[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"
command -v yq >/dev/null 2>&1 || die "yq is required"

CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"

PROXMOX_SECRETS_PATH="$(yq e -r '.swarm.secrets.proxmox // "./proxmox.secrets"' "$CONFIG_FILE")"
if [[ "$PROXMOX_SECRETS_PATH" != /* ]]; then
  PROXMOX_SECRETS_PATH="$CONFIG_DIR/$PROXMOX_SECRETS_PATH"
fi
[[ -f "$PROXMOX_SECRETS_PATH" ]] || die "proxmox secrets file not found: $PROXMOX_SECRETS_PATH"

PROXMOX_SECRETS_LINE="$(head -n 1 "$PROXMOX_SECRETS_PATH" | tr -d '\r')"
[[ "$PROXMOX_SECRETS_LINE" == *:* ]] || die "invalid proxmox secrets format in $PROXMOX_SECRETS_PATH (expected user:password)"
PROXMOX_SSH_USER="${PROXMOX_SECRETS_LINE%%:*}"
PROXMOX_SSH_PASS="${PROXMOX_SECRETS_LINE#*:}"
[[ -n "$PROXMOX_SSH_USER" && -n "$PROXMOX_SSH_PASS" ]] || die "invalid proxmox secrets format in $PROXMOX_SECRETS_PATH (empty user/password)"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

remote_proxmox() {
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$PROXMOX_SSH_PASS" ssh -n "${SSH_OPTS[@]}" "${PROXMOX_SSH_USER}@${PROXMOX_HOST}" "$1"
  else
    ssh -n "${SSH_OPTS[@]}" "${PROXMOX_SSH_USER}@${PROXMOX_HOST}" "$1"
  fi
}

mapfile -t CLUSTER_NODE_ADDRESSES < <(yq e -r '.swarm.nodes[]' "$CONFIG_FILE")
[[ "${#CLUSTER_NODE_ADDRESSES[@]}" -gt 0 ]] || die "missing swarm.nodes[]"

ROUTABLE_NODE_ADDRESSES=()

log "Discovering management IPs from VMIDs via ${PROXMOX_HOST}/${PROXMOX_NODE}"
for cluster_ip in "${CLUSTER_NODE_ADDRESSES[@]}"; do
  IFS='.' read -r _ _ o3 o4 <<< "$cluster_ip"
  [[ -n "$o3" && -n "$o4" ]] || die "invalid cluster IP in swarm.nodes: $cluster_ip"

  vmid="${o3}${o4}"

  vm_node="$(remote_proxmox "LC_ALL=C LANG=C pvesh get /cluster/resources --type vm --output-format json" | yq e -r ".[] | select(.vmid == ${vmid}) | .node" - | head -n 1)"
  [[ -n "$vm_node" && "$vm_node" != "null" ]] || die "cannot determine hosting node for VMID ${vmid}"

  interfaces_json="$(remote_proxmox "LC_ALL=C LANG=C pvesh get /nodes/${vm_node}/qemu/${vmid}/agent/network-get-interfaces --output-format json")" \
    || die "cannot query guest-agent interfaces for VMID ${vmid} on node ${vm_node}"

  mgmt_ip="$(printf '%s\n' "$interfaces_json" | yq e -r '.result[]? | select(.name != "lo" and (.name | test("^vmbr") | not)) | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' - | grep -vE '^127\.|^169\.254\.' | grep -v "^${cluster_ip}$" | head -n 1)"

  [[ -n "$mgmt_ip" ]] || die "could not find management IPv4 for VMID ${vmid} (cluster ip ${cluster_ip})"

  ROUTABLE_NODE_ADDRESSES+=("$mgmt_ip")
  log "VMID ${vmid}: cluster=${cluster_ip} routable=${mgmt_ip}"
done

if [[ "$(printf '%s\n' "${ROUTABLE_NODE_ADDRESSES[@]}" | sort | uniq | wc -l)" -ne "${#ROUTABLE_NODE_ADDRESSES[@]}" ]]; then
  die "duplicate routable IPs discovered: ${ROUTABLE_NODE_ADDRESSES[*]}"
fi

log "Writing swarm.routable_nodes to ${CONFIG_FILE}"
yq e -i '.swarm.routable_nodes = []' "$CONFIG_FILE"
for ip in "${ROUTABLE_NODE_ADDRESSES[@]}"; do
  yq e -i ".swarm.routable_nodes += [\"${ip}\"]" "$CONFIG_FILE"
done

log "Updated routable_nodes:"
yq e -r '.swarm.routable_nodes[]' "$CONFIG_FILE"
