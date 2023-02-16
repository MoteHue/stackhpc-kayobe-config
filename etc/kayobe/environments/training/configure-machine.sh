#!/bin/bash

#############################################
# STACKHPC-KAYOBE-CONFIG AUFN TRAINING ENV  #
#############################################

set -eu

PELICAN_HOST="10.0.0.34 pelican pelican.service.compute.sms-lab.cloud"
PULP_HOST="10.205.3.187 pulp-server pulp-server.internal.sms-cloud"

# FIXME: Work around lack of DNS on SMS lab.
cat << EOF | sudo tee -a /etc/hosts
$PELICAN_HOST
$PULP_HOST
EOF

# Install git and tmux.
if $(which dnf 2>/dev/null >/dev/null); then
    sudo dnf -y install git tmux python3-virtualenv
else
    sudo apt update
    sudo apt -y install git tmux gcc libffi-dev python3-dev python-is-python3 python3-virtualenv
fi

# Disable the firewall.
sudo systemctl is-enabled firewalld && sudo systemctl stop firewalld && sudo systemctl disable firewalld

# Disable SELinux both immediately and permanently.
if $(which setenforce 2>/dev/null >/dev/null); then
    sudo setenforce 0
    sudo sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
fi

# Prevent sudo from performing DNS queries.
echo 'Defaults	!fqdn' | sudo tee /etc/sudoers.d/no-fqdn