#!/bin/bash

# Configure Hyper-V Enhanced Session Mode on Xubuntu 26.04.

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

ensure_pam_hook() {
    local file="$1"
    local stack="$2"
    local line="$3"
    local temp_file

    if grep -Eq "^[[:space:]-]*${stack}[[:space:]].*pam_gnome_keyring\\.so" "$file"; then
        return
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

    if [ -L "$target" ]; then
        if [ "$(readlink "$target")" = "$source" ]; then
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

. /etc/os-release
if [ "${ID:-}" != ubuntu ] || [ "${VERSION_ID:-}" != 26.04 ]; then
    echo 'This script requires Xubuntu 26.04' >&2
    exit 1
fi

if ! dpkg-query -W -f='${Status}\n' xubuntu-desktop |
    grep -qxF 'install ok installed'; then
    echo 'The xubuntu-desktop package is not installed; use the Xubuntu 26.04 image' >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    linux-tools-virtual linux-cloud-tools-virtual \
    xrdp xorgxrdp dbus-x11 dbus-user-session \
    gnome-keyring libpam-gnome-keyring \
    xdg-desktop-portal xdg-desktop-portal-gtk \
    epiphany-browser

# Ubuntu places these Hyper-V KVP helpers outside the path used by the daemon.
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

# Ubuntu 26.04 ships xrdp 0.10.1, which predates the vmconnect option.
backup_once /etc/xrdp/xrdp.ini
remove_ini_value /etc/xrdp/xrdp.ini Globals vmconnect
set_ini_value /etc/xrdp/xrdp.ini Globals port 'vsock://-1:3389'
set_ini_value /etc/xrdp/xrdp.ini Globals security_layer rdp
set_ini_value /etc/xrdp/xrdp.ini Globals crypt_level none
set_ini_value /etc/xrdp/xrdp.ini Globals bitmap_compression false
set_ini_value /etc/xrdp/xrdp.ini Globals default_dpi 120

startxubuntu_temp="$(mktemp /etc/xrdp/startxubuntu.sh.linux-vm-tools.XXXXXX)"
trap 'rm -f -- "$startxubuntu_temp"' EXIT
cat > "$startxubuntu_temp" <<'EOF'
#!/bin/sh
set -eu

# A user's systemd manager and D-Bus activation environment are shared by all
# sessions. Do not overwrite an active local Xubuntu session.
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
export XDG_SESSION_DESKTOP=xubuntu
export XDG_CURRENT_DESKTOP=XFCE
export DESKTOP_SESSION=xubuntu
export GDMSESSION=xubuntu
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
    XDG_SESSION_TYPE XDG_SESSION_DESKTOP XDG_CURRENT_DESKTOP \
    DESKTOP_SESSION GDMSESSION GDK_BACKEND QT_QPA_PLATFORM \
    XDG_RUNTIME_DIR
systemctl --user unset-environment WAYLAND_DISPLAY WAYLAND_SOCKET

exec /etc/X11/Xsession startxfce4
EOF
chown root:root "$startxubuntu_temp"
chmod 755 "$startxubuntu_temp"
mv -f -- "$startxubuntu_temp" /etc/xrdp/startxubuntu.sh
trap - EXIT

backup_once /etc/xrdp/sesman.ini
set_ini_value /etc/xrdp/sesman.ini Globals UserWindowManager startxubuntu.sh
set_ini_value /etc/xrdp/sesman.ini Globals DefaultWindowManager startxubuntu.sh
set_ini_value /etc/xrdp/sesman.ini Chansrv FuseMountName shared-drives

if [ -f /etc/X11/Xwrapper.config ]; then
    backup_once /etc/X11/Xwrapper.config
    set_file_value /etc/X11/Xwrapper.config allowed_users anybody
else
    printf '%s\n' 'allowed_users=anybody' > /etc/X11/Xwrapper.config
fi

usermod -aG ssl-cert xrdp

test -f /etc/pam.d/xrdp-sesman
backup_once /etc/pam.d/xrdp-sesman
ensure_pam_hook \
    /etc/pam.d/xrdp-sesman auth \
    '-auth optional pam_gnome_keyring.so'
ensure_pam_hook \
    /etc/pam.d/xrdp-sesman session \
    '-session optional pam_gnome_keyring.so auto_start'

# Firefox is a snap on Xubuntu and may not start in an xrdp session.
xubuntu_helpers=/etc/xdg/xdg-xubuntu/xfce4/helpers.rc
test -f "$xubuntu_helpers"
backup_once "$xubuntu_helpers"
set_file_value "$xubuntu_helpers" WebBrowser epiphany

printf '%s\n' \
    'blacklist vmw_vsock_vmci_transport' \
    > /etc/modprobe.d/blacklist-vmw_vsock_vmci_transport.conf
printf '%s\n' 'hv_sock' > /etc/modules-load.d/hv_sock.conf
modprobe hv_sock

systemctl enable xrdp xrdp-sesman
systemctl restart xrdp-sesman xrdp

# Validate the installed session before reporting success.
for package in \
    xubuntu-desktop xrdp xorgxrdp dbus-x11 dbus-user-session \
    xdg-desktop-portal-gtk epiphany-browser; do
    dpkg-query -W -f='${Status}\n' "$package" |
        grep -qxF 'install ok installed'
done
command -v startxfce4 > /dev/null
command -v dbus-update-activation-environment > /dev/null
test -d /etc/xdg/xdg-xubuntu
test -x /etc/xrdp/startxubuntu.sh
grep -qxF 'exec /etc/X11/Xsession startxfce4' /etc/xrdp/startxubuntu.sh
grep -qxF 'port=vsock://-1:3389' /etc/xrdp/xrdp.ini
grep -qxF 'security_layer=rdp' /etc/xrdp/xrdp.ini
grep -qxF 'crypt_level=none' /etc/xrdp/xrdp.ini
grep -qxF 'bitmap_compression=false' /etc/xrdp/xrdp.ini
grep -qxF 'default_dpi=120' /etc/xrdp/xrdp.ini
if grep -Eq '^[[:space:]]*vmconnect[[:space:]]*=' /etc/xrdp/xrdp.ini; then
    echo 'Unsupported vmconnect setting remains in /etc/xrdp/xrdp.ini' >&2
    exit 1
fi
grep -qxF 'UserWindowManager=startxubuntu.sh' /etc/xrdp/sesman.ini
grep -qxF 'DefaultWindowManager=startxubuntu.sh' /etc/xrdp/sesman.ini
grep -qxF 'FuseMountName=shared-drives' /etc/xrdp/sesman.ini
grep -qxF 'allowed_users=anybody' /etc/X11/Xwrapper.config
grep -qxF 'WebBrowser=epiphany' /etc/xdg/xdg-xubuntu/xfce4/helpers.rc
grep -Eq '^[[:space:]-]*auth[[:space:]].*pam_gnome_keyring\.so' \
    /etc/pam.d/xrdp-sesman
grep -Eq '^[[:space:]-]*session[[:space:]].*pam_gnome_keyring\.so' \
    /etc/pam.d/xrdp-sesman
test -f /usr/share/polkit-1/rules.d/xrdp-colord.rules
test -d /sys/module/hv_sock
id -nG xrdp | grep -qw ssl-cert
for service in xrdp xrdp-sesman; do
    systemctl is-active --quiet "$service"
    systemctl is-enabled --quiet "$service"
done

echo 'Install is complete.'
echo 'Log out local graphical sessions before connecting with Enhanced Session Mode.'
echo 'Fully power off the VM before changing EnhancedSessionTransportType to HvSocket.'
