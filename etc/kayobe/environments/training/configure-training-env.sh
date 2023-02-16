#!/bin/bash

#############################################
# STACKHPC-KAYOBE-CONFIG AUFN TRAINING ENV  #
#############################################

set -eu

BASE_PATH=~
KAYOBE_ENVIRONMENT=training

PULP_HOST="10.205.3.187 pulp-server pulp-server.internal.sms-cloud"

cd

set +u
source venvs/kayobe/bin/activate
set -u

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
SEED_IP=192.168.33.5
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
kayobe overcloud host configure
kayobe overcloud container image pull
kayobe overcloud service deploy
source $KOLLA_CONFIG_PATH/admin-openrc.sh
kayobe overcloud post configure
source $KOLLA_CONFIG_PATH/admin-openrc.sh

# Run init-runonce.sh to create test elements in the openstack deployment
set +u
deactivate
set -u
$KAYOBE_CONFIG_PATH/environments/$KAYOBE_ENVIRONMENT/init-runonce.sh

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