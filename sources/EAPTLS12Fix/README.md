# EAP TLS 1.2 Fix

Source for the `local.eaptls12fix` package in this repo (current: 1.6.0).

## What it does

**TLS 1.2 for EAP.** iOS 5 and 6 create their EAP (802.1X) TLS context with
`kTLSProtocol1Only` (iOS 7: `kTLSProtocol1`, min = max = TLS 1.0), so PEAP/TTLS
advertises TLS 1.0 even though the OS supports TLS 1.2. RADIUS servers that
require TLS 1.2 (for example ANU-Secure/eduroam) reject the handshake before any
certificate or credential exchange. `EAPTLS12FixV10.dylib` is injected into
`eapolclient` only. It hooks `EAPSSLContextCreate` and raises the *maximum*
protocol of client contexts to TLS 1.2 (the minimum stays TLS 1.0 so re-auth and
resumption can fall back). Certificate validation, pinned anchors, server-name
checks and credentials are untouched.

**Wi-Fi recovery.** `com.jwi.wifiwatchdog` (launchd, KeepAlive) runs
`/usr/bin/wifi-watchdog.sh`, which reads en0's state from SystemConfiguration:

| State | Action |
|---|---|
| Wi-Fi off, or associated with traffic flowing | nothing |
| Associated, no address or self-assigned `169.254.x` (DHCP failed) | renew DHCP, then restart `wifid` |
| Associated with an address, no traffic | restart `wifid` (`launchctl stop`, clean EAP teardown) |
| Powered on but unassociated for 10 min | restart `wifid` to nudge auto-join, at most every 30 min |

Actions need three failed checks in a row and wifid restarts are at least 5 min
apart. A host that refuses a connection counts as reachable; timeouts and
"no route"/"unreachable" errors do not. Log: `/var/mobile/Media/wifi-watchdog.log`
(rotated at 256 KB). `/usr/libexec/wifi-watchdog-reap` stops copies launchd does
not own (iOS 5 has no `ps`/`pkill`); the package scripts run it on install/removal.

## Build

```sh
XCODE_13_4_1_DEVELOPER_DIR=/path/to/Xcode-13.4.1.app/Contents/Developer ./build.sh
```

Needs Xcode 13.4.1 (the last linker that produces armv7), `ldid`, and a directory
with `crt1.3.1.o` (`LEGACY_CRT_DIR`; defaults to the Legacy Swift Development Kit
toolchain). Without `crt1.3.1.o` the linker silently retargets executables to iOS 7,
whose `LC_MAIN` entry point iOS 5 cannot start; `build.sh` refuses that. Output:
`../../debs/eaptls12fix_<version>_iphoneos-arm.deb` (deterministic), then run
`tools/reindex.py` at the repo root.

## Test

`tests/test-watchdog.sh package/usr/bin/wifi-watchdog.sh` runs eight dry-run
scenarios (stubbed `scutil`/`ipconfig`/`timeout`; nothing is restarted) and
should be run on the device (bash 4, no `awk`).

## Tested

- iPod3,1 iOS 5.1.1 (9B206): 1.6.0 upgrade from 1.5.0 reaped two leftover
  watchdogs and left one launchd-owned copy; scenario tests 8/8 on the device;
  the hook logs `installed EAP TLS 1.2 ceiling hook` in `eapolclient`.
  Earlier versions authenticated to ANU-Secure (PEAP, TLS 1.2).
- iPod4,1 iOS 6.1.6 (10B500): earlier versions install and the hook loads.

## Removal

```sh
dpkg -r local.eaptls12fix
```

Reconnect Wi-Fi afterwards.
