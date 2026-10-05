#!/usr/bin/env python3
"""Search and get ebooks (not manga) for the Kindle's own reader, as AZW3.

Sources (all legal):
  Standard Ebooks   — carefully produced public-domain books; they publish a ready AZW3
  Project Gutenberg — ~75k public-domain books (via the Gutendex API); EPUB converted to AZW3 with calibre
  Calibre library   — the user's own ~/Calibre Library (AZW3 used as is, other formats converted)

  books.py search "<query>" [lang]     -> JSON list
  books.py get '<result json>'         -> '@@{json}' progress lines, then a done line with the AZW3 path
"""
import concurrent.futures as cf
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

UA = "MangaToKindle/1.0 (+https://github.com/R1tom/Manga-to-Kindle-macOS)"
CALIBRE_LIB = Path(os.environ.get("MK_CALIBRE_LIBRARY", Path.home() / "Calibre Library"))
EBOOK_CONVERT = os.environ.get("MK_EBOOK_CONVERT", "/Applications/calibre.app/Contents/MacOS/ebook-convert")
DOWNLOADS = Path(os.environ.get("MK_BOOK_DOWNLOADS", Path.home() / "Documents/Books"))
OUTPUT = Path(os.environ.get("MK_BOOK_OUTPUT", Path.home() / "Documents/Kindle/Books"))
PROFILE = "kindle_pw3"          # 1072x1448-class Paperwhite profile (closest calibre has to the Paperwhite 11th gen)


def emit(kind, **d):
    print("@@" + json.dumps({"type": kind, **d}, ensure_ascii=False), flush=True)


