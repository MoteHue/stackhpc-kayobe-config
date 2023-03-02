#!/bin/bash

set -e
set -o pipefail

# This should be run on the seed hypervisor.

# IP addresses on the all-in-one Kayobe cloud network.
# These IP addresses map to those statically configured in
# etc/kayobe/network-allocation.yml and etc/kayobe/networks.yml.
controller_vip=192.168.59.2
seed_hv_ip=192.168.53.4

iface=$(ip route | awk '$1 == "default" {print $5; exit}')

# Private IP address by which the seed hypervisor is accessible in the cloud
# hosting the VM.
seed_hv_private_ip=$(ip a show dev $iface | awk '$1 == "inet" { gsub(/\/[0-9]*/,"",$2); print $2; exit }')

# Forward the following ports to the controller.
# 80: Horizon
# 6080: VNC console
forwarded_ports="80 3000 5601 6080 9091 9093 15672"

# IP of the seed hypervisor on the OpenStack 'external' network created by openstack-config.
public_ip="10.0.2.1"

# Install iptables.
if $(which dnf >/dev/null 2>&1); then
    sudo dnf -y install iptables
fi

# Configure local networking.
# Add bridges for the Kayobe networks.
if ! sudo ip l show brprov >/dev/null 2>&1; then
    sudo ip l add brprov type bridge
    sudo ip l set brprov up
    sudo ip a add $seed_hv_ip/24 dev brprov
fi

if ! sudo ip l show brcloud >/dev/null 2>&1; then
    sudo ip l add brcloud type bridge
    sudo ip l set brcloud up
fi

# On CentOS 8, bridges without a port are DOWN, which causes network
# configuration to fail. Add a dummy interface and plug it into the bridge.
for i in mgmt prov cloud; do
    if ! sudo ip l show dummy-$i >/dev/null 2>&1; then
      sudo ip l add dummy-$i type dummy
    fi
done

# Configure IP routing and NAT to allow the seed VM and overcloud hosts to
# route via this route to the outside world.
sudo iptables -A POSTROUTING -t nat -o $iface -j MASQUERADE
sudo sysctl -w net.ipv4.conf.all.forwarding=1

# FIXME: IP MASQUERADE from control plane fails without this on Ubuntu.
if ! $(which dnf >/dev/null 2>&1); then
    sudo modprobe br_netfilter
    echo 0 | sudo tee /proc/sys/net/bridge/bridge-nf-call-iptables
fi

# Configure port forwarding from the hypervisor to the Horizon GUI on the
# controller.
sudo iptables -A FORWARD -i $iface -o braio -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A FORWARD -i braio -o $iface -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for port in $forwarded_ports; do
  # Allow new connections.
  sudo iptables -A FORWARD -i $iface -o braio -p tcp --syn --dport $port -m conntrack --ctstate NEW -j ACCEPT
  # Destination NAT.
  sudo iptables -t nat -A PREROUTING -i $iface -p tcp --dport $port -j DNAT --to-destination $controller_vip
  # Source NAT.
  sudo iptables -t nat -A POSTROUTING -o braio -p tcp --dport $port -d $controller_vip -j SNAT --to-source $seed_hv_private_ip
done

echo
echo "NOTE: The network configuration applied by this script is not"
echo "persistent across reboots."
echo "If you reboot the system, please re-run this script."
