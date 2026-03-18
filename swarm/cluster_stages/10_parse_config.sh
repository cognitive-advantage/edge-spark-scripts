#!/bin/bash
set -euo pipefail

die() {
  echo "Error: $*" >&2
  exit 1
}

if [[ "$#" -ne 1 ]]; then
  die "usage: $0 <state_file>"
fi

STATE_FILE="$1"
[[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE"

# shellcheck source=/dev/null
source "$STATE_FILE"

[[ -n "${CONFIG_FILE:-}" ]] || die "CONFIG_FILE missing in state"

CLUSTER_NAME=$(yq e -r '.swarm.name' "$CONFIG_FILE")
mapfile -t CLUSTER_NODE_ADDRESSES < <(yq e -r '.swarm.nodes[]' "$CONFIG_FILE")

NODE_KEYS=()
EXPECTED_NODE_NAMES=()
NODE_VMIDS=()
NODE_ADDRESSES=()
ROUTABLE_NODE_ADDRESSES=()

if [[ -z "$CLUSTER_NAME" || "$CLUSTER_NAME" == "null" ]]; then
  die "missing swarm.name in config file: $CONFIG_FILE"
fi

if [[ "${#CLUSTER_NODE_ADDRESSES[@]}" -lt 2 ]]; then
  die "config must define at least two swarm.nodes[] addresses"
fi

for address in "${CLUSTER_NODE_ADDRESSES[@]}"; do
  if [[ -z "$address" || "$address" == "null" ]]; then
    die "one or more swarm node addresses are missing in $CONFIG_FILE"
  fi

  IFS='.' read -r _ _ o3 o4 <<< "$address"
  if [[ -z "$o3" || -z "$o4" ]]; then
    die "invalid node address '$address' in $CONFIG_FILE"
  fi

  vmid="${o3}${o4}"
  node_key="${o3}-${o4}"
  NODE_KEYS+=("$node_key")
  NODE_VMIDS+=("$vmid")
  EXPECTED_NODE_NAMES+=("${CLUSTER_NAME}-${node_key}")
done

if [[ "$(printf '%s\n' "${CLUSTER_NODE_ADDRESSES[@]}" | sort | uniq | wc -l)" -ne "${#CLUSTER_NODE_ADDRESSES[@]}" ]]; then
  die "duplicate node addresses detected in config"
fi

mapfile -t ROUTABLE_NODE_ADDRESSES < <(yq e -r '.swarm.routable_nodes[]?' "$CONFIG_FILE")
if [[ "${#ROUTABLE_NODE_ADDRESSES[@]}" -gt 0 ]]; then
  if [[ "${#ROUTABLE_NODE_ADDRESSES[@]}" -ne "${#CLUSTER_NODE_ADDRESSES[@]}" ]]; then
    die "swarm.routable_nodes count (${#ROUTABLE_NODE_ADDRESSES[@]}) must match swarm.nodes count (${#CLUSTER_NODE_ADDRESSES[@]})"
  fi

  if [[ "$(printf '%s\n' "${ROUTABLE_NODE_ADDRESSES[@]}" | sort | uniq | wc -l)" -ne "${#ROUTABLE_NODE_ADDRESSES[@]}" ]]; then
    die "duplicate IPs detected in swarm.routable_nodes"
  fi

  NODE_ADDRESSES=("${ROUTABLE_NODE_ADDRESSES[@]}")
fi

CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"

LAB_SECRETS_PATH=$(yq e -r '.swarm.secrets.lab // "./lab.secrets"' "$CONFIG_FILE")
if [[ "$LAB_SECRETS_PATH" != /* ]]; then
  LAB_SECRETS_PATH="$CONFIG_DIR/$LAB_SECRETS_PATH"
fi
[[ -f "$LAB_SECRETS_PATH" ]] || die "lab secrets file not found: $LAB_SECRETS_PATH"

LAB_SECRETS_LINE="$(head -n 1 "$LAB_SECRETS_PATH" | tr -d '\r')"
[[ "$LAB_SECRETS_LINE" == *:* ]] || die "invalid lab secrets format in $LAB_SECRETS_PATH (expected user:password)"
LAB_SSH_USER="${LAB_SECRETS_LINE%%:*}"
LAB_SSH_PASS="${LAB_SECRETS_LINE#*:}"
[[ -n "$LAB_SSH_USER" && -n "$LAB_SSH_PASS" ]] || die "invalid lab secrets format in $LAB_SECRETS_PATH (empty user/password)"

PROXMOX_SECRETS_PATH=$(yq e -r '.swarm.secrets.proxmox // "./proxmox.secrets"' "$CONFIG_FILE")
if [[ "$PROXMOX_SECRETS_PATH" != /* ]]; then
  PROXMOX_SECRETS_PATH="$CONFIG_DIR/$PROXMOX_SECRETS_PATH"
fi
[[ -f "$PROXMOX_SECRETS_PATH" ]] || die "proxmox secrets file not found: $PROXMOX_SECRETS_PATH"

PROXMOX_SECRETS_LINE="$(head -n 1 "$PROXMOX_SECRETS_PATH" | tr -d '\r')"
[[ "$PROXMOX_SECRETS_LINE" == *:* ]] || die "invalid proxmox secrets format in $PROXMOX_SECRETS_PATH (expected user:password)"
PROXMOX_SSH_USER="${PROXMOX_SECRETS_LINE%%:*}"
PROXMOX_SSH_PASS="${PROXMOX_SECRETS_LINE#*:}"
[[ -n "$PROXMOX_SSH_USER" && -n "$PROXMOX_SSH_PASS" ]] || die "invalid proxmox secrets format in $PROXMOX_SECRETS_PATH (empty user/password)"

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
} > "$STATE_FILE"