def fetch(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def author_name(a):
    # Gutenberg: "Austen, Jane" -> "Jane Austen"
    if "," in a:
        last, first = a.split(",", 1)
        return f"{first.strip()} {last.strip()}".strip()
    return a.strip()


# ------------------------------------------------------------------ search

def search_standard(q):
    url = "https://standardebooks.org/feeds/opds/all?" + urllib.parse.urlencode({"query": q, "per-page": 24})
    ns = {"a": "http://www.w3.org/2005/Atom", "dc": "http://purl.org/dc/elements/1.1/"}
    root = ET.fromstring(fetch(url))
    out = []
    for e in root.findall("a:entry", ns):
        links = {(l.get("rel") or "", l.get("type") or ""): l.get("href") for l in e.findall("a:link", ns)}
        azw3 = next((h for (r, t), h in links.items() if t == "application/x-mobipocket-ebook"), None)
        epub = next((h for (r, t), h in links.items() if t == "application/epub+zip" and "_advanced" not in h), None)
        cover = links.get(("http://opds-spec.org/image/thumbnail", "image/jpeg")) or links.get(("http://opds-spec.org/image", "image/jpeg"))
        year = (e.findtext("dc:issued", "", ns) or "")[:4]
        out.append({"source": "Standard Ebooks", "id": e.findtext("a:id", "", ns), "title": e.findtext("a:title", "", ns),
                    "author": e.findtext("a:author/a:name", "", ns), "year": year, "cover": cover, "azw3": azw3, "epub": epub,
                    "language": (e.findtext("dc:language", "", ns) or "en")[:2], "downloads": None,
                    "note": "Carefully formatted edition"})
    return out


OTHER_LANGS = {"Finnish", "German", "French", "Spanish", "Italian", "Dutch", "Portuguese", "Swedish", "Danish", "Norwegian",
               "Esperanto", "Chinese", "Japanese", "Latin", "Greek", "Russian", "Polish", "Hungarian", "Czech", "Tagalog",
               "Catalan", "Welsh", "Icelandic", "Hebrew", "Arabic", "Romanian", "Galician", "Bulgarian", "Afrikaans", "Korean"}


def search_gutenberg(q, lang="en"):
    """Project Gutenberg's own OPDS search (fast; Gutendex often times out). Results come in popularity order."""
    url = "https://www.gutenberg.org/ebooks/search.opds/?" + urllib.parse.urlencode({"query": q})
    ns = {"a": "http://www.w3.org/2005/Atom"}
    root = ET.fromstring(fetch(url, timeout=20))
    out = []
    for e in root.findall("a:entry", ns):
        m = re.search(r"/ebooks/(\d+)\.opds", e.findtext("a:id", "", ns))
        if not m:
            continue                      # "sort by…" and other navigation entries
        gid = m.group(1)
        title = e.findtext("a:title", "", ns)
        # Gutenberg marks other-language editions in the title: "… (Finnish)"
        lm = re.search(r"\(([A-Z][a-z]+)\)\s*$", title)
        if lang == "en" and lm and lm.group(1) in OTHER_LANGS:
            continue
        out.append({"source": "Project Gutenberg", "id": gid, "title": title,
                    "author": (e.findtext("a:content", "", ns) or "").strip(), "year": "",
                    "cover": f"https://www.gutenberg.org/cache/epub/{gid}/pg{gid}.cover.medium.jpg", "azw3": None,
                    "epub": f"https://www.gutenberg.org/ebooks/{gid}.epub3.images", "language": lang or "en",
                    "downloads": None, "note": f"gutenberg.org/ebooks/{gid}"})
    return out


def search_calibre(q):
    db = CALIBRE_LIB / "metadata.db"
    if not db.exists():
        return []
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    toks = norm(q).split()
    rows = con.execute("""
        SELECT b.id, b.title, b.path, b.has_cover, b.pubdate,
               (SELECT group_concat(a.name, ', ') FROM authors a JOIN books_authors_link l ON l.author = a.id WHERE l.book = b.id),
               (SELECT group_concat(d.format || ':' || d.name, '|') FROM data d WHERE d.book = b.id)
        FROM books b""").fetchall()
    con.close()
    out = []
    for bid, title, path, has_cover, pub, authors, data in rows:
        hay = norm(f"{title} {authors}")
        if not all(t in hay for t in toks):
            continue
        fmts = dict(x.split(":", 1) for x in (data or "").split("|") if ":" in x)
        folder = CALIBRE_LIB / path
        files = {k.upper(): str(folder / f"{v}.{k.lower()}") for k, v in fmts.items()}
        if not any(k in files for k in ("AZW3", "EPUB", "MOBI", "AZW", "DOCX", "PDF", "TXT")):
            continue
        out.append({"source": "Calibre library", "id": str(bid), "title": title, "author": authors or "",
                    "year": (pub or "")[:4], "cover": str(folder / "cover.jpg") if has_cover else None,
                    "files": files, "language": "", "downloads": None, "note": ", ".join(sorted(files))})
    return out


def search(q, lang="en"):
    results, errors = [], []
    with cf.ThreadPoolExecutor(3) as ex:
        futs = {ex.submit(search_standard, q): "Standard Ebooks", ex.submit(search_gutenberg, q, lang): "Project Gutenberg",
                ex.submit(search_calibre, q): "Calibre library"}
        for f in cf.as_completed(futs):
            try:
                results += f.result()
            except Exception as e:
                errors.append(f"{futs[f]}: {e}")
    nq = norm(q)
    rank_src = {"Calibre library": 0, "Standard Ebooks": 1, "Project Gutenberg": 2}

    def score(r):
        t = norm(r["title"])
        s = 100 if t == nq else 80 if t.startswith(nq) else 60 if nq in t else 40
        return (-s, rank_src[r["source"]])
    results.sort(key=score)
    # one entry per book: Standard Ebooks' edition beats Gutenberg's copies of the same title+author
    seen, deduped = set(), []
    for r in results:
        key = (norm(r["title"]), norm(r["author"]).split(" ")[-1] if r.get("author") else "")
        if r["source"] != "Calibre library" and key in seen:
            continue
        seen.add(key)
        deduped.append(r)
    return {"results": deduped, "errors": errors}


# ------------------------------------------------------------------ get

def safe(s, limit=90):
    s = re.sub(r'[\\/:*?"<>|\x00-\x1f]', " ", s or "")
    return re.sub(r"\s+", " ", s).strip(" .")[:limit] or "Book"


def download(url, dst):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=120) as r, open(str(dst) + ".part", "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        done = 0
        while chunk := r.read(1 << 16):
            f.write(chunk)
            done += len(chunk)
            emit("progress", stage="download", done=done, total=total)
    os.replace(str(dst) + ".part", dst)


def convert(src, dst, item, cover=None):
    """Any ebook -> AZW3 for the Kindle's own reader (calibre, Paperwhite profile, metadata + cover kept)."""
    if not Path(EBOOK_CONVERT).exists():
        raise RuntimeError("calibre isn't installed (needed to make AZW3 files): https://calibre-ebook.com")
    cmd = [EBOOK_CONVERT, str(src), str(dst), "--output-profile", PROFILE,
           "--title", item["title"], "--authors", (item.get("author") or "Unknown").replace(", ", " & ")]
    if cover and Path(cover).exists():
        cmd += ["--cover", str(cover)]
    emit("stage", stage="convert", message="Converting to AZW3 (Kindle format)")
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0 or not Path(dst).exists():
        tail = (p.stderr or p.stdout).strip().splitlines()[-3:]
        raise RuntimeError("calibre couldn't convert it: " + " ".join(tail)[:300])


def get(item):
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    name = safe(f"{item['title']} - {item['author']}" if item.get("author") else item["title"])
    out = OUTPUT / f"{name}.azw3"
    src = item["source"]
    if src == "Standard Ebooks" and item.get("azw3"):
        emit("stage", stage="download", message="Downloading AZW3 from Standard Ebooks")
        download(item["azw3"], out)                       # their own Kindle build — no conversion needed
        shutil.copyfile(out, DOWNLOADS / out.name)
    elif src == "Calibre library":
        files = item["files"]
        if "AZW3" in files:
            emit("stage", stage="download", message="Copying AZW3 from your Calibre library")
            shutil.copyfile(files["AZW3"], out)
        else:
            fmt = next(k for k in ("EPUB", "MOBI", "AZW", "DOCX", "TXT", "PDF") if k in files)
            convert(files[fmt], out, item, item.get("cover"))
    else:
        emit("stage", stage="download", message=f"Downloading EPUB from {src}")
        epub = DOWNLOADS / f"{name}.epub"
        download(item["epub"], epub)
        cover = None
        if item.get("cover"):
            try:
                cover = Path(tempfile.mkdtemp(prefix="mk-cover-")) / "cover.jpg"
                cover.write_bytes(fetch(item["cover"]))
            except Exception:
                cover = None
        convert(epub, out, item, cover)
    size = out.stat().st_size
    emit("done", files=[str(out)], title=item["title"], author=item.get("author", ""), size=size)
    return 0


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 1
    if a[0] == "search":
        print(json.dumps(search(a[1], a[2] if len(a) > 2 else "en"), ensure_ascii=False))
        return 0
    if a[0] == "get":
        try:
            return get(json.loads(a[1]))
        except Exception as e:
            emit("error", message=str(e))
            return 2
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
