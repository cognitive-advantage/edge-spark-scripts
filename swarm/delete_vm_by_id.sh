#!/bin/bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

if [[ "$#" -ne 2 ]]; then
  die "usage: $0 <proxmox_ip> <vm_id>"
fi

PROXMOX_HOST="$1"
VMID="$2"

if [[ -z "$PROXMOX_HOST" ]]; then
  die "proxmox_ip is required"
fi

if [[ ! "$PROXMOX_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
  die "invalid proxmox_ip: $PROXMOX_HOST"
fi

if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
  die "vm_id must be numeric"
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
command -v sshpass >/dev/null 2>&1 || die "sshpass is required"

ssh_exec() {
  sshpass -p "$PROXMOX_PASS" ssh -n "${SSH_OPTS[@]}" \
    -o BatchMode=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    "${PROXMOX_USER}@${PROXMOX_HOST}" "$@"
}

remote_ssh() {
  ssh_exec "LC_ALL=C LANG=C $*"
}

remote_bash_with_vmid() {
  ssh_exec "LC_ALL=C LANG=C bash -s -- '${VMID}'"
}

ssh_exec true >/dev/null 2>&1 || die "cannot authenticate to ${PROXMOX_USER}@${PROXMOX_HOST} using proxmox secrets"

log "Deleting VM ${VMID} on ${PROXMOX_HOST}"

if remote_ssh "qm status ${VMID} >/dev/null 2>&1"; then
  if remote_ssh "qm config ${VMID} | grep -q '^lock:'"; then
    log "Unlocking VM ${VMID}"
    remote_ssh "qm unlock ${VMID} >/dev/null 2>&1 || true"
  fi

  if remote_ssh "qm status ${VMID} | grep -q 'status: running'"; then
    log "Stopping running VM ${VMID}"
    remote_ssh "qm stop ${VMID} --timeout 60 >/dev/null 2>&1 || true"
    sleep 2
  fi

  if remote_ssh "qm status ${VMID} | grep -q 'status: running'"; then
    log "Force stopping VM ${VMID}"
    remote_ssh "qm stop ${VMID} --skiplock 1 --timeout 30 >/dev/null 2>&1 || true"
    sleep 2
  fi

  log "Destroying VM ${VMID}"
  remote_ssh "qm destroy ${VMID} --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 || true"
else
  log "VM ${VMID} not found in qm; continuing with stale artifact cleanup"
fi

log "Cleaning cluster metadata and lock artifacts for VM ${VMID}"
remote_bash_with_vmid <<'EOF_REMOTE_META'
set -euo pipefail
vmid="$1"
for node in $(ls /etc/pve/nodes 2>/dev/null); do
  pvesh delete "/nodes/${node}/qemu/${vmid}" --purge 1 >/dev/null 2>&1 || true
done
find /etc/pve/nodes -maxdepth 3 -type f -name "${vmid}.conf" -delete >/dev/null 2>&1 || true
find /etc/pve -maxdepth 6 -type f -path "*/qemu-server/${vmid}.conf.tmp.*" -delete >/dev/null 2>&1 || true
rm -f "/run/lock/qemu-server/lock-${vmid}.conf" "/var/lock/qemu-server/lock-${vmid}.conf" >/dev/null 2>&1 || true
EOF_REMOTE_META

log "Cleaning storage dross for VM ${VMID}"
remote_bash_with_vmid <<'EOF_REMOTE_STORAGE'
set -euo pipefail
vmid="$1"

clear_cloudinit_watchers() {
  local location="$1"
  local status watcher_ip

  status="$(rbd status "${location}/vm-${vmid}-cloudinit" 2>/dev/null || true)"
  [[ -n "$status" ]] || return 0

  while IFS= read -r watcher_ip; do
    [[ -n "$watcher_ip" ]] || continue
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${watcher_ip}" \
      "pkill -9 -f '/usr/bin/kvm -id ${vmid}' || true" >/dev/null 2>&1 || true
  done < <(printf '%s\n' "$status" | sed -n 's/.*watcher=\([0-9.]*\):.*/\1/p' | sort -u)
}

cleanup_rbd_images() {
  local location="$1"
  local img
  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    rbd snap purge "${location}/${img}" >/dev/null 2>&1 || true
    if ! rbd rm "${location}/${img}" >/dev/null 2>&1; then
      if [[ "$img" == "vm-${vmid}-cloudinit" ]]; then
        clear_cloudinit_watchers "$location"
        sleep 1
        rbd rm "${location}/${img}" >/dev/null 2>&1 || true
      fi
    fi
  done < <(rbd ls "$location" 2>/dev/null | grep -E "^vm-${vmid}-(cloudinit|disk-[0-9]+)$" || true)
}

if command -v pvesm >/dev/null 2>&1; then
  pvesm free "vm-os:vm-${vmid}-cloudinit" >/dev/null 2>&1 || true
  while IFS= read -r storage; do
    [[ -n "$storage" ]] || continue
    while IFS= read -r volid; do
      [[ -n "$volid" ]] || continue
      pvesm free "$volid" >/dev/null 2>&1 || true
    done < <(pvesm list "$storage" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E "vm-${vmid}-(cloudinit|disk-[0-9]+)" || true)
  done < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | sort -u)
fi

if command -v rbd >/dev/null 2>&1; then
  while IFS= read -r pool; do
    [[ -n "$pool" ]] || continue
    clear_cloudinit_watchers "$pool"
    cleanup_rbd_images "$pool"
    while IFS= read -r ns; do
      [[ -n "$ns" ]] || continue
      clear_cloudinit_watchers "$pool/$ns"
      cleanup_rbd_images "$pool/$ns"
    done < <(rbd namespace ls "$pool" 2>/dev/null || true)
  done < <(rbd pool ls 2>/dev/null || true)
fi

# Retry pvesm free after watcher cleanup and direct rbd deletion.
if command -v pvesm >/dev/null 2>&1; then
  while IFS= read -r storage; do
    [[ -n "$storage" ]] || continue
    while IFS= read -r volid; do
      [[ -n "$volid" ]] || continue
      pvesm free "$volid" >/dev/null 2>&1 || true
    done < <(pvesm list "$storage" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E "vm-${vmid}-(cloudinit|disk-[0-9]+)" || true)
  done < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | sort -u)
