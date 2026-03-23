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
Usage: fix_proxmox_node_services.sh <config_file>

Repairs Proxmox node hostname/IP resolution and restarts critical services.
It uses:
  - swarm.name
  - swarm.nodes[]          (cluster link IPs)
  - swarm.routable_nodes[] (management SSH IPs)
  - swarm.secrets.lab      (user:password)
EOF
}

if [[ "$#" -ne 1 ]]; then
  usage
  exit 1
fi

CONFIG_FILE="$1"
[[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"

if ! command -v yq >/dev/null 2>&1; then
  die "yq (mikefarah v4) is required"
fi

YQ_VERSION=$(yq --version 2>&1 || true)
if ! echo "$YQ_VERSION" | grep -Eq 'mikefarah|version v4\.'; then
  die "incompatible yq detected: $YQ_VERSION"
fi

CLUSTER_NAME=$(yq e -r '.swarm.name' "$CONFIG_FILE")
[[ -n "$CLUSTER_NAME" && "$CLUSTER_NAME" != "null" ]] || die "missing swarm.name"

mapfile -t CLUSTER_IPS < <(yq e -r '.swarm.nodes[]' "$CONFIG_FILE")
mapfile -t MGMT_IPS < <(yq e -r '.swarm.routable_nodes[]?' "$CONFIG_FILE")

if [[ "${#CLUSTER_IPS[@]}" -lt 1 ]]; then
  die "missing swarm.nodes[]"
fi

if [[ "${#MGMT_IPS[@]}" -eq 0 ]]; then
  die "missing swarm.routable_nodes[]; provide one management IP per node"
fi

if [[ "${#MGMT_IPS[@]}" -ne "${#CLUSTER_IPS[@]}" ]]; then
  die "swarm.routable_nodes[] count must match swarm.nodes[] count"
fi

CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
LAB_SECRETS_PATH=$(yq e -r '.swarm.secrets.lab // "./lab.secrets"' "$CONFIG_FILE")
if [[ "$LAB_SECRETS_PATH" != /* ]]; then
  LAB_SECRETS_PATH="$CONFIG_DIR/$LAB_SECRETS_PATH"
fi
[[ -f "$LAB_SECRETS_PATH" ]] || die "lab secrets file not found: $LAB_SECRETS_PATH"

LAB_SECRETS_LINE="$(head -n 1 "$LAB_SECRETS_PATH" | tr -d '\r')"
[[ "$LAB_SECRETS_LINE" == *:* ]] || die "invalid lab secrets format (expected user:password)"
LAB_SSH_USER="${LAB_SECRETS_LINE%%:*}"
LAB_SSH_PASS="${LAB_SECRETS_LINE#*:}"
[[ -n "$LAB_SSH_USER" && -n "$LAB_SSH_PASS" ]] || die "invalid lab secrets values"

SSH_BIN="$(command -v ssh)"

run_ssh() {
  local node_ip="$1"
  shift
  sshpass -p "$LAB_SSH_PASS" "$SSH_BIN" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=8 \
    -o BatchMode=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    -n "${LAB_SSH_USER}@${node_ip}" "$@"
}

verify_non_loopback_resolution() {
  local mgmt_ip="$1"
  local expected_hostname="$2"

  local resolved_ip
  resolved_ip=$(run_ssh "$mgmt_ip" "LC_ALL=C LANG=C getent hosts '$expected_hostname' | awk 'NR==1 {print \$1}'")
  [[ -n "$resolved_ip" ]] || die "hostname did not resolve on node $mgmt_ip: $expected_hostname"
  [[ "$resolved_ip" != 127.* ]] || die "hostname resolved to loopback on node $mgmt_ip: $expected_hostname -> $resolved_ip"
}

repair_node() {
  local mgmt_ip="$1"
  local cluster_ip="$2"
  local expected_hostname="$3"

  log "Repairing node $mgmt_ip as $expected_hostname (cluster IP $cluster_ip)"

  run_ssh "$mgmt_ip" "bash -s" -- "$expected_hostname" "$cluster_ip" <<'EOF'
set -euo pipefail
expected_hostname="$1"
cluster_ip="$2"

current_hostname="$(hostname -s)"
if [[ "$current_hostname" != "$expected_hostname" ]]; then
  hostnamectl set-hostname "$expected_hostname"
fi

tmp_hosts="$(mktemp)"
grep -vE "[[:space:]]${expected_hostname}([[:space:]]|$)" /etc/hosts | grep -vE '^127\.0\.1\.1([[:space:]]|$)' > "$tmp_hosts" || true
echo "127.0.1.1 localhost.localdomain localhost" >> "$tmp_hosts"
echo "${cluster_ip} ${expected_hostname}" >> "$tmp_hosts"
cat "$tmp_hosts" > /etc/hosts
rm -f "$tmp_hosts"

# cloud-init can rewrite /etc/hosts on reboot. Keep this system boot-safe too.
if [[ -f /etc/cloud/cloud.cfg ]]; then
  sed -i 's/^manage_etc_hosts: true/manage_etc_hosts: false/' /etc/cloud/cloud.cfg || true
fi

systemctl reset-failed pve-cluster || true
systemctl restart pve-cluster
systemctl restart pvestatd
pvecm updatecerts --force || true
systemctl restart pvedaemon pveproxy

for svc in pve-cluster pvestatd pvedaemon pveproxy; do
  systemctl is-active --quiet "$svc" || {
    echo "service $svc is not active" >&2
    exit 1
  }
done

getent hosts "$expected_hostname" >/dev/null 2>&1 || {
  echo "hostname does not resolve: $expected_hostname" >&2
  exit 1
}
EOF

  verify_non_loopback_resolution "$mgmt_ip" "$expected_hostname"

  if curl -k -sS --max-time 8 "https://${mgmt_ip}:8006/api2/json/version" >/dev/null; then
    log "Node $mgmt_ip API is reachable"
  else
    log "Warning: node $mgmt_ip API endpoint still not reachable from this machine"
  fi
}

for i in "${!CLUSTER_IPS[@]}"; do
  cluster_ip="${CLUSTER_IPS[$i]}"
  mgmt_ip="${MGMT_IPS[$i]}"

  IFS='.' read -r _ _ o3 o4 <<< "$cluster_ip"
  [[ -n "$o3" && -n "$o4" ]] || die "invalid cluster IP: $cluster_ip"
  expected_hostname="${CLUSTER_NAME}-${o3}-${o4}"

  repair_node "$mgmt_ip" "$cluster_ip" "$expected_hostname"
done

log "Recovery complete for ${#CLUSTER_IPS[@]} node(s)."
