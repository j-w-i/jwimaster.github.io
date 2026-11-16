#!/bin/bash
# Scenario tests for wifi-watchdog.sh with stubbed scutil/ipconfig/timeout (dry run: nothing is
# restarted). Runs on the device (bash 4) or a Mac:  bash tests/test-watchdog.sh path/to/wifi-watchdog.sh
set -u
SCRIPT=${1:?usage: test-watchdog.sh wifi-watchdog.sh}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
LOG=/var/mobile/Media/wifi-watchdog-dryrun.log
fail=0
scenario() { # name power assoc ip gw probe(ok|refused|noroute|timeout) seconds expect-regex [forbid-regex]
    local name=$1 power=$2 assoc=$3 ip=$4 gw=$5 probe=$6 secs=$7 expect=$8 forbid=${9:-}
    mkdir -p "$W/$name"; local S="$W/$name"
    printf '#!/bin/bash\ncat >/dev/null\nprintf "<dictionary> {\\n  POWER : <array> {\\n    0 : %s\\n  }\\n  POWERSAVE : 1\\n  STATE : %s\\n}\\n"\n' "$power" "$assoc" > "$S/scutil"
    printf '#!/bin/bash\ncase "$1 $3" in "getifaddr ") echo "%s";; "getoption router") echo "%s";; esac\nexit 0\n' "$ip" "$gw" > "$S/ipconfig"
    case $probe in
        ok)      printf '#!/bin/bash\nexit 0\n' ;;
        refused) printf '#!/bin/bash\necho "bash: connect: Connection refused" >&2; exit 1\n' ;;
        noroute) printf '#!/bin/bash\necho "bash: connect: No route to host" >&2; exit 1\n' ;;
        timeout) printf '#!/bin/bash\nexit 124\n' ;;
    esac > "$S/timeout"
    chmod +x "$S"/*
    rm -f "$LOG"
    WATCHDOG_DRYRUN=1 WATCHDOG_STUB_DIR="$S" WATCHDOG_CHECK_EVERY=1 WATCHDOG_SETTLE_AFTER=1 \
      WATCHDOG_UNASSOCIATED_NUDGE=3 WATCHDOG_RESTART_COOLDOWN=0 bash "$SCRIPT" & local pid=$!
    sleep "$secs"; kill $pid 2>/dev/null; wait $pid 2>/dev/null
    if grep -qE "$expect" "$LOG" && { [ -z "$forbid" ] || ! grep -qE "$forbid" "$LOG"; }; then
        echo "PASS $name"
    else
        echo "FAIL $name"; sed 's/^/    /' "$LOG"; fail=1
    fi
}
scenario wifi-off          0 0 ""            ""        ok      4 "watchdog started"   "would|check failed"
scenario healthy           1 4 10.20.1.25    10.20.0.1 ok      4 "watchdog started"   "would|check failed"
scenario refused-is-alive  1 4 10.20.1.25    10.20.0.1 refused 4 "watchdog started"   "would|check failed"
scenario dhcp-failed       1 4 169.254.53.58 ""        noroute 9 "would renew DHCP.*" 
scenario dhcp-then-restart 1 4 169.254.53.58 ""        noroute 14 "would restart wifid \(self-assigned"
scenario no-address        1 4 ""            ""        ok      9 "would renew DHCP"
scenario dead-link         1 4 10.20.1.25    10.20.0.1 timeout 30 "would restart wifid \(no traffic" "renew DHCP"
scenario unassociated      1 0 ""            ""        ok      6 "would restart wifid \(unassociated"
exit $fail
