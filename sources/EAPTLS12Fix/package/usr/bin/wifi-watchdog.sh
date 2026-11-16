#!/bin/bash
# Wi-Fi auto-recovery for legacy iOS (rootful and rootless). Run only by launchd
# (com.jwi.wifiwatchdog, KeepAlive), which guarantees a single instance.
#
# States, from the live SystemConfiguration store (scutil):
#   Wi-Fi off, or associated with traffic flowing  -> nothing
#   associated, no address or 169.254.x (DHCP)     -> renew DHCP, then restart wifid
#   associated with an address, no traffic         -> restart wifid
#   powered on, unassociated for a long time       -> occasional wifid restart (auto-join nudge)
# WATCHDOG_DRYRUN=1 logs actions without performing them.
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
LOG=/var/mobile/Media/wifi-watchdog.log
PIDFILE=/var/run/wifi-watchdog.pid
[ -d /var/jb ] && PIDFILE=/var/jb/var/run/wifi-watchdog.pid
DRYRUN="${WATCHDOG_DRYRUN:-0}"

CHECK_EVERY=20          # seconds between checks while healthy
FAILS_NEEDED=3          # consecutive failed checks before acting
RESTART_COOLDOWN=300    # minimum seconds between wifid restarts
SETTLE_AFTER=60         # seconds to wait after an action
UNASSOCIATED_NUDGE=600  # seconds powered-on but unassociated before an auto-join nudge
NUDGE_COOLDOWN=1800     # minimum seconds between auto-join nudges
if [ "$DRYRUN" = 1 ]; then
    # Test runs: separate log/PID file (never disturb the launchd instance), optional short timers.
    LOG=/var/mobile/Media/wifi-watchdog-dryrun.log
    PIDFILE=/tmp/wifi-watchdog-dryrun.pid
    CHECK_EVERY=${WATCHDOG_CHECK_EVERY:-$CHECK_EVERY}
    SETTLE_AFTER=${WATCHDOG_SETTLE_AFTER:-$SETTLE_AFTER}
    UNASSOCIATED_NUDGE=${WATCHDOG_UNASSOCIATED_NUDGE:-$UNASSOCIATED_NUDGE}
    RESTART_COOLDOWN=${WATCHDOG_RESTART_COOLDOWN:-$RESTART_COOLDOWN}
    # Test hook: stub scutil/ipconfig/timeout ahead of the system tools.
    [ -n "${WATCHDOG_STUB_DIR:-}" ] && PATH="$WATCHDOG_STUB_DIR:$PATH"
fi

log() {
    # Keep the log bounded: rotate once it passes 256 KB.
    if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || stat -f %z "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
        mv -f "$LOG" "$LOG.1" 2>/dev/null
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
}

# launchd stops the job with SIGTERM: exit (1.5.0 trapped TERM without exiting, so
# every reinstall left the old watchdog running beside the new one).
cleanup() { [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"; }
trap 'cleanup; exit 0' INT TERM HUP
trap cleanup EXIT
mkdir -p "$(dirname "$PIDFILE")" 2>/dev/null
echo $$ > "$PIDFILE"

for tool in timeout ipconfig scutil launchctl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log "watchdog idle: missing $tool"
        # Stay alive (sleeping) so launchd does not respawn us every 30 s.
        while :; do sleep 3600; done
    fi
done

# One scutil round trip for the AirPort state of en0. Pure bash: iOS 5 has no awk.
#   POWER : <array> {        STATE : 4
#     0 : 1
read_state() {
    local key sep value in_power=0
    POWER=""; ASSOC=""
    while read -r key sep value; do
        if [ $in_power = 1 ]; then POWER=$value; in_power=0; continue; fi
        case "$key" in
            POWER) in_power=1 ;;
            STATE) ASSOC=$value ;;
        esac
    done < <(printf 'show State:/Network/Interface/en0/AirPort\nquit\n' | scutil 2>/dev/null)
    IP=$(ipconfig getifaddr en0 2>/dev/null)
    GW=$(ipconfig getoption en0 router 2>/dev/null)
}

# 0 = reachable: connected, or actively refused (the host answered).
# Timeouts and immediate "unreachable"/"no route" errors are failures; 1.5.0 counted
# every non-timeout error as reachable, so a dead 169.254.x link always looked healthy.
probe() {
    local err rc
    err=$(timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1)
    rc=$?
    [ $rc -eq 0 ] && return 0
    case "$err" in *[Rr]efused*) return 0 ;; esac
    return 1
}

traffic_ok() {
    if [ -n "$GW" ]; then
        probe "$GW" 80 && return 0
        probe "$GW" 443 && return 0
    fi
    probe 1.1.1.1 443 && return 0
    probe 8.8.8.8 53 && return 0
    return 1
}

act() { # description command...
    local what=$1; shift
    if [ "$DRYRUN" = 1 ]; then log "DRYRUN would $what"; return 0; fi
    log "$what"
    "$@" >/dev/null 2>&1
}

restart_wifid() {
    # A clean stop lets wifid tear down the EAP session; launchd restarts it at once.
    act "restart wifid ($1)" launchctl stop com.apple.wifid
    last_restart=$(date +%s)
}

log "watchdog started (pid $$, dryrun=$DRYRUN)"
fails=0
renewed=0
last_restart=0
last_nudge=0
unassociated_since=0

while :; do
    read_state
    now=$(date +%s)

    if [ "$POWER" != 1 ]; then
        fails=0; renewed=0; unassociated_since=0
        sleep $CHECK_EVERY; continue
    fi

    if [ "$ASSOC" != 4 ]; then
        # Powered on but not associated: no network in range, or auto-join gave up.
        fails=0; renewed=0
        [ $unassociated_since -eq 0 ] && unassociated_since=$now
        if [ $((now - unassociated_since)) -ge $UNASSOCIATED_NUDGE ] && [ $((now - last_nudge)) -ge $NUDGE_COOLDOWN ]; then
            last_nudge=$now
            restart_wifid "unassociated for $((now - unassociated_since)) s; auto-join nudge"
            sleep $SETTLE_AFTER; continue
        fi
        sleep $CHECK_EVERY; continue
    fi
    unassociated_since=0

    problem=""
    case "$IP" in
        "")         problem="associated but no IPv4 address" ;;
        169.254.*)  problem="self-assigned $IP (DHCP failed)" ;;
        *)          traffic_ok || problem="no traffic ip=$IP gw=${GW:-none}" ;;
    esac

    if [ -z "$problem" ]; then
        [ $fails -gt 0 ] && log "recovered (ip=$IP)"
        fails=0; renewed=0
        sleep $CHECK_EVERY; continue
    fi

    fails=$((fails + 1))
    log "check failed ($fails/$FAILS_NEEDED): $problem"
    if [ $fails -lt $FAILS_NEEDED ]; then
        sleep $CHECK_EVERY; continue
    fi
    fails=0

    # Address problems: renew DHCP once before touching wifid.
    if [ $renewed -eq 0 ] && { [ -z "$IP" ] || [ "${IP#169.254.}" != "$IP" ]; }; then
        renewed=1
        act "renew DHCP on en0" ipconfig set en0 DHCP
        sleep $SETTLE_AFTER; continue
    fi

    if [ $((now - last_restart)) -ge $RESTART_COOLDOWN ]; then
        renewed=0
        restart_wifid "$problem"
        sleep $SETTLE_AFTER; continue
    fi
    log "wifid restart cooldown active ($((RESTART_COOLDOWN - (now - last_restart))) s left)"
    sleep $CHECK_EVERY
done
