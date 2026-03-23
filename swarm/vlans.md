# vlans

the template we are using 1002 has in its hardware two network devices net0 and net1. the net0 should be routable i.e. the router will use a dynamic assigned ip 192.168.221.0/24 address from dhcp. the router will because of the tag 221 put this address in a 221 vlan. the second net1 with go in a private vlan tag 991 with a fixed ip address 10.254.221.0/24 the reason is that i want the cluster to use that network to do cluster things. the other vlan is routable so I can use it to interact with the vms using the web interface or ssh

