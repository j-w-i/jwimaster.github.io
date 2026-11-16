#!/bin/bash
# Wi-Fi auto-recovery for legacy iOS (rootful and rootless). Run only by launchd
# (com.jwi.wifiwatchdog, KeepAlive), which guarantees a single instance.
#
# States, from the live SystemConfiguration store (scutil):
#   Wi-Fi off, or associated with traffic flowing  -> nothing
#   associated, no address or 169.254.x (DHCP)     -> renew DHCP, then restart wifid
#   associated with an address, no traffic         -> restart wifid
#   powered on, unassociated for a long time       -> occasional wifid restart (auto-join nudge)
# Diagnostics: every change of association/network/access point/address is logged with signal
# strength, and on a drop or failed check the surrounding Wi-Fi/EAP/DHCP system log is saved to
# /var/mobile/Media/wifi-diag/ (newest 30 kept), so the reason survives system-log rotation.
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
HEARTBEAT=600           # while associated, log signal strength this often (trend before a drop)
DIAG_DIR=/var/mobile/Media/wifi-diag
DIAG_KEEP=30            # snapshots kept
DIAG_WINDOW=600         # seconds of system log before the event to save
DIAG_MIN_GAP=60         # at most one snapshot per minute
DIAG=/usr/libexec/wifi-watchdog-diag
[ -x /var/jb/usr/libexec/wifi-watchdog-diag ] && DIAG=/var/jb/usr/libexec/wifi-watchdog-diag
if [ "$DRYRUN" = 1 ]; then
    # Test runs: separate log/PID file (never disturb the launchd instance), optional short timers.
    LOG=/var/mobile/Media/wifi-watchdog-dryrun.log
    PIDFILE=/tmp/wifi-watchdog-dryrun.pid
    DIAG_DIR=${WATCHDOG_DIAG_DIR:-/tmp/wifi-diag-dryrun}
    DIAG_MIN_GAP=0
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
#   POWER : <array> {      STATE : 4      SSID_STR : ANU-Secure     BSSID : <data> 0x20a6cd43da61
#     0 : 1                RSSI : <dictionary> {  RSSI_CTL_AGR : -53   CHANNEL : <dictionary> {  CHANNEL : 6
read_state() {
    local key sep value in_power=0
    POWER=""; ASSOC=""; SSID=""; BSSID=""; RSSI=""; CHANNEL=""
    while read -r key sep value; do
        if [ $in_power = 1 ]; then POWER=$value; in_power=0; continue; fi
        case "$key" in
            POWER) in_power=1 ;;
            STATE) ASSOC=$value ;;
            SSID_STR) SSID=$value ;;
            BSSID) BSSID=${value##* } ;;
            RSSI_CTL_AGR) RSSI=$value ;;
            CHANNEL) case "$value" in [0-9]*) CHANNEL=$value ;; esac ;;
        esac
    done < <(printf 'show State:/Network/Interface/en0/AirPort\nquit\n' | scutil 2>/dev/null)
    [ "$ASSOC" = 4 ] || { SSID=""; BSSID=""; RSSI=""; CHANNEL=""; }
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
    snapshot "before wifid restart: $1"
    # A clean stop lets wifid tear down the EAP session; launchd restarts it at once.
    act "restart wifid ($1)" launchctl stop com.apple.wifid
    last_restart=$(date +%s)
}

describe() { # current state as one line
    if [ "$POWER" != 1 ]; then echo "wifi off"; return; fi
    if [ "$ASSOC" != 4 ]; then echo "powered, not associated (state ${ASSOC:-?})"; return; fi
    echo "associated ssid=${SSID:-?} bssid=${BSSID:-?} ch=${CHANNEL:-?} rssi=${RSSI:-?} ip=${IP:-none} gw=${GW:-none}"
}

# Save the Wi-Fi/EAP/DHCP system log around an event: the reason a link dropped lives there
# (driver disassociation, EAP failure, DHCP) but the system log rotates it away.
snapshot() { # reason
    local t file slug
    t=$(date +%s)
    [ $((t - last_snapshot)) -lt $DIAG_MIN_GAP ] && return
    last_snapshot=$t
    mkdir -p "$DIAG_DIR" 2>/dev/null || return
    slug=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-' | cut -c1-40)
    file="$DIAG_DIR/$(date '+%Y%m%d-%H%M%S')-$slug.log"
    {
        echo "event: $1"
        echo "time:  $(date '+%Y-%m-%d %H:%M:%S')"
        echo "state: $(describe)"
        echo "previous: $last_state"
        echo
        echo "== system log (Wi-Fi, EAP, DHCP), last $DIAG_WINDOW s"
        if [ -x "$DIAG" ]; then "$DIAG" $((t - DIAG_WINDOW)) 2>&1; else echo "(wifi-watchdog-diag missing)"; fi
        echo
        echo "== watchdog log tail"
        tail -20 "$LOG" 2>/dev/null
    } > "$file" 2>&1
    log "diagnostics saved: $file"
    # Keep the newest $DIAG_KEEP snapshots.
    ls -t "$DIAG_DIR"/*.log 2>/dev/null | tail -n +$((DIAG_KEEP + 1)) | while read -r old; do rm -f "$old"; done
}

log "watchdog started (pid $$, dryrun=$DRYRUN)"
fails=0
renewed=0
last_restart=0
last_nudge=0
last_snapshot=0
last_heartbeat=0
unassociated_since=0
last_state=""; last_state_key=""; last_ip=""
was_assoc=0

while :; do
    read_state
    now=$(date +%s)

    # Timeline: log every change of power/association/network/access point/address (signal strength
    # is logged with it but is not itself a change), plus a periodic signal heartbeat.
    state_key="$POWER|$ASSOC|$SSID|$BSSID|$IP|$GW"
    if [ "$state_key" != "$last_state_key" ]; then
        current=$(describe)
        log "state: $current"
        if [ $was_assoc = 1 ] && [ "$POWER" = 1 ] && [ "$ASSOC" != 4 ]; then
            snapshot "disassociated"
        elif [ $was_assoc = 1 ] && [ "$ASSOC" = 4 ] && [ -n "$last_ip" ] && [ "${last_ip#169.254.}" = "$last_ip" ] \
             && { [ -z "$IP" ] || [ "${IP#169.254.}" != "$IP" ]; }; then
            snapshot "lost address (was $last_ip)"
        fi
        last_state_key=$state_key; last_state=$current; last_heartbeat=$now
    elif [ "$ASSOC" = 4 ] && [ $((now - last_heartbeat)) -ge $HEARTBEAT ]; then
        log "ok: $(describe)"; last_heartbeat=$now
    fi
    [ "$POWER" = 1 ] && [ "$ASSOC" = 4 ] && was_assoc=1 || was_assoc=0
    last_ip=$IP

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
    [ $fails -eq 1 ] && snapshot "check failed: $problem"
    if [ $fails -lt $FAILS_NEEDED ]; then
        sleep $CHECK_EVERY; continue
    fi
    fails=0

    # Address problems: renew DHCP once before touching wifid.
    if [ $renewed -eq 0 ] && { [ -z "$IP" ] || [ "${IP#169.254.}" != "$IP" ]; }; then
        renewed=1
        snapshot "before DHCP renew: $problem"
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
