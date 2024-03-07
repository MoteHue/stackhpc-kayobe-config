#!/bin/bash

source /home/cloud-user/src/kayobe-config/kayobe-env --environment training
source /home/cloud-user/venvs/kayobe/bin/activate

export TENKS_CONFIG_PATH=/home/cloud-user/src/kayobe-config/etc/kayobe/environments/training/tenks.yml
export KAYOBE_CONFIG_SOURCE_PATH=/home/cloud-user/src/kayobe-config
export KAYOBE_VENV_PATH=/home/cloud-user/venvs/kayobe