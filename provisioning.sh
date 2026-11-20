#!/bin/bash
#

sleep 10 # give user time to connect over ssh to monitor progress

# Use VM_PASSWORD (passed from host) to bootstrap passwordless sudo
USER=$(whoami)
echo "$VM_PASSWORD" | sudo -S -v
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USER
sudo chmod 0440 /etc/sudoers.d/$USER

# you can run any command with `sudo` without a password now

# Remove passwordless sudo after all provisioning is done
sudo rm /etc/sudoers.d/$USER
