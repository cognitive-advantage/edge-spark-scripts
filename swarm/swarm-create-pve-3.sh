qm create 85101 \
  --name raw-snuc1 \
  --ostype l26 \
  --sockets 2 \
  --cores 2 \
  --cpu host \
  --memory 8192 \
  --numa 0 \
  --scsihw virtio-scsi-single \
  --boot "order=scsi0;ide2;net0" \
  --net0 "virtio,bridge=vmbr0,firewall=1,tag=851" \
  --net1 "virtio,bridge=vmbr0,firewall=1,tag=851" \
  --ide2 "ca-image-store:iso/proxmox-ve_9.1-1-proxception.iso,media=cdrom" \
  --scsi0 "vm-os:32,iothread=1,ssd=1" \
  --scsi1 "vm-os:64,iothread=1,ssd=1"

qm create 85102 \
  --name raw-snuc2 \
  --ostype l26 \
  --sockets 2 \
  --cores 2 \
  --cpu host \
  --memory 8192 \
  --numa 0 \
  --scsihw virtio-scsi-single \
  --boot "order=scsi0;ide2;net0" \
  --net0 "virtio,bridge=vmbr0,firewall=1,tag=851" \
  --net1 "virtio,bridge=vmbr0,firewall=1,tag=851" \
  --ide2 "ca-image-store:iso/proxmox-ve_9.1-1-proxception.iso,media=cdrom" \
  --scsi0 "vm-os:32,iothread=1,ssd=1" \
  --scsi1 "vm-os:64,iothread=1,ssd=1"

  qm create 85106 \
  --name raw-snuc3 \
  --ostype l26 \
  --sockets 2 \
  --cores 2 \
  --cpu host \
  --memory 8192 \
  --numa 0 \
  --scsihw virtio-scsi-single \
  --boot "order=scsi0;ide2;net0" \
  --net0 "virtio,bridge=vmbr0,firewall=1,tag=851" \
  --net1 "virtio,bridge=vmbr0,firewall=1,tag=851" \
  --ide2 "ca-image-store:iso/proxmox-ve_9.1-1-proxception.iso,media=cdrom" \
  --scsi0 "vm-os:32,iothread=1,ssd=1" \
  --scsi1 "vm-os:64,iothread=1,ssd=1"