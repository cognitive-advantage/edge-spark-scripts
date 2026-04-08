#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (use sudo)." >&2
  exit 1
fi

FAIL=0
REQUIRE_HOST_KEYS_REMOVED="${REQUIRE_HOST_KEYS_REMOVED:-1}"

ok() {
  echo "PASS: $*"
}

warn() {
  echo "WARN: $*"
}

fail() {
  echo "FAIL: $*"
  FAIL=1
}

require_pkg() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    ok "package installed: ${pkg}"
  else
    fail "package missing: ${pkg}"
  fi
}

echo "== Validate: required packages =="
for pkg in qemu-guest-agent cloud-init cloud-initramfs-growroot openssh-server chrony curl ca-certificates jq ceph-common; do
  require_pkg "$pkg"
done

echo
echo "== Validate: swap disabled =="
if swapon --show | tail -n +2 | grep -q .; then
  fail "active swap detected"
else
  ok "no active swap"
fi

if grep -Eq '^[^#].+[[:space:]]swap[[:space:]]' /etc/fstab; then
  fail "uncommented swap entry exists in /etc/fstab"
else
  ok "no uncommented swap entries in /etc/fstab"
fi

echo
echo "== Validate: modules-load config =="
if [[ -f /etc/modules-load.d/k8s-ceph.conf ]]; then
  ok "found /etc/modules-load.d/k8s-ceph.conf"
  for m in overlay br_netfilter rbd ceph; do
    if grep -Eq "^${m}$" /etc/modules-load.d/k8s-ceph.conf; then
      ok "module configured for boot: ${m}"
    else
      fail "module missing from boot config: ${m}"
    fi
    if lsmod | awk '{print $1}' | grep -qx "$m"; then
      ok "module loaded now: ${m}"
    else
      warn "module not loaded now: ${m} (may still load on boot)"
    fi
  done
else
  fail "missing /etc/modules-load.d/k8s-ceph.conf"
fi

echo
echo "== Validate: sysctl baseline =="
check_sysctl() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(sysctl -n "$key" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    ok "${key}=${expected}"
  else
    fail "${key} expected ${expected}, got '${actual}'"
  fi
}

check_sysctl net.bridge.bridge-nf-call-iptables 1
check_sysctl net.bridge.bridge-nf-call-ip6tables 1
check_sysctl net.ipv4.ip_forward 1

echo
echo "== Validate: cloud-init/machine-id cleanup =="
if [[ -L /var/lib/dbus/machine-id ]]; then
  ok "/var/lib/dbus/machine-id is symlink"
else
  fail "/var/lib/dbus/machine-id is not a symlink"
fi

if [[ -f /etc/machine-id ]]; then
  size="$(stat -c%s /etc/machine-id)"
  if [[ "$size" == "0" ]]; then
    ok "/etc/machine-id is empty"
  else
    warn "/etc/machine-id not empty (${size} bytes)"
  fi
else
  fail "/etc/machine-id missing"
fi

echo
echo "== Validate: host keys policy =="
shopt -s nullglob
host_keys=(/etc/ssh/ssh_host_*)
shopt -u nullglob
if [[ "$REQUIRE_HOST_KEYS_REMOVED" == "1" ]]; then
  if (( ${#host_keys[@]} == 0 )); then
    ok "SSH host keys removed (good for template cloning)"
  else
    fail "SSH host keys still present"
    ls -1 /etc/ssh/ssh_host_* || true
  fi
else
  if (( ${#host_keys[@]} == 0 )); then
    warn "SSH host keys removed"
  else
    ok "SSH host keys present"
  fi
fi

echo
echo "== Validate: services =="
for svc in chrony ssh; do
  if systemctl is-active "$svc" >/dev/null 2>&1; then
    ok "service active: ${svc}"
  else
    fail "service not active: ${svc}"
  fi
done
if systemctl is-active qemu-guest-agent >/dev/null 2>&1; then
  ok "service active: qemu-guest-agent"
else
  warn "qemu-guest-agent not active (can be normal until virtio channel is available)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "TEMPLATE VALIDATION: PASS"
  exit 0
fi

echo "TEMPLATE VALIDATION: FAIL"
exit 1
