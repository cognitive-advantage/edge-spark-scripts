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
Usage: publish_iso_to_cluster_image_store.sh <iso-path> <conf-file> [conf-file...]

Ensures each target Proxmox cluster has a Ceph-backed image store storage ID,
then uploads the ISO into that storage.

Defaults (override with env vars):
  IMAGE_STORE_ID=ca-image-store
  CEPHFS_STORAGE_ID=ceph-fs
  IMAGE_STORE_REL_PATH=image-store

Each conf file must provide:
  CLUSTER_NODES      (comma-separated, first node is used as cluster primary)
  LAB_SWARM_SECRETS  (user:password file, absolute or conf-relative)
EOF
}

if [[ "$#" -lt 2 ]]; then
  usage
  exit 1
fi

ISO_PATH="$1"
shift

[[ -f "$ISO_PATH" ]] || die "ISO file not found: $ISO_PATH"
ISO_BASENAME="$(basename "$ISO_PATH")"

IMAGE_STORE_ID="${IMAGE_STORE_ID:-ca-image-store}"
CEPHFS_STORAGE_ID="${CEPHFS_STORAGE_ID:-ceph-fs}"
IMAGE_STORE_REL_PATH="${IMAGE_STORE_REL_PATH:-image-store}"

command -v ssh >/dev/null 2>&1 || die "ssh is required"
command -v sshpass >/dev/null 2>&1 || die "sshpass is required"
command -v scp >/dev/null 2>&1 || die "scp is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

LOCAL_SHA256="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

for CONF_FILE in "$@"; do
  [[ -f "$CONF_FILE" ]] || die "conf file not found: $CONF_FILE"

  # Load conf in isolated scope per iteration.
  unset CLUSTER_NODES LAB_SWARM_SECRETS NAME
  # shellcheck disable=SC1090
  source "$CONF_FILE"

  [[ -n "${CLUSTER_NODES:-}" ]] || die "missing CLUSTER_NODES in ${CONF_FILE}"
  [[ -n "${LAB_SWARM_SECRETS:-}" ]] || die "missing LAB_SWARM_SECRETS in ${CONF_FILE}"

  IFS=',' read -r -a NODES <<< "$CLUSTER_NODES"
  [[ "${#NODES[@]}" -gt 0 ]] || die "CLUSTER_NODES empty in ${CONF_FILE}"
  PRIMARY_IP="${NODES[0]}"

  CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
  SECRETS_PATH="$LAB_SWARM_SECRETS"
  if [[ "$SECRETS_PATH" != /* ]]; then
    SECRETS_PATH="${CONF_DIR}/${SECRETS_PATH}"
  fi
  [[ -f "$SECRETS_PATH" ]] || die "secrets file not found for ${CONF_FILE}: ${SECRETS_PATH}"

  SECRET_LINE="$(head -n 1 "$SECRETS_PATH" | tr -d '\r')"
  [[ "$SECRET_LINE" == *:* ]] || die "invalid secrets format in ${SECRETS_PATH} (expected user:password)"
  SSH_USER="${SECRET_LINE%%:*}"
  SSH_PASS="${SECRET_LINE#*:}"
  [[ -n "$SSH_USER" && -n "$SSH_PASS" ]] || die "empty user or password in ${SECRETS_PATH}"

  log "Processing cluster from ${CONF_FILE} (primary ${PRIMARY_IP})"

  ssh_run() {
    local cmd="$1"
    sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${PRIMARY_IP}" "LC_ALL=C LANG=C ${cmd}"
  }

  # Validate CephFS storage exists and is active.
  if ! ssh_run "pvesm status | awk 'NR>1 && \$1==\"${CEPHFS_STORAGE_ID}\" && \$3==\"active\" {found=1} END {exit(found?0:1)}'"; then
    die "${CEPHFS_STORAGE_ID} is not active on cluster primary ${PRIMARY_IP}; run cluster/ceph bootstrap first"
  fi

  CEPHFS_PATH="$(ssh_run "awk '/^cephfs: ${CEPHFS_STORAGE_ID}$/{f=1;next} f&&/^[[:space:]]+path[[:space:]]+/{print \$2; exit}' /etc/pve/storage.cfg")"
  [[ -n "$CEPHFS_PATH" ]] || die "could not determine path for cephfs storage ${CEPHFS_STORAGE_ID} on ${PRIMARY_IP}"

  STORE_PATH="${CEPHFS_PATH%/}/${IMAGE_STORE_REL_PATH}"

  if ssh_run "grep -q '^dir: ${IMAGE_STORE_ID}$' /etc/pve/storage.cfg"; then
    log "Storage ${IMAGE_STORE_ID} already exists"
  elif ssh_run "grep -q '^[a-z0-9-]\+: ${IMAGE_STORE_ID}$' /etc/pve/storage.cfg"; then
    die "storage ID ${IMAGE_STORE_ID} exists with a different type on ${PRIMARY_IP}"
  else
    log "Adding Ceph-backed dir storage ${IMAGE_STORE_ID} at ${STORE_PATH}"
    ssh_run "mkdir -p '${STORE_PATH}/template/iso'"
    ssh_run "pvesm add dir ${IMAGE_STORE_ID} --path '${STORE_PATH}' --content iso --shared 1"
  fi

  ssh_run "mkdir -p '${STORE_PATH}/template/iso'"

  REMOTE_ISO_PATH="${STORE_PATH}/template/iso/${ISO_BASENAME}"
  REMOTE_TMP_PATH="/tmp/${ISO_BASENAME}.upload"

  REMOTE_SHA256="$(ssh_run "test -f '${REMOTE_ISO_PATH}' && sha256sum '${REMOTE_ISO_PATH}' | awk '{print \$1}' || true")"
  if [[ "$REMOTE_SHA256" == "$LOCAL_SHA256" ]]; then
    log "ISO already present with matching checksum on ${PRIMARY_IP}: ${REMOTE_ISO_PATH}"
  else
    log "Uploading ISO to ${PRIMARY_IP}:${REMOTE_TMP_PATH}"
    sshpass -p "$SSH_PASS" scp "${SSH_OPTS[@]}" "$ISO_PATH" "${SSH_USER}@${PRIMARY_IP}:${REMOTE_TMP_PATH}"
    ssh_run "install -m 0644 '${REMOTE_TMP_PATH}' '${REMOTE_ISO_PATH}' && rm -f '${REMOTE_TMP_PATH}'"

    VERIFY_SHA256="$(ssh_run "sha256sum '${REMOTE_ISO_PATH}' | awk '{print \$1}'")"
    [[ "$VERIFY_SHA256" == "$LOCAL_SHA256" ]] || die "checksum mismatch after upload for ${PRIMARY_IP}"
    log "ISO uploaded and verified on ${PRIMARY_IP}: ${REMOTE_ISO_PATH}"
  fi

  if ssh_run "pvesm list ${IMAGE_STORE_ID} | grep -q 'iso/${ISO_BASENAME}'"; then
    log "Volume visible in Proxmox storage index: ${IMAGE_STORE_ID}:iso/${ISO_BASENAME}"
  else
    log "ISO copied successfully, but not yet listed in pvesm list (may require a short refresh)"
  fi

done

log "ISO publication completed for all requested clusters"
