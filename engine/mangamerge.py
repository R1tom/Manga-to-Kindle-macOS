#!/usr/bin/env python3
"""Manga → Kindle: merge chapter files (CBZ/ZIP/CBR/RAR/CB7/7Z/CBT/TAR/PDF/EPUB/image folders)
into one correctly ordered book and convert it with Kindle Comic Converter.

  mangamerge.py scan  <path>...                      -> JSON plan on stdout
  mangamerge.py build <plan.json>                    -> builds; progress as '@@{json}' lines
  mangamerge.py check                                -> dependency status JSON

Machine-readable lines start with '@@' followed by JSON; everything else is plain log text.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from xml.etree import ElementTree as ET

from natsort import natsorted, os_sorted
from PIL import Image, ImageFile

ImageFile.LOAD_TRUNCATED_IMAGES = True
Image.MAX_IMAGE_PIXELS = None

HERE = Path(__file__).resolve().parent
KCC_DIR = Path(os.environ.get("MK_KCC_DIR", HERE.parent / "kcc-src"))
BIN_DIR = Path(os.environ.get("MK_BIN_DIR", HERE.parent / "bin"))

ARCHIVE_ZIP = {".cbz", ".zip", ".epub"}
ARCHIVE_OTHER = {".cbr", ".rar", ".cb7", ".7z", ".cbt", ".tar"}
PDF = {".pdf"}
SUPPORTED = ARCHIVE_ZIP | ARCHIVE_OTHER | PDF
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".avif", ".jxl", ".heic"}
PROFILE = "KPW5"  # Kindle Paperwhite 11th gen (Paperwhite 5 / Signature Edition), 1236x1648
PDF_RENDER_HEIGHT = 2200  # render vector PDF pages a bit above device height; KCC downsizes


LOG_FILE = None  # every build also writes ~/Library/Logs/MangaToKindle/<time> <title>.log


def _tee(line):
    if LOG_FILE:
        try:
            LOG_FILE.write(line + "\n")
            LOG_FILE.flush()
        except Exception:
            pass


def emit(kind, **data):
    line = "@@" + json.dumps({"type": kind, **data}, ensure_ascii=False)
    print(line, flush=True)
    if kind != "progress":
        _tee(line)


def log(msg):
    print(msg, flush=True)
    _tee(msg)


# ---------------------------------------------------------------- name parsing

LANG_BRACKET = {"en", "ja", "jp", "ko", "kr", "zh", "cn", "es", "pt", "fr", "id", "vi", "th", "ru", "de", "it", "tr", "ar", "pl"}
RE_LANG = re.compile(r"\((?P<l>[a-z]{2,3}(?:-[a-z]{2,4})?)\)", re.I)
RE_GROUP = re.compile(r"\[(?P<g>[^\]]+)\]")
RE_VOL = re.compile(r"(?<![a-z])(?:vol(?:ume)?|v)[\s._-]*(?P<n>\d+(?:\.\d+)?)", re.I)
RE_CH = re.compile(r"(?<![a-z])(?:ch(?:apter|ap|\.)?|episode|ep\.?|#)[\s._-]*(?P<n>\d+(?:[.,]\d+)?)", re.I)
RE_NUM = re.compile(r"(?<![\d.])(?P<n>\d+(?:\.\d+)?)(?![\d])")


def norm_num(s):
    s = s.replace(",", ".")
    try:
        f = float(s)
    except ValueError:
        return None, None
    txt = ("%f" % f).rstrip("0").rstrip(".")
    return f, txt


def parse_name(stem):
    info = {"vol": None, "ch": None, "chText": None, "title": "", "lang": None, "group": None}
    langs = RE_LANG.findall(stem)
    if langs:
        info["lang"] = langs[-1].lower()
    groups = RE_GROUP.findall(stem)
    if groups:
        info["group"] = groups[-1].strip()
        # "第182話 [jp]" / "Chapter 143 [en]": a bare language code in brackets is the language, not a scan group
        g = info["group"].lower()
        if g in LANG_BRACKET:
            info["group"] = groups[-2].strip() if len(groups) > 1 else None
            if info["lang"] is None:
                info["lang"] = {"jp": "ja", "kr": "ko", "cn": "zh"}.get(g, g)
    core = RE_GROUP.sub(" ", stem)
    core = RE_LANG.sub(" ", core)
    m = RE_VOL.search(core)
    if m:
        info["vol"] = norm_num(m.group("n"))[0]
    m = RE_CH.search(core)
    rest_from = None
    if m:
        info["ch"], info["chText"] = norm_num(m.group("n"))
        rest_from = m.end()
    else:
        # no "Ch." marker: use the first number before any " - title" part, ignoring the volume
        head = core.split(" - ", 1)[0]
        head = RE_VOL.sub(" ", head) if info["vol"] is not None else head
        nums = RE_NUM.findall(head) or RE_NUM.findall(RE_VOL.sub(" ", core))
        if nums:
            info["ch"], info["chText"] = norm_num(nums[0])
    # title: text after " - " following the chapter number
    t = None
    if " - " in core:
        t = core.split(" - ", 1)[1]
    elif rest_from is not None:
        t = core[rest_from:]
    if t:
        # "(LuCaZ) (official)" style tags (MangaFire etc.) are not part of the title
        tags = re.findall(r"\(([^()]*)\)", t)
        bare = re.sub(r"\([^()]*\)", " ", t).strip(" -_:.")
        if not bare:
            t = ""
        if not bare and info["group"] is None:
            g = [x.strip() for x in tags if x.strip() and x.strip().lower() not in ("official", "raw", "colored", "colour", "color")]
            if g:
                info["group"] = g[0]
        t = re.sub(r"\s+", " ", t).strip(" -_:.")
        if re.fullmatch(r"[\d.\s-]*", t):
            t = ""
    info["title"] = t or ""
    return info


# ---------------------------------------------------------------- discovery

def is_image_name(name):
    base = os.path.basename(name)
    return Path(name).suffix.lower() in IMAGE_EXT and not base.startswith(".") and "__MACOSX" not in name


def dir_images(d):
    out = []
    for root, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if not x.startswith(".") and x != "__MACOSX"]
        for f in files:
            p = os.path.join(root, f)
            if is_image_name(p):
                out.append(p)
    return os_sorted(out)


def discover(paths):
    """Return list of chapter units: (kind, path)."""
    units = []
    for p in paths:
        p = Path(p).expanduser()
        if p.is_file():
            if p.suffix.lower() in SUPPORTED:
                units.append(("file", p))
            continue
        if not p.is_dir():
            continue
        for root, dirs, files in os.walk(p):
            dirs[:] = [x for x in dirs if not x.startswith(".") and x != "__MACOSX"]
            r = Path(root)
            chapter_files = [r / f for f in files if Path(f).suffix.lower() in SUPPORTED and not f.startswith(".")]
            imgs = [f for f in files if is_image_name(f)]
            units += [("file", f) for f in chapter_files]
            # a folder of images (HaruNeko "image folder" output) is one chapter;
            # skip the top folder if it only holds a cover next to chapter folders
            if imgs and not chapter_files and not (r == p and dirs and len(imgs) <= 2):
                units.append(("dir", r))
                dirs[:] = []
    seen, out = set(), []
    for k, u in units:
        if str(u) not in seen:
            seen.add(str(u))
            out.append((k, u))
    return out


def count_pages(kind, path):
    try:
        if kind == "dir":
            return len(dir_images(path))
        ext = path.suffix.lower()
        if ext in ARCHIVE_ZIP:
            with zipfile.ZipFile(path) as z:
                return sum(1 for n in z.namelist() if is_image_name(n))
        if ext in PDF:
            import pymupdf as fitz
            with fitz.open(path) as d:
                return d.page_count
        r = subprocess.run(["bsdtar", "-tf", str(path)], capture_output=True, text=True, timeout=120)
        return sum(1 for n in r.stdout.splitlines() if is_image_name(n))
    except Exception:
        return 0


def series_title(paths, units):
    if len(paths) == 1 and Path(paths[0]).is_dir():
        return Path(paths[0]).name
    parents = Counter(u.parent.name if k == "file" else u.parent.name for k, u in units)
    return parents.most_common(1)[0][0] if parents else "Manga"


def scan(paths, lang=None):
    units = discover(paths)
    with ThreadPoolExecutor(8) as ex:
        pages = list(ex.map(lambda ku: count_pages(*ku), units))
    items = []
    for (kind, path), n in zip(units, pages):
        stem = path.name if kind == "dir" else path.stem
        info = parse_name(stem)
        items.append({
            "path": str(path), "kind": kind, "name": path.name,
            "format": "folder" if kind == "dir" else path.suffix.lower().lstrip("."),
            "pages": n, **info,
        })
    langs = Counter(i["lang"] or "" for i in items)
    if lang is None:
        if "en" in langs:
            lang = "en"
        elif langs:
            lang = langs.most_common(1)[0][0]
        else:
            lang = ""
    apply_default_selection(items, lang)
    title = series_title(paths, [(k, u) for k, u in units])
    return {
        "title": title,
        "language": lang,
        "languages": [{"code": k, "count": v} for k, v in langs.most_common()],
        "items": sort_items(items),
    }


def sort_key(i):
    ch = i["ch"] if i["ch"] is not None else float("inf")
    vol = i["vol"] if i["vol"] is not None else float("inf")
    return (ch, vol, i["name"].lower())


def sort_items(items):
    return sorted(items, key=sort_key)


def apply_default_selection(items, lang):
    """Pick one file per chapter number: chosen language, best-covering scan group."""
    for i in items:
        i["selected"] = False
        i["duplicate"] = False
    pool = [i for i in items if (lang == "*" or (i["lang"] or "") == lang) and i["pages"] > 0]
    # chapters taken from a second source may have no language tag: use them where the chosen language has nothing
    if lang not in ("*", ""):
        def ch_key(i):
            return i["chText"] if i["ch"] is not None else "name:" + i["name"]
        have = {ch_key(i) for i in pool}
        pool += [i for i in items if not i["lang"] and i["pages"] > 0 and i["ch"] is not None and ch_key(i) not in have]
    # A "chapter" that is really a whole volume (e.g. MangaFire's "Ch. 0 Volume 33", 190 pages) would land at the front
    # of the book and repeat chapters that are there anyway: leave such bundles out (they can still be ticked by hand).
    sizes = sorted(i["pages"] for i in pool)
    median = sizes[len(sizes) // 2] if sizes else 0
    if len(pool) >= 5:
        for i in pool:
            if i["pages"] >= max(80, 3 * median) and re.search(r"(?<![a-z])vol(?:ume)?\b", i["name"], re.I):
                i["bundle"] = True
        pool = [i for i in pool if not i.get("bundle")]
    group_cov = Counter(i["group"] or "" for i in pool)
    by_ch = defaultdict(list)
    for i in pool:
        key = i["chText"] if i["ch"] is not None else "name:" + i["name"]
        by_ch[key].append(i)
    for key, lst in by_ch.items():
        lst.sort(key=lambda i: (-group_cov[i["group"] or ""], -i["pages"], i["name"]))
        lst[0]["selected"] = True
        for dup in lst[1:]:
            dup["duplicate"] = True


def gaps(items):
    nums = sorted({int(i["ch"]) for i in items if i.get("selected") and i["ch"] is not None})
    if not nums:
        return []
    have = set(nums)
    return [n for n in range(nums[0], nums[-1] + 1) if n not in have]


# ---------------------------------------------------------------- extraction

def safe_name(s, limit=80):
    s = re.sub(r'[\\/:*?"<>|\x00-\x1f]', " ", s)
    s = re.sub(r"\s+", " ", s).strip(" .")
    return s[:limit].strip() or "Untitled"


def chapter_label(i):
    if i.get("label"):
        return i["label"]
    if i.get("ch") is None:
        return Path(i["name"]).stem
    lab = f"Chapter {i['chText']}"
    if i.get("title"):
        lab += f" - {i['title']}"
    return lab


def save_image(data_or_path, dst_base):
    """Validate an image and write it as JPEG/PNG. Returns written path or None."""
    try:
        if isinstance(data_or_path, (bytes, bytearray)):
            import io
            src = io.BytesIO(data_or_path)
        else:
            src = data_or_path
        with Image.open(src) as im:
            fmt = (im.format or "").upper()
            im.load()
            if fmt in ("JPEG", "PNG") and im.mode in ("L", "RGB", "P", "LA", "RGBA", "1") and not getattr(im, "is_animated", False):
                ext = ".jpg" if fmt == "JPEG" else ".png"
                out = dst_base + ext
                if isinstance(data_or_path, (bytes, bytearray)):
                    with open(out, "wb") as f:
                        f.write(data_or_path)
                else:
                    shutil.copyfile(data_or_path, out)
                return out
            if getattr(im, "is_animated", False):
                im.seek(0)
            if im.mode in ("RGBA", "LA", "P"):
                im = im.convert("RGBA")
                bg = Image.new("RGB", im.size, "white")
                bg.paste(im, mask=im.split()[-1])
                im = bg
            elif im.mode not in ("RGB", "L"):
                im = im.convert("RGB")
            out = dst_base + ".png" if im.mode == "L" else dst_base + ".jpg"
            if out.endswith(".png"):
                im.save(out, "PNG", optimize=False)
            else:
                im.save(out, "JPEG", quality=92)
            return out
    except Exception as e:
        log(f"  ! skipped unreadable image {dst_base}: {e}")
        return None


def epub_order(z):
    """Image entries of an EPUB in reading (spine) order; falls back to natural order."""
    try:
        cont = ET.fromstring(z.read("META-INF/container.xml"))
        opf_path = cont.find(".//{*}rootfile").get("full-path")
        opf = ET.fromstring(z.read(opf_path))
        base = os.path.dirname(opf_path)
        manifest = {it.get("id"): it.get("href") for it in opf.iter("{*}item")}
        names = set(z.namelist())
        order = []
        for ref in opf.iter("{*}itemref"):
            href = manifest.get(ref.get("idref"))
            if not href:
                continue
            doc_path = os.path.normpath(os.path.join(base, href)).replace("\\", "/")
            if doc_path not in names:
                continue
            html = z.read(doc_path).decode("utf-8", "ignore")
            for src in re.findall(r'(?:src|xlink:href|href)\s*=\s*["\']([^"\']+)["\']', html):
                p = os.path.normpath(os.path.join(os.path.dirname(doc_path), src.split("#")[0])).replace("\\", "/")
                if p in names and is_image_name(p) and p not in order:
                    order.append(p)
        if order:
            return order
    except Exception:
        pass
    return os_sorted([n for n in z.namelist() if is_image_name(n)])


def extract_unit(item, dst):
    """Extract all pages of one chapter into dst as 0001.jpg, 0002.png, ..."""
    os.makedirs(dst, exist_ok=True)
    path = Path(item["path"])
    n = 0

    def put(src):
        nonlocal n
        if save_image(src, os.path.join(dst, f"{n + 1:04d}")):
            n += 1

    if item["kind"] == "dir":
        for p in dir_images(path):
            put(p)
        return n
    ext = path.suffix.lower()
    if ext in ARCHIVE_ZIP:
        with zipfile.ZipFile(path) as z:
            names = epub_order(z) if ext == ".epub" else os_sorted([x for x in z.namelist() if is_image_name(x)])
            for name in names:
                put(z.read(name))
        return n
    if ext in PDF:
        import pymupdf as fitz
        with fitz.open(path) as doc:
            for page in doc:
                imgs = page.get_images(full=True)
                done = False
                if len(imgs) == 1:
                    try:
                        bbox = page.get_image_bbox(imgs[0])
                        if bbox.width * bbox.height >= 0.85 * page.rect.width * page.rect.height:
                            data = doc.extract_image(imgs[0][0])
                            if data and data.get("image") and data.get("height", 0) >= 800:
                                put(data["image"])
                                done = True
                    except Exception:
                        pass
                if not done:
                    zoom = PDF_RENDER_HEIGHT / max(page.rect.height, 1)
                    pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
                    put(pix.tobytes("png"))
        return n
    # RAR / 7z / tar via libarchive (bsdtar ships with macOS)
    with tempfile.TemporaryDirectory(prefix="mk-x-") as tmp:
        r = subprocess.run(["bsdtar", "-xf", str(path), "-C", tmp], capture_output=True, text=True)
        if r.returncode != 0:
            log(f"  ! bsdtar: {r.stderr.strip()[:300]}")
        for p in dir_images(tmp):
            put(p)
    return n


# ---------------------------------------------------------------- build

def kcc_cmd(opts, src, outdir):
    kcc_fmt = "CBZ" if opts.get("format", "").lower() == "pdf" else "MOBI"   # PDF: processed pages, then pdfbook.py
    cmd = [sys.executable, str(KCC_DIR / "kcc-c2e.py"), "-p", opts.get("profile", PROFILE), "-f", kcc_fmt,
           "-t", opts["title"], "-o", str(outdir)]
    if opts.get("author"):
        cmd += ["-a", opts["author"]]
    if opts.get("manga", True):
        cmd.append("-m")
    if opts.get("webtoon"):
        cmd.append("-w")
    if opts.get("upscale", True):
        cmd.append("-u")
    # Best image for Paperwhite 11th gen (16-gray e-ink): lossless pages already reduced to the
    # screen's 16 grays (KCC "PNG" mode, stored as GIF inside AZW3) — sharper and usually smaller than JPEG.
    image_mode = opts.get("imageMode", "best")
    if image_mode == "best" and not opts.get("webtoon"):
        cmd.append("--forcepng")
    else:
        cmd += ["--mozjpeg", "--jpeg-quality", str(int(opts.get("jpegQuality") or 90))]
    # double-page spreads: split into halves / rotate whole / both (rotated spread first, then the halves)
    spreads = {"split": "0", "rotate": "1", "both": "2"}.get(opts.get("spreads", "both"), "2")
    if not opts.get("webtoon"):
        cmd += ["-r", spreads]
    # crop strength for white margins + page numbers (KCC cropping mode 2)
    cmd += ["--cp", {"normal": "1.0", "strong": "1.5"}.get(opts.get("crop", "strong"), "1.5")]
    # border colour for the space around the page
    borders = opts.get("borders", "auto")
    if borders == "black":
        cmd.append("--blackborders")
    elif borders == "white":
        cmd.append("--whiteborders")
    # page tone: gamma > 1 darkens midtones (faded scans), < 1 lightens (very dark scans)
    tone = {"darker": "1.3", "lighter": "0.8"}.get(opts.get("tone", "auto"))
    if tone:
        cmd += ["-g", tone]
    if opts.get("autolevel", True):
        cmd.append("--autolevel")  # deep blacks on faded scans
    if opts.get("hq"):
        cmd.append("--hq")  # 1.5x pages for sharper Panel View zoom (about 2x file size)
    if opts.get("split"):
        cmd += ["-b", "1", "--ts", str(opts.get("targetSize", 400))]
    else:
        cmd += ["-b", "0"]
    cmd += [str(src)]
    return cmd


def run_kcc(opts, src, outdir):
    env = dict(os.environ)
    env["PATH"] = f"{BIN_DIR}:{env.get('PATH', '')}:/usr/local/bin:/opt/homebrew/bin"
    cmd = kcc_cmd(opts, src, outdir)
    log("$ " + " ".join(f'"{c}"' if " " in c else c for c in cmd))
    # Cap KCC's worker pools (default = every core + 4 parallel kindlegens) and run it at
    # low priority: full-CPU conversions overheat this Intel MacBook and preceded its
    # display drop-outs / WindowServer crashes (2026-10-03/04). MK_KCC_PROCS overrides.
    procs = max(1, int(os.environ.get("MK_KCC_PROCS", "2")))
    cap = (f"import multiprocessing as m, os, sys, runpy; n={procs}; os.cpu_count = m.cpu_count = lambda: n; "
           "P = m.Pool; m.Pool = lambda processes=None, *a, **k: P(min(processes or n, n), *a, **k); "
           "sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name='__main__')")
    cmd = ["/usr/bin/nice", "-n", "10", cmd[0], "-c", cap] + cmd[1:]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
                         cwd=str(KCC_DIR), errors="replace")
    out = []
    for line in p.stdout:
        line = line.rstrip()
        out.append(line)
        if line:
            log("  kcc: " + line)
    p.wait()
    return p.returncode, "\n".join(out)


def build(plan):
    global LOG_FILE
    opts = plan["options"]
    title = safe_name(opts["title"], 120)
    try:
        logdir = Path.home() / "Library/Logs/MangaToKindle"
        logdir.mkdir(parents=True, exist_ok=True)
        LOG_FILE = open(logdir / f"{time.strftime('%Y-%m-%d %H-%M-%S')} {title}.log", "w")
        LOG_FILE.write(json.dumps(opts, ensure_ascii=False) + "\n")
    except Exception:
        LOG_FILE = None
    opts["title"] = title
    items = [i for i in plan["items"] if i.get("selected")]
    if not items:
        emit("error", message="No chapters selected.")
        return 2
    outdir = Path(opts.get("outputDir") or "~/Documents/Kindle").expanduser()
    outdir.mkdir(parents=True, exist_ok=True)
    fmt = opts.get("format", "azw3").lower()

    work = Path(tempfile.mkdtemp(prefix="mangakindle-"))
    book = work / title
    book.mkdir()
    try:
        # 1) unpack every chapter into its own ordered folder (KCC turns folders into the table of contents)
        labels, used = [], set()
        for idx, it in enumerate(items):
            lab = safe_name(chapter_label(it), 90)
            while lab.lower() in used:
                lab += " (2)"
            used.add(lab.lower())
            labels.append(lab)
        # folder names must sort naturally in exactly our order, else prefix them
        if os_sorted(labels) != labels:
            labels = [f"{n + 1:04d} {lab}" for n, lab in enumerate(labels)]
            log("Chapter names don't sort naturally; numbered prefixes added to keep the order.")
        total = len(items)
        emit("stage", stage="extract", message=f"Merging {total} chapters")
        done = 0
        pages_total = 0
        problems = []

        def job(a):
            it, lab = a
            return it, lab, extract_unit(it, str(book / lab))

        with ThreadPoolExecutor(min(6, os.cpu_count() or 4)) as ex:
            for it, lab, n in ex.map(job, zip(items, labels)):
                done += 1
                pages_total += n
                if n == 0:
                    problems.append(it["name"])
                    shutil.rmtree(book / lab, ignore_errors=True)
                emit("progress", stage="extract", done=done, total=total, message=f"{lab} ({n} pages)")
        if problems:
            log("No readable pages in: " + "; ".join(problems))
        if pages_total == 0:
            emit("error", message="No pages could be read from the selected files.")
            return 3
        log(f"Merged {pages_total} pages from {total - len(problems)} chapters.")

        results = []
        # 2) optional merged CBZ (one file with chapter folders)
        if opts.get("keepCbz"):
            emit("stage", stage="cbz", message="Writing merged CBZ")
            cbz = unique_path(outdir / f"{title}.cbz")
            with zipfile.ZipFile(cbz, "w", zipfile.ZIP_STORED) as z:
                for lab in os_sorted(os.listdir(book)):
                    for f in os_sorted(os.listdir(book / lab)):
                        z.write(book / lab / f, f"{lab}/{f}")
            results.append(str(cbz))
            log(f"Merged CBZ: {cbz}")

        # 3) Kindle Comic Converter -> MOBI (KF8), renamed to .azw3 if asked
        emit("stage", stage="kcc", message=f"Converting with KCC ({opts.get('profile', PROFILE)})")
        kcc_out = work / "out"
        kcc_out.mkdir()
        code, text = run_kcc(opts, book, kcc_out)
        if fmt == "pdf":
            return finish_pdf(opts, code, text, kcc_out, outdir, results, pages_total, total, problems)
        made = sorted(kcc_out.glob("*.mobi"))
        if (code != 0 or not made) and not opts.get("split") and ("23026" in text or "too big" in text.lower()
                                                                    or "EPUB too big" in text):
            log("Book is too large for a single Kindle file; splitting into parts automatically.")
            emit("stage", stage="kcc", message="Too big for one file — splitting into parts")
            opts["split"] = True
            for f in kcc_out.iterdir():
                f.unlink()
            code, text = run_kcc(opts, book, kcc_out)
            made = sorted(kcc_out.glob("*.mobi"))
        if (code != 0 or not made) and "Conversion interrupted" not in text:
            log("KCC failed — retrying once.")
            emit("stage", stage="kcc", message="Retrying conversion")
            for f in kcc_out.iterdir():
                f.unlink()
            code, text = run_kcc(opts, book, kcc_out)
            made = sorted(kcc_out.glob("*.mobi"))
        if code != 0 or not made:
            lines = [l.strip() for l in text.splitlines() if l.strip()]
            cause = [l for l in lines if "Cause:" in l or l.startswith(("RuntimeError", "UserWarning", "OSError", "MemoryError", "Error"))]
            reason = cause[-1] if cause else (lines[-1] if lines else "no output")
            emit("error", message=f"Kindle Comic Converter failed (exit {code}): {reason[:400]}"
                                  + (f"\nFull log: {LOG_FILE.name}" if LOG_FILE else ""))
            return 4
        for f in os_sorted(made, key=lambda p: p.name):
            outs = []
            if fmt in ("azw3", "both"):
                dst = unique_path(outdir / (f.stem + ".azw3"))
                if to_kf8(f, dst):  # real AZW3: just the KF8 half of KCC's dual MOBI
                    outs.append(dst)
                elif fmt == "azw3":
                    shutil.copyfile(f, dst)
                    outs.append(dst)
            if fmt == "kfx":
                # KFX: Kindle's native format — sideloaded AZW3/MOBI comics show ghosting / white borders on
                # firmware 5.19.2+ (older Kindles never got the fix); see kfx.py
                kf8 = f.with_suffix(".kf8.azw3")
                src = kf8 if to_kf8(f, kf8) else f
                dst = unique_path(outdir / (f.stem + ".kfx"))
                emit("stage", stage="kfx", message=f"Making KFX: {f.stem}")
                try:
                    sys.path.insert(0, str(HERE))
                    import kfx
                    n = kfx.convert(src, dst, title=f.stem, direction="rtl" if opts.get("manga", True) else "ltr")
                    log(f"  KFX: {n} pages")
                    outs.append(dst)
                except Exception as e:
                    emit("error", message=f"Making the KFX file failed: {e}")
                    return 5
                finally:
                    kf8.unlink(missing_ok=True)
            if fmt in ("mobi", "both"):
                dst = unique_path(outdir / (f.stem + ".mobi"))
                shutil.copyfile(f, dst)  # KCC's dual MOBI (MOBI + KF8 inside)
                outs.append(dst)
            for dst in outs:
                results.append(str(dst))
                log(f"Kindle file: {dst}  ({dst.stat().st_size / 1048576:.1f} MB)")
        emit("done", files=results, pages=pages_total, chapters=total - len(problems), skipped=problems)
        return 0
    finally:
        if not os.environ.get("MK_KEEP_WORK"):
            shutil.rmtree(work, ignore_errors=True)


def finish_pdf(opts, code, text, kcc_out, outdir, results, pages_total, total, problems):
    """KCC's processed CBZ -> lossless PDF(s) with a chapter list, for KOReader (and the Kindle's PDF reader)."""
    made = sorted(kcc_out.glob("*.cbz"))
    if code != 0 or not made:
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        emit("error", message=f"Kindle Comic Converter failed (exit {code}): {(lines[-1] if lines else 'no output')[:400]}")
        return 4
    sys.path.insert(0, str(HERE))
    import pdfbook
    emit("stage", stage="pdf", message="Writing PDF")
    files = pdfbook.cbz_to_pdf(made[0], outdir, opts["title"], author=opts.get("author") or "",
                               progress=lambda d, t: emit("progress", stage="pdf", done=d, total=t, message=f"{d}/{t} pages"))
    for f in files:
        results.append(str(f))
        log(f"Kindle file: {f}  ({f.stat().st_size / 1048576:.1f} MB)")
    emit("done", files=results, pages=pages_total, chapters=total - len(problems), skipped=problems)
    return 0


def to_kf8(src, dst):
    """Write only the KF8 (AZW3) part of a dual MOBI. Falls back to the dual file if that fails."""
    try:
        sys.path.insert(0, str(HERE))
        from kindleunpack import mobi_split
        ms = mobi_split.mobi_split(str(src))
        data = ms.getResult8() if ms.combo else None
        if not data:
            return False
        with open(dst, "wb") as f:
            f.write(data)
        return True
    except Exception as e:
        log(f"  ! AZW3 split failed ({e}); keeping the dual MOBI/AZW3 file")
        return False


def unique_path(p):
    p = Path(p)
    if not p.exists():
        return p
    n = 2
    while True:
        q = p.with_name(f"{p.stem} ({n}){p.suffix}")
        if not q.exists():
            return q
        n += 1


def check():
    st = {"python": sys.version.split()[0], "kcc": (KCC_DIR / "kcc-c2e.py").exists()}
    kg = BIN_DIR / "kindlegen"
    st["kindlegen"] = kg.exists() and os.access(kg, os.X_OK)
    st["bsdtar"] = shutil.which("bsdtar") is not None
    try:
        import pymupdf  # noqa
        st["pymupdf"] = True
    except Exception:
        st["pymupdf"] = False
    try:
        r = subprocess.run([sys.executable, str(KCC_DIR / "kcc-c2e.py"), "--help"], capture_output=True, text=True, timeout=60)
        m = re.search(r"v(\d+\.\d+\.\d+)", r.stdout)
        st["kccVersion"] = m.group(1) if m else None
    except Exception:
        st["kccVersion"] = None
    print(json.dumps(st))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == "scan":
        args = sys.argv[2:]
        lang = None
        if "--lang" in args:
            k = args.index("--lang")
            lang = args[k + 1]
            del args[k:k + 2]
        res = scan(args, lang)
        res["missing"] = gaps(res["items"])
        print(json.dumps(res, ensure_ascii=False))
        return 0
    if cmd == "build":
        with open(sys.argv[2]) as f:
            plan = json.load(f)
        return build(plan)
    if cmd == "check":
        check()
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
