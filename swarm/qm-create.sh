# boot: order=scsi0;ide2;net0
# cores: 2
# cpu: host
# ide2: ca-image-store:iso/proxmox-ve_9.1-1-proxception.iso,media=cdrom,size=1790016K
# memory: 8192
# meta: creation-qemu=10.1.2,ctime=1774235771
# name: raw-snuc
# net0: virtio=BC:24:11:6E:8D:20,bridge=vmbr0,firewall=1,tag=850
# net1: virtio=BC:24:11:6E:8D:21,bridge=vmbr0,firewall=1,tag=850
# numa: 0
# ostype: l26
# scsi0: vm-os:vm-22101-disk-0,iothread=1,size=32G,ssd=1
# scsi1: vm-os:vm-22101-disk-1,iothread=1,size=64G,ssd=1
# scsihw: virtio-scsi-single
# smbios1: uuid=d7cef1ff-aae4-4044-8f48-ed22ad863e16
# sockets: 2
# vmgenid: 037a447f-5fc8-4aca-84be-1aec88568cca


qm create 22101 \
  --name raw-snuc \
  --ostype l26 \
  --sockets 2 \
  --cores 2 \
  --cpu host \
  --memory 8192 \
  --numa 0 \
  --scsihw virtio-scsi-single \
  --boot "order=scsi0;ide2;net0" \
  --net0 "virtio,bridge=vmbr0,firewall=1,tag=850" \
  --net1 "virtio,bridge=vmbr0,firewall=1,tag=850" \
  --ide2 "ca-image-store:iso/proxmox-ve_9.1-1-proxception.iso,media=cdrom" \
  --scsi0 "vm-os:32,iothread=1,ssd=1" \
  --scsi1 "vm-os:64,iothread=1,ssd=1"



  qm create 22104 --name raw-snuc4 --ostype l26 --sockets 2 --cores 2 --cpu host --memory 8192 --numa 0 --scsihw virtio-scsi-single --boot "order=scsi0;ide2;net0" --net0 "virtio,bridge=vmbr0,firewall=1,tag=850" --net1 "virtio,bridge=vmbr0,firewall=1,tag=850" --ide2 "ca-image-store:iso/ubuntu-24.04.3-live-server-amd64.iso,media=cdrom" --scsi0 "vm-os:32,iothread=1,ssd=1" --scsi1 "vm-os:64,iothread=1,ssd=1"