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

declare -A CLUSTER_IP_BY_NODE_ADDRESS=()

for i in "${!NODE_ADDRESSES[@]}"; do
  CLUSTER_IP_BY_NODE_ADDRESS["${NODE_ADDRESSES[$i]}"]="${CLUSTER_NODE_ADDRESSES[$i]}"
done

FIRST_NODE_CLUSTER_ADDRESS="${CLUSTER_NODE_ADDRESSES[0]}"
if [[ -n "${FIRST_NODE_ACCESS_OVERRIDE:-}" ]]; then
  NODE_ADDRESSES[0]="$FIRST_NODE_ACCESS_OVERRIDE"
fi
FIRST_NODE_ACCESS_ADDRESS="${NODE_ADDRESSES[0]}"
CLUSTER_IP_BY_NODE_ADDRESS["$FIRST_NODE_ACCESS_ADDRESS"]="$FIRST_NODE_CLUSTER_ADDRESS"

log "Using explicit swarm.routable_nodes management addresses"
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
  declare -p CLUSTER_IP_BY_NODE_ADDRESS
  declare -p FIRST_NODE_CLUSTER_ADDRESS
  declare -p FIRST_NODE_ACCESS_ADDRESS
  declare -p JOIN_NODE_ADDRESSES
  declare -p DESIRED_PRIMARY_HOSTNAME
  declare -p PRIMARY_HOSTNAME_BEFORE_RENAME
} > "$STATE_FILE"
