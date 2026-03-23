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

if [[ -z "$PROXMOX_HOST" ]]; then
	die "proxmox_host is required"
fi

if [[ ! "$PROXMOX_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
	die "invalid proxmox_host: $PROXMOX_HOST"
fi

if [[ -z "$PROXMOX_TARGET_NODE" ]]; then
	die "target_node is required"
fi

if [[ ! "$PROXMOX_TARGET_NODE" =~ ^[A-Za-z0-9._-]+$ ]]; then
	die "invalid target_node: $PROXMOX_TARGET_NODE"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
	die "config file not found: $CONFIG_FILE"
fi

if ! command -v yq > /dev/null 2>&1; then
	die "yq is required"
fi

CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"

CLUSTER_NAME="$(yq e -r '.swarm.name' "$CONFIG_FILE")"
TEMPLATE_ID="$(yq e -r '.swarm.template' "$CONFIG_FILE")"
ROUTABLE_VLAN="$(yq e -r '.swarm.vlans[] | select(has("routable")) | .routable' "$CONFIG_FILE")"
CLUSTER_VLAN="$(yq e -r '.swarm.vlans[] | select(has("cluster")) | .cluster' "$CONFIG_FILE")"
PROXMOX_SECRETS_PATH="$(yq e -r '.swarm.secrets.proxmox' "$CONFIG_FILE")"

mapfile -t NODE_IPS < <(yq e -r '.swarm.nodes[]' "$CONFIG_FILE")

if [[ -z "$CLUSTER_NAME" || "$CLUSTER_NAME" == "null" ]]; then
	die "missing swarm.name"
fi

if [[ -z "$TEMPLATE_ID" || "$TEMPLATE_ID" == "null" ]]; then
	die "missing swarm.template"
fi

if [[ -z "$ROUTABLE_VLAN" || "$ROUTABLE_VLAN" == "null" ]]; then
	die "missing swarm.vlans[].routable"
fi

if [[ -z "$CLUSTER_VLAN" || "$CLUSTER_VLAN" == "null" ]]; then
	die "missing swarm.vlans[].cluster"
fi

if [[ "${#NODE_IPS[@]}" -eq 0 ]]; then
	die "missing swarm.nodes[]"
fi

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

if [[ -z "$PROXMOX_USER" || -z "$PROXMOX_PASS" ]]; then
	die "invalid proxmox secrets format in $PROXMOX_SECRETS_PATH (empty user/password)"
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

command -v sshpass >/dev/null 2>&1 || die "sshpass is required"
sshpass -p "$PROXMOX_PASS" ssh -n "${SSH_OPTS[@]}" -o BatchMode=no -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no "${PROXMOX_USER}@${PROXMOX_HOST}" true >/dev/null 2>&1 \
	|| die "cannot authenticate to ${PROXMOX_USER}@${PROXMOX_HOST} using proxmox secrets"

remote_ssh() {
	sshpass -p "$PROXMOX_PASS" ssh -n "${SSH_OPTS[@]}" \
		-o BatchMode=no \
		-o PreferredAuthentications=password,keyboard-interactive \
		-o PubkeyAuthentication=no \
		"${PROXMOX_USER}@${PROXMOX_HOST}" "LC_ALL=C LANG=C $*"
}

wait_for_guest_agent() {
	local vmid="$1"
	local attempts=36
	local sleep_seconds=5

	while (( attempts > 0 )); do
		if remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/qemu/${vmid}/agent/ping >/dev/null 2>&1"; then
			return 0
		fi

		attempts=$((attempts - 1))
		sleep "$sleep_seconds"
	done

	die "guest agent did not become ready for VM ${vmid}"
}

configure_guest_identity() {
	local vmid="$1"
	local hostname="$2"
	local cluster_ip="$3"
	local script
	local script_escaped
	local exec_json
	local pid
	local status_json
	local exited
	local exitcode

	read -r -d '' script <<EOF || true
set -euo pipefail
hostnamectl set-hostname '${hostname}'
tmp_hosts="\$(mktemp)"
grep -vE '[[:space:]]${hostname}([[:space:]]|\$)' /etc/hosts | grep -vE '^127\\.0\\.1\\.1([[:space:]]|\$)' > "\$tmp_hosts" || true
echo '127.0.1.1 localhost.localdomain localhost' >> "\$tmp_hosts"
echo '${cluster_ip} ${hostname}' >> "\$tmp_hosts"
cat "\$tmp_hosts" > /etc/hosts
rm -f "\$tmp_hosts"
if [[ -f /etc/cloud/cloud.cfg ]]; then
  sed -i 's/^manage_etc_hosts: true/manage_etc_hosts: false/' /etc/cloud/cloud.cfg || true
fi
EOF

	script_escaped="${script//\'/\'\"\'\"\'}"
	exec_json="$(remote_ssh "pvesh create /nodes/${PROXMOX_TARGET_NODE}/qemu/${vmid}/agent/exec --command /bin/bash --arg -lc --arg '$script_escaped' --output-format json")"
	pid="$(printf '%s\n' "$exec_json" | yq e -r '.pid' -)"
	[[ -n "$pid" && "$pid" != "null" ]] || die "failed to start guest identity config for VM ${vmid}"

	for _ in {1..30}; do
		status_json="$(remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/qemu/${vmid}/agent/exec-status --pid ${pid} --output-format json")"
		exited="$(printf '%s\n' "$status_json" | yq e -r '.exited' -)"
		if [[ "$exited" == "true" ]]; then
			exitcode="$(printf '%s\n' "$status_json" | yq e -r '.exitcode' -)"
			if [[ "$exitcode" == "0" ]]; then
				return 0
			fi
			echo "guest exec output for VM ${vmid}:" >&2
			printf '%s\n' "$status_json" | yq e -r '."out-data" // ."err-data" // "(no output)"' - >&2 || true
			die "guest identity config failed for VM ${vmid} with exit code ${exitcode}"
		fi
		sleep 2
	done

	die "guest identity config timed out for VM ${vmid}"
}

log "Preflight: validating remote prerequisites on ${PROXMOX_HOST}"
remote_ssh "command -v qm >/dev/null" || die "qm command not found on ${PROXMOX_HOST}"
remote_ssh "command -v pvesh >/dev/null" || die "pvesh command not found on ${PROXMOX_HOST}"
remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/status >/dev/null 2>&1" || die "target node '${PROXMOX_TARGET_NODE}' not found on ${PROXMOX_HOST}"
remote_ssh "qm config ${TEMPLATE_ID} >/dev/null 2>&1" || die "template VM ${TEMPLATE_ID} not found"
remote_ssh "qm config ${TEMPLATE_ID} | grep -q '^template: 1'" || die "VM ${TEMPLATE_ID} exists but is not marked as a template"
TEMPLATE_HAS_CLOUDINIT="0"
if remote_ssh "qm config ${TEMPLATE_ID} | grep -q '^ide2:.*cloudinit'"; then
	TEMPLATE_HAS_CLOUDINIT="1"
else
	log "Preflight: template ${TEMPLATE_ID} has no cloud-init drive; skipping guest IP injection"
fi

declare -A SEEN_VMIDS=()

for NODE_IP in "${NODE_IPS[@]}"; do
	if [[ ! "$NODE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
		die "invalid node IP: $NODE_IP"
	fi

	IFS='.' read -r o1 o2 o3 o4 <<< "$NODE_IP"
	for octet in "$o1" "$o2" "$o3" "$o4"; do
		if (( octet < 0 || octet > 255 )); then
			die "invalid node IP: $NODE_IP"
		fi
	done

	VMID="${o3}${o4}"
	if [[ -n "${SEEN_VMIDS[$VMID]:-}" ]]; then
		die "duplicate derived VMID $VMID from nodes list"
	fi
	SEEN_VMIDS[$VMID]=1
done

for NODE_IP in "${NODE_IPS[@]}"; do
	IFS='.' read -r o1 o2 o3 o4 <<< "$NODE_IP"

	VMID="${o3}${o4}"
	HOSTNAME="${CLUSTER_NAME}-${o3}-${o4}"
	IPCONFIG0="ip=dhcp"
	IPCONFIG1="ip=${NODE_IP}/24"
	NET0="virtio,bridge=vmbr0,tag=${ROUTABLE_VLAN}"
	NET1="virtio,bridge=vmbr0,tag=${CLUSTER_VLAN}"

	log "Processing node IP ${NODE_IP} -> VMID ${VMID}, hostname ${HOSTNAME}"

	if remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/status/current >/dev/null 2>&1"; then
		EXISTING_NAME="$(remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/config | awk -F': ' '/^name:/{print \$2; exit}'")"
		if [[ "$EXISTING_NAME" == "$HOSTNAME" ]]; then
			log "VM ${VMID} already exists as ${HOSTNAME}; skipping clone"
			continue
		fi

		die "VMID ${VMID} already exists as '${EXISTING_NAME}', expected '${HOSTNAME}'"
	fi

	set +e
	CLONE_OUTPUT="$(remote_ssh "qm clone ${TEMPLATE_ID} ${VMID} --name ${HOSTNAME} --target ${PROXMOX_TARGET_NODE} --full 0" 2>&1)"
	CLONE_STATUS=$?
	set -e

	if [[ $CLONE_STATUS -ne 0 ]]; then
		echo "$CLONE_OUTPUT" >&2
		if echo "$CLONE_OUTPUT" | grep -Eq "qemu-server/${VMID}\\.conf'.*does not exist|Configuration file 'nodes/.*/qemu-server/${VMID}\\.conf' does not exist|qemu-server/${VMID}\\.conf'.*File exists|vm-${VMID}-cloudinit already exists"; then
			die "stale Proxmox metadata detected for VMID ${VMID}; run ./delete_vm_by_id.sh ${PROXMOX_HOST} ${VMID} then rerun create_virtual_lab.sh"
		fi
		die "failed to clone VM ${VMID}"
	fi

	echo "$CLONE_OUTPUT"
	remote_ssh "pvesh set /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/config --net0 '${NET0}' --net1 '${NET1}'"
	if [[ "$TEMPLATE_HAS_CLOUDINIT" == "1" ]]; then
		remote_ssh "pvesh set /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/config --ipconfig0 '${IPCONFIG0}' --ipconfig1 '${IPCONFIG1}'"
	fi
	remote_ssh "pvesh set /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/config --onboot 1"
	remote_ssh "pvesh create /nodes/${PROXMOX_TARGET_NODE}/qemu/${VMID}/status/start"
	wait_for_guest_agent "${VMID}"
	configure_guest_identity "${VMID}" "${HOSTNAME}" "${NODE_IP}"

	log "VM ${VMID} (${HOSTNAME}) provisioned"
done

log "Virtual lab provisioning complete"
