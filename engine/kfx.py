#!/usr/bin/env python3
"""AZW3/MOBI (made by KCC) -> KFX, Kindle's native format.

Kindle firmware 5.19.2 broke sideloaded AZW3/MOBI comics (page refresh / ghosting, white borders, no page-turn
animation) and the fix (5.19.6) never reached older devices such as the Paperwhite 11th gen. KFX takes a
different rendering path that works.

The KFX writer is HankunYu/kindle-comic-workaround-5.19.x (no license, so it is not bundled in this repo —
setup.sh clones it into kfx-tool/). kindlegen stores lossless pages as GIF, which that writer skips, so pages
are turned back into PNG first (lossless).

  kfx.py <book.azw3|.mobi> <out.kfx> [--title T] [--direction rtl|ltr] [--language en]
"""
import argparse
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def tool_dir():
    for d in (os.environ.get("MK_KFX_DIR"), HERE.parent / "kfx", HERE.parent / "kfx-tool",
              Path.home() / "MangaKindle" / "kfx-tool"):
        if d and (Path(d) / "kpf_generator.py").exists():
            return Path(d)
    raise FileNotFoundError("KFX writer not found — run setup.sh (clones kindle-comic-workaround-5.19.x into kfx-tool/)")


def convert(src, dst, title="", direction="rtl", language="en"):
    sys.path.insert(0, str(tool_dir()))
    from PIL import Image
    from mobi_images import extract_images_from_mobi, read_mobi_metadata
    from convert import run_kfx_generation
    with tempfile.TemporaryDirectory(prefix="mk-kfx-") as d:
        n = extract_images_from_mobi(str(src), d)
        if not n:
            raise RuntimeError("no page images found in " + str(src))
        for f in sorted(os.listdir(d)):
            if f.lower().endswith(".gif"):
                p = os.path.join(d, f)
                with Image.open(p) as im:
                    im.save(p[:-4] + ".png")
                os.unlink(p)
        meta = read_mobi_metadata(str(src)) or {}
        tmp = str(dst) + ".part"
        run_kfx_generation(d, tmp, title=title or meta.get("title") or Path(src).stem,
                           author=meta.get("author") or "", reading_direction=direction, language=language)
        os.replace(tmp, dst)
    return n


def main():
    a = argparse.ArgumentParser()
    a.add_argument("src")
    a.add_argument("dst")
    a.add_argument("--title", default="")
    a.add_argument("--direction", default="rtl", choices=["rtl", "ltr"])
    a.add_argument("--language", default="en")
    o = a.parse_args()
    n = convert(o.src, o.dst, o.title, o.direction, o.language)
    print(f"{n} pages -> {o.dst} ({os.path.getsize(o.dst) / 1048576:.1f} MB)")


if __name__ == "__main__":
    main()
