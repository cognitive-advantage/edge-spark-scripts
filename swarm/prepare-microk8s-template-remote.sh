#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (use sudo)." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

ensure_service_running() {
  local service="$1"
  if ! systemctl start --no-block "$service" >/dev/null 2>&1; then
    echo "Warning: ${service} start request failed in current runtime context." >&2
    return 0
  fi
  # Some units are static and cannot be enabled; do not fail the script for that.
  if ! systemctl enable "$service" >/dev/null 2>&1; then
    echo "Info: ${service} could not be enabled (likely static unit); started for current boot." >&2
  fi
  systemctl is-active "$service" >/dev/null 2>&1 || echo "Info: ${service} is not active yet." >&2
}

apt-get update -y
apt-get install -y \
  qemu-guest-agent \
  cloud-init \
  cloud-initramfs-growroot \
  openssh-server \
  chrony \
  curl \
  ca-certificates \
  jq \
  ceph-common

ensure_service_running qemu-guest-agent
ensure_service_running chrony
ensure_service_running ssh

# Disable swap immediately and persistently.
swapoff -a || true
cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
awk '
  {
    if ($0 ~ /^[[:space:]]*#/ || NF == 0) {
      print $0
      next
    }
    if ($3 == "swap") {
      print "# " $0 "  # disabled for kubernetes"
      next
    }
    print $0
  }
' /etc/fstab > /tmp/fstab.k8s && mv /tmp/fstab.k8s /etc/fstab

# Ensure required kernel modules load on boot.
cat <<'EOF' > /etc/modules-load.d/k8s-ceph.conf
overlay
br_netfilter
rbd
ceph
EOF

for mod in overlay br_netfilter rbd ceph; do
  if ! modprobe "$mod"; then
    echo "Warning: modprobe ${mod} failed. Verify kernel module availability." >&2
  fi
done

# Baseline Kubernetes networking sysctls.
cat <<'EOF' > /etc/sysctl.d/99-k8s-ceph.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

sysctl --system >/dev/null

# Golden-template cleanup.
cloud-init clean --logs
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

if [[ "${REMOVE_HOST_KEYS:-0}" == "1" ]]; then
  rm -f /etc/ssh/ssh_host_*
fi

echo "Template preparation complete on $(hostname)."
echo ""
echo "Validation summary:"
dpkg -l qemu-guest-agent cloud-init cloud-initramfs-growroot openssh-server chrony curl ca-certificates jq ceph-common | awk '/^ii/{print $2, $3}'
echo ""
echo "Swap status (should be empty):"
swapon --show || true
echo ""
echo "Module config file: /etc/modules-load.d/k8s-ceph.conf"
cat /etc/modules-load.d/k8s-ceph.conf
echo ""
echo "Sysctl config file: /etc/sysctl.d/99-k8s-ceph.conf"
cat /etc/sysctl.d/99-k8s-ceph.conf
