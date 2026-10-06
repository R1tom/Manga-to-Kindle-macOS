#!/usr/bin/env python3
"""Send books to a Kindle plugged in over USB (mass-storage mode, shows up as a drive in Finder).

  kindle.py detect                         -> JSON {found, mount, name, free, total}
  kindle.py send [--folder Manga] <file>…  -> copies with '@@{json}' progress
  kindle.py list [--folder Manga]          -> JSON list of books in documents/<folder>
  kindle.py delete <path>…                 -> remove books (+ their .sdr reading data)
  kindle.py eject                          -> flush + eject

Copies are written byte-for-byte (the book is not modified), checked, then the macOS
"._" side files are removed and a cover thumbnail is written to system/thumbnails —
the same layout calibre leaves behind.
"""
import io
import json
import re
import os
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

BOOK_EXT = {".azw3", ".mobi", ".azw", ".kfx", ".pdf", ".epub"}
ALL_BOOK_EXT = BOOK_EXT | {".azw4", ".azw8", ".prc", ".pobi", ".txt", ".docx", ".kfx-zip"}
NEVER_LIST = {"my clippings.txt"}


def emit(kind, **d):
    print("@@" + json.dumps({"type": kind, **d}, ensure_ascii=False), flush=True)


def find_kindle():
    vols = Path("/Volumes")
    for v in sorted(vols.iterdir()) if vols.exists() else []:
        try:
            if (v / "documents").is_dir() and (v / "system").is_dir():
                st = os.statvfs(v)
                return {"found": True, "mount": str(v), "name": v.name,
                        "free": st.f_bavail * st.f_frsize, "total": st.f_blocks * st.f_frsize}
        except OSError:
            continue
    return {"found": False}


# ---------------------------------------------------------------- MOBI cover + ASIN

def mobi_info(path):
    """ASIN (EXTH 113), cdetype (EXTH 501) and cover image bytes of a MOBI/AZW3 file."""
    with open(path, "rb") as f:
        head = f.read(78)
        n = struct.unpack(">H", head[76:78])[0]
        offs = [struct.unpack(">I", f.read(8)[:4])[0] for _ in range(n)]
        f.seek(0, 2)
        size = f.tell()
        offs.append(size)

        def rec(i):
            f.seek(offs[i])
            return f.read(offs[i + 1] - offs[i])

        r0 = rec(0)
        mobi = r0[16:]
        hlen = struct.unpack(">I", mobi[4:8])[0]
        first_img = struct.unpack(">I", mobi[92:96])[0]
        exth = {}
        if struct.unpack(">I", mobi[112:116])[0] & 0x40:
            e = mobi[hlen:]
            cnt = struct.unpack(">I", e[8:12])[0]
            p = 12
            for _ in range(cnt):
                t, l = struct.unpack(">II", e[p:p + 8])
                exth.setdefault(t, e[p + 8:p + l])
                p += l
        asin = exth.get(113, b"").decode("utf-8", "ignore") or exth.get(504, b"").decode("utf-8", "ignore")
        cde = exth.get(501, b"PDOC").decode("utf-8", "ignore") or "PDOC"
        cover = None
        if 201 in exth and first_img not in (0, 0xFFFFFFFF):
            idx = first_img + struct.unpack(">I", exth[201])[0]
            if idx < n:
                cover = rec(idx)
        return asin, cde, cover


def write_thumbnail(book, mount):
    try:
        from PIL import Image
        asin, cde, cover = mobi_info(book)
        if not asin or not cover:
            return None
        thumbs = Path(mount) / "system" / "thumbnails"
        if not thumbs.is_dir():
            return None
        im = Image.open(io.BytesIO(cover)).convert("L")
        im.thumbnail((330, 470))
        out = thumbs / f"thumbnail_{asin}_{cde}_portrait.jpg"
        im.save(out, "JPEG", quality=90)
        strip_appledouble(out)
        return str(out)
    except Exception:
        return None


def strip_appledouble(p):
    p = Path(p)
    side = p.with_name("._" + p.name)
    try:
        if side.exists():
            side.unlink()
    except OSError:
        pass


# ---------------------------------------------------------------- commands

