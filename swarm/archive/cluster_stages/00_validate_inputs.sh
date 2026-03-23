#!/bin/bash
set -euo pipefail

die() {
  echo "Error: $*" >&2
  exit 1
}

if [[ "$#" -lt 2 ]]; then
  die "usage: $0 <state_file> <config_file> [first_node_access_address]"
fi

STATE_FILE="$1"
shift

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  die "Usage: create_proxmox_cluster.sh <config_file> [first_node_access_address]"
fi

CONFIG_FILE="$1"
FIRST_NODE_ACCESS_OVERRIDE="${2:-}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  die "config file not found: $CONFIG_FILE"
fi

if ! command -v yq >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Error: yq is required but not installed.
This script requires mikefarah yq v4.

Install on Linux amd64:
  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo chmod +x /usr/local/bin/yq

Install on Linux arm64:
  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64
  sudo chmod +x /usr/local/bin/yq
EOF
  exit 1
fi

YQ_VERSION=$(yq --version 2>&1 || true)
if ! echo "$YQ_VERSION" | grep -Eq 'mikefarah|version v4\.'; then
  cat >&2 <<EOF
Error: incompatible yq detected.
This script requires mikefarah yq v4, but found:
  $YQ_VERSION

Note: on Ubuntu/Debian, "sudo apt install yq" often installs the Python yq wrapper,
which is not compatible with this script.

Install on Linux amd64:
  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo chmod +x /usr/local/bin/yq

Install on Linux arm64:
  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64
  sudo chmod +x /usr/local/bin/yq
EOF
  exit 1
fi

{
  printf 'CONFIG_FILE=%q\n' "$CONFIG_FILE"
  printf 'FIRST_NODE_ACCESS_OVERRIDE=%q\n' "$FIRST_NODE_ACCESS_OVERRIDE"
} > "$STATE_FILE"
