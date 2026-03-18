#!/bin/bash
set -euo pipefail

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
	echo "Error: $*" >&2
	exit 1
}

if [[ "$#" -ne 3 ]]; then
	die "usage: $0 <proxmox_host> <target_node> <config_file>"
fi

PROXMOX_HOST="$1"
PROXMOX_TARGET_NODE="$2"
CONFIG_FILE="$3"

if [[ ! "$PROXMOX_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
	die "invalid proxmox_host: $PROXMOX_HOST"
fi

if [[ ! "$PROXMOX_TARGET_NODE" =~ ^[A-Za-z0-9._-]+$ ]]; then
	die "invalid target_node: $PROXMOX_TARGET_NODE"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
	die "config file not found: $CONFIG_FILE"
fi

if ! command -v yq >/dev/null 2>&1; then
	die "yq is required"
fi

CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
PROXMOX_SECRETS_PATH="$(yq e -r '.swarm.secrets.proxmox' "$CONFIG_FILE")"
if [[ "$PROXMOX_SECRETS_PATH" == "null" || -z "$PROXMOX_SECRETS_PATH" ]]; then
	PROXMOX_SECRETS_PATH="./proxmox.secrets"
fi
if [[ "$PROXMOX_SECRETS_PATH" != /* ]]; then
	PROXMOX_SECRETS_PATH="$CONFIG_DIR/$PROXMOX_SECRETS_PATH"
fi
if [[ ! -f "$PROXMOX_SECRETS_PATH" ]]; then
	die "proxmox secrets file not found: $PROXMOX_SECRETS_PATH"
fi

PROXMOX_SECRETS_LINE="$(head -n 1 "$PROXMOX_SECRETS_PATH" | tr -d '\r')"
if [[ "$PROXMOX_SECRETS_LINE" != *:* ]]; then
	die "invalid proxmox secrets format in $PROXMOX_SECRETS_PATH (expected user:password)"
fi
PROXMOX_USER="${PROXMOX_SECRETS_LINE%%:*}"
PROXMOX_PASS="${PROXMOX_SECRETS_LINE#*:}"

mapfile -t NODE_IPS < <(yq e -r '.swarm.nodes[]' "$CONFIG_FILE")
if [[ "${#NODE_IPS[@]}" -eq 0 ]]; then
	die "missing swarm.nodes[]"
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
AUTH_MODE=""
if ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes "${PROXMOX_USER}@${PROXMOX_HOST}" true >/dev/null 2>&1; then
	AUTH_MODE="key"
elif command -v sshpass >/dev/null 2>&1 && sshpass -p "$PROXMOX_PASS" ssh -n "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" true >/dev/null 2>&1; then
	AUTH_MODE="password"
else
	die "cannot authenticate to ${PROXMOX_USER}@${PROXMOX_HOST}; ensure SSH key works or install sshpass"
fi

remote_ssh() {
	if [[ "$AUTH_MODE" == "key" ]]; then
		ssh -n "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "LC_ALL=C LANG=C $*"
	else
		sshpass -p "$PROXMOX_PASS" ssh -n "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "LC_ALL=C LANG=C $*"
	fi
}

fail_count=0
warn_count=0

log "Verifying lab VMs on ${PROXMOX_HOST} node ${PROXMOX_TARGET_NODE}"
for NODE_IP in "${NODE_IPS[@]}"; do
	IFS='.' read -r _ _ o3 o4 <<< "$NODE_IP"
	VMID="${o3}${o4}"
	EXPECTED_IPCONF1="ip=${NODE_IP}/24"

	echo ""
	echo "VM ${VMID} expected cluster IP ${NODE_IP}"

	if ! CONFIG_JSON="$(remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/config --output-format json" 2>/dev/null)"; then
		echo "  FAIL: VM ${VMID} config not found on node ${PROXMOX_TARGET_NODE}"
		fail_count=$((fail_count + 1))
		continue
	fi

	NET0_LINE="$(printf '%s\n' "$CONFIG_JSON" | yq e -r '.net0 // ""' -)"
	NET1_LINE="$(printf '%s\n' "$CONFIG_JSON" | yq e -r '.net1 // ""' -)"
	IPCONF0_LINE="$(printf '%s\n' "$CONFIG_JSON" | yq e -r '.ipconfig0 // ""' -)"
	IPCONF1_LINE="$(printf '%s\n' "$CONFIG_JSON" | yq e -r '.ipconfig1 // ""' -)"

	if [[ -n "$NET0_LINE" ]]; then
		echo "  PASS: net0 present"
	else
		echo "  FAIL: net0 missing"
		fail_count=$((fail_count + 1))
	fi

	if [[ -n "$NET1_LINE" ]]; then
		echo "  PASS: net1 present"
	else
		echo "  FAIL: net1 missing"
		fail_count=$((fail_count + 1))
	fi

	if [[ "$IPCONF0_LINE" == ip=dhcp* ]]; then
		echo "  PASS: ipconfig0 is dhcp"
	else
		echo "  FAIL: ipconfig0 expected ip=dhcp, got '${IPCONF0_LINE:-<missing>}'"
		fail_count=$((fail_count + 1))
	fi

	if [[ "$IPCONF1_LINE" == "$EXPECTED_IPCONF1"* ]]; then
		echo "  PASS: ipconfig1 is ${EXPECTED_IPCONF1}"
	else
		echo "  FAIL: ipconfig1 expected ${EXPECTED_IPCONF1}, got '${IPCONF1_LINE:-<missing>}'"
		fail_count=$((fail_count + 1))
	fi

	# Optional guest-agent verification of effective in-guest IPs.
	if GUEST_NET="$(remote_ssh "qm guest cmd ${VMID} network-get-interfaces" 2>/dev/null)"; then
		if echo "$GUEST_NET" | grep -q "$NODE_IP"; then
			echo "  PASS: guest agent reports ${NODE_IP}"
		else
			echo "  WARN: guest agent did not report ${NODE_IP}"
			warn_count=$((warn_count + 1))
		fi
	else
		echo "  WARN: guest agent query unavailable for VM ${VMID}"
		warn_count=$((warn_count + 1))
	fi
done

echo ""
echo "Summary: fails=${fail_count} warnings=${warn_count}"
if (( fail_count > 0 )); then
	exit 1
fi
