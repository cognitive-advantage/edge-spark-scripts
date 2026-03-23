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
Usage: create_proxmox_cluster.sh <config_file>

Forms a Proxmox cluster from already provisioned lab VMs.
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
command -v ssh >/dev/null 2>&1 || die "ssh is required"

CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"

CLUSTER_NAME="$(yq e -r '.swarm.name' "$CONFIG_FILE")"
PROXMOX_HOST="$(yq e -r '.swarm.lab_host[] | select(has("host")) | .host' "$CONFIG_FILE")"
PROXMOX_TARGET_NODE="$(yq e -r '.swarm.lab_host[] | select(has("host_node")) | .host_node' "$CONFIG_FILE")"
PROXMOX_SECRETS_PATH="$(yq e -r '.swarm.lab_host[] | select(has("secrets")) | .secrets' "$CONFIG_FILE")"
LAB_SECRETS_PATH="$(yq e -r '.swarm.lab_swarm.secrets' "$CONFIG_FILE")"
ROUTABLE_NETWORK_CIDR="$(yq e -r '.swarm.lab_host[] | select(has("vlan")) | .vlan[] | select(has("routable")) | .routable[] | select(has("network")) | .network' "$CONFIG_FILE")"

mapfile -t CLUSTER_NODE_IPS < <(yq e -r '.swarm.lab_host[] | select(has("vlan")) | .vlan[] | select(has("cluster")) | .cluster[] | select(has("nodes")) | .nodes[]' "$CONFIG_FILE")

[[ -n "$CLUSTER_NAME" && "$CLUSTER_NAME" != "null" ]] || die "missing swarm.name"
[[ -n "$PROXMOX_HOST" && "$PROXMOX_HOST" != "null" ]] || die "missing swarm.lab_host[].host"
[[ -n "$PROXMOX_TARGET_NODE" && "$PROXMOX_TARGET_NODE" != "null" ]] || die "missing swarm.lab_host[].host_node"
[[ "${#CLUSTER_NODE_IPS[@]}" -ge 2 ]] || die "cluster requires at least two node IPs"

[[ -n "$PROXMOX_SECRETS_PATH" && "$PROXMOX_SECRETS_PATH" != "null" ]] || die "missing swarm.lab_host[].secrets"
[[ -n "$LAB_SECRETS_PATH" && "$LAB_SECRETS_PATH" != "null" ]] || die "missing swarm.lab_swarm.secrets"
[[ -n "$ROUTABLE_NETWORK_CIDR" && "$ROUTABLE_NETWORK_CIDR" != "null" ]] || die "missing swarm.lab_host[].vlan[].routable[].network"

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

PROX_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=no -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no)
LAB_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o BatchMode=no -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no)

remote_ssh() {
  sshpass -p "$PROXMOX_PASS" ssh "${PROX_SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "LC_ALL=C LANG=C $*"
}

wait_for_guest_agent() {
  local vmid="$1"
  local retries=30

  while (( retries > 0 )); do
    if remote_ssh "pvesh create /nodes/${PROXMOX_TARGET_NODE}/qemu/${vmid}/agent/ping >/dev/null 2>&1"; then
      return 0
    fi
    retries=$((retries - 1))
    sleep 5
  done

  die "guest agent not ready for VMID ${vmid}"
}