def send(files, folder):
    k = find_kindle()
    if not k["found"]:
        emit("error", message="No Kindle connected. Plug it in with the USB cable (it should appear as a drive called Kindle).")
        return 2
    dest = Path(k["mount"]) / "documents"
    if folder:
        dest = dest / folder
    dest.mkdir(parents=True, exist_ok=True)
    strip_appledouble(dest)
    files = [f for f in files if Path(f).suffix.lower() in BOOK_EXT and Path(f).exists()]
    need = sum(os.path.getsize(f) for f in files)
    if need > k["free"] - 50 * 1024 * 1024:
        emit("error", message=f"Not enough space on the Kindle: need {need / 1e9:.2f} GB, free {k['free'] / 1e9:.2f} GB.")
        return 3
    total, done_bytes, sent = need, 0, []
    # Gentle copy: Kindles (seen on a jailbroken Paperwhite 11th gen, firmware 5.19.2) drop out of USB mode or freeze
    # after a few GB at full speed. Sync every 64 MB and pause briefly; ~9 MB/s, and it never froze that way.
    gentle = os.environ.get("MK_KINDLE_FAST") != "1"
    for i, f in enumerate(files):
        if gentle and i:
            time.sleep(10)
        src = Path(f)
        dst = dest / src.name
        tmp = dest / (".mk-partial-" + src.name)
        emit("file", name=src.name, size=src.stat().st_size)
        with open(src, "rb") as a, open(tmp, "wb") as b:
            while True:
                chunk = a.read(4 << 20)
                if not chunk:
                    break
                b.write(chunk)
                done_bytes += len(chunk)
                emit("progress", done=done_bytes, total=total, name=src.name)
                if gentle:
                    if done_bytes % (64 << 20) < (4 << 20):
                        b.flush()
                        os.fsync(b.fileno())
                        time.sleep(1.0)
                    else:
                        time.sleep(0.15)
            b.flush()
            os.fsync(b.fileno())
        if tmp.stat().st_size != src.stat().st_size:
            tmp.unlink(missing_ok=True)
            emit("error", message=f"Copy of {src.name} came out the wrong size — the Kindle may be full or was unplugged.")
            return 4
        if dst.exists():
            dst.unlink()
        os.replace(tmp, dst)
        strip_appledouble(tmp)
        strip_appledouble(dst)
        thumb = write_thumbnail(dst, k["mount"])
        sent.append({"name": src.name, "path": str(dst), "thumbnail": bool(thumb)})
    subprocess.run(["sync"])
    emit("done", sent=sent, folder=str(dest))
    return 0


def book_title(p):
    """Title stored inside a MOBI/AZW file (EXTH 503 updated title, else the MOBI full name)."""
    try:
        with open(p, "rb") as f:
            head = f.read(78)
            if head[60:68] not in (b"BOOKMOBI", b"TEXtREAd"):
                return None
            n = struct.unpack(">H", head[76:78])[0]
            r0 = struct.unpack(">I", f.read(8)[:4])[0]
            r1 = struct.unpack(">I", f.read(8)[:4])[0] if n > 1 else r0 + 4096
            f.seek(r0)
            rec0 = f.read(min(r1 - r0, 65536))
        mobi = rec0[16:]
        if mobi[:4] != b"MOBI":
            return None
        hlen = struct.unpack(">I", mobi[4:8])[0]
        if struct.unpack(">I", mobi[112:116])[0] & 0x40:
            e = mobi[hlen:]
            cnt = struct.unpack(">I", e[8:12])[0]
            q = 12
            for _ in range(cnt):
                t, l = struct.unpack(">II", e[q:q + 8])
                if t == 503:
                    return e[q + 8:q + l].decode("utf-8", "ignore").strip() or None
                q += l
        off, ln = struct.unpack(">II", mobi[68:76])
        return rec0[off:off + ln].decode("utf-8", "ignore").strip() or None
    except Exception:
        return None


def book_kind(rel):
    low = rel.lower()
    if low.startswith("dictionaries/"):
        return "dictionary"
    if low.startswith("downloads/"):
        return "store"
    if low.endswith((".pdf", ".txt", ".docx")):
        return "document"
    return "book"


def list_all():
    """Every book-like file under documents/, plus reading-data (.sdr) folders whose book is gone."""
    k = find_kindle()
    if not k["found"]:
        print(json.dumps({"found": False, "books": [], "orphans": []}))
        return 0
    base = Path(k["mount"]) / "documents"
    books, stems = [], set()
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if not d.startswith(".") and not d.lower().endswith(".sdr")]
        for name in files:
            if name.startswith(".") or name.lower() in NEVER_LIST:
                continue
            p = Path(root) / name
            if p.suffix.lower() not in ALL_BOOK_EXT:
                continue
            st = p.stat()
            rel = str(p.relative_to(base))
            stems.add(str(p.with_suffix("")))
            title = book_title(p) if p.suffix.lower() in (".azw3", ".mobi", ".azw", ".prc", ".azw4") else None
            books.append({"name": name, "path": str(p), "rel": rel, "folder": str(Path(rel).parent) if "/" in rel else "",
                          "title": title or p.stem, "size": st.st_size, "modified": st.st_mtime,
                          "ext": p.suffix.lower().lstrip("."), "kind": book_kind(rel)})
    orphans = []
    for sdr in base.rglob("*.sdr"):
        if sdr.name.startswith(".") or not sdr.is_dir():
            continue
        if str(sdr.with_suffix("")) not in stems:
            size = sum(f.stat().st_size for f in sdr.rglob("*") if f.is_file())
            orphans.append({"path": str(sdr), "rel": str(sdr.relative_to(base)), "size": size})
    print(json.dumps({**k, "books": books, "orphans": orphans}, ensure_ascii=False))
    return 0


