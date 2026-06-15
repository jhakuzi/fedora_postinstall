#!/bin/bash
set -e

# List of standard packages to install
PACKAGES=(
    btop
    fastfetch
    thunderbird
    solaar
    gimp
    kate
    steam
    wine
    btrfs-assistant
    ethtool
)

echo "==> Enabling RPM Fusion..."
sudo dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

echo "==> Updating system..."
sudo dnf update -y

echo "==> Installing core packages..."
sudo dnf install -y "${PACKAGES[@]}"

echo "==> Enabling CachyOS COPR Repositories..."
sudo dnf copr enable -y bieszczaders/kernel-cachyos
sudo dnf copr enable -y bieszczaders/kernel-cachyos-addons

echo "==> Installing CachyOS Kernel..."
sudo dnf install -y kernel-cachyos kernel-cachyos-devel-matched

echo "==> Swapping to CachyOS settings..."
# Using '|| true' so non-fatal DNF swap warnings don't trigger 'set -e' and kill the script
sudo dnf swap -y zram-generator-defaults cachyos-settings --allowerasing || true

echo "==> Installing SCX Schedulers..."
sudo dnf install -y scx-scheds scx-tools scx-manager

echo "==> Updating SELinux policy for kernel modules..."
sudo setsebool -P domain_kernel_load_modules on

echo "==> Creating kernel post-install hook for grubby..."
sudo mkdir -p /etc/kernel/postinst.d
sudo tee /etc/kernel/postinst.d/99-default << 'EOF'
#!/bin/sh
set -e
grubby --set-default=/boot/$(ls /boot | grep vmlinuz.*cachy | sort -V | tail -1)
EOF

echo "==> Setting permissions on post-install hook..."
sudo chown root:root /etc/kernel/postinst.d/99-default
sudo chmod u+rx /etc/kernel/postinst.d/99-default

echo "==> Rebuilding initramfs with new kernel settings..."
sudo dracut -f --regenerate-all

echo "==> Installing Faugus Launcher..."
sudo dnf copr enable -y faugus/faugus-launcher
sudo dnf install -y faugus-launcher

echo "==> Installing LACT (AMD Linux App)..."
sudo dnf copr enable -y ilyaz/LACT
sudo dnf install -y lact
sudo systemctl enable --now lactd

echo "==> Installing xpadneo..."
sudo dnf copr enable -y atim/xpadneo
sudo dnf install -y xpadneo

echo "==> Installing Plasma AppGrid..."
sudo dnf copr enable -y scujas/plasma-applet-appgrid
sudo dnf install -y plasma-applet-appgrid

echo "==> Installing Cider..."
sudo rpm --import https://repo.cider.sh/RPM-GPG-KEY
sudo tee /etc/yum.repos.d/cider.repo << 'EOF'
[cidercollective]
name=Cider Collective Repository
baseurl=https://repo.cider.sh/rpm/RPMS
enabled=1
gpgcheck=1
gpgkey=https://repo.cider.sh/RPM-GPG-KEY
EOF
sudo dnf makecache
sudo dnf install -y Cider

echo "==> Installing CKAN (KSP Mod Manager)..."
# Note: 'addrepo' is DNF5 syntax (Fedora 41+). For F40-, use '--add-repo'
sudo dnf config-manager addrepo --from-repofile https://ksp-ckan.s3-us-west-2.amazonaws.com/rpm/stable/ckan_stable.repo
sudo dnf install -y ckan

echo "==> Configuring Wake-on-LAN (WoL)..."
# Automatically find the first primary Ethernet interface name (e.g., enp3s0, eno1)
ETH_INTERFACE=$(nmcli -t -f DEVICE,TYPE device status | grep ':ethernet' | head -n1 | cut -d: -f1)

if [ -n "$ETH_INTERFACE" ]; then
    echo "    Found Ethernet interface: $ETH_INTERFACE"
    sudo ethtool -s "$ETH_INTERFACE" wol g
    
    # Dynamically find the active NetworkManager connection profile tied to this interface
    CONN_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$ETH_INTERFACE$" | cut -d: -f1)
    
    if [ -n "$CONN_NAME" ]; then
        echo "    Applying WoL to NetworkManager connection: $CONN_NAME"
        sudo nmcli connection modify "$CONN_NAME" 802-3-ethernet.wake-on-lan magic
    else
        echo "    ⚠️ Warning: Could not determine active NetworkManager connection name. Skipping NM WoL config."
    fi
else
    echo "    ⚠️ Warning: Active Ethernet interface could not be determined. Skipping WoL config."
fi

echo "==> Cleaning up..."
sudo dnf autoremove -y
sudo dnf clean all

echo "==> Setup complete! Please reboot your system to initialize everything."
