# Remove all proton packages
sudo apt remove --purge \
    proton-vpn-daemon \
    proton-vpn-gnome-desktop \
    proton-vpn-gtk-app \
    protonvpn-beta-release \
    python3-proton-core \
    python3-proton-keyring-linux \
    python3-proton-vpn-api-core \
    python3-proton-vpn-local-agent \
    python3-proton-vpn-network-manager \
    python3-proton-vpn-network-manager-openvpn \
    python3-proton-vpn-killswitch \
    python3-proton-vpn-killswitch-network-manager \
    python3-proton-vpn-session -y

# Remove repo and keys
sudo rm -f /etc/apt/sources.list.d/proton*.list
sudo rm -f /usr/share/keyrings/proton*.gpg

# Remove config and cache
rm -rf ~/.config/protonvpn
rm -rf ~/.local/share/protonvpn
rm -rf ~/.cache/protonvpn
sudo rm -rf /etc/protonvpn

# Remove leftover NM connections
sudo nmcli connection show | grep -i proton | awk '{print $1}' | xargs -I{} sudo nmcli connection delete {}

# Clean up
sudo apt autoremove -y
sudo apt autoclean
sudo apt update

# Verify
dpkg -l | grep proton