def list_books(folder):
    k = find_kindle()
    if not k["found"]:
        print(json.dumps({"found": False, "books": []}))
        return 0
    base = Path(k["mount"]) / "documents"
    root = base / folder if folder else base
    books = []
    for p in sorted(root.rglob("*")) if root.exists() else []:
        if p.is_file() and p.suffix.lower() in BOOK_EXT and not p.name.startswith((".", "._")):
            st = p.stat()
            books.append({"name": p.name, "path": str(p), "size": st.st_size, "modified": st.st_mtime,
                          "folder": str(p.parent.relative_to(base))})
    print(json.dumps({**k, "books": books}))
    return 0


def delete(paths):
    """Remove books (with their .sdr reading data, macOS side files and cover thumbnail) or orphan .sdr folders."""
    k = find_kindle()
    removed, freed = 0, 0
    if not k["found"]:
        print(json.dumps({"removed": 0, "freed": 0}))
        return 0
    docs = Path(k["mount"]) / "documents"
    thumbs = Path(k["mount"]) / "system" / "thumbnails"
    for s in paths:
        p = Path(s)
        try:
            p.resolve().relative_to(docs.resolve())
        except ValueError:
            continue  # never touch anything outside the Kindle's documents folder
        if not p.exists():
            continue
        asin = cde = None
        if p.is_file() and p.suffix.lower() in (".azw3", ".mobi", ".azw"):
            try:
                asin, cde, _ = mobi_info(p)
            except Exception:
                pass
        targets = [p] if p.suffix.lower() == ".sdr" else [p, p.with_suffix(".sdr"), p.with_name("._" + p.name)]
        for q in targets:
            try:
                if q.is_dir():
                    freed += sum(f.stat().st_size for f in q.rglob("*") if f.is_file())
                    shutil.rmtree(q, ignore_errors=True)
                elif q.exists():
                    freed += q.stat().st_size
                    q.unlink()
            except OSError:
                pass
        if asin and thumbs.is_dir():
            for t in thumbs.glob(f"thumbnail_{asin}_*"):
                t.unlink(missing_ok=True)
        # store books live in their own folder (Downloads/Items01/<ASIN>/…): drop it when nothing is left
        parent = p.parent
        if parent != docs and parent.exists() and parent.name.lower() not in ("downloads", "items01", "dictionaries"):
            rest = [x for x in parent.iterdir() if not x.name.startswith(".")]
            if not rest:
                shutil.rmtree(parent, ignore_errors=True)
        removed += 1
    subprocess.run(["sync"])
    print(json.dumps({"removed": removed, "freed": freed}))
    return 0


def eject():
    k = find_kindle()
    if not k["found"]:
        print(json.dumps({"ok": True, "message": "No Kindle connected."}))
        return 0
    subprocess.run(["sync"])
    for _ in range(4):
        r = subprocess.run(["diskutil", "eject", k["mount"]], capture_output=True, text=True)
        if r.returncode == 0:
            print(json.dumps({"ok": True, "message": "Kindle ejected — safe to unplug."}))
            return 0
        time.sleep(1.5)
    r2 = subprocess.run(["lsof", "+f", "--", k["mount"]], capture_output=True, text=True)
    apps = sorted({l.split()[0] for l in r2.stdout.splitlines()[1:] if l.strip()})
    print(json.dumps({"ok": False, "message": "Kindle is busy" + (f" (used by {', '.join(apps)})" if apps else "") +
                      ". Don't unplug yet."}))
    return 1