fi
EOF_REMOTE_STORAGE

log "Verifying VM ${VMID} is fully gone"
remote_bash_with_vmid <<'EOF_REMOTE_VERIFY'
set -euo pipefail
vmid="$1"

if qm status "$vmid" >/dev/null 2>&1; then
  echo "qm still has VM $vmid" >&2
  exit 1
fi

if find /etc/pve/nodes -maxdepth 3 -type f -name "${vmid}.conf" | grep -q .; then
  echo "stale qemu config still present for VM $vmid" >&2
  exit 1
fi

if command -v pvesm >/dev/null 2>&1; then
  if pvesm list vm-os 2>/dev/null | awk 'NR>1 {print $1}' | grep -Eq "^vm-os:vm-${vmid}-cloudinit$"; then
    echo "cloud-init volume still present for VM $vmid" >&2
    exit 1
  fi
  if pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | while IFS= read -r storage; do pvesm list "$storage" 2>/dev/null | awk 'NR>1 {print $1}'; done | grep -Eq "vm-${vmid}-(cloudinit|disk-[0-9]+)"; then
    echo "storage volume still present for VM $vmid" >&2
    exit 1
  fi
fi

if command -v rbd >/dev/null 2>&1; then
  if rbd pool ls 2>/dev/null | while IFS= read -r pool; do
    rbd ls "$pool" 2>/dev/null || true
    rbd namespace ls "$pool" 2>/dev/null | while IFS= read -r ns; do
      rbd ls "$pool/$ns" 2>/dev/null || true
    done
  done | grep -Eq "^vm-${vmid}-(cloudinit|disk-[0-9]+)$"; then
    echo "RBD image still present for VM $vmid" >&2
    exit 1
  fi
fi
EOF_REMOTE_VERIFY

log "Sweeping all storages for orphaned vm disks/cloudinit volumes"
remote_ssh "LC_ALL=C LANG=C bash -s" <<'EOF_REMOTE_SWEEP'
set -euo pipefail

active_vmids_file="$(mktemp)"
pvesm_orphan_count=0
rbd_orphan_count=0

pvesh get /cluster/resources --type vm --output-format json \
  | sed -n 's/.*"vmid"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' \
  | sort -u > "$active_vmids_file"

