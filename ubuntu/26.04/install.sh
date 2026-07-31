#!/bin/bash

# Configure Hyper-V Enhanced Session Mode on Ubuntu 26.04.
# GNOME 50 is Wayland-only, so xrdp uses a separate Xfce/Xorg session.

set -euo pipefail

backup_once() {
    local file="$1"
    local backup="${file}.linux-vm-tools.orig"

    if [ -e "$backup" ] || [ -L "$backup" ]; then
        return
    fi

    cp -a -- "$file" "$backup"
}

commit_temp_file() {
    local file="$1"
    local temp_file="$2"

    if ! chown --reference="$file" "$temp_file" ||
        ! chmod --reference="$file" "$temp_file" ||
        ! mv -f -- "$temp_file" "$file"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

edit_ini_value() {
    local file="$1"
    local section="$2"
    local key="$3"
    local operation="$4"
    local value="${5:-}"
    local temp_file

    case "$key" in
        *[!A-Za-z0-9_]*)
            echo "Unsupported INI key: $key" >&2
            return 1
            ;;
    esac

    case "$operation" in
        set|remove) ;;
        *)
            echo "Unsupported INI operation: $operation" >&2
            return 1
            ;;
    esac

    temp_file="$(mktemp "${file}.linux-vm-tools.XXXXXX")"
    if ! awk \
        -v target_section="$section" \
        -v key="$key" \
        -v operation="$operation" \
        -v value="$value" '
        function section_name(line, name) {
            name = line
            sub(/^[[:space:]]*\[/, "", name)
            sub(/\][[:space:]]*$/, "", name)
            return name
        }

        BEGIN {
            in_target = 0
            section_count = 0
            key_count = 0
        }

        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            if (in_target && key_count == 0 && operation == "set") {
                print key "=" value
            }

            in_target = section_name($0) == target_section
            if (in_target) {
                section_count++
            }

            print
            next
        }

        in_target && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            key_count++
            if (operation == "set") {
                print key "=" value
            }
            next
        }

        { print }

        END {
            if (in_target && key_count == 0 && operation == "set") {
                print key "=" value
            }

            if (section_count != 1 || (operation == "set" && key_count > 1)) {
                exit 1
            }
        }
    ' "$file" > "$temp_file"; then
        rm -f -- "$temp_file"
        echo "Could not $operation [$section] $key in $file" >&2
        return 1
    fi

    commit_temp_file "$file" "$temp_file"
}

set_ini_value() {
    edit_ini_value "$1" "$2" "$3" set "$4"
}

remove_ini_value() {
    edit_ini_value "$1" "$2" "$3" remove
}

set_file_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local temp_file

    case "$key" in
        *[!A-Za-z0-9_]*)
            echo "Unsupported setting key: $key" >&2
            return 1
            ;;
    esac

    temp_file="$(mktemp "${file}.linux-vm-tools.XXXXXX")"
    if ! awk -v key="$key" -v value="$value" '
        BEGIN { key_count = 0 }

        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            key_count++
            print key "=" value
            next
        }

        { print }

        END {
            if (key_count == 0) {
                print key "=" value
            } else if (key_count > 1) {
                exit 1
            }
        }
    ' "$file" > "$temp_file"; then
        rm -f -- "$temp_file"
        echo "Could not set $key in $file" >&2
        return 1
    fi

    commit_temp_file "$file" "$temp_file"
}

ensure_line() {
    local file="$1"
    local line="$2"
    local grep_status
    local temp_file

    grep -qxF -- "$line" "$file" && return
    grep_status=$?
    if [ "$grep_status" -ne 1 ]; then
        return "$grep_status"
    fi

    temp_file="$(mktemp "${file}.linux-vm-tools.XXXXXX")"
    if ! awk -v line="$line" '{ print } END { print line }' "$file" > "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi

    commit_temp_file "$file" "$temp_file"
}