KOREADER_SETTINGS = {
    # manga defaults that worked on the Paperwhite 11th gen (2026-10-04)
    "inverse_reading_order": "true",            # right-to-left page turns (tap left = next)
    "full_refresh_count": "1",                  # full e-ink refresh on every page: no ghosting
    "night_full_refresh_count": "1",
    "kopt_page_scroll": "0",                    # page view, not continuous (pages don't bleed into the next chapter)
    "kopt_page_gap_height": "0",
    "kopt_zoom_mode_genus": "4",                # fit the whole page
    "kopt_zoom_mode_type": "2",
    "disable_double_tap": "true",               # no 10-page jumps, faster page turns
    "home_dir": '"/mnt/us/documents/Manga"',
}
KOREADER_GESTURES_OFF = ("tap_top_left_corner", "tap_top_right_corner", "tap_left_bottom_corner", "tap_right_bottom_corner",
                         "one_finger_swipe_bottom_edge_left", "one_finger_swipe_bottom_edge_right")


def koreader_setup():
    """Write the manga settings into KOReader on the Kindle (KOReader must be closed: it rewrites its files on exit)."""
    k = find_kindle()
    if not k["found"]:
        print(json.dumps({"ok": False, "message": "No Kindle connected."}))
        return 1
    ko = Path(k["mount"]) / "koreader"
    if not ko.is_dir():
        print(json.dumps({"ok": False, "message": "KOReader isn't installed on this Kindle (no koreader folder)."}))
        return 1
    changed = []

    def set_keys(path, keys, section=None):
        s = path.read_text() if path.exists() else "return {\n}\n"
        for key, val in keys.items():
            pat = re.compile(r'(\n\s*)\["' + re.escape(key) + r'"\] = (\{[^{}]*\}|[^,\n]+),')
            if pat.search(s):
                s = pat.sub(lambda m: f'{m.group(1)}["{key}"] = {val},', s, count=1)
            else:
                s = s.rstrip()
                assert s.endswith("}")
                s = s[:-1].rstrip() + f'\n    ["{key}"] = {val},\n}}\n'
        path.write_text(s)
        changed.append(path.name)

    set_keys(ko / "settings.reader.lua", KOREADER_SETTINGS)
    # no status-bar tap strip at the bottom edge (in page-flipping mode a tap there jumps to that spot in the book)
    set_keys(ko / "defaults.custom.lua", {"DTAP_ZONE_MINIBAR": '{ ["h"] = 0, ["w"] = 0, ["x"] = 0, ["y"] = 1, }'})
    # corner taps / bottom-edge swipes: page flipping, bookmarks, frontlight… easy to hit by accident while reading
    g = ko / "settings" / "gestures.lua"
    if g.exists():
        s = g.read_text()
        start = s.find('["gesture_reader"]')
        if start >= 0:
            head, reader = s[:start], s[start:]          # only the reader's gestures, not the file browser's
            for name in KOREADER_GESTURES_OFF:
                reader = re.sub(r'(\["' + name + r'"\] = )\{[^{}]*\}', r"\g<1>{}", reader)
            g.write_text(head + reader)
            changed.append(g.name)
    # every book KOReader has opened keeps its own view settings (a stray tap on the bottom menu can switch one to
    # "fit width"/continuous): put the PDFs back to page view + fit full page, keeping the reading position
    fixed = 0
    for meta in (Path(k["mount"]) / "documents").rglob("metadata.pdf.lua"):
        try:
            s = meta.read_text()
            s2 = s
            for key, val in (("kopt_page_scroll", "0"), ("kopt_page_gap_height", "0"),
                             ("kopt_zoom_mode_genus", "4"), ("kopt_zoom_mode_type", "2")):
                s2 = re.sub(r'(\["' + key + r'"\] = )[^,\n]+,', r"\g<1>" + val + ",", s2)
            if s2 != s:
                meta.write_text(s2)
                fixed += 1
        except OSError:
            pass
    if fixed:
        changed.append(f"{fixed} book setting(s)")
    for junk in ko.rglob("._*"):
        junk.unlink(missing_ok=True)
    subprocess.run(["sync"])
    print(json.dumps({"ok": True, "message": "KOReader is set up for manga: right-to-left, full refresh every page, page view, "
                                             "no accidental jumps.", "files": changed}))
    return 0


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 1
    folder = "Manga"
    if "--folder" in a:
        i = a.index("--folder")
        folder = a[i + 1].strip().strip("/")
        del a[i:i + 2]
    cmd, rest = a[0], a[1:]
    if cmd == "detect":
        print(json.dumps(find_kindle()))
        return 0
    if cmd == "send":
        return send(rest, folder)
    if cmd == "list":
        return list_books(folder)
    if cmd == "list-all":
        return list_all()
    if cmd == "delete":
        return delete(rest)
    if cmd == "koreader-setup":
        return koreader_setup()
    if cmd == "eject":
        return eject()
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
