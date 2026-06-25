#!/usr/bin/env bash
#
# SerialMux guided installer
# --------------------------
# Sets up SerialMux (share one USB radio between several programs) and, if you
# want, a MeshCore observer and/or the MeshCore bot — wiring each to a virtual
# port so they never fight over the real USB device.
#
# Run it with:
#   curl -fsSL https://raw.githubusercontent.com/jjkroell/SerialMux/main/install.sh | sudo bash
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Pretty output + prompt helpers (read from /dev/tty so it works when piped via
# `curl | bash`, where stdin is the script, not the keyboard).
# ---------------------------------------------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'; else B=; G=; Y=; R=; C=; N=; fi
step()  { printf '\n%s==> %s%s\n' "$B$C" "$*" "$N"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s✓ %s%s\n' "$G" "$*" "$N"; }
warn()  { printf '    %s! %s%s\n' "$Y" "$*" "$N"; }
die()   { printf '\n%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

prompt() {  # prompt VARNAME "Question" "default"
    local __var=$1 __q=$2 __def=${3:-} __ans
    if [ -n "$__def" ]; then printf '    %s [%s]: ' "$__q" "$__def"; else printf '    %s: ' "$__q"; fi
    read -r __ans </dev/tty || true
    [ -z "$__ans" ] && __ans=$__def
    printf -v "$__var" '%s' "$__ans"
}

ask_yn() {  # ask_yn "Question" default(y/n) -> returns 0 for yes
    local __q=$1 __def=${2:-y} __ans __hint
    [ "$__def" = y ] && __hint="Y/n" || __hint="y/N"
    while true; do
        printf '    %s [%s]: ' "$__q" "$__hint"
        read -r __ans </dev/tty || true
        __ans=${__ans:-$__def}
        case "$__ans" in [Yy]*) return 0;; [Nn]*) return 1;; esac
    done
}

menu() {  # menu "Prompt" item1 item2 ... -> sets REPLY_INDEX (1-based) and REPLY_VALUE
    local __q=$1; shift
    local __items=("$@") __i __ans
    printf '    %s\n' "$__q"
    for __i in "${!__items[@]}"; do printf '      %s) %s\n' "$((__i+1))" "${__items[$__i]}"; done
    while true; do
        printf '    Enter a number (1-%s): ' "${#__items[@]}"
        read -r __ans </dev/tty || true
        if [[ "$__ans" =~ ^[0-9]+$ ]] && [ "$__ans" -ge 1 ] && [ "$__ans" -le "${#__items[@]}" ]; then
            REPLY_INDEX=$__ans; REPLY_VALUE=${__items[$((__ans-1))]}; return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# Must run as root (creates /dev symlinks, installs services).
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    die "Please run this with sudo:  curl -fsSL .../install.sh | sudo bash"
fi
command -v apt-get >/dev/null 2>&1 || die "This installer targets Debian/Raspberry Pi OS (needs apt)."

SM_DIR=/opt/serialmux
SM_REPO=https://github.com/jjkroell/SerialMux
NEXT_VPORT=0          # index of the next free virtual port to hand out
VPORT_COUNT=0

assign_vport() {      # sets REPLY_VPORT to the next free vport (call WITHOUT $(); a
                      # subshell wouldn't persist the counter). Reuses the last
                      # port if the user asked for fewer ports than programs.
    local idx=$NEXT_VPORT
    if [ "$idx" -ge "$VPORT_COUNT" ]; then
        idx=$((VPORT_COUNT-1))
        warn "More programs than virtual ports — reusing /dev/ttyV$idx (re-run and pick more ports if they conflict)."
    fi
    REPLY_VPORT="/dev/ttyV$idx"
    if [ "$NEXT_VPORT" -lt "$VPORT_COUNT" ]; then NEXT_VPORT=$((NEXT_VPORT+1)); fi
    return 0
}

printf '%s\n' "${B}${C}"
cat <<'BANNER'
   ____            _       _ __  __
  / ___|  ___ _ __(_) __ _| |  \/  |_   ___  __
  \___ \ / _ \ '__| |/ _` | | |\/| | | | \ \/ /
   ___) |  __/ |  | | (_| | | |  | | |_| |>  <
  |____/ \___|_|  |_|\__,_|_|_|  |_|\__,_/_/\_\

  Share one USB radio between a bot AND an observer.
BANNER
printf '%s\n' "$N"

# ===========================================================================
step "Step 1 of 5 — Install prerequisites"
# ===========================================================================
info "Updating package lists and installing git, python3, pyserial, curl..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git python3 python3-serial curl >/dev/null
ok "Tools installed."

# ===========================================================================
step "Step 2 of 5 — Download SerialMux"
# ===========================================================================
if [ -d "$SM_DIR/.git" ]; then
    info "SerialMux already present at $SM_DIR — updating..."
    git -C "$SM_DIR" pull --ff-only -q || warn "Could not update (continuing with existing copy)."
else
    git clone -q "$SM_REPO" "$SM_DIR"
fi
[ -f "$SM_DIR/SerialMux.py" ] || die "SerialMux.py not found in $SM_DIR"
ok "SerialMux is at $SM_DIR"

# ===========================================================================
step "Step 3 of 5 — Choose your radio and virtual ports"
# ===========================================================================
info "Scanning for USB serial devices..."
mapfile -t BYID < <(ls -1 /dev/serial/by-id/ 2>/dev/null || true)
DEV_PATHS=(); DEV_LABELS=()
if [ "${#BYID[@]}" -gt 0 ]; then
    for name in "${BYID[@]}"; do
        target=$(readlink -f "/dev/serial/by-id/$name" 2>/dev/null || echo "?")
        DEV_PATHS+=("/dev/serial/by-id/$name")
        DEV_LABELS+=("$name  (-> ${target##*/})")
    done
else
    warn "Nothing under /dev/serial/by-id/. Falling back to raw device names."
    for d in /dev/ttyACM* /dev/ttyUSB*; do [ -e "$d" ] && { DEV_PATHS+=("$d"); DEV_LABELS+=("$d"); }; done
fi
[ "${#DEV_PATHS[@]}" -gt 0 ] || die "No USB serial devices found. Plug in your radio (check the cable carries data) and re-run."

menu "Which device is your MeshCore radio?" "${DEV_LABELS[@]}"
REAL_PORT=${DEV_PATHS[$((REPLY_INDEX-1))]}
ok "Selected: $REAL_PORT"
if [[ "$REAL_PORT" != /dev/serial/by-id/* ]]; then
    warn "This raw name (e.g. ttyACM0) can change after a reboot. /dev/serial/by-id/ is more reliable if available."
fi

menu "How many virtual ports do you need? (one per program that will use the radio)" \
     "1 — a single program" "2 — e.g. an observer + a bot" "3 — observer + bot + spare"
VPORT_COUNT=$REPLY_INDEX
VP_PYLIST=""
for i in $(seq 0 $((VPORT_COUNT-1))); do VP_PYLIST+="${VP_PYLIST:+, }'/dev/ttyV$i'"; done
ok "Will create: $(echo "$VP_PYLIST" | tr -d "'")"

step "Writing SerialMux configuration"
sed -i "s|^REAL_PORT = .*|REAL_PORT = '$REAL_PORT'|" "$SM_DIR/SerialMux.py"
sed -i "s|^VPORTS = .*|VPORTS = [$VP_PYLIST]|" "$SM_DIR/SerialMux.py"
ok "Set REAL_PORT and $VPORT_COUNT virtual port(s) in SerialMux.py"

# ===========================================================================
step "Step 4 of 5 — Install SerialMux as a service and verify it"
# ===========================================================================
cat > /etc/systemd/system/serialmux.service <<EOF
[Unit]
Description=SerialMux virtual serial port multiplexer
After=multi-user.target

[Service]
ExecStart=/usr/bin/python3 $SM_DIR/SerialMux.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q serialmux 2>/dev/null || true
systemctl restart serialmux
info "Starting up and checking..."
sleep 3
if systemctl is-active --quiet serialmux && [ -e /dev/ttyV0 ]; then
    ok "SerialMux is running. Virtual ports: $(ls -1 /dev/ttyV* 2>/dev/null | tr '\n' ' ')"
else
    systemctl status serialmux --no-pager -l | tail -n 15 || true
    die "SerialMux did not start cleanly. Check the device path and run: journalctl -u serialmux -e"
fi

# ===========================================================================
step "Step 5 of 5 — Connect your programs (observer / bot)"
# ===========================================================================

OBSERVER_KIND=none          # companion | repeater | none
OBSERVER_CFGDIR=""
OBSERVER_SVC=""
OBSERVER_VPORT=""

OBSERVER_OVERRIDE=""             # path to our dedicated override file
configure_observer_serial() {   # writes a SerialMux-owned override that wins on load
    # Named zz-* so it sorts AFTER 99-user.toml; both tools load config.d/*.toml
    # sorted and deep-merge, so this overrides the serial port WITHOUT touching
    # the user's own config (their IATA, brokers, etc. stay intact).
    OBSERVER_OVERRIDE="$OBSERVER_CFGDIR/config.d/zz-serialmux.toml"
    mkdir -p "$OBSERVER_CFGDIR/config.d"
    {
        echo "# Managed by the SerialMux installer. Points the observer at a"
        echo "# SerialMux virtual port. Loaded last, so it wins. Safe to delete"
        echo "# if you stop using SerialMux."
        echo
        if [ "$OBSERVER_KIND" = companion ]; then
            echo "[capture]"
            echo 'connection_type = "serial"'
            echo
        fi
        echo "[serial]"
        echo "ports = [\"$OBSERVER_VPORT\"]"
    } > "$OBSERVER_OVERRIDE"
    ok "Pointed the observer at $OBSERVER_VPORT  ($OBSERVER_OVERRIDE)"
}

# --- Observer ---
if [ -d /etc/mctomqtt ] || [ -d /etc/meshcore-packet-capture ]; then
    EXIST="(unknown)"
    [ -d /etc/mctomqtt ] && { OBSERVER_KIND=repeater;  OBSERVER_CFGDIR=/etc/mctomqtt;                OBSERVER_SVC=mctomqtt;                  EXIST="repeater (mctomqtt)"; }
    [ -d /etc/meshcore-packet-capture ] && { OBSERVER_KIND=companion; OBSERVER_CFGDIR=/etc/meshcore-packet-capture; OBSERVER_SVC=meshcore-packet-capture; EXIST="companion (packet-capture)"; }
    info "Detected an observer already installed: $EXIST"
    if ask_yn "Repoint it at a SerialMux virtual port?" y; then
        assign_vport; OBSERVER_VPORT=$REPLY_VPORT
        configure_observer_serial
        systemctl restart "$OBSERVER_SVC" 2>/dev/null || warn "Could not restart $OBSERVER_SVC — restart it yourself."
    else
        OBSERVER_KIND=none
    fi
else
    if ask_yn "Do you want to install a MeshCore observer now?" y; then
        menu "What role is this node?" \
             "Companion — installs agessaman/meshcore-packet-capture" \
             "Repeater  — installs Cisien/meshcoretomqtt"
        if [ "$REPLY_INDEX" = 1 ]; then
            OBSERVER_KIND=companion; OBSERVER_CFGDIR=/etc/meshcore-packet-capture; OBSERVER_SVC=meshcore-packet-capture
            step "Running the official meshcore-packet-capture installer"
            bash -c "$(curl -fsSL https://raw.githubusercontent.com/agessaman/meshcore-packet-capture/main/install.sh)" </dev/tty || warn "Upstream installer reported an issue — review its output above."
        else
            OBSERVER_KIND=repeater;  OBSERVER_CFGDIR=/etc/mctomqtt; OBSERVER_SVC=mctomqtt
            step "Running the official meshcoretomqtt installer"
            curl -fsSL https://raw.githubusercontent.com/Cisien/meshcoretomqtt/main/install.sh | bash </dev/tty || warn "Upstream installer reported an issue — review its output above."
        fi
        assign_vport; OBSERVER_VPORT=$REPLY_VPORT
        step "Wiring the observer to SerialMux"
        configure_observer_serial
        systemctl restart "$OBSERVER_SVC" 2>/dev/null || warn "Could not restart $OBSERVER_SVC yet."
    fi
fi

# --- Bot ---
BOT_VPORT=""
if ask_yn "Do you want to install the MeshCore bot (agessaman/meshcore-bot)?" n; then
    BOT_SRC=/opt/meshcore-bot-src
    step "Downloading and installing the MeshCore bot"
    if [ -d "$BOT_SRC/.git" ]; then git -C "$BOT_SRC" pull --ff-only -q || true; else git clone -q https://github.com/agessaman/meshcore-bot "$BOT_SRC"; fi
    assign_vport; BOT_VPORT=$REPLY_VPORT
    [ -f "$BOT_SRC/config.ini" ] || cp "$BOT_SRC/config.ini.quickstart" "$BOT_SRC/config.ini"
    sed -i -E "s|^connection_type *=.*|connection_type = serial|; s|^serial_port *=.*|serial_port = $BOT_VPORT|" "$BOT_SRC/config.ini"
    ok "Bot will use $BOT_VPORT (edit $BOT_SRC/config.ini later for bot name, location, etc.)"
    info "Running the bot's service installer..."
    ( cd "$BOT_SRC" && bash ./install-service.sh </dev/tty ) || warn "Bot service installer reported an issue — see its output above."
    # The service installs to /opt/meshcore-bot; make sure config + serial port land there too.
    if [ -d /opt/meshcore-bot ] && [ "$(readlink -f /opt/meshcore-bot)" != "$(readlink -f "$BOT_SRC")" ]; then
        cp "$BOT_SRC/config.ini" /opt/meshcore-bot/config.ini 2>/dev/null || true
        sed -i -E "s|^connection_type *=.*|connection_type = serial|; s|^serial_port *=.*|serial_port = $BOT_VPORT|" /opt/meshcore-bot/config.ini 2>/dev/null || true
    fi
    systemctl restart meshcore-bot 2>/dev/null || true
fi

# --- Custom broker for the observer ---
if [ "$OBSERVER_KIND" != none ]; then
    if ask_yn "Do you want to add a custom MQTT broker for the observer?" n; then
        prompt BK_NAME   "Broker name (a label)" "local"
        prompt BK_SERVER "Broker hostname or IP" ""
        prompt BK_PORT   "Broker port" "1883"
        menu "Transport?" "tcp (plain MQTT, usually port 1883)" "websockets (usually port 443)"
        [ "$REPLY_INDEX" = 1 ] && BK_TRANS=tcp || BK_TRANS=websockets
        if ask_yn "Use TLS/SSL?" "$([ "$BK_TRANS" = websockets ] && echo y || echo n)"; then BK_TLS=true; else BK_TLS=false; fi
        if ask_yn "Does the broker require a username/password?" n; then
            prompt BK_USER "Username" ""
            prompt BK_PASS "Password" ""
            BK_AUTH=password
        else
            BK_AUTH=none
        fi
        userf="${OBSERVER_OVERRIDE:-$OBSERVER_CFGDIR/config.d/zz-serialmux.toml}"
        {
            echo
            echo "[[broker]]"
            echo "name = \"$BK_NAME\""
            echo "enabled = true"
            echo "server = \"$BK_SERVER\""
            echo "port = $BK_PORT"
            echo "transport = \"$BK_TRANS\""
            echo "keepalive = 60"
            echo "qos = 0"
            echo "retain = true"
            echo
            echo "[broker.tls]"
            echo "enabled = $BK_TLS"
            echo "verify = true"
            echo
            echo "[broker.auth]"
            echo "method = \"$BK_AUTH\""
            if [ "$BK_AUTH" = password ]; then
                echo "username = \"$BK_USER\""
                echo "password = \"$BK_PASS\""
            fi
        } >> "$userf"
        ok "Added broker '$BK_NAME' ($BK_SERVER:$BK_PORT) to $userf"
        systemctl restart "$OBSERVER_SVC" 2>/dev/null || warn "Restart $OBSERVER_SVC to apply."
    fi
fi

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%s===========================================================%s\n' "$B$G" "$N"
printf '%s  All done!%s\n' "$B$G" "$N"
printf '%s===========================================================%s\n\n' "$B$G" "$N"
info "Radio (real device):  $REAL_PORT"
info "Virtual ports:        $(ls -1 /dev/ttyV* 2>/dev/null | tr '\n' ' ')"
[ -n "${OBSERVER_VPORT:-}" ] && info "Observer ($OBSERVER_KIND):   uses $OBSERVER_VPORT   [service: $OBSERVER_SVC]"
[ -n "$BOT_VPORT" ] && info "Bot:                  uses $BOT_VPORT   [service: meshcore-bot]"
echo
info "Check things are running:"
info "  sudo systemctl status serialmux"
[ "$OBSERVER_KIND" != none ] && info "  sudo systemctl status $OBSERVER_SVC"
[ -n "$BOT_VPORT" ] && info "  sudo systemctl status meshcore-bot"
echo
info "Everything starts automatically on boot. Re-run this script any time to change things."
