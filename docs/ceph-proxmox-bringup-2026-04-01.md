# Ceph Bring-Up On Proxmox (2026-04-01)

This documents exactly what was done to move the 3-node Proxmox cluster from:

- `HEALTH_WARN: OSD count 0 < osd_pool_default_size 3`

to:

- `HEALTH_OK` with `3 osds: 3 up, 3 in`

## Cluster Nodes

- `pve01` = `192.168.51.63`
- `pve02` = `192.168.51.25`
- `pve03` = `192.168.51.23`

## Starting State

Checked on `pve01`:

```bash
pveceph status
```

Observed:

- MON and MGR existed
- OSD count was 0
- Health warning about replica size vs OSD count

Checked available block devices on each node:

```bash
lsblk
```

Free data disk selected on all nodes:

- `/dev/sdb`

## What Was Run

### 1) Create first OSD on pve01

```bash
ssh root@192.168.51.63 'pveceph osd create /dev/sdb'
```

Result: created and activated `osd.0`.

### 2) Create OSD on pve02

Initial attempt:

```bash
ssh root@192.168.51.25 'pveceph osd create /dev/sdb'
```

Result: failed due to missing Ceph binaries (`/usr/bin/ceph-mon` not installed).

Installed Ceph packages, then retried:

```bash
ssh root@192.168.51.25 'pveceph install --version squid'
ssh root@192.168.51.25 'pveceph osd create /dev/sdb'
```

Result: created and activated `osd.1`.

### 3) Create OSD on pve03

Installed Ceph packages, then created OSD:

```bash
ssh root@192.168.51.23 'pveceph install --version squid'
ssh root@192.168.51.23 'pveceph osd create /dev/sdb'
```

Result: created and activated `osd.2`.

### 4) Stabilize OSD service on pve03

`osd.2` briefly reported down during convergence, so service was checked and restarted:

```bash
ssh root@192.168.51.23 'systemctl status ceph-osd@2 --no-pager -l'
ssh root@192.168.51.23 'journalctl -u ceph-osd@2 -n 80 --no-pager'
ssh root@192.168.51.23 'systemctl restart ceph-osd@2'
```

## Final Verification

Run from `pve01`:

```bash
ceph -s
ceph osd stat
ceph osd tree
ceph health detail
```

Final observed state:

- `HEALTH_OK`
- `3 osds: 3 up, 3 in`
- PGs `active+clean`

## Notes

- `pveceph osd create` consumes and prepares the disk for Ceph OSD use.
- Verify the target disk is not used by Proxmox system/storage before creating an OSD.
- For multi-node clusters, ensure Ceph packages are installed on each node where OSDs are created.

## Replicated Pool Layout Added For Proxmox Storage

After base OSD bring-up, a dedicated replicated RBD pool was created and added as shared Proxmox storage.

### Commands Used

Run on `pve01`:

```bash
pveceph pool create rbd-vm --application rbd --size 3 --min_size 2 --pg_autoscale_mode on --pg_num 32
pvesm add rbd ceph-rbd --pool rbd-vm --content images,rootdir --krbd 0
```

### Result

- New Ceph pool: `rbd-vm`
- Replica layout: `size=3`, `min_size=2`
- PG autoscaling: `on`
- Proxmox storage ID: `ceph-rbd`
- Storage content types: `images,rootdir`

### Verification Commands

```bash
ceph -s
ceph osd pool ls detail
pvesm status
cat /etc/pve/storage.cfg
```

Observed after creation:

- Cluster remained `HEALTH_OK`
- Pools increased to 2 (`.mgr` and `rbd-vm`)
- `ceph-rbd` showed `active` on all three nodes

## CephFS Shared File Storage Target Added

To support shared file storage use cases (ISOs, templates, backups, snippets), CephFS was created and attached to Proxmox.

### Commands Used

Run on `pve01`:

```bash
# CephFS requires at least one Metadata Server daemon.
pveceph mds create

# Create CephFS and backing pools.
pveceph fs create --name cephfs --pg_num 32

# Add CephFS as Proxmox storage.
pvesm add cephfs ceph-fs --fs-name cephfs --path /mnt/pve/ceph-fs --content iso,vztmpl,backup,snippets
```

### Result

- New CephFS filesystem: `cephfs`
- New pools created by Proxmox/Ceph: `cephfs_data`, `cephfs_metadata`
- Proxmox storage ID: `ceph-fs`
- Storage content types: `iso,vztmpl,backup,snippets`

### Verification Commands

```bash
ceph -s
ceph fs ls
ceph fs status
pvesm status
cat /etc/pve/storage.cfg
```

Observed after creation:

- Cluster remained `HEALTH_OK`
- MDS service was up (`1/1 daemons up`)
- Ceph pools increased to 4 (`.mgr`, `rbd-vm`, `cephfs_data`, `cephfs_metadata`)
- `ceph-fs` showed `active` across nodes