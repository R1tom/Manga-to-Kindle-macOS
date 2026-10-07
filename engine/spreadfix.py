#!/usr/bin/env python3
"""Remove the duplicate double-page spreads from a manga PDF made with spreads = "Both".

KCC's "Both" mode puts every two-page spread in the book three times over: the right half, the left half, then
the whole spread turned sideways. In KOReader that reads as every spread page coming up twice. This deletes the
sideways copy (only when both halves are in the book; a very wide spread that KCC didn't split is kept), keeps
every image as it is (lossless, no reconversion), shifts the chapter list, and moves the KOReader reading
position on the Kindle by the number of pages removed before it.

Which pages are the sideways copies is worked out exactly, not guessed from the pictures:
  1. books made by this app from now on carry the list inside the PDF (embedded file "mk-pages.json");
  2. older books: every chapter in the PDF's chapter list is matched to its downloaded chapter file, and KCC's
     own spread check is run on the source images (same options as the build). A chapter is only touched when
     the page count KCC would produce equals that chapter's page count in the PDF.

  spreadfix.py scan  <book.pdf> [--source <dir>]...   -> JSON: pages to remove, chapters matched/unmatched
  spreadfix.py apply <book.pdf> [--source <dir>]...   -> rewrites the PDF in place ('@@{json}' progress lines)
  spreadfix.py fix   <book.pdf>...                     -> the app's "Remove Duplicate Spread Pages": the PDF may be the
        Mac copy (~/Documents/Kindle) or the one on the Kindle. The Mac copy is fixed, then copied over the Kindle's
        copy (gently, like a normal send) and the KOReader reading position on the Kindle is moved to match.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from multiprocessing import Pool
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import mangamerge  # noqa: E402

MARKER = "mk-pages.json"
HARU_DIR = Path.home() / "Documents" / "HARUNEKU"


def emit(kind, **d):
    print("@@" + json.dumps({"type": kind, **d}, ensure_ascii=False), flush=True)


# ---------------------------------------------------------------- KCC's spread check on source images

_OPTS = None


def kcc_options(build_opts):
    """The KCC options a build used (only what decides cropping/splitting matters here)."""
    sys.path.insert(0, str(mangamerge.KCC_DIR))
    from kindlecomicconverter import comic2ebook
    cmd = mangamerge.kcc_cmd({**build_opts, "format": "pdf", "title": "x"}, "/tmp/x", "/tmp")
    args = cmd[cmd.index("-p"):-1] + ["/tmp/x"]
    i = args.index("-o")
    del args[i:i + 2]
    o = comic2ebook.makeParser().parse_args(args)
    o.format = "CBZ"
    comic2ebook.options = o
    return comic2ebook.checkOptions(o)


def _init(build_opts):
    global _OPTS
    _OPTS = kcc_options(build_opts)


def _modes(job):
    """KCC output pages for one source image, in book order: list of 'N' / 'S1' / 'S2' / 'R'."""
    path, first = job
    from kindlecomicconverter import image
    try:
        p = image.ComicPageParser((os.path.dirname(path), os.path.basename(path)), first, _OPTS)
    except Exception:
        return None
    order = {"S1": 0, "S2": 1, "R": 2, "N": 3}   # -kcc-b, -kcc-c, -kcc-d, -kcc-x sort order
    return sorted((x[0] for x in p.payload), key=lambda m: order.get(m, 9))


def chapter_pages(images, pool, first_book_image=None):
    """Page kinds KCC makes from these source images; dup flags mark the sideways copy of a split spread."""
    res = pool.map(_modes, [(p, p == first_book_image) for p in images])
    if any(r is None for r in res):
        return None
    kinds = []
    for modes in res:
        split = "S1" in modes
        kinds += [("dup" if (m == "R" and split) else m) for m in modes]
    return kinds


# ---------------------------------------------------------------- matching the PDF's chapters to source files

def label_number(label):
    """'Chapter 7.0001' / 'Chapter 0012 - Title' -> '7.1' / '12' (pdfbook zero-pads for sorting)."""
    m = re.search(r"\b(?:Chapter|Ch\.?)\s*(\d+)(?:\.(\d+))?", label, re.I)
    if not m:
        return None
    txt = str(int(m.group(1)))
    if m.group(2) and int(m.group(2)):
        txt += "." + str(int(m.group(2)))
    return txt


def source_dirs_for(pdf, extra):
    if extra:
        return [Path(x) for x in extra]
    title = re.sub(r"\s+\d+$", "", Path(pdf).stem).strip()          # "Black Clover 2" -> "Black Clover"
    title = re.sub(r"\s*\(\d+\)$", "", title)
    found = []
    if HARU_DIR.is_dir():
        for src in HARU_DIR.iterdir():
            d = src / title
            if d.is_dir():
                found.append(d)
    return found


def analyze(pdf, sources=None, build_opts=None, progress=None):
    import pymupdf
    doc = pymupdf.open(pdf)
    n = doc.page_count
    # 1) exact list written by pdfbook
    if MARKER in (doc.embfile_names() or []):
        info = json.loads(doc.embfile_get(MARKER))
        dups = [i for i, k in enumerate(info.get("kinds", [])) if k == "dup"]
        return {"pdf": str(pdf), "pages": n, "remove": dups, "method": "marker", "matched": None, "unmatched": []}
    toc = [t for t in doc.get_toc() if t[0] == 1]
    doc.close()
    if not toc:
        return {"pdf": str(pdf), "pages": n, "remove": [], "method": "none", "error": "This book has no chapter list."}
    dirs = source_dirs_for(pdf, sources)
    if not dirs:
        return {"pdf": str(pdf), "pages": n, "remove": [], "method": "none",
                "error": "Couldn't find the downloaded chapters for this book (needed to know which pages are copies)."}
    plan = mangamerge.scan([str(d) for d in dirs])
    by_num = {}
    for it in plan["items"]:
        if it.get("chText"):
            by_num.setdefault(it["chText"], []).append(it)
    for v in by_num.values():                      # the file the app would have picked first
        v.sort(key=lambda it: (not it.get("selected"), it.get("lang") != plan.get("language")))
    spans = []
    for k, (lvl, label, start) in enumerate(toc):
        end = toc[k + 1][2] - 1 if k + 1 < len(toc) else n
        spans.append((label, start - 1, end - start + 1))
    remove, matched, unmatched = [], 0, []
    opts = build_opts or {"spreads": "both", "crop": "strong", "manga": True, "upscale": True, "imageMode": "best",
                          "autolevel": True}
    procs = max(1, int(os.environ.get("MK_KCC_PROCS", "2")))
    with tempfile.TemporaryDirectory(prefix="mk-spread-") as tmp, Pool(procs, _init, (opts,)) as pool:
        for ci, (label, start, count) in enumerate(spans):
            if progress:
                progress(ci, len(spans), label)
            num = label_number(label)
            ok = False
            for it in by_num.get(num, [])[:4]:
                d = Path(tmp) / f"c{ci}"
                if d.exists():
                    import shutil
                    shutil.rmtree(d)
                got = mangamerge.extract_unit(it, str(d))
                if not got:
                    continue
                images = [str(d / f) for f in sorted(os.listdir(d))]
                kinds = chapter_pages(images, pool)
                if kinds and len(kinds) == count:
                    remove += [start + i for i, kd in enumerate(kinds) if kd == "dup"]
                    matched += 1
                    ok = True
                    break
            if not ok:
                unmatched.append(label)
    if progress:
        progress(len(spans), len(spans), "")
    return {"pdf": str(pdf), "pages": n, "remove": sorted(set(remove)), "method": "source",
            "matched": matched, "unmatched": unmatched}


# ---------------------------------------------------------------- rewriting the PDF

def remove_pages(pdf, remove, out=None):
    """Delete pages (0-based) losslessly; the chapter list follows. Writes next to the file, then swaps it in."""
    import pymupdf
    pdf = Path(pdf)
    doc = pymupdf.open(pdf)
    toc = doc.get_toc()
    gone = set(remove)
    shift = [0] * (doc.page_count + 1)
    for i in range(doc.page_count):
        shift[i + 1] = shift[i] + (1 if i in gone else 0)
    new_toc = []
    for lvl, title, page in toc:
        p = page - 1
        while p in gone and p + 1 < doc.page_count:   # a chapter starting on a removed page starts on the next one
            p += 1
        new_toc.append([lvl, title, p - shift[p] + 1])
    doc.delete_pages(sorted(gone))
    doc.set_toc(new_toc)
    if MARKER in (doc.embfile_names() or []):
        info = json.loads(doc.embfile_get(MARKER))
        info["kinds"] = [k for i, k in enumerate(info.get("kinds", [])) if i not in gone]
        doc.embfile_del(MARKER)                  # (embfile_upd fails on bytes in this PyMuPDF)
        doc.embfile_add(MARKER, json.dumps(info).encode())
    else:                                        # fixed from the source chapters: no duplicates left
        doc.embfile_add(MARKER, json.dumps({"kinds": ["N"] * doc.page_count, "fixed": True}).encode())
    dst = Path(out) if out else pdf
    tmp = dst.with_name(dst.name + ".part")
    doc.save(tmp, garbage=3, deflate=True)
    doc.close()
    tmp.replace(dst)
    return shift


def new_page_number(old_page, remove):
    """1-based reading position after removing pages (a removed page maps to the page after it)."""
    gone = set(remove)
    p = old_page - 1
    return p - sum(1 for i in gone if i < p) + 1


def koreader_meta(pdf):
    m = Path(str(pdf)[:-4] + ".sdr") / "metadata.pdf.lua"
    return m if m.exists() else None


def fix_koreader_position(meta, remove, new_total):
    s = meta.read_text()
    m = re.search(r'\n\s*\["last_page"\] = (\d+),', s)
    old = int(m.group(1)) if m else 1
    new = new_page_number(old, remove)
    import kindle
    kindle.fix_book_view(meta, {"last_page": str(new), "doc_pages": str(new_total),
                                "percent_finished": repr(round(new / max(new_total, 1), 8))})
    # stats.pages is nested; update it too
    s = meta.read_text()
    s = re.sub(r'(\["stats"\] = \{[^{}]*?\["pages"\] = )\d+', lambda mm: mm.group(1) + str(new_total), s)
    meta.write_text(s)
    return old, new


def fix(paths):
    """Fix each book on the Mac, then replace the Kindle's copy and move its reading position."""
    import kindle
    k = kindle.find_kindle()
    mount = Path(k["mount"]) if k.get("found") else None
    out_dir = Path.home() / "Documents" / "Kindle"
    results, errors = [], []
    for n, given in enumerate(paths, 1):
        given = Path(given)
        name = given.name
        on_kindle = mount is not None and str(given).startswith(str(mount) + "/")
        mac = (out_dir / name) if on_kindle else given
        dev = given if on_kindle else None
        if dev is None and mount is not None:
            for cand in (mount / "documents").rglob(name):
                if cand.is_file() and mac.exists() and cand.stat().st_size == mac.stat().st_size:
                    dev = cand
                    break
        if on_kindle and (not mac.exists() or mac.stat().st_size != given.stat().st_size):
            errors.append(f"{name}: no identical copy on the Mac ({out_dir}) to fix and send back.")
            continue
        emit("book", name=name, index=n, count=len(paths))

        def prog(d, t, label, name=name):
            emit("progress", stage="spreads", done=d, total=t, name=name,
                 message=f"{name}: checking {label} ({d + 1}/{t})" if label else f"{name}: checked")

        res = analyze(str(mac), progress=prog)
        if res.get("error"):
            errors.append(f"{name}: {res['error']}")
            continue
        if not res["remove"]:
            results.append(f"{name}: no duplicate pages")
            continue
        emit("stage", stage="write", name=name, message=f"{name}: removing {len(res['remove'])} duplicate pages…")
        remove_pages(mac, res["remove"])
        new_total = res["pages"] - len(res["remove"])
        line = f"{name}: removed {len(res['remove'])} duplicate pages ({res['pages']} → {new_total})"
        if res.get("unmatched"):
            line += f"; {len(res['unmatched'])} chapter(s) left as they were"
        if dev is not None:
            emit("stage", stage="send", name=name, message=f"{name}: copying the fixed book to the Kindle…")
            folder = str(dev.parent.relative_to(mount / "documents"))
            if kindle.send([str(mac)], folder) != 0:
                errors.append(f"{name}: fixed on the Mac, but copying to the Kindle failed — send it again.")
                continue
            meta = koreader_meta(dev)
            if meta:
                old, new = fix_koreader_position(meta, res["remove"], new_total)
                line += f"; KOReader page {old} → {new}"
            line += "; Kindle copy replaced"
        results.append(line)
    if mount is not None:
        subprocess.run(["sync"])
    msg = "\n".join(results + errors) or "Nothing to do."
    emit("result", ok=not errors, message=msg)
    return 0 if not errors else 2