is_orphan_vmid() {
  local candidate_vmid="$1"
  ! grep -qx "$candidate_vmid" "$active_vmids_file"
}

extract_vmid_from_name() {
  local name="$1"
  printf '%s\n' "$name" | sed -n 's/.*vm-\([0-9]\+\)-.*/\1/p'
}

clear_rbd_watchers() {
  local location="$1"
  local image="$2"
  local status watcher_ip

  status="$(rbd status "${location}/${image}" 2>/dev/null || true)"
  [[ -n "$status" ]] || return 0

  while IFS= read -r watcher_ip; do
    [[ -n "$watcher_ip" ]] || continue
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${watcher_ip}" \
      "pkill -9 -f '/usr/bin/kvm -id [0-9]+' || true" >/dev/null 2>&1 || true
  done < <(printf '%s\n' "$status" | sed -n 's/.*watcher=\([0-9.]*\):.*/\1/p' | sort -u)
}

delete_orphan_rbd_image() {
  local location="$1"
  local image="$2"

  rbd snap purge "${location}/${image}" >/dev/null 2>&1 || true
  if ! rbd rm "${location}/${image}" >/dev/null 2>&1; then
    clear_rbd_watchers "$location" "$image"
    sleep 1
    rbd rm "${location}/${image}" >/dev/null 2>&1 || true
  fi
}

if command -v pvesm >/dev/null 2>&1; then
  while IFS= read -r storage; do
    [[ -n "$storage" ]] || continue

    while IFS= read -r volid; do
      [[ -n "$volid" ]] || continue

      if [[ ! "$volid" =~ vm-[0-9]+-(cloudinit|disk-[0-9]+)$ ]]; then
        continue
      fi

      candidate_vmid="$(printf '%s\n' "$volid" | sed -n 's/.*vm-\([0-9]\+\)-.*/\1/p')"
      [[ -n "$candidate_vmid" ]] || continue

      if is_orphan_vmid "$candidate_vmid"; then
        echo "Deleting orphan volume: $volid"
        pvesm free "$volid" >/dev/null 2>&1 || true
        pvesm_orphan_count=$((pvesm_orphan_count + 1))
      fi
    done < <(pvesm list "$storage" 2>/dev/null | awk 'NR>1 {print $1}')
  done < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | sort -u)
fi

if command -v rbd >/dev/null 2>&1; then
  while IFS= read -r pool; do
    [[ -n "$pool" ]] || continue

    while IFS= read -r image; do
      [[ -n "$image" ]] || continue
      [[ "$image" =~ ^vm-[0-9]+-(cloudinit|disk-[0-9]+)$ ]] || continue

      candidate_vmid="$(extract_vmid_from_name "$image")"
      [[ -n "$candidate_vmid" ]] || continue

      if is_orphan_vmid "$candidate_vmid"; then
        echo "Deleting orphan RBD image: ${pool}/${image}"
        delete_orphan_rbd_image "$pool" "$image"
        rbd_orphan_count=$((rbd_orphan_count + 1))
      fi
    done < <(rbd ls "$pool" 2>/dev/null || true)

    while IFS= read -r ns; do
      [[ -n "$ns" ]] || continue
      location="${pool}/${ns}"

      while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        [[ "$image" =~ ^vm-[0-9]+-(cloudinit|disk-[0-9]+)$ ]] || continue

        candidate_vmid="$(extract_vmid_from_name "$image")"
        [[ -n "$candidate_vmid" ]] || continue

        if is_orphan_vmid "$candidate_vmid"; then
          echo "Deleting orphan RBD image: ${location}/${image}"
          delete_orphan_rbd_image "$location" "$image"
          rbd_orphan_count=$((rbd_orphan_count + 1))
        fi
      done < <(rbd ls "$location" 2>/dev/null || true)
    done < <(rbd namespace ls "$pool" 2>/dev/null || true)
  done < <(rbd pool ls 2>/dev/null || true)
fi

rm -f "$active_vmids_file"
echo "Orphan sweep complete. pvesm deleted: $pvesm_orphan_count, rbd deleted: $rbd_orphan_count"
EOF_REMOTE_SWEEP

log "VM ${VMID} fully cleaned up"