discover_mgmt_ip() {
  local vmid="$1"
  local cluster_ip="$2"
  local interfaces_json
  local routable_prefix
  local cluster_last_octet
  local fallback_ip
  local ip

  interfaces_json="$(remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/qemu/${vmid}/agent/network-get-interfaces --output-format json")" \
    || die "cannot query guest agent for VMID ${vmid}"

  mapfile -t CANDIDATES < <(printf '%s\n' "$interfaces_json" | yq e -r '.result[]? | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' - | grep -vE '^127\.|^169\.254\.' | grep -v "^${cluster_ip}$" | sort -u)

  if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
    routable_prefix="$(printf '%s\n' "$ROUTABLE_NETWORK_CIDR" | sed -n 's/^\([0-9]\+\.[0-9]\+\.[0-9]\+\)\.[0-9]\+\/[0-9]\+$/\1/p')"
    cluster_last_octet="${cluster_ip##*.}"
    if [[ -n "$routable_prefix" && "$cluster_last_octet" =~ ^[0-9]+$ ]]; then
      fallback_ip="${routable_prefix}.${cluster_last_octet}"
      CANDIDATES=("$fallback_ip")
    fi
  fi

  [[ "${#CANDIDATES[@]}" -gt 0 ]] || die "no management IP discovered for VMID ${vmid}"

  for ip in "${CANDIDATES[@]}"; do
    if sshpass -p "$LAB_PASS" ssh "${LAB_SSH_OPTS[@]}" "${LAB_USER}@${ip}" true >/dev/null 2>&1; then
      echo "$ip"
      return 0
    fi
  done

  die "discovered management IPs for VMID ${vmid} are not SSH reachable: ${CANDIDATES[*]}"
}

wait_ready() {
  local mgmt_ip="$1"
  local expected_hostname="$2"
  local retries=30

  while (( retries > 0 )); do
    if sshpass -p "$LAB_PASS" ssh "${LAB_SSH_OPTS[@]}" "${LAB_USER}@${mgmt_ip}" "LC_ALL=C LANG=C test \"\$(hostname -s)\" = \"$expected_hostname\" && for svc in pve-cluster pvedaemon pveproxy pvestatd; do systemctl is-active --quiet \"\$svc\" || exit 1; done"; then
      return 0
    fi
    retries=$((retries - 1))
    sleep 5
  done

  die "node ${mgmt_ip} did not become ready as ${expected_hostname}"
}

declare -a NODE_HOSTNAMES=()
declare -a MGMT_IPS=()

