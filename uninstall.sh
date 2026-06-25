#!/usr/bin/env bash
#
# SerialMux uninstaller
# ---------------------
# Removes SerialMux and, if you want, the MeshCore observer / bot it set up.
#
#   curl -fsSL https://raw.githubusercontent.com/jjkroell/SerialMux/main/uninstall.sh | sudo bash
#
# Preview what it would do without changing anything:
#   bash uninstall.sh --dry-run
#
set -euo pipefail

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'; else B=; G=; Y=; R=; C=; N=; fi
step() { printf '\n%s==> %s%s\n' "$B$C" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓ %s%s\n' "$G" "$*" "$N"; }
warn() { printf '    %s! %s%s\n' "$Y" "$*" "$N"; }
die()  { printf '\n%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
_read() { if { read -r "$1" </dev/tty; } 2>/dev/null; then return 0; fi; read -r "$1" 2>/dev/null || true; }
ask_yn() {
    local q=$1 def=${2:-n} a hint; [ "$def" = y ] && hint="Y/n" || hint="y/N"
    printf '\n'
    while true; do printf '    %s [%s]: ' "$q" "$hint"; _read a; a=${a:-$def}; case "$a" in [Yy]*) return 0;; [Nn]*) return 1;; esac; done
}

DRYRUN=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRYRUN=1; done
run() { if [ "$DRYRUN" = 1 ]; then info "[dry-run] would run: $*"; else "$@"; fi; }

[ "$DRYRUN" = 1 ] || [ "$(id -u)" -eq 0 ] || die "Run with sudo:  curl -fsSL .../uninstall.sh | sudo bash"

MCTOMQTT_DIR=/etc/mctomqtt
PKTCAP_DIR=/etc/meshcore-packet-capture

printf '%s\n' "$B$C"
cat <<'BANNER'
  SerialMux — uninstaller
BANNER
printf '%s\n' "$N"
[ "$DRYRUN" = 1 ] && warn "DRY RUN — showing what would happen, changing nothing."

if [ "$DRYRUN" = 0 ] && ! ask_yn "Remove SerialMux from this machine?" y; then
    info "Nothing changed."; exit 0
fi

# 1. SerialMux service + files + virtual ports
step "Removing SerialMux"
if systemctl list-unit-files 2>/dev/null | grep -q '^serialmux\.service'; then
    run systemctl disable --now serialmux
fi
run rm -f /etc/systemd/system/serialmux.service
run systemctl daemon-reload
run rm -rf /opt/serialmux
for v in /dev/ttyV*; do [ -L "$v" ] && run rm -f "$v"; done 2>/dev/null || true
ok "SerialMux service, files, and virtual ports removed."

# 2. Revert observer overrides so the observer uses its own config again
step "Reverting observer config (removing the SerialMux override)"
reverted=0
for d in "$MCTOMQTT_DIR" "$PKTCAP_DIR"; do
    f="$d/config.d/zz-serialmux.toml"
    if [ -f "$f" ]; then
        svc=mctomqtt; [ "$d" = "$PKTCAP_DIR" ] && svc=meshcore-packet-capture
        run rm -f "$f"
        run systemctl restart "$svc"
        ok "Removed the SerialMux override from $d (restarted $svc)."
        reverted=1
    fi
done
[ "$reverted" = 0 ] && info "No SerialMux observer overrides found."
[ "$reverted" = 1 ] && warn "Your observer now uses its OWN configured serial port again — open its config and set it back to the real radio (e.g. /dev/serial/by-id/...) if needed."

# 3. Optionally remove the observer entirely (via its own uninstaller)
if [ -d "$PKTCAP_DIR" ] || [ -d "$MCTOMQTT_DIR" ]; then
    if ask_yn "Also completely uninstall the MeshCore observer?" n; then
        if [ -d "$PKTCAP_DIR" ]; then
            step "Uninstalling meshcore-packet-capture (companion)"
            if [ "$DRYRUN" = 1 ]; then info "[dry-run] would run the official uninstaller: agessaman/meshcore-packet-capture"
            else bash <(curl -fsSL https://raw.githubusercontent.com/agessaman/meshcore-packet-capture/main/uninstall.sh) </dev/tty || warn "Observer uninstaller reported an issue."; fi
        fi
        if [ -d "$MCTOMQTT_DIR" ]; then
            step "Uninstalling meshcoretomqtt (repeater)"
            if [ "$DRYRUN" = 1 ]; then info "[dry-run] would run the official uninstaller: Cisien/meshcoretomqtt"
            else curl -fsSL https://raw.githubusercontent.com/Cisien/meshcoretomqtt/main/uninstall.sh | bash </dev/tty || warn "Observer uninstaller reported an issue."; fi
        fi
    fi
fi

# 4. Optionally remove the bot
if systemctl list-unit-files 2>/dev/null | grep -q '^meshcore-bot\.service' || [ -d /opt/meshcore-bot ]; then
    if ask_yn "Also uninstall the MeshCore bot?" n; then
        step "Removing the MeshCore bot"
        run systemctl disable --now meshcore-bot
        run rm -f /etc/systemd/system/meshcore-bot.service
        run systemctl daemon-reload
        run rm -rf /opt/meshcore-bot /opt/meshcore-bot-src
        ok "Bot service and files removed."
    fi
fi

printf '\n%s===========================================================%s\n' "$B$G" "$N"
printf '%s  Uninstall complete.%s\n' "$B$G" "$N"
printf '%s===========================================================%s\n' "$B$G" "$N"
[ "$DRYRUN" = 1 ] && info "(That was a dry run — nothing was actually changed.)"
