#!/bin/bash

# Configure Hyper-V Enhanced Session Mode on Ubuntu 26.04.
# GNOME 50 is Wayland-only, so xrdp uses a separate Xfce/Xorg session.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo 'This script must be run with root privileges' >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update

# Hyper-V utilities, xrdp's Xorg backend, and an X11-capable desktop session.
# Ubuntu 26.04 ships polkit 127 which uses JS .rules files (the legacy .pkla
# backend and polkitd-pkla package have been dropped).
# gnome-keyring + libpam-gnome-keyring provide pam_gnome_keyring.so for
# auto-unlocking the secret store when logging into the Xfce session.
apt-get install -y \
    linux-tools-virtual linux-cloud-tools-virtual \
    xrdp xorgxrdp xfce4 \
    gnome-keyring libpam-gnome-keyring

# Fix hypervkvpd journal errors: the daemon looks for these helpers in
# /usr/libexec/hypervkvpd/ but Ubuntu ships them in /usr/sbin/.
if [ -x /usr/sbin/hv_get_dhcp_info ]; then
    mkdir -p /usr/libexec/hypervkvpd
    [ -e /usr/libexec/hypervkvpd/hv_get_dhcp_info ] \
        || ln -s /usr/sbin/hv_get_dhcp_info /usr/libexec/hypervkvpd/hv_get_dhcp_info
fi
if [ -x /usr/sbin/hv_get_dns_info ]; then
    mkdir -p /usr/libexec/hypervkvpd
    [ -e /usr/libexec/hypervkvpd/hv_get_dns_info ] \
        || ln -s /usr/sbin/hv_get_dns_info /usr/libexec/hypervkvpd/hv_get_dns_info
fi

systemctl stop xrdp xrdp-sesman

# Use Hyper-V sockets and plain RDP security for Enhanced Session Mode.
sed -i_orig -E \
    -e '0,/^port=/{s|^port=.*$|port=vsock://-1:3389|}' \
    -e 's|^security_layer=.*$|security_layer=rdp|' \
    -e 's|^crypt_level=.*$|crypt_level=none|' \
    -e 's|^bitmap_compression=.*$|bitmap_compression=false|' \
    /etc/xrdp/xrdp.ini

# Enable Hyper-V vmconnect support (xrdp >= 0.10.4).  This allows wider
# security protocol support when connected via vmconnect.exe over vsock.
if ! grep -q '^vmconnect=true' /etc/xrdp/xrdp.ini; then
    sed -i '/^port=vsock:/a vmconnect=true' /etc/xrdp/xrdp.ini
fi

cat > /etc/xrdp/startxfce.sh <<'EOF'
#!/bin/sh
# Clear inherited Wayland environment from the GNOME/GDM login session.
# Ubuntu 26.04 uses GNOME 50 (Wayland-only).  When xrdp-sesman starts via
# PAM, it connects to the user's existing systemd --user instance which
# already has WAYLAND_DISPLAY set by GDM.  Merely unsetting in this shell
# is insufficient because D-Bus-activated services (xfce4-notifyd, etc.)
# inherit from the D-Bus activation environment, not the shell.
unset WAYLAND_DISPLAY WAYLAND_SOCKET
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb
# Remove Wayland variables from systemd user environment and update D-Bus
# activation environment so D-Bus-activated services get the cleaned env.
systemctl --user unset-environment WAYLAND_DISPLAY WAYLAND_SOCKET 2>/dev/null || true
dbus-update-activation-environment \
    DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP GDK_BACKEND QT_QPA_PLATFORM \
    2>/dev/null || true
exec startxfce4
EOF
chmod 755 /etc/xrdp/startxfce.sh

sed -i_orig -E \
    -e 's|^UserWindowManager=.*$|UserWindowManager=startxfce.sh|' \
    -e 's|^DefaultWindowManager=.*$|DefaultWindowManager=startxfce.sh|' \
    -e 's|^FuseMountName=.*$|FuseMountName=shared-drives|' \
    /etc/xrdp/sesman.ini

if [ -f /etc/X11/Xwrapper.config ]; then
    sed -i_orig -E 's|^allowed_users=.*$|allowed_users=anybody|' /etc/X11/Xwrapper.config
else
    echo 'allowed_users=anybody' > /etc/X11/Xwrapper.config
fi

