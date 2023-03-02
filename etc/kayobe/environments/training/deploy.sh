#!/bin/bash
# Script for a full deployment.

set -eu

##########################################################################

# These parameters must be changed to your own fork 
KAYOBE_CONFIG_REPO="https://github.com/motehue/stackhpc-kayobe-config"
KAYOBE_CONFIG_BRANCH=task-4-networking

##########################################################################

# These parameters may be changed if you wish to deviate from the defaults
BASE_PATH=~
KAYOBE_BRANCH=stackhpc/yoga 
KAYOBE_ENVIRONMENT=training


if [ $KAYOBE_CONFIG_REPO = "https://github.com/example/stackhpc-kayobe-config" ]
then
    echo "To run this script, you must first edit it to use your own repository"
    exit 0
fi


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

# Clone repositories
cd $BASE_PATH
mkdir -p src
pushd src
[[ -d kayobe ]] || git clone https://github.com/stackhpc/kayobe.git -b $KAYOBE_BRANCH
[[ -d kayobe-config ]] || git clone $KAYOBE_CONFIG_REPO kayobe-config -b $KAYOBE_CONFIG_BRANCH
[[ -d kayobe/tenks ]] || (cd kayobe && git clone https://opendev.org/openstack/tenks.git)
[[ -d openstack-config ]] || (git clone https://github.com/motehue/openstack-config.git)

# Change hard-coded seed IP in kayobe
sudo sed -i 's/SEED_IP=.*/SEED_IP="192.168.53.5"/' kayobe/dev/functions
popd

# Create Kayobe virtualenv
mkdir -p venvs
pushd venvs
if [[ ! -d kayobe ]]; then
    virtualenv kayobe
fi
# NOTE: Virtualenv's activate and deactivate scripts reference an
# unbound variable. 
set +u
source kayobe/bin/activate
set -u
pip install -U pip
pip install ../src/kayobe
popd

# Activate environment
pushd $BASE_PATH/src/kayobe-config
source kayobe-env --environment $KAYOBE_ENVIRONMENT

# Configure host networking (bridge, routes & firewall)
$KAYOBE_CONFIG_PATH/environments/$KAYOBE_ENVIRONMENT/configure-local-networking.sh

# Bootstrap the Ansible control host.
kayobe control host bootstrap

# Configure the seed hypervisor host.
kayobe seed hypervisor host configure

# Provision the seed VM.
kayobe seed vm provision

# Configure the seed host, and deploy a local registry.
kayobe seed host configure


# Deploy local pulp server as a container on the seed VM
kayobe seed service deploy --tags seed-deploy-containers --kolla-tags none

# Deploying the seed restarts networking interface, run configure-local-networking.sh again to re-add routes.
$KAYOBE_CONFIG_PATH/environments/$KAYOBE_ENVIRONMENT/configure-local-networking.sh

#######################################################################
# NEED TO ADD 10.205.3.187 pulp-server pulp-server.internal.sms-cloud 
# TO ETC/HOSTS OF DOCKER CONTAINER BEFORE SYNCING WITH UPSTEAM PULP
#######################################################################

# Add sms lab test pulp to /etc/hosts of seed vm's pulp container
SEED_IP=192.168.53.5
REMOTE_COMMAND="docker exec pulp sh -c 'echo $PULP_HOST | tee -a /etc/hosts'"
ssh stack@$SEED_IP $REMOTE_COMMAND

# Sync package & container repositories.
kayobe playbook run $KAYOBE_CONFIG_PATH/ansible/pulp-repo-sync.yml
kayobe playbook run $KAYOBE_CONFIG_PATH/ansible/pulp-repo-publish.yml
kayobe playbook run $KAYOBE_CONFIG_PATH/ansible/pulp-container-sync.yml
kayobe playbook run $KAYOBE_CONFIG_PATH/ansible/pulp-container-publish.yml

kayobe seed container image build bifrost_deploy

# Re-run full task to set up bifrost_deploy etc. using newly-populated pulp repo
kayobe seed service deploy


# Deploying the seed restarts networking interface, run configure-local-networking.sh again to re-add routes.
$KAYOBE_CONFIG_PATH/environments/$KAYOBE_ENVIRONMENT/configure-local-networking.sh


# NOTE: Make sure to use ./tenks, since just ‘tenks’ will install via PyPI.
(export TENKS_CONFIG_PATH=$KAYOBE_CONFIG_PATH/environments/$KAYOBE_ENVIRONMENT/tenks.yml && \
 export KAYOBE_CONFIG_SOURCE_PATH=$BASE_PATH/src/kayobe-config && \
 export KAYOBE_VENV_PATH=$BASE_PATH/venvs/kayobe && \
 cd $BASE_PATH/src/kayobe && \
 ./dev/tenks-deploy-overcloud.sh ./tenks)

# Inspect and provision the overcloud hardware:
kayobe overcloud inventory discover
kayobe overcloud provision
kayobe overcloud host command run --command "sudo sed -i 's/BOOTPROTO=.*/BOOTPROTO=none/' /etc/sysconfig/network-scripts/ifcfg-eth1" -l compute,storage
kayobe overcloud host configure
kayobe overcloud container image pull

kayobe playbook run $KAYOBE_CONFIG_PATH/ansible/cephadm-deploy.yml
sleep 30
kayobe playbook run $KAYOBE_CONFIG_PATH/ansible/cephadm.yml
kayobe playbook run $KAYOBE_CONFIG_PATH/ansible/cephadm-gather-keys.yml

kayobe overcloud service deploy
source $KOLLA_CONFIG_PATH/admin-openrc.sh
kayobe overcloud post configure
source $KOLLA_CONFIG_PATH/admin-openrc.sh

set +u
deactivate
set -u
# Create Openstack-Config virtualenv
cd $BASE_PATH
pushd venvs
if [[ ! -d os-config-venv ]]; then
    python3 -m venv os-config-venv
fi
# NOTE: Virtualenv's activate and deactivate scripts reference an unbound variable.
set +u
source os-config-venv/bin/activate
set -u
pip install -U pip
pushd $BASE_PATH/src/openstack-config
pip install -r requirements.txt
ansible-galaxy role install -p ansible/roles -r requirements.yml
ansible-galaxy role install -p ansible/collections -r requirements.yml
source $KOLLA_CONFIG_PATH/admin-openrc.sh
tools/openstack-config
popd
popd

# Create a test vm 
VENV_DIR=$BASE_PATH/venvs/os-venv
source $VENV_DIR/bin/activate
source $KOLLA_CONFIG_PATH/admin-openrc.sh
echo "Creating test vm:"
openstack server create --key-name mykey --flavor m1.tiny --image cirros --network demo-net test-vm-1
echo "Attaching floating IP:"
openstack floating ip create public1
openstack server add floating ip test-vm-1 `openstack floating ip list -c ID  -f value`
echo -e "Done! \nopenstack server list:"
openstack server list
