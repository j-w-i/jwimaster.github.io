# EAP TLS 1.2 Fix

Source for the `local.eaptls12fix` package in this repo.

## What it does

iOS 5 and 6 create their EAP (802.1X) TLS context with `kTLSProtocol1Only`, so
PEAP/TTLS authentication advertises TLS 1.0 even though the OS itself supports
TLS 1.2. RADIUS servers that require TLS 1.2 (for example ANU-Secure/eduroam)
then reject the handshake before any certificate or credential exchange.

The tweak is injected into `eapolclient` only. It hooks `EAPSSLContextCreate`
and, for client contexts created as TLS 1.0-only, raises the context's minimum
and maximum protocol to TLS 1.2 using the public `SSLSetProtocolVersionMin/Max`
APIs. Certificate validation, pinned anchors, server-name checks and
credentials are untouched.

## Build

Requires an ARMv7-capable Darwin linker (`ld64.lld` does not support ARMv7):

```sh
clang -target armv7-apple-ios5.1.1 -mthumb -fno-stack-protector \
  -fno-exceptions -Os -c EAPTLS12Fix.c -o EAPTLS12Fix.o
arm-apple-darwin11-ld -arch armv7 -dylib -undefined dynamic_lookup \
  -ios_version_min 5.1 \
  -install_name /Library/MobileSubstrate/DynamicLibraries/EAPTLS12Fix.dylib \
  -o EAPTLS12FixV3.dylib EAPTLS12Fix.o
```

Sign on a jailbroken device with `ldid -S EAPTLS12FixV3.dylib`, then package
it with the Substrate filter so both files land in
`/Library/MobileSubstrate/DynamicLibraries/`:

```sh
dpkg-deb -b root local.eaptls12fix_1.0.1_iphoneos-arm.deb
```

`EAPTLS12FixV3.plist` restricts loading to the `eapolclient` executable.

## Tested

- iPod3,1 — iOS 5.1.1 (9B206): ANU-Secure PEAP authenticated; TLS 1.2 negotiated.
- iPod4,1 — iOS 6.1.6 (10B500): package installs and the hook loads.

## Removal

```sh
dpkg -r local.eaptls12fix
```

Reconnect Wi-Fi afterwards.
