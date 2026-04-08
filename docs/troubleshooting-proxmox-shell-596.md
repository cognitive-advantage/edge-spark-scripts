# Troubleshooting Proxmox Shell Connection Error 596

## Symptom

In Proxmox web UI (or shell proxy), shell/open-console operations fail with:

```text
Connection error 596: error:0A000086:SSL routines::certificate verify failed
```

## Root Cause

Cluster node TLS certificates were valid, but node-to-node hostname resolution was incomplete.

Each node's `/etc/hosts` had only its own hostname mapping, so peer hostnames were not consistently resolvable during internal Proxmox API/proxy calls.

When Proxmox components validated peer certificates against hostnames, verification could fail intermittently and surface as error 596.

## Confirming The Issue

On an affected node, check cluster health and certificate metadata:

```bash
pvecm status
openssl x509 -in /etc/pve/nodes/$(hostname)/pve-ssl.pem -noout -subject -issuer -dates -ext subjectAltName
```

Then check hostname resolution for all peers:

```bash
getent hosts pve01 pve02 pve03
```

If peer names are missing or not resolved correctly, you likely hit this issue.

## Remedy

Add all cluster node hostname mappings to `/etc/hosts` on every node.

Example for a 3-node cluster:

```text
192.168.51.63 pve01.edgespark.local pve01
192.168.51.25 pve02.edgespark.local pve02
192.168.51.23 pve03.edgespark.local pve03
```

After updating `/etc/hosts` on each node, restart `pveproxy`:

```bash
systemctl restart pveproxy
```

## Verification

Run on each node:

```bash
getent hosts pve01 pve02 pve03
systemctl is-active pveproxy
```

Expected:

- all three hostnames resolve
- `pveproxy` is `active`
- Proxmox web shell opens without TLS verify error 596

## Notes

- This issue is about internal hostname resolution consistency, not certificate expiration.
- Even with valid cert SANs, failed/missing peer name resolution can still break TLS verification paths.
