#!/bin/bash
set -eu

# Check for root upfront so we don't need sudo inside
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root or with sudo."
    exit 1
fi

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
dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

echo "==> Updating system..."
dnf update -y

echo "==> Installing core packages..."
dnf install -y "${PACKAGES[@]}"

echo "==> Enabling CachyOS COPR Repositories..."
dnf copr enable -y bieszczaders/kernel-cachyos
dnf copr enable -y bieszczaders/kernel-cachyos-addons

echo "==> Installing CachyOS Kernel..."
dnf install -y kernel-cachyos kernel-cachyos-devel-matched

echo "==> Swapping to CachyOS settings..."
dnf swap -y zram-generator-defaults cachyos-settings --allowerasing || true

echo "==> Installing SCX Schedulers..."
dnf install -y scx-scheds scx-tools scx-manager

echo "==> Updating SELinux policy for kernel modules..."
setsebool -P domain_kernel_load_modules on

echo "==> Creating kernel post-install hook for grubby..."
mkdir -p /etc/kernel/postinst.d
tee /etc/kernel/postinst.d/99-default << 'EOF'
#!/bin/sh
set -e
grubby --set-default=/boot/$(ls /boot | grep vmlinuz.*cachy | sort -V | tail -1)
EOF

echo "==> Setting permissions on post-install hook..."
chown root:root /etc/kernel/postinst.d/99-default
chmod u+rx /etc/kernel/postinst.d/99-default

echo "==> Rebuilding initramfs with new kernel settings..."
dracut -f --regenerate-all

echo "==> Installing Faugus Launcher..."
dnf copr enable -y faugus/faugus-launcher
dnf install -y faugus-launcher

echo "==> Installing LACT (AMD Linux App)..."
dnf copr enable -y ilyaz/LACT
dnf install -y lact
systemctl enable --now lactd

echo "==> Installing xpadneo..."
dnf copr enable -y atim/xpadneo
dnf install -y xpadneo

echo "==> Installing Plasma AppGrid..."
dnf copr enable -y scujas/plasma-applet-appgrid
dnf install -y plasma-applet-appgrid

echo "==> Installing Cider..."
rpm --import https://repo.cider.sh/RPM-GPG-KEY
tee /etc/yum.repos.d/cider.repo << 'EOF'
[cidercollective]
name=Cider Collective Repository
baseurl=https://repo.cider.sh/rpm/RPMS
enabled=1
gpgcheck=1
gpgkey=https://repo.cider.sh/RPM-GPG-KEY
EOF
dnf makecache
dnf install -y Cider

echo "==> Installing CKAN (KSP Mod Manager)..."
dnf config-manager addrepo --from-repofile https://ksp-ckan.s3-us-west-2.amazonaws.com/rpm/stable/ckan_stable.repo
dnf install -y ckan

echo "==> Configuring Wake-on-LAN (WoL)..."
ETH_INTERFACE=$(nmcli -t -f DEVICE,TYPE device status | grep ':ethernet' | head -n1 | cut -d: -f1)

if [ -n "$ETH_INTERFACE" ]; then
    echo "    Found Ethernet interface: $ETH_INTERFACE"
    ethtool -s "$ETH_INTERFACE" wol g

    CONN_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$ETH_INTERFACE$" | cut -d: -f1)

    if [ -n "$CONN_NAME" ]; then
        echo "    Applying WoL to NetworkManager connection: $CONN_NAME"
        nmcli connection modify "$CONN_NAME" 802-3-ethernet.wake-on-lan magic
    else
        echo "    WARNING: Could not determine active NetworkManager connection name. Skipping NM WoL config."
    fi
else
    echo "    WARNING: Active Ethernet interface could not be determined. Skipping WoL config."
fi

echo "==> Cleaning up..."
dnf autoremove -y
dnf clean all

echo "==> Setup complete! Please reboot your system to initialize everything."
