#!/usr/bin/env bash
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
Usage: ensure_proxmox_cluster_from_conf.sh <conf-file> [ceph-version]

Reads a swarm conf file (KEY=VALUE format) and ensures:
1) Hostnames are set to NAME-pve-<index>
2) Nodes in CLUSTER_NODES belong to one Proxmox cluster named NAME
3) Ceph is brought up and mounted in Proxmox storage

Arguments:
  conf-file     Path to conf file like lab.swarm02.conf
  ceph-version  Optional Ceph train for pveceph install (default: squid)

Required conf keys:
  NAME
  CLUSTER_NODES   # comma-separated IPs, in desired cluster order

Notes:
- Requires sshpass and a LAB_SWARM_SECRETS file with user:password.
- The first CLUSTER_NODES entry is used as the cluster bootstrap/primary node.
- Ceph defaults can be overridden in the conf file (see variable names in script).
EOF
}

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  usage
  exit 1
fi

CONF_FILE="$1"
CEPH_VERSION="${2:-squid}"

[[ -f "$CONF_FILE" ]] || die "conf file not found: $CONF_FILE"
command -v ssh >/dev/null 2>&1 || die "ssh is required"
command -v sshpass >/dev/null 2>&1 || die "sshpass is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required"

# shellcheck disable=SC1090
source "$CONF_FILE"

[[ -n "${NAME:-}" ]] || die "missing required key NAME in ${CONF_FILE}"
[[ -n "${CLUSTER_NODES:-}" ]] || die "missing required key CLUSTER_NODES in ${CONF_FILE}"
[[ -n "${LAB_SWARM_SECRETS:-}" ]] || die "missing required key LAB_SWARM_SECRETS in ${CONF_FILE}"

DOMAIN="${DOMAIN:-edgespark.local}"
[[ -n "$DOMAIN" ]] || die "DOMAIN must not be empty"

CEPH_PUBLIC_NETWORK="${CEPH_PUBLIC_NETWORK:-${VLAN_ROUTABLE_NETWORK:-}}"
CEPH_VERSION="${CEPH_VERSION:-${CEPH_VERSION_OVERRIDE:-$CEPH_VERSION}}"
CEPH_OSD_DEVICE="${CEPH_OSD_DEVICE:-/dev/sdb}"
CEPH_POOL_NAME="${CEPH_POOL_NAME:-rbd-vm}"
CEPH_POOL_SIZE="${CEPH_POOL_SIZE:-3}"
CEPH_POOL_MIN_SIZE="${CEPH_POOL_MIN_SIZE:-2}"
CEPH_POOL_PG_NUM="${CEPH_POOL_PG_NUM:-32}"
CEPH_RBD_STORAGE_ID="${CEPH_RBD_STORAGE_ID:-ceph-rbd}"
CEPH_RBD_CONTENT="${CEPH_RBD_CONTENT:-images,rootdir}"
CEPH_FS_NAME="${CEPH_FS_NAME:-cephfs}"
CEPH_FS_STORAGE_ID="${CEPH_FS_STORAGE_ID:-ceph-fs}"
CEPH_FS_PATH="${CEPH_FS_PATH:-/mnt/pve/ceph-fs}"
CEPH_FS_CONTENT="${CEPH_FS_CONTENT:-iso,vztmpl,backup,snippets}"
PVE_REPO_CHANNEL="${PVE_REPO_CHANNEL:-no-subscription}"
PVE_REPO_SUITES="${PVE_REPO_SUITES:-trixie}"

CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
if [[ "$LAB_SWARM_SECRETS" != /* ]]; then
  LAB_SWARM_SECRETS="${CONF_DIR}/${LAB_SWARM_SECRETS}"
fi
[[ -f "$LAB_SWARM_SECRETS" ]] || die "lab secrets file not found: $LAB_SWARM_SECRETS"

LAB_LINE="$(head -n 1 "$LAB_SWARM_SECRETS" | tr -d '\r')"
[[ "$LAB_LINE" == *:* ]] || die "invalid LAB_SWARM_SECRETS format in $LAB_SWARM_SECRETS (expected user:password)"
LAB_USER="${LAB_LINE%%:*}"
LAB_PASS="${LAB_LINE#*:}"
[[ -n "$LAB_USER" && -n "$LAB_PASS" ]] || die "invalid LAB_SWARM_SECRETS values"

IFS=',' read -r -a NODES <<< "$CLUSTER_NODES"
[[ "${#NODES[@]}" -ge 1 ]] || die "CLUSTER_NODES must contain at least one node"

for node in "${NODES[@]}"; do
  [[ "$node" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "invalid node IP in CLUSTER_NODES: $node"
done

declare -a HOSTNAMES=()
declare -A HOSTNAME_SET=()
for i in "${!NODES[@]}"; do
  idx="$((i + 1))"
  host="${NAME}-pve-${idx}"
  if [[ -n "${HOSTNAME_SET[$host]:-}" ]]; then
    die "derived duplicate hostname: ${host}"
  fi
  HOSTNAME_SET["$host"]=1
  HOSTNAMES+=("$host")
done

PRIMARY_IP="${NODES[0]}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

ssh_run() {
  local ip="$1"
  local cmd="$2"
  sshpass -p "$LAB_PASS" ssh "${SSH_OPTS[@]}" "${LAB_USER}@${ip}" "LC_ALL=C LANG=C ${cmd}"
}

get_api_fingerprint() {
  local ip="$1"

  echo | openssl s_client -connect "${ip}:8006" -servername "$ip" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 \
    | cut -d= -f2
}

render_hosts_block() {
  local out=""
  local i
  for i in "${!NODES[@]}"; do
    out+="${NODES[$i]} ${HOSTNAMES[$i]}.${DOMAIN} ${HOSTNAMES[$i]}\n"
  done
  printf '%b' "$out"
}

ensure_hostnames_and_hosts_file() {
  local hosts_block_b64
  hosts_block_b64="$(render_hosts_block | base64 -w0)"

  local i
  for i in "${!NODES[@]}"; do
    local ip="${NODES[$i]}"
    local expected_host="${HOSTNAMES[$i]}"

    log "Ensuring hostname ${expected_host} on ${ip}"
    sshpass -p "$LAB_PASS" ssh "${SSH_OPTS[@]}" "${LAB_USER}@${ip}" "bash -s" -- "$expected_host" "$hosts_block_b64" <<'EOF'
set -euo pipefail
expected_hostname="$1"
hosts_block_b64="$2"
hosts_block="$(printf '%s' "$hosts_block_b64" | base64 -d)"

current="$(hostname -s)"
if [[ "$current" != "$expected_hostname" ]]; then
  hostnamectl set-hostname "$expected_hostname"
fi

tmp_hosts="$(mktemp)"
cp /etc/hosts "$tmp_hosts"

# Remove legacy default Proxmox aliases before adding canonical names.
grep -vE '(^|[[:space:]])pve([[:space:]]|$)|(^|[[:space:]])pve\.edgespark\.local([[:space:]]|$)' "$tmp_hosts" > "${tmp_hosts}.new" || true
mv "${tmp_hosts}.new" "$tmp_hosts"

# Remove any previous entries for the managed hostnames/FQDNs, then append desired map.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  set -- $line
  entry_ip="$1"
  entry_fqdn="$2"
  entry_short="$3"

  grep -vE "[[:space:]]${entry_fqdn}([[:space:]]|$)|[[:space:]]${entry_short}([[:space:]]|$)" "$tmp_hosts" > "${tmp_hosts}.new" || true
  mv "${tmp_hosts}.new" "$tmp_hosts"

  echo "${entry_ip} ${entry_fqdn} ${entry_short}" >> "$tmp_hosts"
done <<< "$hosts_block"

cat "$tmp_hosts" > /etc/hosts
rm -f "$tmp_hosts"

pvecm updatecerts --force >/dev/null 2>&1 || true
systemctl restart pve-cluster corosync pveproxy pvedaemon pvestatd
EOF
  done
}

ensure_cluster_membership() {
  local current_cluster
  local primary_fingerprint
  local cluster_pass_b64

  primary_fingerprint="$(get_api_fingerprint "$PRIMARY_IP")"
  [[ -n "$primary_fingerprint" ]] || die "unable to determine API fingerprint for ${PRIMARY_IP}"
  cluster_pass_b64="$(printf '%s' "$LAB_PASS" | base64 -w0)"

  current_cluster="$(ssh_run "$PRIMARY_IP" "pvecm status 2>/dev/null | awk -F': *' '/^Name:/{print \$2; exit}'" || true)"

  if [[ -z "$current_cluster" ]]; then
    log "Creating Proxmox cluster ${NAME} on primary ${PRIMARY_IP}"
    ssh_run "$PRIMARY_IP" "pvecm create ${NAME} --link0 ${PRIMARY_IP}"
  elif [[ "$current_cluster" != "$NAME" ]]; then
    die "primary node ${PRIMARY_IP} already belongs to cluster '${current_cluster}', expected '${NAME}'"
  else
    log "Primary node already in expected cluster ${NAME}"
  fi

  local i
  for i in "${!NODES[@]}"; do
    if [[ "$i" -eq 0 ]]; then
      continue
    fi

    local ip="${NODES[$i]}"
    local node_cluster

    node_cluster="$(ssh_run "$ip" "pvecm status 2>/dev/null | awk -F': *' '/^Name:/{print \$2; exit}'" || true)"
    if [[ "$node_cluster" == "$NAME" ]]; then
      log "Node ${ip} already in cluster ${NAME}; skipping join"
      continue
    fi

    if [[ -n "$node_cluster" && "$node_cluster" != "$NAME" ]]; then
      die "node ${ip} belongs to different cluster '${node_cluster}'"
    fi

    log "Joining ${ip} to cluster ${NAME} via ${PRIMARY_IP}"
    sshpass -p "$LAB_PASS" ssh "${SSH_OPTS[@]}" "${LAB_USER}@${ip}" "cluster_pass_b64='${cluster_pass_b64}' primary_ip='${PRIMARY_IP}' node_ip='${ip}' fp='${primary_fingerprint}' bash -lc 'printf \"%s\" \"\$cluster_pass_b64\" | base64 -d | pvecm add \"\$primary_ip\" --force --link0 \"address=\$node_ip\" --fingerprint \"\$fp\"'"
  done

  local expected_count actual_count
  expected_count="${#NODES[@]}"
  actual_count="$(ssh_run "$PRIMARY_IP" "pvecm status | awk -F': *' '/^Nodes:/{print \$2; exit}'")"

  [[ "$actual_count" == "$expected_count" ]] || die "cluster node count mismatch: expected ${expected_count}, got ${actual_count}"
  log "Cluster ${NAME} has expected node count ${actual_count}"
}

ensure_ceph_installed() {
  local primary_host
  local i

  primary_host="${HOSTNAMES[0]}"

  for i in "${!NODES[@]}"; do
    local ip="${NODES[$i]}"

    if [[ "$PVE_REPO_CHANNEL" == "no-subscription" ]]; then
      log "Configuring no-subscription Proxmox/Ceph repos on ${ip}"
      sshpass -p "$LAB_PASS" ssh "${SSH_OPTS[@]}" "${LAB_USER}@${ip}" "bash -s" -- "$PVE_REPO_SUITES" <<'EOF_REPO'
set -euo pipefail
suite="$1"

if [[ -f /etc/apt/sources.list.d/pve-enterprise.sources ]]; then
  mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.disabled
fi
if [[ -f /etc/apt/sources.list.d/ceph.sources ]]; then
  mv /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph-enterprise.sources.disabled
fi

cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOT
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${suite}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOT

cat > /etc/apt/sources.list.d/ceph-no-subscription.sources <<EOT
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: ${suite}
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOT

apt-get update
EOF_REPO
    fi

    if ssh_run "$ip" "command -v ceph-mon >/dev/null 2>&1 && command -v ceph-osd >/dev/null 2>&1"; then
      log "Ceph daemons already installed on ${ip}"
    else
      log "Installing Ceph (${CEPH_VERSION}) on ${ip}"
      ssh_run "$ip" "DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none bash -lc 'yes | pveceph install --version ${CEPH_VERSION}'"
    fi

    ssh_run "$ip" "command -v ceph-mon >/dev/null 2>&1"
    ssh_run "$ip" "command -v ceph-osd >/dev/null 2>&1"
  done

  if [[ -z "$CEPH_PUBLIC_NETWORK" ]]; then
    die "missing CEPH_PUBLIC_NETWORK (or VLAN_ROUTABLE_NETWORK) for ceph init"
  fi

  if ssh_run "$PRIMARY_IP" "test -f /etc/pve/ceph.conf"; then
    log "Ceph config already exists on primary ${PRIMARY_IP}"
  else
    log "Initializing Ceph cluster on ${PRIMARY_IP} (network ${CEPH_PUBLIC_NETWORK})"
    ssh_run "$PRIMARY_IP" "pveceph init --network ${CEPH_PUBLIC_NETWORK}"
  fi

  if ssh_run "$PRIMARY_IP" "systemctl list-units 'ceph-mon@*.service' --all --no-legend 2>/dev/null | grep -q 'ceph-mon@'"; then
    log "Ceph monitor already present"
  else
    log "Creating initial Ceph monitor on ${PRIMARY_IP}"
    ssh_run "$PRIMARY_IP" "pveceph mon create"
  fi

  if ssh_run "$PRIMARY_IP" "systemctl list-units 'ceph-mgr@*.service' --all --no-legend 2>/dev/null | grep -q 'ceph-mgr@'"; then
    log "Ceph manager already present"
  else
    log "Creating initial Ceph manager on ${PRIMARY_IP}"
    ssh_run "$PRIMARY_IP" "pveceph mgr create"
  fi

  for i in "${!NODES[@]}"; do
    local ip="${NODES[$i]}"
    local host="${HOSTNAMES[$i]}"

    if ssh_run "$ip" "systemctl list-units 'ceph-osd@*' --all --no-legend 2>/dev/null | grep -q 'ceph-osd@'"; then
      log "Ceph OSD already present on ${ip}; skipping OSD create"
      continue
    fi

    log "Creating Ceph OSD on ${ip} using ${CEPH_OSD_DEVICE}"
    ssh_run "$ip" "test -b ${CEPH_OSD_DEVICE}"
    ssh_run "$ip" "pveceph osd create ${CEPH_OSD_DEVICE}"
    log "OSD create finished on ${host}"
  done

  if ssh_run "$PRIMARY_IP" "ceph osd pool ls 2>/dev/null | grep -qx '${CEPH_POOL_NAME}'"; then
    log "Ceph pool ${CEPH_POOL_NAME} already exists"
  else
    log "Creating Ceph RBD pool ${CEPH_POOL_NAME}"
    ssh_run "$PRIMARY_IP" "pveceph pool create ${CEPH_POOL_NAME} --application rbd --size ${CEPH_POOL_SIZE} --min_size ${CEPH_POOL_MIN_SIZE} --pg_autoscale_mode on --pg_num ${CEPH_POOL_PG_NUM}"
  fi

  if ssh_run "$PRIMARY_IP" "grep -q '^rbd: ${CEPH_RBD_STORAGE_ID}$' /etc/pve/storage.cfg"; then
    log "Proxmox storage ${CEPH_RBD_STORAGE_ID} already exists"
  else
    log "Adding Proxmox RBD storage ${CEPH_RBD_STORAGE_ID}"
    ssh_run "$PRIMARY_IP" "pvesm add rbd ${CEPH_RBD_STORAGE_ID} --pool ${CEPH_POOL_NAME} --content ${CEPH_RBD_CONTENT} --krbd 0"
  fi

  if ssh_run "$PRIMARY_IP" "ceph fs ls 2>/dev/null | grep -q 'name: ${CEPH_FS_NAME}'"; then
    log "CephFS ${CEPH_FS_NAME} already exists"
  else
    if ssh_run "$PRIMARY_IP" "ceph mds stat 2>/dev/null | grep -Eq 'up:|standby'"; then
      log "Ceph MDS already present"
    else
      log "Creating Ceph MDS daemon"
      ssh_run "$PRIMARY_IP" "pveceph mds create"
    fi

    log "Creating CephFS ${CEPH_FS_NAME}"
    ssh_run "$PRIMARY_IP" "pveceph fs create --name ${CEPH_FS_NAME} --pg_num ${CEPH_POOL_PG_NUM}"
  fi

  if ssh_run "$PRIMARY_IP" "grep -q '^cephfs: ${CEPH_FS_STORAGE_ID}$' /etc/pve/storage.cfg"; then
    log "Proxmox storage ${CEPH_FS_STORAGE_ID} already exists"
  else
    log "Adding Proxmox CephFS storage ${CEPH_FS_STORAGE_ID}"
    ssh_run "$PRIMARY_IP" "pvesm add cephfs ${CEPH_FS_STORAGE_ID} --fs-name ${CEPH_FS_NAME} --path ${CEPH_FS_PATH} --content ${CEPH_FS_CONTENT}"
  fi

  log "Final Ceph health check"
  ssh_run "$PRIMARY_IP" "ceph -s | sed -n '1,80p'"
  ssh_run "$PRIMARY_IP" "pvesm status | grep -E '^Name|${CEPH_RBD_STORAGE_ID}|${CEPH_FS_STORAGE_ID}'"
}

log "Using config file: ${CONF_FILE}"
log "Cluster name: ${NAME}"
log "Cluster nodes: ${CLUSTER_NODES}"

ensure_hostnames_and_hosts_file
ensure_cluster_membership
ensure_ceph_installed

log "Cluster and Ceph bootstrap completed successfully"
