#!/bin/bash
# NullOS: neon purple, built on Ubuntu 24.04 (like Mint). XFCE desktop, live ISO.
# Keep the assets folder next to this script.
# Run from inside this folder:  sudo bash build-nullos.sh
set -euo pipefail
OS_NAME="NullOS"
OS_VER="1.0"
SUITE="noble"               # Ubuntu 24.04 base
MIRROR="${MIRROR:-https://mirrors.edge.kernel.org/ubuntu}"   # HTTPS mirror; works where port 80 to archive.ubuntu.com is blocked
WORK="${WORK:-$HOME/os-build}"; CH="$WORK/chroot"; IMG="$WORK/image"
LOW=$(echo "$OS_NAME" | tr 'A-Z' 'a-z')

[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
apt-get update
apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools dosfstools
# Older hosts (e.g. Ubuntu 22.04) ship a debootstrap that doesn't know newer releases yet.
# Every Ubuntu script is a link to "gutsy", so teach it the missing one.
[ -e "/usr/share/debootstrap/scripts/$SUITE" ] || ln -s gutsy "/usr/share/debootstrap/scripts/$SUITE"
# Space check: the full build needs about 15 GB free.
FREE=$(df --output=avail -BG "$(dirname "$WORK")" | tail -1 | tr -dc 0-9)
[ "$FREE" -ge 15 ] || echo "WARNING: only ${FREE} GB free here; the build may run out of space."
# A failed earlier debootstrap leaves a broken chroot; start that step over.
[ -x "$CH/bin/bash" ] || rm -rf "$CH"

mkdir -p "$WORK"
[ -d "$CH/etc" ] || debootstrap --arch=amd64 --variant=minbase --include=ca-certificates "$SUITE" "$CH" "$MIRROR"

for d in dev dev/pts proc sys run; do mountpoint -q "$CH/$d" || mount --bind "/$d" "$CH/$d"; done
cleanup() { for d in run sys proc dev/pts dev; do umount -lf "$CH/$d" 2>/dev/null || true; done; }
trap cleanup EXIT
cp /etc/resolv.conf "$CH/etc/resolv.conf"

cat > "$CH/etc/apt/sources.list" <<S
deb $MIRROR $SUITE main restricted universe multiverse
deb $MIRROR $SUITE-updates main restricted universe multiverse
deb $MIRROR $SUITE-security main restricted universe multiverse
S

chroot "$CH" /bin/bash -e <<C
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
echo "$LOW" > /etc/hostname
apt-get update
apt-get install -y --no-install-recommends systemd-sysv linux-generic casper initramfs-tools \
  sudo locales tzdata network-manager network-manager-gnome wpasupplicant ca-certificates curl gpg \
  xorg lightdm lightdm-gtk-greeter xfce4 xfce4-terminal xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin \
  thunar mousepad ristretto file-roller pipewire-pulse pavucontrol \
  arc-theme papirus-icon-theme fonts-noto-core fonts-noto-color-emoji \
  synaptic gnome-software-plugin-flatpak flatpak plymouth plymouth-label xfce4-panel-profiles
# ---- everyday apps ----
apt-get update
apt-get install -y --no-install-recommends \
  libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-gtk3 \
  vlc gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
  gnome-calculator xfce4-screenshooter atril xfce4-taskmanager xfce4-notifyd xfce4-power-manager xfce4-settings \
  gnome-disk-utility gparted timeshift system-config-printer cups simple-scan \
  blueman bluez xfce4-clipman-plugin catfish \
  unzip p7zip-full ntfs-3g exfatprogs htop neofetch git
# Firefox as a real .deb (Ubuntu's default is a snap)
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla
apt-get update && apt-get install -y firefox
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
locale-gen en_US.UTF-8
C

# ---- Ghost Mode (privacy features apply ONLY when booted in Ghost Mode; normal mode is stock) ----
chroot "$CH" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y ufw tor torbrowser-launcher iptables || true"
chroot "$CH" /bin/bash -c "systemctl disable tor 2>/dev/null; true"
G="$CH/etc/nullos/ghost"; mkdir -p "$G"
cat > "$G/00-nullos-mac.conf" <<'MAC'
[device]
wifi.scan-rand-mac-address=yes
[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
MAC
cat > "$G/99-nullos-hardening.conf" <<'SYS'
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.yama.ptrace_scope=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.tcp_syncookies=1
net.ipv6.conf.all.use_tempaddr=2
net.ipv6.conf.default.use_tempaddr=2
SYS
cat > "$G/policies.json" <<'FF'
{"policies":{
 "DisableTelemetry":true,"DisableFirefoxStudies":true,"DisablePocket":true,
 "DisableFormHistory":true,"OfferToSaveLogins":false,"PasswordManagerEnabled":false,
 "EnableTrackingProtection":{"Value":true,"Locked":true,"Cryptomining":true,"Fingerprinting":true,"EmailTracking":true},
 "Cookies":{"Behavior":"reject-tracker-and-partition-foreign"},
 "SanitizeOnShutdown":{"Cache":true,"Cookies":true,"History":true,"Sessions":true,"SiteSettings":false,"OfflineApps":true,"FormData":true,"Downloads":true},
 "HttpsOnlyMode":"force_enabled",
 "FirefoxHome":{"SponsoredTopSites":false,"SponsoredPocket":false,"Pocket":false},
 "ExtensionSettings":{"uBlock0@raymondhill.net":{"installation_mode":"force_installed","install_url":"https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"}}
}}
FF
cat > "$CH/usr/local/sbin/nullos-ghost" <<'GH'
#!/bin/bash
# Runs at every boot; does nothing unless the boot menu passed nullos.ghost=1
grep -qw 'nullos.ghost=1' /proc/cmdline || exit 0
G=/etc/nullos/ghost
swapoff -a || true
systemctl stop apport whoopsie motd-news.timer 2>/dev/null || true
mkdir -p /etc/NetworkManager/conf.d /etc/firefox/policies
cp "$G/00-nullos-mac.conf" /etc/NetworkManager/conf.d/
cp "$G/policies.json" /etc/firefox/policies/policies.json
sysctl -q -p "$G/99-nullos-hardening.conf" || true
ufw --force enable || true
printf 'VirtualAddrNetworkIPv4 10.192.0.0/10\nAutomapHostsOnResolve 1\nTransPort 9040\nDNSPort 5353\n' >> /etc/tor/torrc
T=$(id -u debian-tor)
iptables -t nat -I OUTPUT 1 -m owner --uid-owner "$T" -j RETURN
iptables -t nat -I OUTPUT 2 -p udp --dport 53 -j REDIRECT --to-ports 5353
iptables -t nat -I OUTPUT 3 -d 127.0.0.0/8 -j RETURN
iptables -t nat -I OUTPUT 4 -p tcp --syn -j REDIRECT --to-ports 9040
iptables -I OUTPUT 1 -m owner --uid-owner "$T" -j ACCEPT
iptables -I OUTPUT 2 -o lo -j ACCEPT
iptables -I OUTPUT 3 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -I OUTPUT 4 -j REJECT
ip6tables -I OUTPUT 1 -o lo -j ACCEPT
ip6tables -I OUTPUT 2 -j REJECT
systemctl start tor
GH
chmod 755 "$CH/usr/local/sbin/nullos-ghost"
cat > "$CH/etc/systemd/system/nullos-ghost.service" <<'GS'
[Unit]
Description=NullOS Ghost Mode (only active when booted with nullos.ghost=1)
After=local-fs.target ufw.service
Before=NetworkManager.service network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nullos-ghost
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
GS
chroot "$CH" /bin/bash -c "systemctl enable nullos-ghost.service"

# ---- branding ----
cat > "$CH/etc/os-release" <<R
PRETTY_NAME="$OS_NAME $OS_VER"
NAME="$OS_NAME"
VERSION_ID="$OS_VER"
VERSION="$OS_VER ($SUITE base)"
ID=$LOW
HOME_URL="https://github.com/"
LOGO=nullos
ID_LIKE="ubuntu debian"
UBUNTU_CODENAME=$SUITE
VERSION_CODENAME=$SUITE
R
printf 'DISTRIB_ID=%s\nDISTRIB_RELEASE=%s\nDISTRIB_CODENAME=%s\nDISTRIB_DESCRIPTION="%s %s"\n' "$OS_NAME" "$OS_VER" "$SUITE" "$OS_NAME" "$OS_VER" > "$CH/etc/lsb-release"
printf 'export USERNAME="null"\nexport USERFULLNAME="Null"\nexport HOST="%s"\nexport BUILD_SYSTEM="NullOS"\n' "$LOW" > "$CH/etc/casper.conf"
# Mint-like look for every new user: Arc-Dark + Papirus, whisker menu
X="$CH/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"; mkdir -p "$X"
cat > "$X/xsettings.xml" <<'XS'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0"><property name="Net" type="empty">
<property name="ThemeName" type="string" value="NullOS-Neon"/><property name="IconThemeName" type="string" value="Papirus-Dark"/></property></channel>
XS
cat > "$X/xfwm4.xml" <<'XW'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0"><property name="general" type="empty"><property name="theme" type="string" value="Arc-Dark"/></property></channel>
XW
mkdir -p "$CH/etc/lightdm/lightdm-gtk-greeter.conf.d"
printf '[greeter]\ntheme-name=NullOS-Neon\nbackground=/usr/share/backgrounds/nullos/wallpaper.png\nicon-theme-name=Papirus-Dark\n' > "$CH/etc/lightdm/lightdm-gtk-greeter.conf.d/50-$LOW.conf"
# ---- NullOS look ----
AS="$(cd "$(dirname "$0")" && pwd)/assets"
mkdir -p "$CH/usr/share/backgrounds/nullos" "$CH/usr/share/themes/NullOS-Neon" "$CH/usr/share/plymouth/themes/nullos" "$CH/usr/share/pixmaps"
cp "$AS/wallpaper.png" "$CH/usr/share/backgrounds/nullos/"; cp "$AS/logo.png" "$CH/usr/share/pixmaps/nullos.png"
cp -r "$AS/theme/." "$CH/usr/share/themes/NullOS-Neon/"
cp -r "$CH/usr/share/themes/Arc-Dark/xfwm4" "$CH/usr/share/themes/NullOS-Neon/" 2>/dev/null || true
cp "$AS"/plymouth/* "$AS/logo.png" "$CH/usr/share/plymouth/themes/nullos/"
mkdir -p "$CH/etc/skel/.config/xfce4/terminal"; cp "$AS/terminalrc" "$CH/etc/skel/.config/xfce4/terminal/terminalrc"
cat > "$X/xfce4-desktop.xml" <<'XD'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0"><property name="backdrop" type="empty"><property name="screen0" type="empty">
<property name="monitorVirtual-1" type="empty"><property name="workspace0" type="empty"><property name="last-image" type="string" value="/usr/share/backgrounds/nullos/wallpaper.png"/><property name="image-style" type="int" value="5"/></property></property>
<property name="monitor0" type="empty"><property name="workspace0" type="empty"><property name="last-image" type="string" value="/usr/share/backgrounds/nullos/wallpaper.png"/><property name="image-style" type="int" value="5"/></property></property>
</property></property></channel>
XD
sed -i 's/value="Arc-Dark"/value="NullOS-Neon"/' "$X/xfwm4.xml"
ln -sf /usr/share/backgrounds/nullos/wallpaper.png "$CH/usr/share/backgrounds/xfce/xfce-shapes.svg" 2>/dev/null || true
chroot "$CH" /bin/bash -c "update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/nullos/nullos.plymouth 200 && update-alternatives --set default.plymouth /usr/share/plymouth/themes/nullos/nullos.plymouth"
chroot "$CH" /bin/bash -c "update-initramfs -u -k all && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*"
cleanup; trap - EXIT

# ---- live ISO image ----
rm -rf "$IMG"; mkdir -p "$IMG/casper" "$IMG/boot/grub"
cp "$(ls "$CH"/boot/vmlinuz-* | sort -V | tail -1)" "$IMG/casper/vmlinuz"
cp "$(ls "$CH"/boot/initrd.img-* | sort -V | tail -1)" "$IMG/casper/initrd"
mksquashfs "$CH" "$IMG/casper/filesystem.squashfs" -comp xz -noappend -e boot
printf '%s' "$(du -sx --block-size=1 "$CH" | cut -f1)" > "$IMG/casper/filesystem.size"
cp "$AS/wallpaper.png" "$IMG/boot/grub/wallpaper.png"
cat > "$IMG/boot/grub/grub.cfg" <<G
set timeout=5
insmod all_video
insmod gfxterm
insmod png
terminal_output gfxterm
background_image /boot/grub/wallpaper.png
set color_normal=light-magenta/black
set menu_color_highlight=white/magenta
menuentry "Boot $OS_NAME $OS_VER" { linux /casper/vmlinuz boot=casper quiet splash ---; initrd /casper/initrd; }
menuentry "$OS_NAME Ghost Mode (all traffic via Tor, leaves no trace)" { linux /casper/vmlinuz boot=casper nullos.ghost=1 quiet splash ---; initrd /casper/initrd; }
menuentry "Try $OS_NAME (safe graphics)" { linux /casper/vmlinuz boot=casper nomodeset ---; initrd /casper/initrd; }
G
OUT="$WORK/${LOW}-${OS_VER}-amd64.iso"
grub-mkrescue -o "$OUT" "$IMG" -- -volid "${OS_NAME^^}_${OS_VER/./_}"
echo; echo "Done: $OUT  ($(du -h "$OUT" | cut -f1))"
