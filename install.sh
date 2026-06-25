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
# Try it safely first (no root, no changes — uses a fake radio in a sandbox):
#   bash install.sh --dry-run
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Pretty output + prompt helpers. Prompts read from /dev/tty so they work when
# piped via `curl | bash` (stdin is the script then), and fall back to stdin
# when there's no controlling terminal (so --dry-run is scriptable/testable).
# ---------------------------------------------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'; else B=; G=; Y=; R=; C=; N=; fi
step()  { printf '\n%s==> %s%s\n' "$B$C" "$*" "$N"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s✓ %s%s\n' "$G" "$*" "$N"; }
warn()  { printf '    %s! %s%s\n' "$Y" "$*" "$N"; }
die()   { printf '\n%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

_read() { # read one line from the terminal, or stdin if there's no terminal
    if { read -r "$1" </dev/tty; } 2>/dev/null; then return 0; fi
    read -r "$1" 2>/dev/null || true
}

prompt() {  # prompt VARNAME "Question" "default"
    local __var=$1 __q=$2 __def=${3:-} __ans=""
    if [ -n "$__def" ]; then printf '    %s [%s]: ' "$__q" "$__def"; else printf '    %s: ' "$__q"; fi
    _read __ans
    [ -z "$__ans" ] && __ans=$__def
    printf -v "$__var" '%s' "$__ans"
}

qsep() { printf '\n    %s┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄%s\n' "$C" "$N"; }

ask_yn() {  # ask_yn "Question" default(y/n) -> returns 0 for yes
    local __q=$1 __def=${2:-y} __ans __hint
    [ "$__def" = y ] && __hint="Y/n" || __hint="y/N"
    qsep
    while true; do
        printf '    %s [%s]: ' "$__q" "$__hint"
        _read __ans
        __ans=${__ans:-$__def}
        case "$__ans" in [Yy]*) return 0;; [Nn]*) return 1;; esac
    done
}

read_multiline() {  # sets REPLY_MULTI to pasted lines, terminated by a line: END
    REPLY_MULTI=""; local __line __src=/dev/stdin
    { true </dev/tty; } 2>/dev/null && __src=/dev/tty
    while IFS= read -r __line; do
        [ "$__line" = "END" ] && break
        REPLY_MULTI+="$__line"$'\n'
    done <"$__src"
}