ensure_symlink() {
    local source="$1"
    local target="$2"
    local current_target

    if [ -L "$target" ]; then
        current_target="$(readlink "$target")"
        if [ "$current_target" = "$source" ]; then
            return
        fi

        ln -sfn -- "$source" "$target"
        return
    fi

    if [ -e "$target" ]; then
        echo "$target exists and is not a symbolic link" >&2
        return 1
    fi

    ln -s -- "$source" "$target"
}

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
# xfce4-goodies adds extra panel plugins and Thunar extensions. Epiphany is a
# native deb browser and avoids the snap confinement problems seen in xrdp.
apt-get install -y \
    linux-tools-virtual linux-cloud-tools-virtual \
    xrdp xorgxrdp xfce4 xfce4-goodies xfce4-whiskermenu-plugin \
    xfce4-notifyd xfce4-power-manager xfce4-pulseaudio-plugin \
    dbus-x11 dbus-user-session gnome-keyring libpam-gnome-keyring \
    xdg-desktop-portal xdg-desktop-portal-gtk epiphany-browser \
    greybird-gtk-theme elementary-xfce-icon-theme \
    fonts-noto-core fonts-noto-mono \
    ubuntu-wallpapers

# Fix hypervkvpd journal errors: the daemon looks for these helpers in
# /usr/libexec/hypervkvpd/ but Ubuntu ships them in /usr/sbin/.
if [ -x /usr/sbin/hv_get_dhcp_info ]; then
    mkdir -p /usr/libexec/hypervkvpd
    ensure_symlink \
        /usr/sbin/hv_get_dhcp_info \
        /usr/libexec/hypervkvpd/hv_get_dhcp_info
fi
if [ -x /usr/sbin/hv_get_dns_info ]; then
    mkdir -p /usr/libexec/hypervkvpd
    ensure_symlink \
        /usr/sbin/hv_get_dns_info \
        /usr/libexec/hypervkvpd/hv_get_dns_info
fi

# Use the compatibility profile supported by Ubuntu's xrdp package. Hyper-V
# sockets are host-local, so Enhanced Session Mode does not expose a TCP port.
backup_once /etc/xrdp/xrdp.ini
remove_ini_value /etc/xrdp/xrdp.ini Globals vmconnect
set_ini_value /etc/xrdp/xrdp.ini Globals port 'vsock://-1:3389'
set_ini_value /etc/xrdp/xrdp.ini Globals security_layer rdp
set_ini_value /etc/xrdp/xrdp.ini Globals crypt_level none
set_ini_value /etc/xrdp/xrdp.ini Globals bitmap_compression false
set_ini_value /etc/xrdp/xrdp.ini Globals default_dpi 120

startxfce_temp="$(mktemp /etc/xrdp/startxfce.sh.linux-vm-tools.XXXXXX)"
trap 'rm -f -- "$startxfce_temp"' EXIT
cat > "$startxfce_temp" <<'EOF'
#!/bin/sh
set -eu

# A systemd user manager and its D-Bus activation environment are shared by
# all sessions for the same account. Refuse to overwrite an active local
# graphical session with Xfce/X11 values.
current_session="${XDG_SESSION_ID:-}"
if [ -z "$current_session" ]; then
    echo 'xrdp session has no logind session ID' >&2
    exit 1
fi

sessions="$(loginctl show-user "$(id -u)" --property=Sessions --value)"
for session in $sessions; do
    if [ "$session" = "$current_session" ]; then
        continue
    fi

    session_type="$(loginctl show-session "$session" --property=Type --value)"
    case "$session_type" in
        x11|wayland)
            echo 'Log out other graphical sessions before starting xrdp' >&2
            exit 1
            ;;
    esac
done

unset WAYLAND_DISPLAY WAYLAND_SOCKET
export XDG_SESSION_TYPE=x11
export XDG_SESSION_DESKTOP=xfce
export XDG_CURRENT_DESKTOP=XFCE
export DESKTOP_SESSION=xfce
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
    echo "User D-Bus socket is missing: $XDG_RUNTIME_DIR/bus" >&2
    exit 1
fi

WAYLAND_DISPLAY= WAYLAND_SOCKET= \
dbus-update-activation-environment --systemd \
    WAYLAND_DISPLAY WAYLAND_SOCKET DBUS_SESSION_BUS_ADDRESS DISPLAY XAUTHORITY \
    XDG_SESSION_TYPE XDG_SESSION_DESKTOP \
    XDG_CURRENT_DESKTOP DESKTOP_SESSION GDK_BACKEND QT_QPA_PLATFORM \
    XDG_RUNTIME_DIR
