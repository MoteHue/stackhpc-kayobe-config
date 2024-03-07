#!/bin/bash

set -e

if [[ ! -d ~/venvs/os-venv ]]; then
  virtualenv ~/venvs/os-venv
fi
~/venvs/os-venv/bin/pip install -U pip 
~/venvs/os-venv/bin/pip install python-openstackclient 

init_runonce=$KOLLA_SOURCE_PATH/tools/init-runonce
if [[ ! -f $init_runonce ]]; then
  echo "Unable to find kolla-ansible repo"
  exit 1
fi

source ~/venvs/os-venv/bin/activate
$init_runonce