# Suppress "Authentication required to create managed color device" popups in
# remote xrdp sessions.  Ubuntu 26.04 uses polkit 127 with the JavaScript
# rules engine, so we write a .rules file instead of a legacy .pkla file.
mkdir -p /etc/polkit-1/rules.d/
cat > /etc/polkit-1/rules.d/45-allow-colord.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.color-manager.create-device" ||
         action.id == "org.freedesktop.color-manager.create-profile" ||
         action.id == "org.freedesktop.color-manager.delete-device" ||
         action.id == "org.freedesktop.color-manager.delete-profile" ||
         action.id == "org.freedesktop.color-manager.modify-device" ||
         action.id == "org.freedesktop.color-manager.modify-profile") &&
        subject.isInGroup("users"))
    {
        return polkit.Result.YES;
    }
});
EOF

usermod -aG ssl-cert xrdp

# Auto-unlock GNOME keyring on xrdp login (Xfce uses it for secret storage).
# The leading '-' on optional lines makes PAM skip a missing module silently.
if [ -f /etc/pam.d/xrdp-sesman ] && [ ! -f /etc/pam.d/xrdp-sesman.orig ]; then
    cp -p /etc/pam.d/xrdp-sesman /etc/pam.d/xrdp-sesman.orig
fi
cat > /etc/pam.d/xrdp-sesman <<'EOF'
#%PAM-1.0
auth     required  pam_env.so readenv=1
auth     required  pam_env.so readenv=1 envfile=/etc/default/locale
@include common-auth
-auth    optional  pam_gnome_keyring.so

@include common-account
@include common-password

session    required     pam_limits.so
session    required     pam_loginuid.so
session    optional     pam_lastlog.so quiet
@include common-session
-session optional  pam_gnome_keyring.so auto_start
EOF

echo 'blacklist vmw_vsock_vmci_transport' > /etc/modprobe.d/blacklist-vmw_vsock_vmci_transport.conf
echo 'hv_sock' > /etc/modules-load.d/hv_sock.conf
modprobe hv_sock

systemctl daemon-reload
systemctl enable xrdp xrdp-sesman
systemctl restart xrdp-sesman xrdp

# Fail rather than reporting success when a package or setting is missing.
for package in xrdp xorgxrdp xfce4; do
    dpkg-query -W -f='${Status}\n' "$package" | grep -qxF 'install ok installed'
done
command -v startxfce4 > /dev/null
test -x /etc/xrdp/startxfce.sh
grep -qxF 'port=vsock://-1:3389' /etc/xrdp/xrdp.ini
grep -qxF 'vmconnect=true' /etc/xrdp/xrdp.ini
grep -qxF 'security_layer=rdp' /etc/xrdp/xrdp.ini
grep -qxF 'crypt_level=none' /etc/xrdp/xrdp.ini
grep -qxF 'bitmap_compression=false' /etc/xrdp/xrdp.ini
grep -qxF 'UserWindowManager=startxfce.sh' /etc/xrdp/sesman.ini
grep -qxF 'DefaultWindowManager=startxfce.sh' /etc/xrdp/sesman.ini
for service in xrdp xrdp-sesman; do
    systemctl is-active --quiet "$service"
done
for service in xrdp xrdp-sesman; do
    systemctl is-enabled --quiet "$service"
done
# Colord polkit policy present.
test -f /etc/polkit-1/rules.d/45-allow-colord.rules
# Xwrapper allows any user.
grep -qxF 'allowed_users=anybody' /etc/X11/Xwrapper.config
# xrdp is in the ssl-cert group.
id -nG xrdp | grep -qw ssl-cert
# hv_sock is loaded.
lsmod | grep -q hv_sock
# hypervkvpd symlinks exist (only checked when the source binaries are present).
if [ -x /usr/sbin/hv_get_dhcp_info ]; then
    test -e /usr/libexec/hypervkvpd/hv_get_dhcp_info
fi
if [ -x /usr/sbin/hv_get_dns_info ]; then
    test -e /usr/libexec/hypervkvpd/hv_get_dns_info
fi
# PAM keyring auto-unlock configured.
grep -q 'pam_gnome_keyring.so' /etc/pam.d/xrdp-sesman

echo 'Install is complete.'
echo 'Fully power off the VM, set EnhancedSessionTransportType to HvSocket on the host, then start it again.'
