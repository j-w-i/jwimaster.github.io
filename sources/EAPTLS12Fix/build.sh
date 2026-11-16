#!/bin/bash
# Build debs/eaptls12fix_<version>_iphoneos-arm.deb from this directory.
#   XCODE_13_4_1_DEVELOPER_DIR=/path/to/Xcode-13.4.1.app/Contents/Developer ./build.sh
# Xcode 13.4.1 is the last Xcode whose linker still produces armv7 (iOS 5/6) images.
# Needs ldid on PATH for the ad-hoc signatures jailbroken iOS expects, and crt1.3.1.o (the iOS < 6
# startup object; without it the linker silently retargets executables to iOS 7, whose LC_MAIN entry
# point iOS 5 cannot start). LEGACY_CRT_DIR defaults to the Legacy Swift Development Kit toolchain.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
XC="${XCODE_13_4_1_DEVELOPER_DIR:?set XCODE_13_4_1_DEVELOPER_DIR to Xcode 13.4.1.app/Contents/Developer}"
SDK="$XC/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk"
CC="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
LIPO="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/lipo"
export DEVELOPER_DIR="$XC"
command -v ldid >/dev/null || { echo "ldid is required" >&2; exit 1; }
if [ -z "${LEGACY_CRT_DIR:-}" ]; then
  for d in "$HOME/Library/Application Support/Legacy Swift Development Kit/Environments"/*/Toolchains/5.10.1-ios5.xctoolchain/usr/lib/swift_ios5/iphoneos; do
    [ -f "$d/crt1.3.1.o" ] && { LEGACY_CRT_DIR="$d"; break; }
  done
fi
[ -f "${LEGACY_CRT_DIR:-}/crt1.3.1.o" ] || { echo "set LEGACY_CRT_DIR to a directory containing crt1.3.1.o" >&2; exit 1; }
VERSION="$(sed -n 's/^Version: //p' "$HERE/package/DEBIAN/control")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/root"; cp -R "$HERE/package" "$STAGE"
mkdir -p "$STAGE/Library/MobileSubstrate/DynamicLibraries" "$STAGE/usr/libexec"

# Tweak: armv7 (Thumb, iOS 5.1) + arm64 (iOS 7).
DYLIB=EAPTLS12FixV10.dylib
"$CC" -target armv7-apple-ios5.1 -isysroot "$SDK" -mthumb -fno-stack-protector -Os -dynamiclib \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$DYLIB" "$HERE/EAPTLS12Fix.c" -o "$WORK/tweak-armv7"
"$CC" -target arm64-apple-ios7.0 -isysroot "$SDK" -Os -dynamiclib \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$DYLIB" "$HERE/EAPTLS12Fix.c" -o "$WORK/tweak-arm64"
"$LIPO" -create "$WORK/tweak-armv7" "$WORK/tweak-arm64" -output "$STAGE/Library/MobileSubstrate/DynamicLibraries/$DYLIB"

# Reaper helper: same two slices.
"$CC" -target armv7-apple-ios5.0 -isysroot "$SDK" -Os -L "$LEGACY_CRT_DIR" -Wl,-fatal_warnings \
  "$HERE/wifi-watchdog-reap.c" -o "$WORK/reap-armv7"
# iOS 5 can only start LC_UNIXTHREAD executables; refuse anything else.
"$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/otool" -l "$WORK/reap-armv7" | grep -q LC_UNIXTHREAD \
  || { echo "armv7 reaper is not an iOS 5 executable (no LC_UNIXTHREAD)" >&2; exit 1; }
"$CC" -target arm64-apple-ios7.0 -isysroot "$SDK" -Os "$HERE/wifi-watchdog-reap.c" -o "$WORK/reap-arm64"
"$LIPO" -create "$WORK/reap-armv7" "$WORK/reap-arm64" -output "$STAGE/usr/libexec/wifi-watchdog-reap"

# System-log capture helper for diagnostics snapshots: same two slices and iOS 5 entry-point check.
"$CC" -target armv7-apple-ios5.0 -isysroot "$SDK" -Os -Wno-deprecated-declarations -L "$LEGACY_CRT_DIR" -Wl,-fatal_warnings \
  "$HERE/wifi-watchdog-diag.c" -o "$WORK/diag-armv7"
"$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/otool" -l "$WORK/diag-armv7" | grep -q LC_UNIXTHREAD \
  || { echo "armv7 diag helper is not an iOS 5 executable (no LC_UNIXTHREAD)" >&2; exit 1; }
"$CC" -target arm64-apple-ios7.0 -isysroot "$SDK" -Os -Wno-deprecated-declarations "$HERE/wifi-watchdog-diag.c" -o "$WORK/diag-arm64"
"$LIPO" -create "$WORK/diag-armv7" "$WORK/diag-arm64" -output "$STAGE/usr/libexec/wifi-watchdog-diag"

ldid -S "$STAGE/Library/MobileSubstrate/DynamicLibraries/$DYLIB" "$STAGE/usr/libexec/wifi-watchdog-reap" "$STAGE/usr/libexec/wifi-watchdog-diag"
cp "$STAGE/Library/MobileSubstrate/DynamicLibraries/$DYLIB" "$HERE/$DYLIB"

OUT="$REPO/debs/eaptls12fix_${VERSION}_iphoneos-arm.deb"
/usr/bin/python3 -B - "$STAGE" "$OUT" <<'PY'
# Deterministic .deb: root:root ownership, fixed mtimes, sorted entries, gzip mtime 0.
import gzip, io, os, sys, tarfile
stage, out = sys.argv[1], sys.argv[2]
MTIME = 1794787200  # 2026-11-17
EXEC = {"DEBIAN/postinst", "DEBIAN/prerm", "usr/bin/wifi-watchdog.sh", "usr/libexec/wifi-watchdog-reap", "usr/libexec/wifi-watchdog-diag"}
def tar_gz(base, names):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as t:
        for rel in names:
            path = os.path.join(base, rel)
            info = t.gettarinfo(path, "./" + rel if rel else ".")
            info.uid = info.gid = 0; info.uname = info.gname = "root"; info.mtime = MTIME
            if info.isdir(): info.mode = 0o755
            else:
                full = os.path.relpath(path, stage)
                info.mode = 0o755 if (full in EXEC or rel.endswith(".dylib")) else 0o644
            t.addfile(info, open(path, "rb") if info.isfile() else None)
    data = io.BytesIO()
    with gzip.GzipFile(fileobj=data, mode="wb", mtime=0) as g: g.write(raw.getvalue())
    return data.getvalue()
def walk(base, skip=()):
    names = [""]
    for root, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if os.path.relpath(os.path.join(root, d), base) not in skip)
        for d in dirs: names.append(os.path.relpath(os.path.join(root, d), base))
        for f in sorted(files):
            if f != ".DS_Store": names.append(os.path.relpath(os.path.join(root, f), base))
    return names
control = tar_gz(os.path.join(stage, "DEBIAN"), [n for n in walk(os.path.join(stage, "DEBIAN"))])
data = tar_gz(stage, walk(stage, skip=("DEBIAN",)))
def member(name, payload):
    hdr = "%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, 0, 0, 0, "100644", len(payload))
    return hdr.encode() + payload + (b"\n" if len(payload) % 2 else b"")
with open(out, "wb") as f:
    f.write(b"!<arch>\n" + member("debian-binary", b"2.0\n") + member("control.tar.gz", control) + member("data.tar.gz", data))
print("built", out, os.path.getsize(out), "bytes")
PY
