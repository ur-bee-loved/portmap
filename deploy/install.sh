#!/usr/bin/env bash
# Install portmap as a systemd service that serves the page on the local
# network, started now and on every boot. Run it from the checkout on the Pi:
#
#   sudo deploy/install.sh [--port N]   install or update, then (re)start it
#   sudo deploy/install.sh --uninstall  stop and remove it; data/ is kept
#
# The service runs as the owner of this folder, straight from it, so after a
# "git pull" a "sudo systemctl restart portmap" is enough. Re-running this
# keeps the port that is installed unless --port is given.

set -euo pipefail

PROG=${0##*/}
UNIT=portmap
UNIT_FILE=/etc/systemd/system/$UNIT.service
DEFAULT_PORT=8765
APP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() { echo "$PROG: error: $*" >&2; exit 1; }
note() { echo "$PROG: $*"; }

usage() {
    cat <<EOF
usage: sudo $0 [--port N]    install or update the service and (re)start it
       sudo $0 --uninstall   stop and remove the service; data/ is kept
EOF
}

# The port the installed service uses, drop-ins included; empty if none.
installed_port() {
    systemctl show -p Environment --value "$UNIT" 2>/dev/null \
        | grep -o 'PORTMAP_PORT=[0-9]*' | tail -n 1 | cut -d = -f 2 || true
}

# firewall open|close PORT: change the rule in ufw or firewalld, if one is active.
firewall() {
    local action=$1 port=$2
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
        if [[ $action == open ]]; then
            ufw allow "$port/tcp" >/dev/null
            note "ufw: allowed tcp port $port"
        else
            ufw --force delete allow "$port/tcp" >/dev/null || true
            note "ufw: removed the rule for tcp port $port"
        fi
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        if [[ $action == open ]]; then
            firewall-cmd --quiet --permanent --add-port="$port/tcp"
            note "firewalld: opened tcp port $port"
        else
            firewall-cmd --quiet --permanent --remove-port="$port/tcp" || true
            note "firewalld: closed tcp port $port"
        fi
        firewall-cmd --quiet --reload
    elif [[ $action == open ]]; then
        note "no active firewall (ufw or firewalld), so tcp port $port is reachable as it is;" \
             "if you manage nftables or iptables yourself, allow it there"
    fi
}

install_service() {
    case $APP_DIR in
        *[[:space:]%\&\|\\\"\']*) die "the unit file cannot take this folder's path, move it (e.g. to ~/portmap): $APP_DIR" ;;
    esac
    [[ -f $APP_DIR/server.py && -f $APP_DIR/deploy/$UNIT.service ]] || die "$APP_DIR is not a portmap checkout"
    local user
    user=$(stat -c %U -- "$APP_DIR")
    [[ $user != root ]] || die "$APP_DIR belongs to root; clone it as your normal user (or chown -R it) so the service does not run as root"
    if ! /usr/bin/python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
        die "portmap needs /usr/bin/python3, version 3.10 or newer"
    fi

    local old
    old=$(installed_port)
    port=${port:-${old:-$DEFAULT_PORT}}
    if ! [[ $port =~ ^[1-9][0-9]{3,4}$ ]] || ((port < 1024 || port > 65535)); then
        die "the port must be a number from 1024 to 65535 (lower ones need root): $port"
    fi

    sed -e "s|^User=.*|User=$user|" \
        -e "s|/home/pi/portmap|$APP_DIR|g" \
        -e "s|^Environment=PORTMAP_PORT=.*|Environment=PORTMAP_PORT=$port|" \
        "$APP_DIR/deploy/$UNIT.service" >"$UNIT_FILE.tmp"
    chmod 0644 "$UNIT_FILE.tmp"
    mv -f "$UNIT_FILE.tmp" "$UNIT_FILE"
    systemctl daemon-reload
    systemctl enable --quiet "$UNIT"
    # Type=notify: this returns once the server is listening, or fails.
    if ! systemctl restart "$UNIT"; then
        journalctl -u "$UNIT" -n 20 --no-pager >&2 || true
        die "the service did not start; the log above says why"
    fi

    port=$(installed_port)
    [[ -z $old || $old == "$port" ]] || firewall close "$old"
    firewall open "$port"

    note "running as $user from $APP_DIR, on port $port; it also starts on boot"
    if [[ -f $APP_DIR/data/network.json ]]; then
        note "data: $APP_DIR/data/network.json"
    else
        note "no data/network.json yet: the page shows the example data until the first edit" \
             "(or copy your network.json into $APP_DIR/data/ and restart)"
    fi
    echo
    echo "Open it from another device on the network:"
    if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
        echo "  http://$(hostname).local:$port/"
    fi
    local ip
    for ip in $(hostname -I 2>/dev/null || true); do
        [[ $ip == *:* ]] || echo "  http://$ip:$port/"
    done
    echo
    echo "Status: systemctl status $UNIT    Log: journalctl -u $UNIT -f"
}

uninstall_service() {
    if [[ ! -f $UNIT_FILE ]]; then
        note "the service is not installed"
        return
    fi
    local port
    port=$(installed_port)
    systemctl disable --now --quiet "$UNIT" || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    systemctl reset-failed "$UNIT" 2>/dev/null || true
    [[ -z $port ]] || firewall close "$port"
    note "removed the service; the data is still in $APP_DIR/data"
}

port=""
uninstall=0
while (($#)); do
    case $1 in
        -p | --port)
            [[ $# -ge 2 ]] || die "$1 needs a value"
            port=$2
            shift 2
            ;;
        --port=*) port=${1#*=}; shift ;;
        --uninstall) uninstall=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run it as root: sudo $0"
[[ -d /run/systemd/system ]] || die "systemd is not running on this machine"

if ((uninstall)); then
    uninstall_service
else
    install_service
fi
