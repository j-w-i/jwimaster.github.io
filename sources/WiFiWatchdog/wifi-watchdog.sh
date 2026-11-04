#!/bin/bash
# Wi-Fi auto-recovery for legacy iOS (rootful and rootless).
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:$PATH"
LOG=/var/mobile/Media/wifi-watchdog.log
[ -d /var/jb ] && LOG=/var/mobile/Media/wifi-watchdog.log
PIDFILE=/var/run/wifi-watchdog.pid
[ -d /var/jb ] && PIDFILE=/tmp/wifi-watchdog.pid
TIMEOUT=$(command -v timeout)
KILLALL=$(command -v killall)
IPCONFIG=$(command -v ipconfig)
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

if [ -z "$TIMEOUT" ] || [ -z "$KILLALL" ] || [ -z "$IPCONFIG" ]; then
    log "watchdog disabled: missing timeout/killall/ipconfig"
    exit 0
fi

# 0 = reachable (connected or actively refused), 1 = timeout/unreachable
probe() {
    "$TIMEOUT" 6 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1
    [ $? -eq 124 ] && return 1
    return 0
}

fail=0
last=0
log "watchdog started"
while :; do
    ip=$("$IPCONFIG" getifaddr en0 2>/dev/null)
    if [ -z "$ip" ]; then
        fail=0
        sleep 20
        continue
    fi
    gw=$("$IPCONFIG" getoption en0 router 2>/dev/null)
    ok=0
    if [ -n "$gw" ]; then probe "$gw" 80 && ok=1; fi
    if [ $ok -eq 0 ] && [ -n "$gw" ]; then probe "$gw" 443 && ok=1; fi
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
            log "restarting wifid to recover link"
            "$KILLALL" -9 wifid 2>/dev/null
            last=$now
            fail=0
            sleep $SLEEP_AFTER
            continue
        fi
        log "cooldown active"
        fail=0
    fi
    sleep $SLEEP_OK
done
