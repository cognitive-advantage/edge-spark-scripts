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
PROXMOX_DISCOVERY_HOST="${PROXMOX_DISCOVERY_HOST:-192.168.216.221}"
PROXMOX_DISCOVERY_NODE="${PROXMOX_DISCOVERY_NODE:-pve-4}"

discover_node_access_address() {
  local vmid="$1"
  local cluster_ip="$2"
  local vm_node
  local interfaces_json

  vm_node=$(sshpass -p "$PROXMOX_SSH_PASS" "$SSH_BIN" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${PROXMOX_SSH_USER}@${PROXMOX_DISCOVERY_HOST}" \
    "LC_ALL=C LANG=C pvesh get /cluster/resources --type vm --output-format json" | yq e -r ".[] | select(.vmid == ${vmid}) | .node" - | head -n 1)
  [[ -n "$vm_node" && "$vm_node" != "null" ]] || die "cannot determine hosting node for VMID ${vmid} via ${PROXMOX_DISCOVERY_HOST}"

  interfaces_json=$(sshpass -p "$PROXMOX_SSH_PASS" "$SSH_BIN" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${PROXMOX_SSH_USER}@${PROXMOX_DISCOVERY_HOST}" \
    "LC_ALL=C LANG=C pvesh get /nodes/${vm_node}/qemu/${vmid}/agent/network-get-interfaces --output-format json") \
    || die "cannot query guest-agent interfaces for VMID ${vmid} via ${PROXMOX_DISCOVERY_HOST}/${vm_node}"

  mapfile -t candidate_ips < <(printf '%s\n' "$interfaces_json" | yq e -r '.result[]? | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' - | grep -vE '^127\.|^169\.254\.' | grep -v "^${cluster_ip}$" | sort -u)
  [[ "${#candidate_ips[@]}" -gt 0 ]] || die "no management IPv4 candidates found for VMID ${vmid}"

  for ip in "${candidate_ips[@]}"; do
    if sshpass -p "$LAB_SSH_PASS" "$SSH_BIN" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -n "${LAB_SSH_USER}@${ip}" true >/dev/null 2>&1; then
      echo "$ip"
      return 0
    fi
  done

  die "could not find reachable management IP for VMID ${vmid}; candidates: ${candidate_ips[*]}"
}

declare -A CLUSTER_IP_BY_NODE_ADDRESS=()

if [[ "${#NODE_ADDRESSES[@]}" -eq 0 ]]; then
  log "Resolving management IPs from VMIDs via Proxmox guest-agent"
  for i in "${!NODE_VMIDS[@]}"; do
    vmid="${NODE_VMIDS[$i]}"
    cluster_ip="${CLUSTER_NODE_ADDRESSES[$i]}"
    mgmt_ip="$(discover_node_access_address "$vmid" "$cluster_ip")"
    NODE_ADDRESSES+=("$mgmt_ip")
    CLUSTER_IP_BY_NODE_ADDRESS["$mgmt_ip"]="$cluster_ip"
    log "Resolved VMID ${vmid}: cluster=${cluster_ip} management=${mgmt_ip}"
  done
fi

for i in "${!NODE_ADDRESSES[@]}"; do
  CLUSTER_IP_BY_NODE_ADDRESS["${NODE_ADDRESSES[$i]}"]="${CLUSTER_NODE_ADDRESSES[$i]}"
done

FIRST_NODE_CLUSTER_ADDRESS="${CLUSTER_NODE_ADDRESSES[0]}"
FIRST_NODE_ACCESS_ADDRESS="${NODE_ADDRESSES[0]}"
if [[ -n "${FIRST_NODE_ACCESS_OVERRIDE:-}" ]]; then
  FIRST_NODE_ACCESS_ADDRESS="$FIRST_NODE_ACCESS_OVERRIDE"
  NODE_ADDRESSES[0]="$FIRST_NODE_ACCESS_OVERRIDE"
fi
JOIN_NODE_ADDRESSES=("${NODE_ADDRESSES[@]:1}")
DESIRED_PRIMARY_HOSTNAME="${CLUSTER_NAME}-${NODE_KEYS[0]}"
PRIMARY_HOSTNAME_BEFORE_RENAME=""

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
