# handy things

```shell
# move old templates
ssh -n root@192.168.222.155 'set -euo pipefail; mkdir -p /etc/pve/nodes/lab-swarm02-node01/qemu-server /etc/pve/nodes/lab-swarm02-node01/lxc; ts=$(date +%s); mkdir -p /root/pve-manual-move-backup-$ts; cp -a /etc/pve/nodes/proxception01 /root/pve-manual-move-backup-$ts/ 2>/dev/null || true; if ls /etc/pve/nodes/proxception01/qemu-server/*.conf >/dev/null 2>&1; then mv -f /etc/pve/nodes/proxception01/qemu-server/*.conf /etc/pve/nodes/lab-swarm02-node01/qemu-server/; fi; if ls /etc/pve/nodes/proxception01/lxc/*.conf >/dev/null 2>&1; then mv -f /etc/pve/nodes/proxception01/lxc/*.conf /etc/pve/nodes/lab-swarm02-node01/lxc/; fi; systemctl restart pvestatd pvedaemon pveproxy; echo backup:/root/pve-manual-move-backup-$ts; echo "== qemu files now =="; ls -1 /etc/pve/nodes/lab-swarm02-node01/qemu-server || true; echo "== cluster vm ownership =="; LC_ALL=C LANG=C pvesh get /cluster/resources --type vm | sed -n "1,140p"'
```