menu() {  # menu "Prompt" item1 item2 ... -> sets REPLY_INDEX (1-based)
    local __q=$1; shift
    local __items=("$@") __i __ans
    qsep
    printf '    %s\n' "$__q"
    for __i in "${!__items[@]}"; do printf '      %s) %s\n' "$((__i+1))" "${__items[$__i]}"; done
    while true; do
        printf '    Enter a number (1-%s): ' "${#__items[@]}"
        _read __ans
        if [[ "$__ans" =~ ^[0-9]+$ ]] && [ "$__ans" -ge 1 ] && [ "$__ans" -le "${#__items[@]}" ]; then
            REPLY_INDEX=$__ans; return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# Dry-run / real-run setup. In dry-run everything lives under a sandbox dir,
# no root is needed, and system-changing commands are mocked.
# ---------------------------------------------------------------------------
DRYRUN=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRYRUN=1; done
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")
FAKERADIO_PID=""; SM_PID=""

cleanup() { [ -n "$SM_PID" ] && kill "$SM_PID" 2>/dev/null || true; [ -n "$FAKERADIO_PID" ] && kill "$FAKERADIO_PID" 2>/dev/null || true; }

if [ "$DRYRUN" = 1 ]; then
    trap cleanup EXIT INT TERM
    # A unique throwaway sandbox per run, so concurrent dry-runs never collide
    # (and there's no destructive rm of a fixed path). Override with SERIALMUX_DEMO_ROOT.
    if [ -n "${SERIALMUX_DEMO_ROOT:-}" ]; then DEMO_ROOT="$SERIALMUX_DEMO_ROOT"; else DEMO_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/serialmux-demo.XXXXXX")"; fi
    mkdir -p "$DEMO_ROOT"/dev/serial/by-id "$DEMO_ROOT"/etc/systemd/system "$DEMO_ROOT"/opt
    SYSROOT="$DEMO_ROOT"
    BYID_DIR="$DEMO_ROOT/dev/serial/by-id"
    VPORT_BASE="$DEMO_ROOT/dev/ttyV"
else
    SYSROOT=""
    BYID_DIR="/dev/serial/by-id"
    VPORT_BASE="/dev/ttyV"
fi
SM_DIR="$SYSROOT/opt/serialmux"
SERVICE_FILE="$SYSROOT/etc/systemd/system/serialmux.service"
MCTOMQTT_DIR="$SYSROOT/etc/mctomqtt"
PKTCAP_DIR="$SYSROOT/etc/meshcore-packet-capture"
SM_REPO=https://github.com/jjkroell/SerialMux
VPORT_COUNT=0
VP_PYLIST=""
declare -a USED_VPORTS=()

aptget() { if [ "$DRYRUN" = 1 ]; then info "[dry-run] would run: apt-get $*"; else apt-get "$@"; fi; }
sctl()   { if [ "$DRYRUN" = 1 ]; then info "[dry-run] would run: systemctl $*"; else systemctl "$@"; fi; }

rebuild_vp_pylist() { VP_PYLIST=""; local i; for i in $(seq 0 $((VPORT_COUNT-1))); do VP_PYLIST+="${VP_PYLIST:+, }'${VPORT_BASE}$i'"; done; }
vport_in_use() { local v; [ "${#USED_VPORTS[@]}" -eq 0 ] && return 1; for v in "${USED_VPORTS[@]}"; do [ "$v" = "$1" ] && return 0; done; return 1; }

# Grow a running SerialMux by one virtual port (used when a new program needs one
# but every current port is already taken — e.g. adding a bot to an observer-only
# setup that only had a single port).
grow_serialmux() {
    VPORT_COUNT=$((VPORT_COUNT+1)); rebuild_vp_pylist
    sed -i "s|^VPORTS = .*|VPORTS = [$VP_PYLIST]|" "$SM_DIR/SerialMux.py"
    if [ "$DRYRUN" = 1 ] && [ "${SM_SIMULATED:-0}" = 1 ]; then
        ln -sf /dev/null "${VPORT_BASE}$((VPORT_COUNT-1))"
    elif [ "$DRYRUN" = 1 ]; then
        [ -n "$SM_PID" ] && kill "$SM_PID" 2>/dev/null || true; sleep 1
        nohup python3 "$SM_DIR/SerialMux.py" >"$DEMO_ROOT/serialmux.log" 2>&1 & SM_PID=$!; sleep 2
    else
        sctl restart serialmux; sleep 2
    fi
    warn "Added an extra virtual port (${VPORT_BASE}$((VPORT_COUNT-1))) so each program gets its own."
}

# Hand out the next FREE virtual port; grow the muxer if they're all taken.
assign_vport() {
    local i v
    for i in $(seq 0 $((VPORT_COUNT-1))); do
        v="${VPORT_BASE}$i"
        if ! vport_in_use "$v"; then REPLY_VPORT="$v"; USED_VPORTS+=("$v"); return 0; fi
    done
    grow_serialmux
    v="${VPORT_BASE}$((VPORT_COUNT-1))"; REPLY_VPORT="$v"; USED_VPORTS+=("$v"); return 0
}

# Spin up a fake radio: a PTY whose slave is symlinked into the sandbox by-id
# dir, emitting periodic chatter so the muxer has something to broadcast.
start_fake_radio() {
    python3 - "$BYID_DIR/usb-Fake_MeshCore_Radio_DEMO-if00" <<'PY' &
import os, sys, time
byid = sys.argv[1]
master, slave = os.openpty()
slave_name = os.ttyname(slave)
if os.path.islink(byid) or os.path.exists(byid):
    os.remove(byid)
os.symlink(slave_name, byid)
try:
    while True:
        os.write(master, b"FAKE-RADIO heartbeat\r\n")
        time.sleep(2)
except Exception:
    pass
PY
    FAKERADIO_PID=$!
    sleep 1
}

# ---------------------------------------------------------------------------
if [ "$DRYRUN" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    die "Please run this with sudo:  curl -fsSL .../install.sh | sudo bash   (or try: bash install.sh --dry-run)"
fi
[ "$DRYRUN" = 1 ] || command -v apt-get >/dev/null 2>&1 || die "This installer targets Debian/Raspberry Pi OS (needs apt)."

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
[ "$DRYRUN" = 1 ] && warn "DRY RUN — no root, no system changes. Everything goes under $DEMO_ROOT"

# ===========================================================================
step "Step 1 of 5 — Install prerequisites"
# ===========================================================================
info "Installing git, python3, pyserial, curl..."
aptget update -qq
aptget install -y -qq git python3 python3-serial curl >/dev/null 2>&1 || true
ok "Tools ready."

# ===========================================================================
step "Step 2 of 5 — Download SerialMux"
# ===========================================================================
if [ "$DRYRUN" = 1 ] && [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/SerialMux.py" ]; then
    mkdir -p "$SM_DIR"
    [ -f "$SM_DIR/SerialMux.py" ] || cp "$SCRIPT_DIR/SerialMux.py" "$SM_DIR/"  # don't clobber a kept config on re-run
    info "[dry-run] using local SerialMux.py"
elif [ -d "$SM_DIR/.git" ]; then
    info "Updating existing copy at $SM_DIR..."; git -C "$SM_DIR" pull --ff-only -q || warn "Update failed; using existing copy."
else
    git clone -q "$SM_REPO" "$SM_DIR"
fi
[ -f "$SM_DIR/SerialMux.py" ] || die "SerialMux.py not found in $SM_DIR"
ok "SerialMux is at $SM_DIR"

# ===========================================================================
step "Step 3 of 5 — Choose your radio and virtual ports"
# ===========================================================================
[ "$DRYRUN" = 1 ] && { info "[dry-run] creating a fake radio so SerialMux has something to talk to..."; start_fake_radio; }

# If SerialMux was already set up by a previous run, offer to keep it — so
# re-running just to add/change a program doesn't make you redo the radio +
# port selection. (The service file is only ever created by this installer.)
SM_KEEP=0
if [ -f "$SERVICE_FILE" ] && grep -q "^REAL_PORT = '" "$SM_DIR/SerialMux.py" 2>/dev/null; then
    cur_port=$(sed -n "s/^REAL_PORT = '\(.*\)'.*/\1/p" "$SM_DIR/SerialMux.py" | head -1)
    cur_count=$(grep -m1 '^VPORTS' "$SM_DIR/SerialMux.py" | grep -oE 'ttyV[0-9]+' | wc -l | tr -d ' ')
    info "SerialMux is already set up here — radio: $cur_port ($cur_count virtual port(s))."
    if ask_yn "Keep this SerialMux setup and just add or change programs?" y; then
        REAL_PORT="$cur_port"; VPORT_COUNT="$cur_count"; rebuild_vp_pylist; SM_KEEP=1
        ok "Keeping the existing SerialMux setup."
    fi
fi

if [ "$SM_KEEP" != 1 ]; then
    info "Scanning for USB serial devices..."
    mapfile -t BYID < <(ls -1 "$BYID_DIR" 2>/dev/null || true)
    DEV_PATHS=(); DEV_LABELS=()
    if [ "${#BYID[@]}" -gt 0 ]; then
        for name in "${BYID[@]}"; do
            target=$(readlink -f "$BYID_DIR/$name" 2>/dev/null || echo "?")
            DEV_PATHS+=("$BYID_DIR/$name"); DEV_LABELS+=("$name  (-> ${target##*/})")
        done
    else
        warn "Nothing under $BYID_DIR. Falling back to raw device names."
        for d in /dev/ttyACM* /dev/ttyUSB*; do [ -e "$d" ] && { DEV_PATHS+=("$d"); DEV_LABELS+=("$d"); }; done
    fi
    [ "${#DEV_PATHS[@]}" -gt 0 ] || die "No USB serial devices found. Plug in your radio (check the cable carries data) and re-run."

    menu "Which device is your MeshCore radio?" "${DEV_LABELS[@]}"
    REAL_PORT=${DEV_PATHS[$((REPLY_INDEX-1))]}
    ok "Selected: $REAL_PORT"

    menu "How many virtual ports do you need? (one per program that will use the radio)" \
         "1 — a single program" "2 — e.g. an observer + a bot" "3 — observer + bot + spare"
    VPORT_COUNT=$REPLY_INDEX; rebuild_vp_pylist
    ok "Will create: $(echo "$VP_PYLIST" | tr -d "'")"

    step "Writing SerialMux configuration"
    sed -i "s|^REAL_PORT = .*|REAL_PORT = '$REAL_PORT'|" "$SM_DIR/SerialMux.py"
    sed -i "s|^VPORTS = .*|VPORTS = [$VP_PYLIST]|" "$SM_DIR/SerialMux.py"
    ok "Set REAL_PORT and $VPORT_COUNT virtual port(s)."
fi

# ===========================================================================
step "Step 4 of 5 — Install SerialMux as a service and verify it"
# ===========================================================================
cat > "$SERVICE_FILE" <<EOF
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
sctl daemon-reload
sctl enable -q serialmux 2>/dev/null || true
SM_SIMULATED=0
if [ "$DRYRUN" = 1 ]; then
    if python3 -c "import serial" 2>/dev/null; then
        info "[dry-run] launching SerialMux against the fake radio..."
        nohup python3 "$SM_DIR/SerialMux.py" >"$DEMO_ROOT/serialmux.log" 2>&1 &
        SM_PID=$!
    else
        warn "[dry-run] pyserial isn't installed here, so SerialMux can't really run — simulating the virtual ports instead."
        for i in $(seq 0 $((VPORT_COUNT-1))); do ln -sf /dev/null "${VPORT_BASE}$i"; done
        SM_SIMULATED=1
    fi
else
    sctl restart serialmux
fi
info "Starting up and checking..."
sleep 3
RUNNING=0
if [ "$DRYRUN" = 1 ]; then
    if [ "$SM_SIMULATED" = 1 ]; then [ -e "${VPORT_BASE}0" ] && RUNNING=1
    else kill -0 "$SM_PID" 2>/dev/null && [ -e "${VPORT_BASE}0" ] && RUNNING=1; fi
else systemctl is-active --quiet serialmux && [ -e "${VPORT_BASE}0" ] && RUNNING=1; fi
if [ "$RUNNING" = 1 ]; then
    ok "SerialMux is running. Virtual ports: $(ls -1 ${VPORT_BASE}* 2>/dev/null | tr '\n' ' ')"
else
    [ "$DRYRUN" = 1 ] && { tail -n 15 "$DEMO_ROOT/serialmux.log" 2>/dev/null || true; }
    die "SerialMux did not start cleanly. Check the device path."
fi

# ===========================================================================
step "Step 5 of 5 — Connect your programs (observer / bot)"
# ===========================================================================
OBSERVER_KIND=none; OBSERVER_CFGDIR=""; OBSERVER_SVC=""; OBSERVER_VPORT=""; OBSERVER_OVERRIDE=""

configure_observer_serial() {  # SerialMux-owned override that wins on load (sorts after 99-user.toml)
    OBSERVER_OVERRIDE="$OBSERVER_CFGDIR/config.d/zz-serialmux.toml"
    mkdir -p "$OBSERVER_CFGDIR/config.d"
    {
        echo "# Managed by the SerialMux installer. Points the observer at a"
        echo "# SerialMux virtual port. Loaded last (deep-merged), so it wins"
        echo "# without touching your own config. Safe to delete if you stop SerialMux."
        echo
        if [ "$OBSERVER_KIND" = companion ]; then echo "[capture]"; echo 'connection_type = "serial"'; echo; fi
        echo "[serial]"
        echo "ports = [\"$OBSERVER_VPORT\"]"
    } > "$OBSERVER_OVERRIDE"
    ok "Pointed the observer at $OBSERVER_VPORT  ($OBSERVER_OVERRIDE)"
}

run_upstream() {  # run_upstream "label" "command..."   (mocked in dry-run)
    if [ "$DRYRUN" = 1 ]; then info "[dry-run] would run the official installer: $1"; else eval "$2" </dev/tty || warn "Upstream installer reported an issue — review its output above."; fi
}

# --- Observer ---
if [ -d "$MCTOMQTT_DIR" ] || [ -d "$PKTCAP_DIR" ]; then
    [ -d "$MCTOMQTT_DIR" ] && { OBSERVER_KIND=repeater;  OBSERVER_CFGDIR=$MCTOMQTT_DIR; OBSERVER_SVC=mctomqtt; }
    [ -d "$PKTCAP_DIR" ]   && { OBSERVER_KIND=companion; OBSERVER_CFGDIR=$PKTCAP_DIR;   OBSERVER_SVC=meshcore-packet-capture; }
    OBSERVER_OVERRIDE="$OBSERVER_CFGDIR/config.d/zz-serialmux.toml"
    cur_vp=""
    [ -f "$OBSERVER_OVERRIDE" ] && cur_vp=$(grep -oE "${VPORT_BASE}[0-9]+|/dev/ttyV[0-9]+" "$OBSERVER_OVERRIDE" 2>/dev/null | head -1)
    if [ -n "$cur_vp" ]; then
        # Already wired to SerialMux — keep that port reserved so a new bot
        # doesn't grab it, and leave the observer untouched.
        OBSERVER_VPORT="$cur_vp"; vport_in_use "$cur_vp" || USED_VPORTS+=("$cur_vp")
        info "Observer ($OBSERVER_KIND) is already using $cur_vp — leaving it as-is."
    else
        info "Detected an observer already installed ($OBSERVER_KIND), not yet using SerialMux."
        if ask_yn "Repoint it at a SerialMux virtual port?" y; then
            assign_vport; OBSERVER_VPORT=$REPLY_VPORT
            configure_observer_serial
            sctl restart "$OBSERVER_SVC" 2>/dev/null || warn "Restart $OBSERVER_SVC to apply."
        else OBSERVER_KIND=none; fi
    fi
else
    if ask_yn "Do you want to install a MeshCore observer now?" y; then
        menu "What role is this node?" \
             "Companion — installs agessaman/meshcore-packet-capture" \
             "Repeater  — installs Cisien/meshcoretomqtt"
        if [ "$REPLY_INDEX" = 1 ]; then
            OBSERVER_KIND=companion; OBSERVER_CFGDIR=$PKTCAP_DIR; OBSERVER_SVC=meshcore-packet-capture
            step "Installing the companion observer (meshcore-packet-capture)"
            run_upstream "meshcore-packet-capture" 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/agessaman/meshcore-packet-capture/main/install.sh)"'
        else
            OBSERVER_KIND=repeater; OBSERVER_CFGDIR=$MCTOMQTT_DIR; OBSERVER_SVC=mctomqtt
            step "Installing the repeater observer (meshcoretomqtt)"
            run_upstream "meshcoretomqtt" 'curl -fsSL https://raw.githubusercontent.com/Cisien/meshcoretomqtt/main/install.sh | bash'
        fi
        assign_vport; OBSERVER_VPORT=$REPLY_VPORT
        step "Wiring the observer to SerialMux"
        configure_observer_serial
        sctl restart "$OBSERVER_SVC" 2>/dev/null || true
    fi
fi

# --- Bot ---
BOT_VPORT=""; BOT_NAME=""; BOT_LAT=""; BOT_LON=""
apply_bot_config() {  # $1 = path to config.ini — sets serial port + the basics
    sed -i -E "s|^connection_type *=.*|connection_type = serial|; s|^serial_port *=.*|serial_port = $BOT_VPORT|" "$1"
    [ -n "$BOT_NAME" ] && sed -i -E "s|^bot_name *=.*|bot_name = $BOT_NAME|" "$1" || true
    [ -n "$BOT_LAT" ]  && sed -i -E "s|^bot_latitude *=.*|bot_latitude = $BOT_LAT|" "$1" || true
    [ -n "$BOT_LON" ]  && sed -i -E "s|^bot_longitude *=.*|bot_longitude = $BOT_LON|" "$1" || true
}
if ask_yn "Do you want to install the MeshCore bot (agessaman/meshcore-bot)?" n; then
    BOT_SRC="$SYSROOT/opt/meshcore-bot-src"
    assign_vport; BOT_VPORT=$REPLY_VPORT
    info "The bot starts from sensible defaults; set the essentials now, and tweak"
    info "anything else (channels, commands, etc.) later in config.ini."
    prompt BOT_NAME "Bot name (how it appears in the mesh)" "MeshCoreBot"
    prompt BOT_LAT  "Bot latitude (decimal degrees, blank to skip)" ""
    prompt BOT_LON  "Bot longitude (decimal degrees, blank to skip)" ""
    step "Installing the MeshCore bot"
    if [ "$DRYRUN" = 1 ]; then
        info "[dry-run] would clone agessaman/meshcore-bot and run ./install-service.sh"
        mkdir -p "$BOT_SRC"
        printf '[Connection]\nconnection_type = ble\nserial_port = /dev/ttyUSB0\n\n[Bot]\nbot_name = MeshCoreBot\nbot_latitude = 40.7128\nbot_longitude = -74.0060\n' > "$BOT_SRC/config.ini"
    else
        if [ -d "$BOT_SRC/.git" ]; then git -C "$BOT_SRC" pull --ff-only -q || true; else git clone -q https://github.com/agessaman/meshcore-bot "$BOT_SRC"; fi
        [ -f "$BOT_SRC/config.ini" ] || cp "$BOT_SRC/config.ini.quickstart" "$BOT_SRC/config.ini"
    fi
    apply_bot_config "$BOT_SRC/config.ini"
    ok "Bot configured: name='$BOT_NAME', port=$BOT_VPORT (full settings in $BOT_SRC/config.ini)"
    if [ "$DRYRUN" = 1 ]; then info "[dry-run] resulting config.ini:"; sed -n '1,8p' "$BOT_SRC/config.ini" | sed 's/^/        /'
    else ( cd "$BOT_SRC" && bash ./install-service.sh </dev/tty ) || warn "Bot service installer reported an issue."
         if [ -d /opt/meshcore-bot ] && [ "$(readlink -f /opt/meshcore-bot)" != "$(readlink -f "$BOT_SRC")" ]; then
             cp "$BOT_SRC/config.ini" /opt/meshcore-bot/config.ini 2>/dev/null || true
             apply_bot_config /opt/meshcore-bot/config.ini 2>/dev/null || true
         fi
         sctl restart meshcore-bot 2>/dev/null || true
    fi
fi

# --- Custom broker for the observer ---
if [ "$OBSERVER_KIND" != none ]; then
    if ask_yn "Do you want to add a custom MQTT broker for the observer?" n; then
        userf="${OBSERVER_OVERRIDE:-$OBSERVER_CFGDIR/config.d/zz-serialmux.toml}"
        menu "How would you like to add the broker?" \
             "Enter the details step by step (guided)" \
             "Paste a complete [[broker]] block (e.g. copied from another node)"
        if [ "$REPLY_INDEX" = 2 ]; then
            qsep
            info "Paste your [[broker]] block below. When finished, type a line with"
            info "just the word  END  and press Enter:"
            read_multiline
            printf '\n%s\n' "$REPLY_MULTI" >> "$userf"
            BK_DESC="pasted block"
        else
            prompt BK_NAME   "Broker name (a label)" "local"
            prompt BK_SERVER "Broker hostname or IP" ""
            prompt BK_PORT   "Broker port" "1883"
            menu "Transport?" "tcp (plain MQTT, usually port 1883)" "websockets (usually port 443)"
            [ "$REPLY_INDEX" = 1 ] && BK_TRANS=tcp || BK_TRANS=websockets
            if ask_yn "Use TLS/SSL?" "$([ "$BK_TRANS" = websockets ] && echo y || echo n)"; then BK_TLS=true; else BK_TLS=false; fi
            if ask_yn "Does the broker require a username/password?" n; then
                prompt BK_USER "Username" ""; prompt BK_PASS "Password" ""; BK_AUTH=password
            else BK_AUTH=none; fi
            {
                echo; echo "[[broker]]"
                echo "name = \"$BK_NAME\""; echo "enabled = true"; echo "server = \"$BK_SERVER\""
                echo "port = $BK_PORT"; echo "transport = \"$BK_TRANS\""
                echo "keepalive = 60"; echo "qos = 0"; echo "retain = true"
                echo; echo "[broker.tls]"; echo "enabled = $BK_TLS"; echo "verify = true"
                echo; echo "[broker.auth]"; echo "method = \"$BK_AUTH\""
                [ "$BK_AUTH" = password ] && { echo "username = \"$BK_USER\""; echo "password = \"$BK_PASS\""; }
            } >> "$userf"
            BK_DESC="$BK_NAME ($BK_SERVER:$BK_PORT)"
        fi
        if python3 -c "import tomllib" 2>/dev/null && ! python3 -c "import tomllib;tomllib.load(open('$userf','rb'))" 2>/dev/null; then
            warn "Broker added, but $userf may not be valid TOML — please double-check it."
        else
            ok "Added broker ($BK_DESC) to $userf"
        fi
        sctl restart "$OBSERVER_SVC" 2>/dev/null || true
    fi
fi

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%s===========================================================%s\n' "$B$G" "$N"
printf '%s  All done!%s\n' "$B$G" "$N"
printf '%s===========================================================%s\n\n' "$B$G" "$N"
info "Radio (real device):  $REAL_PORT"
info "Virtual ports:        $(ls -1 ${VPORT_BASE}* 2>/dev/null | tr '\n' ' ')"
[ -n "$OBSERVER_VPORT" ] && info "Observer ($OBSERVER_KIND):  uses $OBSERVER_VPORT   [service: $OBSERVER_SVC]"
[ -n "$BOT_VPORT" ]      && info "Bot:                  uses $BOT_VPORT   [service: meshcore-bot]"
echo
if [ "$DRYRUN" = 1 ]; then
    info "This was a DRY RUN. Generated config files (under $DEMO_ROOT):"
    find "$DEMO_ROOT" -name '*.toml' -o -name 'config.ini' -o -name 'serialmux.service' 2>/dev/null | sed 's/^/      /' || true
    echo
    [ -n "$OBSERVER_OVERRIDE" ] && [ -f "$OBSERVER_OVERRIDE" ] && { info "Observer override ($OBSERVER_OVERRIDE):"; sed 's/^/      /' "$OBSERVER_OVERRIDE"; echo; }
    if [ -e "${VPORT_BASE}0" ] && [ "$SM_SIMULATED" != 1 ]; then
        info "SerialMux is live in the sandbox right now. Open another terminal and run"
        info "one of these to watch the fake radio arrive on a virtual port (Ctrl+C to stop):"
        info "    cat ${VPORT_BASE}0                    # works everywhere, nothing to install"
        info "    screen ${VPORT_BASE}0 115200          # only if 'screen' is installed"
        printf '\n    Press Enter here to tear down the demo... '
        _read _
    fi
    info "Sandbox left at $DEMO_ROOT (delete it any time: rm -rf $DEMO_ROOT)"
else
    info "Everything starts automatically on boot. Re-run this script any time to change things."
    info "  Check: sudo systemctl status serialmux"
fi
