#!/bin/bash
set -eu

# Check for root upfront so we don't need sudo inside
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root or with sudo."
    exit 1
fi

# Function to dynamically fetch and install the latest RPM from a GitHub repo
install_latest_github_rpm() {
    local REPO=$1
    echo "  -> Fetching latest release for $REPO..."

    # Query the GitHub API for the latest release and use jq to extract the .rpm download URL
    # We use 'head -n 1' just in case there are multiple RPMs (e.g., debug or different architectures)
    local RPM_URL=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | \
                    jq -r '.assets[] | select(.name | endswith(".rpm")) | .browser_download_url' | \
                    grep -i -E "x86_64|x64|amd64" | head -n 1)

    # Fallback in case the grep filtered everything out (if the dev didn't put x86_64 in the filename)
    if [ -z "$RPM_URL" ]; then
        RPM_URL=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | \
                  jq -r '.assets[] | select(.name | endswith(".rpm")) | .browser_download_url' | \
                  head -n 1)
    fi

    if [ -n "$RPM_URL" ] && [ "$RPM_URL" != "null" ]; then
        echo "  -> Downloading and installing: $RPM_URL"
        dnf install -y "$RPM_URL"
    else
        echo "  -> WARNING: Could not find a valid .rpm file in the latest release for $REPO!"
    fi
}

echo "==> 1/5: CONFIGURING REPOSITORIES..."

# Standard Repos
dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# COPR Repos
dnf copr enable -y bieszczaders/kernel-cachyos
dnf copr enable -y bieszczaders/kernel-cachyos-addons
dnf copr enable -y faugus/faugus-launcher
dnf copr enable -y jackgreiner/lug-helper
dnf copr enable -y ilyaz/LACT
dnf copr enable -y sentry/xpadneo
dnf copr enable -y scujas/plasma-applet-appgrid
dnf copr enable -y jhakuzi/opentrack-wine
dnf copr enable -y lizardbyte/stable

# Cider Repo
rpm --import https://repo.cider.sh/RPM-GPG-KEY
tee /etc/yum.repos.d/cider.repo << 'EOF'
[cidercollective]
name=Cider Collective Repository
baseurl=https://repo.cider.sh/rpm/RPMS
enabled=1
gpgcheck=1
gpgkey=https://repo.cider.sh/RPM-GPG-KEY
EOF

echo "==> Updating system metadata..."
dnf update -y


echo "==> 2/5: INSTALLING DNF PACKAGES..."

PACKAGES=(
    # Core Utilities & Apps
    btop
    fastfetch
    thunderbird
    solaar
    gimp
    kate
    steam
    wine
    btrfs-assistant
    vlc
    jq
    curl
    krita
    flatpak  # Ensuring flatpak is present for the next step
    
    # CachyOS Kernel
    kernel-cachyos
    kernel-cachyos-devel-matched
    
    # SCX Schedulers
    scx-scheds
    scx-tools
    scx-manager
    
    # Third-Party / COPR Apps
    faugus-launcher
    lug-helper
    lact
    xpadneo
    plasma-applet-appgrid
    opentrack
    Cider
    Sunshine
)

dnf install -y "${PACKAGES[@]}"

echo "==> 2.5/5: INSTALLING DYNAMIC GITHUB RPMs..."

# Provide the "DeveloperName/RepoName"
install_latest_github_rpm "Vencord/Vesktop" # Vesktop (Discord)
install_latest_github_rpm "rmcrackan/libation" # Libation for Audible
install_latest_github_rpm "rustdesk/rustdesk" # Rustdesk for remote


echo "==> 3/5: INSTALLING FLATPAKS..."

echo "  -> Setting up Flathub remote..."
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

FLATPAKS=(
    # Adjust these App IDs to your liking
    it.mijorus.gearlever # Gear Lever
    dev.goats.xivlauncher # XIV Launcher
    com.teamspeak.TeamSpeak # Teamspeak
    io.github.flattool.Warehouse # Warehouse
    io.github.CyberTimon.RapidRAW # Lightroom alternative
)

echo "  -> Installing Flatpak applications..."
flatpak install -y --noninteractive flathub "${FLATPAKS[@]}"


echo "==> 4/5: POST-INSTALL CONFIGURATIONS..."

echo "  -> Swapping to CachyOS settings..."
dnf swap -y zram-generator-defaults cachyos-settings --allowerasing || true

echo "  -> Updating SELinux policy for kernel modules..."
setsebool -P domain_kernel_load_modules on

echo "  -> Creating kernel post-install hook for grubby..."
mkdir -p /etc/kernel/postinst.d
tee /etc/kernel/postinst.d/99-default << 'EOF'
#!/bin/sh
set -e
grubby --set-default=/boot/$(ls /boot | grep vmlinuz.*cachy | sort -V | tail -1)
EOF

echo "  -> Setting permissions on post-install hook..."
chown root:root /etc/kernel/postinst.d/99-default
chmod u+rx /etc/kernel/postinst.d/99-default

echo "  -> Rebuilding initramfs with new kernel settings..."
dracut -f --regenerate-all

echo "  -> Enabling LACT Daemon..."
systemctl enable --now lactd

echo "  -> Configuring Wake-on-LAN (WoL)..."
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


echo "==> 5/5: CLEANUP..."

dnf autoremove -y
dnf clean all

echo "==> Setup complete! Please reboot your system to initialize everything."
