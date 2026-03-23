#!/bin/bash
set -euo pipefail

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
	echo "Error: $*" >&2
	exit 1
}

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
	die "usage: $0 <proxmox_host> <template_id> [cloudinit_storage]"
fi

PROXMOX_HOST="$1"
TEMPLATE_ID="$2"
CLOUDINIT_STORAGE="${3:-vm-os}"

if [[ ! "$PROXMOX_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
	die "invalid proxmox_host: $PROXMOX_HOST"
fi

if [[ ! "$TEMPLATE_ID" =~ ^[0-9]+$ ]]; then
	die "template_id must be numeric"
fi

if [[ ! "$CLOUDINIT_STORAGE" =~ ^[A-Za-z0-9._-]+$ ]]; then
	die "invalid cloudinit_storage: $CLOUDINIT_STORAGE"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXMOX_SECRETS_PATH="${PROXMOX_SECRETS:-${SCRIPT_DIR}/proxmox.secrets}"

if [[ ! -f "$PROXMOX_SECRETS_PATH" ]]; then
	die "proxmox secrets file not found: $PROXMOX_SECRETS_PATH"
fi

PROXMOX_SECRETS_LINE="$(head -n 1 "$PROXMOX_SECRETS_PATH" | tr -d '\r')"
if [[ "$PROXMOX_SECRETS_LINE" != *:* ]]; then
	die "invalid proxmox secrets format in $PROXMOX_SECRETS_PATH (expected user:password)"
fi

PROXMOX_USER="${PROXMOX_SECRETS_LINE%%:*}"
PROXMOX_PASS="${PROXMOX_SECRETS_LINE#*:}"

if [[ -z "$PROXMOX_USER" || -z "$PROXMOX_PASS" ]]; then
	die "invalid proxmox secrets format in $PROXMOX_SECRETS_PATH (empty user/password)"
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

log "Checking template ${TEMPLATE_ID} on ${PROXMOX_HOST}"
remote_ssh "qm config ${TEMPLATE_ID} >/dev/null 2>&1" || die "template VM ${TEMPLATE_ID} not found"

if ! remote_ssh "qm config ${TEMPLATE_ID} | grep -q '^template: 1'"; then
	die "VM ${TEMPLATE_ID} exists but is not marked as a template"
fi

if remote_ssh "qm config ${TEMPLATE_ID} | grep -q '^ide2:.*cloudinit'"; then
	log "cloud-init drive already attached"
	remote_ssh "qm config ${TEMPLATE_ID} | grep -E '^template:|^ide2:'"
	exit 0
fi

log "Adding cloud-init drive using storage ${CLOUDINIT_STORAGE}"
remote_ssh "qm set ${TEMPLATE_ID} --ide2 ${CLOUDINIT_STORAGE}:cloudinit"

log "Verifying template config"
remote_ssh "qm config ${TEMPLATE_ID} | grep -E '^template:|^ide2:'"

log "Template ${TEMPLATE_ID} is cloud-init ready"
