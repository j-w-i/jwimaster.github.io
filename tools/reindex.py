#!/usr/bin/env python3
"""Regenerate the APT index (Packages, Packages.gz/.bz2, Release) from debs/.

Usage: tools/reindex.py [--check]
--check exits non-zero if the committed index is out of date or invalid.
"""
import bz2, hashlib, io, os, struct, sys, tarfile, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEBS = os.path.join(ROOT, "debs")
FIELDS = ["Package", "Name", "Version", "Architecture", "Maintainer",
          "Author", "Section", "Depends", "Installed-Size", "Description"]


def ar_members(path):
    with open(path, "rb") as f:
        if f.read(8) != b"!<arch>\n":
            raise ValueError("not an ar archive: %s" % path)
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                return
            name = hdr[:16].decode().strip().rstrip("/")
            size = int(hdr[48:58].decode().strip())
            data = f.read(size)
            if size % 2:
                f.read(1)
            yield name, data


def deb_control(path):
    for name, data in ar_members(path):
        if name.startswith("control.tar"):
            with tarfile.open(fileobj=io.BytesIO(data)) as t:
                for m in t.getmembers():
                    if m.name.lstrip("./") == "control":
                        return t.extractfile(m).read().decode()
    raise ValueError("no control file in %s" % path)


def parse_control(text):
    fields = {}
    key = None
    for line in text.splitlines():
        if not line.strip():
            continue
        if line[0] in " \t" and key:
            fields[key] += "\n" + line
        else:
            k, _, v = line.partition(":")
            key = k.strip()
            fields[key] = v.lstrip()
    return fields


def stanza_for(path):
    rel = os.path.relpath(path, ROOT)
    blob = open(path, "rb").read()
    c = parse_control(deb_control(path))
    out = []
    for f in FIELDS:
        if f in c:
            out.append("%s: %s" % (f, c[f]))
    out += ["Filename: ./" + rel,
            "Size: %d" % len(blob),
            "MD5sum: " + hashlib.md5(blob).hexdigest(),
            "SHA1: " + hashlib.sha1(blob).hexdigest(),
            "SHA256: " + hashlib.sha256(blob).hexdigest()]
    return c.get("Package", rel), "\n".join(out)


def gzip_stable(data):
    """gzip with a fixed header so output is byte-identical everywhere."""
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = co.compress(data) + co.flush()
    header = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03"
    trailer = struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF, len(data) & 0xFFFFFFFF)
    return header + body + trailer


def build():
    debs = sorted(os.path.join(DEBS, f) for f in os.listdir(DEBS) if f.endswith(".deb"))
    stanzas = [stanza_for(p) for p in debs]
    stanzas.sort(key=lambda s: s[0])
    text = "\n\n".join(s for _, s in stanzas) + "\n\n"
    return text, stanzas


def main():
    text, stanzas = build()
    raw = text.encode()
    gz = gzip_stable(raw)
    bz = bz2.compress(raw)
    files = {"Packages": raw, "Packages.gz": gz, "Packages.bz2": bz}
    head = ("Origin: J_W_I_'s Repo\nLabel: J_W_I_'s Repo\nSuite: stable\n"
            "Version: 1.0\nCodename: ios\n"
            "Architectures: iphoneos-arm64 iphoneos-arm\n"
            "Components: main\nDescription: Cool Tweaks\n")
    rel = [head]
    for label, algo in (("MD5Sum", hashlib.md5), ("SHA1", hashlib.sha1), ("SHA256", hashlib.sha256)):
        rel.append(label + ":\n" + "".join(
            " %s %d %s\n" % (algo(files[n]).hexdigest(), len(files[n]), n)
            for n in ("Packages", "Packages.gz", "Packages.bz2")))
    release = "".join(rel)

    if "--check" in sys.argv:
        ok = True
        for name, data in files.items():
            p = os.path.join(ROOT, name)
            if not os.path.exists(p) or open(p, "rb").read() != data:
                print("STALE: %s" % name)
                ok = False
        p = os.path.join(ROOT, "Release")
        if not os.path.exists(p) or open(p).read() != release:
            print("STALE: Release")
            ok = False
        for pkg, _ in stanzas:
            if pkg not in text:
                ok = False
        if not ok:
            print("Index is stale or invalid: run tools/reindex.py")
            return 1
        print("index ok (%d packages)" % len(stanzas))
        return 0

    for name, data in files.items():
        mode = "wb" if name != "Release" else "w"
        with open(os.path.join(ROOT, name), mode) as f:
            f.write(data)
    with open(os.path.join(ROOT, "Release"), "w") as f:
        f.write(release)
    print("wrote index for %d packages" % len(stanzas))
    return 0


if __name__ == "__main__":
    sys.exit(main())