def main():
    a = sys.argv[1:]
    if len(a) >= 2 and a[0] == "fix":
        return fix(a[1:])
    if len(a) < 2 or a[0] not in ("scan", "apply"):
        print(__doc__)
        return 1
    cmd, pdf = a[0], a[1]
    sources = [a[i + 1] for i, x in enumerate(a) if x == "--source" and i + 1 < len(a)]

    def prog(d, t, label):
        emit("progress", stage="spreads", done=d, total=t, message=f"Checking {label}" if label else "Checked")

    res = analyze(pdf, sources, progress=prog)
    if cmd == "scan" or not res["remove"]:
        if cmd == "apply" and not res.get("error"):
            res["message"] = "No duplicate spread pages in this book."
        print(json.dumps(res, ensure_ascii=False))
        return 0 if not res.get("error") else 2
    emit("stage", stage="write", message=f"Removing {len(res['remove'])} duplicate pages")
    remove_pages(pdf, res["remove"])
    new_total = res["pages"] - len(res["remove"])
    meta = koreader_meta(pdf)
    if meta:
        old, new = fix_koreader_position(meta, res["remove"], new_total)
        res["position"] = {"old": old, "new": new}
    res["newPages"] = new_total
    res["message"] = f"Removed {len(res['remove'])} duplicate spread pages ({res['pages']} → {new_total} pages)."
    print(json.dumps(res, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
