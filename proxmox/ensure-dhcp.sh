#!/usr/bin/env bash
# Exit on error, undefined vars, and failed pipeline commands.
set -euo pipefail

# Ensure a given interface in /etc/network/interfaces is configured for DHCP.
# Designed for Debian/Proxmox hosts that use ifupdown.

# Path to the ifupdown configuration file used on Debian/Proxmox.
INTERFACES_FILE="/etc/network/interfaces"
# Interface to enforce DHCP on. Defaults to vmbr0 for common Proxmox setups.
TARGET_IFACE="vmbr0"
# Whether to reload networking after file update.
APPLY_CHANGES=""

# Parse arguments:
# - interface name (optional)
# - --apply (optional)
# Supports either order, e.g.:
#   ensure-dhcp.sh
#   ensure-dhcp.sh --apply
#   ensure-dhcp.sh vmbr1
#   ensure-dhcp.sh vmbr1 --apply
#   ensure-dhcp.sh --apply vmbr1
for arg in "$@"; do
  case "${arg}" in
    --apply)
      APPLY_CHANGES="--apply"
      ;;
    -h|--help)
      echo "Usage: $0 [interface] [--apply]"
      echo "Default interface: vmbr0"
      exit 0
      ;;
    --*)
      echo "Error: unknown option: ${arg}"
      echo "Usage: $0 [interface] [--apply]"
      exit 1
      ;;
    *)
      if [[ "${TARGET_IFACE}" != "vmbr0" ]]; then
        echo "Error: multiple interfaces provided: ${TARGET_IFACE} and ${arg}"
        echo "Usage: $0 [interface] [--apply]"
        exit 1
      fi
      TARGET_IFACE="${arg}"
      ;;
  esac
done

# Validate interface name before touching system config.
# Linux interface names may include alnum, underscore, dot, colon, and hyphen,
# but must not start with a dash.
if [[ "${TARGET_IFACE}" == -* || ! "${TARGET_IFACE}" =~ ^[[:alnum:]_.:-]+$ ]]; then
  echo "Error: invalid interface name: ${TARGET_IFACE}"
  echo "Usage: $0 [interface] [--apply]"
  exit 1
fi

# Require root because we modify system networking config.
if [[ "${EUID}" -ne 0 ]]; then
  echo "Error: run as root (sudo)."
  exit 1
fi

# Ensure the target config file exists before editing.
if [[ ! -f "${INTERFACES_FILE}" ]]; then
  echo "Error: ${INTERFACES_FILE} not found."
  exit 1
fi

# Guard against a legacy bad stanza produced by older argument parsing.
# If present, applying networking can fail with dhclient "Unknown command: --apply".
if grep -Eq '^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+--apply([[:space:]]|$)' "${INTERFACES_FILE}"; then
  echo "Error: detected invalid interface stanza '--apply' in ${INTERFACES_FILE}."
  echo "Fix by removing lines that reference '--apply' (for example: 'auto --apply' and 'iface --apply ...')."
  echo "Tip: restore from a backup file like ${INTERFACES_FILE}.bak.<timestamp> if available."
  exit 1
fi

# Prepare temporary output and a timestamped backup for rollback safety.
TMP_FILE="$(mktemp)"
BACKUP_FILE="${INTERFACES_FILE}.bak.$(date +%Y%m%d%H%M%S)"

# Backup current network config before any transformation.
cp -a "${INTERFACES_FILE}" "${BACKUP_FILE}"
echo "Backup created: ${BACKUP_FILE}"

# Rewrite only the target interface stanza using awk:
# - convert iface line to "inet dhcp"
# - remove static-only keys in that stanza
# - append a new DHCP stanza if target interface is missing
awk -v target_iface="${TARGET_IFACE}" '
BEGIN {
  # in_target: currently parsing the target iface stanza.
  # found: target iface stanza was seen at least once.
  in_target = 0
  found = 0
}

# Detect the start of any iface stanza.
/^iface[[:space:]]+/ {
  if ($2 == target_iface) {
    # Rewrite iface line to DHCP regardless of current method/family.
    print "iface " $2 " inet dhcp"
    in_target = 1
    found = 1
  } else {
    print $0
    in_target = 0
  }
  next
}

# Drop fields that only make sense for static configs.
in_target && /^[[:space:]]*(address|netmask|gateway|broadcast|pointopoint)[[:space:]]+/ {
  next
}

# Preserve all other lines.
{
  print $0
}

END {
  # If the interface was never declared, append a minimal DHCP stanza.
  if (!found) {
    print ""
    print "auto " target_iface
    print "iface " target_iface " inet dhcp"
  }
}
' "${INTERFACES_FILE}" > "${TMP_FILE}"

# Atomically replace the interfaces file with transformed output.
mv "${TMP_FILE}" "${INTERFACES_FILE}"
echo "Updated ${INTERFACES_FILE}: ${TARGET_IFACE} is set to DHCP."

# Optionally activate changes immediately.
if [[ "${APPLY_CHANGES}" == "--apply" ]]; then
  echo "Applying network configuration..."

  # Proxmox commonly provides ifreload (ifupdown2); prefer it if available.
  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a
  # Otherwise restart the networking service if it is currently active.
  elif systemctl is-active networking >/dev/null 2>&1; then
    systemctl restart networking
  else
    # Fallback for minimal environments without ifreload/systemd integration.
    ifdown "${TARGET_IFACE}" || true
    ifup "${TARGET_IFACE}"
  fi

  echo "Network configuration applied."
else
  # Default behavior is safe: write config now, reload later when ready.
  echo "Dry apply mode: no network reload attempted."
  echo "Run with --apply to reload networking now."
fi
