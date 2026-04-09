#!/usr/bin/env bash
# 1. Download and install stable repo
wget https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_1.0.8_all.deb
sudo dpkg -i ./protonvpn-stable-release_1.0.8_all.deb && sudo apt update

# 2. Install the app
sudo apt install proton-vpn-gnome-desktop -y

# 3. Install split tunneling dependencies
sudo apt install linux-headers-"$(uname -r)" -y
sudo apt install systemd-resolved -y

# 4. Install tray icon support (optional but useful)
sudo apt install gnome-shell-extension-appindicator gnome-shell-extension-prefs -y
