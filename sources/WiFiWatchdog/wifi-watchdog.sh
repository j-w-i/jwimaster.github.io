#!/bin/bash
# Wi-Fi auto-recovery for legacy iOS devices.
# Legacy EAP/Wi-Fi stacks can keep a "connected" association after the AP
# session has died: en0 still has an IP, but nothing passes. This watchdog
# probes reachability and restarts wifid (forcing a fresh scan/associate/
# EAP/DHCP cycle) only after several consecutive failures.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOG=/var/mobile/Media/wifi-watchdog.log
PIDFILE=/var/run/wifi-watchdog.pid
DRYRUN=${WIFI_WATCHDOG_DRYRUN:-0}
FAILS_NEEDED=3
COOLDOWN=300
SLEEP_OK=20
SLEEP_AFTER=40

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

if [ -f "$PIDFILE" ]; then
    old=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT INT TERM

# 0 = reachable (connected or actively refused), 1 = timeout/unreachable
probe() {
    timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1
    [ $? -eq 124 ] && return 1
    return 0
}

fail=0
last=0
log "watchdog started (dryrun=$DRYRUN)"
while :; do
    ip=$(ipconfig getifaddr en0 2>/dev/null)
    if [ -z "$ip" ]; then
        fail=0
        sleep 20
        continue
    fi
    gw=$(ipconfig getoption en0 router 2>/dev/null)
    ok=0
    if [ -n "$gw" ]; then probe "$gw" 80 && ok=1; fi
    if [ $ok -eq 0 ]; then
        if [ -n "$gw" ]; then probe "$gw" 443 && ok=1; fi
    fi
    if [ $ok -eq 0 ]; then probe 1.1.1.1 443 && ok=1; fi
    if [ $ok -eq 0 ]; then probe 10.250.0.10 53 && ok=1; fi

    if [ $ok -eq 1 ]; then
        fail=0
        sleep $SLEEP_OK
        continue
    fi

    fail=$((fail + 1))
    log "probe failed ($fail/$FAILS_NEEDED) ip=$ip gw=$gw"
    if [ $fail -ge $FAILS_NEEDED ]; then
        now=$(date +%s)
        if [ $((now - last)) -ge $COOLDOWN ]; then
            if [ "$DRYRUN" = "1" ]; then
                log "would restart wifid (dry run)"
            else
                log "restarting wifid to recover link"
                killall -9 wifid 2>/dev/null
            fi
            last=$now
            fail=0
            sleep $SLEEP_AFTER
            continue
        fi
        log "cooldown active; not restarting yet"
        fail=0
    fi
    sleep $SLEEP_OK
done
