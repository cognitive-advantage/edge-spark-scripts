#!/bin/bash
# Exit on error, undefined vars, and failed pipeline commands.
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

wait_for_management_ready() {
  local node_address="$1"
  local expected_hostname="$2"
  local retries=30
  local sleep_seconds=5

  while (( retries > 0 )); do
    if ssh -n "${LAB_SSH_USER}@$node_address" "LC_ALL=C LANG=C test \"\$(hostname -s)\" = \"$expected_hostname\" && for svc in pve-cluster pvedaemon pveproxy pvestatd; do systemctl is-active --quiet \"\$svc\" || exit 1; done"; then
      return 0
    fi

    retries=$((retries - 1))
    sleep "$sleep_seconds"
  done

  die "node $node_address did not become ready as '$expected_hostname' after rename/service restart"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$SCRIPT_DIR/cluster_stages"
STATE_FILE="$(mktemp /tmp/create_proxmox_cluster.XXXXXX.state)"

cleanup_state() {
  rm -f "$STATE_FILE"
}
trap cleanup_state EXIT

"$STAGE_DIR/00_validate_inputs.sh" "$STATE_FILE" "$@"
"$STAGE_DIR/10_parse_config.sh" "$STATE_FILE"
# shellcheck source=/dev/null
source "$STATE_FILE"

# Creates a Proxmox VE cluster by joining nodes together using pvecm.
# Usage: create_proxmox_cluster.sh <config_file> [first_node_access_address]
# The config file should be a YAML file with the following structure:

# swarm:
#   name: lab-swarm01
#   template: 1002
#   vlans: 
#     - routable: 221
#     - cluster: 921
#   secrets: 
#     proxmox: ./proxmox.secrets
#     lab: ./lab.secrets
#   nodes:
#   - 10.254.221.11
#   - 10.254.221.12
#   - 10.254.221.13
#   routable_nodes:
#   - 192.168.221.145
#   - 192.168.221.95
#   - 192.168.221.200

# etc...


# Joining Proxmox VE machines into a cluster via CLI involves creating the cluster on one node, then using the
# pvecm (Proxmox VE Cluster Manager) tool on other nodes to join. Important: The node joining the cluster cannot have any local VMs or containers with conflicting IDs.
# This script requires explicit swarm.routable_nodes management addresses.

SSH_BIN="$(command -v ssh)"

"$STAGE_DIR/20_resolve_management.sh" "$STATE_FILE"
"$STAGE_DIR/30_preflight_connectivity.sh" "$STATE_FILE"
# shellcheck source=/dev/null
source "$STATE_FILE"

ssh() {
  command -v sshpass >/dev/null 2>&1 || die "sshpass is required for lab node authentication"

  local -a auth_args=()
  while (( "$#" )); do
    case "$1" in
      -o)
        if (( "$#" >= 2 )) && [[ "$2" == "BatchMode=yes" ]]; then
          shift 2
          continue
        fi
        if (( "$#" >= 2 )); then
          auth_args+=("$1" "$2")
          shift 2
          continue
        fi
        auth_args+=("$1")
        shift
        continue
        ;;
      -oBatchMode=yes)
        shift
        continue
        ;;
    esac

    auth_args+=("$1")
    shift
  done

  sshpass -p "$LAB_SSH_PASS" "$SSH_BIN" \
    -o BatchMode=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    "${auth_args[@]}"
}

"$STAGE_DIR/40_normalize_identity.sh" "$STATE_FILE"
# shellcheck source=/dev/null
source "$STATE_FILE"

"$STAGE_DIR/50_ensure_primary_cluster.sh" "$STATE_FILE"
"$STAGE_DIR/60_reconcile_primary_metadata.sh" "$STATE_FILE"
"$STAGE_DIR/70_prepare_pending_joins.sh" "$STATE_FILE"
# shellcheck source=/dev/null
source "$STATE_FILE"

"$STAGE_DIR/80_join_pending_nodes.sh" "$STATE_FILE"
"$STAGE_DIR/90_postflight_verify.sh" "$STATE_FILE"

