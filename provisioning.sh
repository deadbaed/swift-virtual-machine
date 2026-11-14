#!/bin/bash
#

sleep 10 # give user time to connect over ssh to monitor progress

# Use VM_PASSWORD (passed from host) to bootstrap passwordless sudo
USER=$(whoami)
echo "$VM_PASSWORD" | sudo -S -v
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USER
sudo chmod 0440 /etc/sudoers.d/$USER

# Install Nix in multi-user mode (no password needed now)
curl -L https://releases.nixos.org/nix/nix-2.34.9/install | sh -s -- --yes

# Source Nix environment (new shell not needed)
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

nix-shell -p git --run "git clone https://codeberg.org/philt3r/comaps-nix-darwin.git"
cd comaps-nix-darwin
nix-shell -p git --run "git switch xcode27"
NIX_PATH=darwin=$(nix --extra-experimental-features nix-command eval --raw -f npins/default.nix darwin) nix-build '<darwin>' -A darwin-rebuild
sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
sudo ./result/bin/darwin-rebuild switch -I darwin-config=./configuration.nix -I darwin=$(nix --extra-experimental-features nix-command eval --raw -f npins/default.nix darwin)

# TODO: configure attic secret as root before building

# Remove passwordless sudo after all provisioning is done
sudo rm /etc/sudoers.d/$USER