systemctl --user unset-environment WAYLAND_DISPLAY WAYLAND_SOCKET

# Run Debian's standard X11 session initialization before starting Xfce. This
# loads locale, Xresources, accessibility, D-Bus and portal integration.
exec /etc/X11/Xsession startxfce4
EOF
chown root:root "$startxfce_temp"
chmod 755 "$startxfce_temp"
mv -f -- "$startxfce_temp" /etc/xrdp/startxfce.sh
trap - EXIT

backup_once /etc/xrdp/sesman.ini
set_ini_value /etc/xrdp/sesman.ini Globals UserWindowManager startxfce.sh
set_ini_value /etc/xrdp/sesman.ini Globals DefaultWindowManager startxfce.sh
set_ini_value /etc/xrdp/sesman.ini Chansrv FuseMountName shared-drives

if [ -f /etc/X11/Xwrapper.config ]; then
    backup_once /etc/X11/Xwrapper.config
    set_file_value /etc/X11/Xwrapper.config allowed_users anybody
else
    printf '%s\n' 'allowed_users=anybody' > /etc/X11/Xwrapper.config
fi

usermod -aG ssl-cert xrdp

# Preserve the package-managed PAM stack and add only the optional keyring
# hooks needed by the Xfce session.
test -f /etc/pam.d/xrdp-sesman
backup_once /etc/pam.d/xrdp-sesman
ensure_line /etc/pam.d/xrdp-sesman '-auth optional pam_gnome_keyring.so'
ensure_line /etc/pam.d/xrdp-sesman '-session optional pam_gnome_keyring.so auto_start'

# Xfce launchers use this helper instead of invoking a browser directly.
test -f /etc/xdg/xfce4/helpers.rc
backup_once /etc/xdg/xfce4/helpers.rc
set_file_value /etc/xdg/xfce4/helpers.rc WebBrowser epiphany

echo 'blacklist vmw_vsock_vmci_transport' > /etc/modprobe.d/blacklist-vmw_vsock_vmci_transport.conf
echo 'hv_sock' > /etc/modules-load.d/hv_sock.conf
modprobe hv_sock

# Apply coherent Xfce-native defaults. Yaru does not provide matching xfwm4
# decorations, which results in undersized borders and inconsistent scaling.
mkdir -p /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Greybird"/>
    <property name="IconThemeName" type="string" value="elementary-xfce"/>
  </property>
  <property name="Xft" type="empty">
    <property name="DPI" type="int" value="120"/>
    <property name="Antialias" type="int" value="1"/>
    <property name="Hinting" type="int" value="1"/>
    <property name="HintStyle" type="string" value="hintslight"/>
    <property name="RGBA" type="string" value="rgb"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Noto Sans 10"/>
    <property name="MonospaceFontName" type="string" value="Noto Sans Mono 10"/>
    <property name="CursorThemeName" type="string" value="DMZ-White"/>
    <property name="CursorThemeSize" type="int" value="24"/>
    <property name="DecorationLayout" type="string" value="menu:minimize,maximize,close"/>
  </property>
</channel>
EOF
cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Greybird"/>
    <property name="title_font" type="string" value="Noto Sans Bold 10"/>
    <property name="button_layout" type="string" value="O|HMC"/>
    <property name="box_move" type="bool" value="false"/>
    <property name="box_resize" type="bool" value="false"/>
    <property name="use_compositing" type="bool" value="true"/>
    <property name="workspace_count" type="int" value="1"/>
  </property>
</channel>
EOF
cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="/usr/share/backgrounds/warty-final-ubuntu.png"/>
        <property name="image-style" type="int" value="3"/>
      </property>
    </property>
  </property>
</channel>
EOF

