#!/usr/bin/env python3
"""Processed comic pages (KCC CBZ) -> lossless PDF with a chapter list (bookmarks).

For KOReader on a jailbroken Kindle (right-to-left, full refresh every page) and as a fallback for the Kindle's
own PDF reader, which does a full refresh on every page turn — sideloaded AZW3/MOBI/KFX comics ghost on
firmware 5.19.2. Pages are embedded as they are (PNG stays PNG, JPEG stays JPEG). Big books are split at chapter
boundaries (FAT32 on the Kindle can't hold files over 4 GB; smaller files also open faster).

  pdfbook.py <book.cbz> <out_dir> <title>
"""
import io
import re
import sys
import zipfile
from pathlib import Path

PART_BYTES = 1500 * 1024 * 1024
IMG = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff")


def natural(s):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


def chapter_of(name):
    parts = Path(name).parts
    if len(parts) < 2:
        return ""
    # KCC nests chapter folders; the last folder above the page is the chapter
    return parts[-2]


def cbz_to_pdf(cbz, out_dir, title, author="", progress=None):
    import pymupdf as fitz
    from PIL import Image
    out_dir = Path(out_dir)
    with zipfile.ZipFile(cbz) as z:
        names = sorted((n for n in z.namelist() if n.lower().endswith(IMG) and not Path(n).name.startswith(".")
                        and "__MACOSX" not in n), key=natural)
        sizes = {n: z.getinfo(n).file_size for n in names}
        # group pages by chapter, keep order
        chapters = []
        for n in names:
            c = chapter_of(n)
            if not chapters or chapters[-1][0] != c:
                chapters.append([c, []])
            chapters[-1][1].append(n)
        # split into parts at chapter boundaries
        parts, cur, cur_size = [], [], 0
        for c in chapters:
            csize = sum(sizes[n] for n in c[1])
            if cur and cur_size + csize > PART_BYTES:
                parts.append(cur)
                cur, cur_size = [], 0
            cur.append(c)
            cur_size += csize
        if cur:
            parts.append(cur)
        files, done, total = [], 0, len(names)
        for pi, part in enumerate(parts, 1):
            name = title if len(parts) == 1 else f"{title} {pi}"
            dst = unique(out_dir / f"{safe(name)}.pdf")
            doc = fitz.open()
            toc = []
            for label, pages in part:
                if label:
                    toc.append([1, pretty(label), doc.page_count + 1])
                for n in pages:
                    data = z.read(n)
                    ext = Path(n).suffix.lower()
                    if ext not in (".png", ".jpg", ".jpeg"):
                        buf = io.BytesIO()
                        Image.open(io.BytesIO(data)).save(buf, "PNG")
                        data = buf.getvalue()
                    with Image.open(io.BytesIO(data)) as im:
                        w, h = im.size
                    page = doc.new_page(width=w * 72 / 300, height=h * 72 / 300)
                    page.insert_image(page.rect, stream=data)
                    done += 1
                    if progress and done % 25 == 0:
                        progress(done, total)
            if toc:
                doc.set_toc(toc)
            doc.set_metadata({"title": name, "author": author or "Manga to Kindle"})
            tmp = dst.with_suffix(".pdf.part")
            doc.save(tmp, garbage=3, deflate=True)
            doc.close()
            tmp.replace(dst)
            files.append(dst)
        if progress:
            progress(total, total)
    return files


def pretty(label):
    # KCC prefixes folders with sort keys like "0003_Chapter 3 - Title"; keep the readable part
    label = re.sub(r"^\d{3,}[_ -]+", "", label).strip() or label
    # "Chapter 0002" -> "Chapter 2" (numbers are zero-padded for sorting)
    return re.sub(r"\b(Chapter|Ch\.?|Vol(?:ume)?\.?)\s*0+(\d)", r"\1 \2", label)


def safe(s):
    return re.sub(r'[\\/:*?"<>|\x00-\x1f]', " ", s).strip() or "Manga"


def unique(p):
    if not p.exists():
        return p
    i = 2
    while True:
        q = p.with_name(f"{p.stem} ({i}){p.suffix}")
        if not q.exists():
            return q
        i += 1


if __name__ == "__main__":
    for f in cbz_to_pdf(sys.argv[1], sys.argv[2], sys.argv[3]):
        print(f)