for NODE_IP in "${CLUSTER_NODE_IPS[@]}"; do
  [[ "$NODE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "invalid node IP: $NODE_IP"
  IFS='.' read -r _ _ o3 o4 <<< "$NODE_IP"
  vmid="${o3}${o4}"
  hostname="${CLUSTER_NAME}-${o3}-${o4}"

  remote_ssh "pvesh get /nodes/${PROXMOX_TARGET_NODE}/qemu/${vmid}/status/current >/dev/null 2>&1" || die "VMID ${vmid} not found on ${PROXMOX_TARGET_NODE}; run create_virtual_lab.sh first"
  wait_for_guest_agent "$vmid"

  mgmt_ip="$(discover_mgmt_ip "$vmid" "$NODE_IP")"

  NODE_HOSTNAMES+=("$hostname")
  MGMT_IPS+=("$mgmt_ip")

  log "Node ${hostname}: cluster=${NODE_IP} management=${mgmt_ip}"
done

HOSTS_BLOCK=""
for i in "${!CLUSTER_NODE_IPS[@]}"; do
  HOSTS_BLOCK+="${CLUSTER_NODE_IPS[$i]} ${NODE_HOSTNAMES[$i]}"
  HOSTS_BLOCK+=$'\n'
done
HOSTS_BLOCK_B64="$(printf '%s' "$HOSTS_BLOCK" | base64 -w0)"

for i in "${!MGMT_IPS[@]}"; do
  mgmt="${MGMT_IPS[$i]}"
  host="${NODE_HOSTNAMES[$i]}"

  sshpass -p "$LAB_PASS" ssh "${LAB_SSH_OPTS[@]}" "${LAB_USER}@${mgmt}" "LC_ALL=C LANG=C bash -s" -- "$host" "$HOSTS_BLOCK_B64" <<'EOF'
set -euo pipefail
expected_hostname="$1"
hosts_block_b64="$2"
hosts_block="$(printf '%s' "$hosts_block_b64" | base64 -d)"

current_hostname="$(hostname -s)"
if [[ "$current_hostname" != "$expected_hostname" ]]; then
  hostnamectl set-hostname "$expected_hostname"
fi

tmp_hosts="$(mktemp)"
cp /etc/hosts "$tmp_hosts"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  host_name="${line#* }"
  grep -vE "[[:space:]]${host_name}([[:space:]]|$)" "$tmp_hosts" > "${tmp_hosts}.new" || true
  mv "${tmp_hosts}.new" "$tmp_hosts"
  echo "$line" >> "$tmp_hosts"
done <<< "$hosts_block"
cat "$tmp_hosts" > /etc/hosts
rm -f "$tmp_hosts"

systemctl restart pve-cluster pvestatd
EOF

  wait_ready "$mgmt" "$host"
done

PRIMARY_MGMT_IP="${MGMT_IPS[0]}"
PRIMARY_CLUSTER_IP="${CLUSTER_NODE_IPS[0]}"

CURRENT_CLUSTER_NAME="$(sshpass -p "$LAB_PASS" ssh "${LAB_SSH_OPTS[@]}" "${LAB_USER}@${PRIMARY_MGMT_IP}" "LC_ALL=C LANG=C pvecm status 2>/dev/null | awk -F': *' '/^Name:/{print \$2; exit}'" || true)"
if [[ -z "$CURRENT_CLUSTER_NAME" ]]; then
  log "Creating cluster ${CLUSTER_NAME} on ${PRIMARY_MGMT_IP}"
  sshpass -p "$LAB_PASS" ssh "${LAB_SSH_OPTS[@]}" "${LAB_USER}@${PRIMARY_MGMT_IP}" "LC_ALL=C LANG=C pvecm create ${CLUSTER_NAME} --link0 ${PRIMARY_CLUSTER_IP}"
elif [[ "$CURRENT_CLUSTER_NAME" != "$CLUSTER_NAME" ]]; then
  die "primary node already belongs to cluster '${CURRENT_CLUSTER_NAME}', expected '${CLUSTER_NAME}'"
else
  log "Primary node already in cluster ${CLUSTER_NAME}; continuing"
fi

for i in "${!MGMT_IPS[@]}"; do
  if [[ "$i" -eq 0 ]]; then
    continue
  fi

  mgmt="${MGMT_IPS[$i]}"
  node_cluster_ip="${CLUSTER_NODE_IPS[$i]}"

  joined_name="$(sshpass -p "$LAB_PASS" ssh "${LAB_SSH_OPTS[@]}" "${LAB_USER}@${mgmt}" "LC_ALL=C LANG=C pvecm status 2>/dev/null | awk -F': *' '/^Name:/{print \$2; exit}'" || true)"
  if [[ "$joined_name" == "$CLUSTER_NAME" ]]; then
    log "Node ${mgmt} already in cluster ${CLUSTER_NAME}; skipping"
    continue
  fi
  if [[ -n "$joined_name" && "$joined_name" != "$CLUSTER_NAME" ]]; then
    die "node ${mgmt} already belongs to cluster '${joined_name}', expected '${CLUSTER_NAME}'"
  fi

  log "Joining node ${mgmt}"
  sshpass -p "$LAB_PASS" ssh "${LAB_SSH_OPTS[@]}" "${LAB_USER}@${mgmt}" "LC_ALL=C LANG=C pvecm add ${PRIMARY_CLUSTER_IP} --use_ssh 1 --force --link0 address=${node_cluster_ip}"
done

EXPECTED_COUNT="${#CLUSTER_NODE_IPS[@]}"
ACTUAL_COUNT="$(sshpass -p "$LAB_PASS" ssh "${LAB_SSH_OPTS[@]}" "${LAB_USER}@${PRIMARY_MGMT_IP}" "LC_ALL=C LANG=C pvecm status | awk -F': *' '/^Nodes:/{print \$2; exit}'")"
[[ "$ACTUAL_COUNT" == "$EXPECTED_COUNT" ]] || die "cluster node count mismatch (expected ${EXPECTED_COUNT}, got ${ACTUAL_COUNT})"

log "Cluster ${CLUSTER_NAME} is ready"
sshpass -p "$LAB_PASS" ssh "${LAB_SSH_OPTS[@]}" "${LAB_USER}@${PRIMARY_MGMT_IP}" "LC_ALL=C LANG=C pvecm nodes"
