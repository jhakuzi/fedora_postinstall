#!/bin/bash
set -eu

# Check for root/sudo
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root or with sudo."
    exit 1
fi

# Arrays for failures
FAILED_DNF=()
FAILED_FLATPAKS=()

# Function to fetch and install the latest .rpm from github repo
install_latest_github_rpm() {
    local REPO=$1
    echo "  -> Fetching latest release for $REPO..."

    # Query the github api for the latest release and extract the .rpm download url
    # Use 'head -n 1' in case there are multiple .rpm files
    local RPM_URL=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | \
                    jq -r '.assets[] | select(.name | endswith(".rpm")) | .browser_download_url' | \
                    grep -i -E "x86_64|x64|amd64" | head -n 1)

    # Fallback if grep filtered everything
    if [ -z "$RPM_URL" ]; then
        RPM_URL=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | \
                  jq -r '.assets[] | select(.name | endswith(".rpm")) | .browser_download_url' | \
                  head -n 1)
    fi

    if [ -n "$RPM_URL" ] && [ "$RPM_URL" != "null" ]; then
        echo "  -> Downloading and installing: $RPM_URL"
        dnf install -y "$RPM_URL" || FAILED_DNF+=("$REPO (GitHub RPM)")
    else
        echo "  -> WARNING: Could not find a valid .rpm file in the latest release for $REPO!"
        FAILED_DNF+=("$REPO (No valid RPM found on GitHub)")
    fi
}

echo "==> 1/5: CONFIGURING REPOSITORIES..."

# Standard Repos
dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# COPR
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


echo "==> 1.5/5: INSTALLING FULL MULTIMEDIA CODECS & DRIVERS..."

echo "  -> Swapping to full ffmpeg..."
dnf swap -y ffmpeg-free ffmpeg --allowerasing || FAILED_DNF+=("ffmpeg (swap)")

echo "  -> Installing multimedia group..."
dnf install -y @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin || FAILED_DNF+=("@multimedia group")

echo "  -> Installing freeworld hardware acceleration drivers..."
dnf install -y mesa-va-drivers-freeworld || FAILED_DNF+=("mesa-va-drivers-freeworld")


echo "==> 2/5: INSTALLING DNF PACKAGES..."

PACKAGES=(
    # Standard apps
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
    gnome-boxes
    flatpak
    
    # CachyOS kernel
    kernel-cachyos
    kernel-cachyos-devel-matched

    # CachyOS tools
    scx-scheds
    scx-tools
    scx-manager

    # COPR apps
    faugus-launcher
    lug-helper
    lact
    xpadneo
    plasma-applet-appgrid
    opentrack
    Cider
    Sunshine
)

# Using forgiving flags so one broken package doesnt abort the entire run
dnf install -y --setopt=strict=0 --skip-broken "${PACKAGES[@]}" || true

echo "==> 2.5/5: INSTALLING DYNAMIC GITHUB RPMs..."

# Install custom .rpm
install_latest_github_rpm "Vencord/Vesktop" # Vesktop (Discord)
install_latest_github_rpm "rmcrackan/libation" # Libation for Audible
# install_latest_github_rpm "rustdesk/rustdesk" # Rustdesk for remote (currently not working)


echo "==> 3/5: INSTALLING FLATPAKS..."

echo "  -> Setting up Flathub remote..."
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

FLATPAKS=(
    it.mijorus.gearlever # Gear Lever
    dev.goats.xivlauncher # XIV Launcher
    com.teamspeak.TeamSpeak # Teamspeak
    io.github.flattool.Warehouse # Warehouse
    io.github.CyberTimon.RapidRAW # Lightroom alternative
    com.rustdesk.RustDesk # Rustdesk remote desktop
)

echo "  -> Installing Flatpak applications..."
for app in "${FLATPAKS[@]}"; do
    echo "     Installing $app..."
    flatpak install -y --noninteractive flathub "$app" || FAILED_FLATPAKS+=("$app")
done


echo "==> 4/5: POST-INSTALL CONFIGURATIONS..."

echo "  -> Swapping to CachyOS settings..."
dnf swap -y zram-generator-defaults cachyos-settings --allowerasing || true

echo "  -> Updating SELinux policy for kernel modules..."
setsebool -P domain_kernel_load_modules on

echo "  -> Creating kernel post-install hook for GRUB..."
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

echo "  -> Enabling LACT daemon..."
systemctl enable --now lactd

echo "  -> Configuring Wake-on-LAN..."
ETH_INTERFACE=$(nmcli -t -f DEVICE,TYPE device status | grep ':ethernet' | head -n1 | cut -d: -f1)

if [ -n "$ETH_INTERFACE" ]; then
    echo "    Found Ethernet interface: $ETH_INTERFACE"
    
    # failsafe
    if ethtool -s "$ETH_INTERFACE" wol g 2>/dev/null; then
        echo "    Successfully enabled WoL via ethtool."
        
        CONN_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$ETH_INTERFACE$" | cut -d: -f1)
        
        if [ -n "$CONN_NAME" ]; then
            echo "    Applying WoL to NetworkManager connection: $CONN_NAME"
            # Append || true so nm failing doesn't exit
            nmcli connection modify "$CONN_NAME" 802-3-ethernet.wake-on-lan magic || echo "    WARNING: NetworkManager WoL modification failed."
        else
            echo "    WARNING: Could not determine active NetworkManager connection name. Skipping NM WoL config."
        fi
    else
        # error trigger in on unsupported hardware without exit
        echo "    WARNING: ethtool could not enable WoL on $ETH_INTERFACE (This is normal in VMs or unsupported NICs)."
    fi
else
    echo "    WARNING: Active Ethernet interface could not be determined. Skipping WoL config."
fi



echo "==> 5/5: CLEANUP & VERIFICATION..."

dnf autoremove -y || true
dnf clean all || true

# Verify dnf packages
for pkg in "${PACKAGES[@]}"; do
    if [[ "$pkg" != http* ]] && [[ "$pkg" != *"/"* ]]; then
        if ! rpm -q "$pkg" &> /dev/null; then
            FAILED_DNF+=("$pkg")
        fi
    fi
done

# Final report
echo ""
echo "================================================================"
echo "                    INSTALLATION SUMMARY                        "
echo "================================================================"

if [ ${#FAILED_DNF[@]} -eq 0 ] && [ ${#FAILED_FLATPAKS[@]} -eq 0 ]; then
    echo "SUCCESS: All packages and Flatpaks installed cleanly!"
else
    echo "WARNING: Some transactions failed or were skipped."

    if [ ${#FAILED_DNF[@]} -ne 0 ]; then
        echo ""
        echo "Failed DNF / RPM Packages:"
        for failed in "${FAILED_DNF[@]}"; do
            echo "      - $failed"
        done
    fi

    if [ ${#FAILED_FLATPAKS[@]} -ne 0 ]; then
        echo ""
        echo "Failed Flatpaks:"
        for failed in "${FAILED_FLATPAKS[@]}"; do
            echo "      - $failed"
        done
    fi
fi

echo "================================================================"
echo "==> Setup complete! Please reboot your system to initialize everything."