mkdir -p /etc/xdg/xfce4/panel
cat > /etc/xdg/xfce4/panel/default.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=8;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="36"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
        <value type="int" value="7"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu"/>
    <property name="plugin-2" type="string" value="tasklist">
      <property name="flat-buttons" type="bool" value="true"/>
      <property name="show-handle" type="bool" value="false"/>
    </property>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-4" type="string" value="systray">
      <property name="show-frame" type="bool" value="false"/>
      <property name="square-icons" type="bool" value="true"/>
    </property>
    <property name="plugin-5" type="string" value="notification-plugin"/>
    <property name="plugin-6" type="string" value="pulseaudio"/>
    <property name="plugin-7" type="string" value="clock">
      <property name="digital-format" type="string" value=" %m-%d %H:%M "/>
    </property>
  </property>
  <property name="configver" type="int" value="2"/>
</channel>
EOF

systemctl enable xrdp xrdp-sesman
systemctl restart xrdp-sesman xrdp

# Fail rather than reporting success when a package or setting is missing.
for package in \
    xrdp xorgxrdp xfce4 xfce4-goodies dbus-x11 dbus-user-session \
    epiphany-browser xdg-desktop-portal-gtk greybird-gtk-theme \
    elementary-xfce-icon-theme; do
    dpkg-query -W -f='${Status}\n' "$package" | grep -qxF 'install ok installed'
done
command -v startxfce4 > /dev/null
command -v dbus-update-activation-environment > /dev/null
test -x /etc/xrdp/startxfce.sh
grep -qxF 'dbus-update-activation-environment --systemd \' /etc/xrdp/startxfce.sh
grep -qxF 'exec /etc/X11/Xsession startxfce4' /etc/xrdp/startxfce.sh
grep -qxF 'port=vsock://-1:3389' /etc/xrdp/xrdp.ini
grep -qxF 'security_layer=rdp' /etc/xrdp/xrdp.ini
grep -qxF 'crypt_level=none' /etc/xrdp/xrdp.ini
grep -qxF 'bitmap_compression=false' /etc/xrdp/xrdp.ini
grep -qxF 'default_dpi=120' /etc/xrdp/xrdp.ini
if grep -Eq '^[[:space:]]*vmconnect[[:space:]]*=' /etc/xrdp/xrdp.ini; then
    echo 'Unsupported vmconnect setting remains in /etc/xrdp/xrdp.ini' >&2
    exit 1
fi
grep -qxF 'UserWindowManager=startxfce.sh' /etc/xrdp/sesman.ini
grep -qxF 'DefaultWindowManager=startxfce.sh' /etc/xrdp/sesman.ini
grep -qxF 'FuseMountName=shared-drives' /etc/xrdp/sesman.ini
for service in xrdp xrdp-sesman; do
    systemctl is-active --quiet "$service"
done
for service in xrdp xrdp-sesman; do
    systemctl is-enabled --quiet "$service"
done
# Use the policy shipped and maintained by the xrdp package.
test -f /usr/share/polkit-1/rules.d/xrdp-colord.rules
# Xwrapper allows any user.
grep -qxF 'allowed_users=anybody' /etc/X11/Xwrapper.config
# xrdp is in the ssl-cert group.
id -nG xrdp | grep -qw ssl-cert
# hv_sock is loaded.
test -d /sys/module/hv_sock
# hypervkvpd symlinks exist (only checked when the source binaries are present).
if [ -x /usr/sbin/hv_get_dhcp_info ]; then
    test "$(readlink /usr/libexec/hypervkvpd/hv_get_dhcp_info)" = \
        /usr/sbin/hv_get_dhcp_info
fi
if [ -x /usr/sbin/hv_get_dns_info ]; then
    test "$(readlink /usr/libexec/hypervkvpd/hv_get_dns_info)" = \
        /usr/sbin/hv_get_dns_info
fi
# PAM keyring auto-unlock configured.
grep -qxF -- '-auth optional pam_gnome_keyring.so' /etc/pam.d/xrdp-sesman
grep -qxF -- '-session optional pam_gnome_keyring.so auto_start' /etc/pam.d/xrdp-sesman
grep -qxF 'WebBrowser=epiphany' /etc/xdg/xfce4/helpers.rc
# Xfce system-wide theme defaults present.
test -f /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml
test -f /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
test -f /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
test -f /etc/xdg/xfce4/panel/default.xml
test -f /usr/share/backgrounds/warty-final-ubuntu.png

echo 'Install is complete.'
echo 'Fully power off the VM, set EnhancedSessionTransportType to HvSocket on the host, then start it again.'
