"""Send books to a connected Kindle with calibre's own Kindle driver (same path as calibre's "Send to device").

Run with calibre's interpreter:
  calibre-debug -e calibre_send.py -- detect
  calibre-debug -e calibre_send.py -- send <author> <file>...
Machine-readable lines start with '@@' + JSON.
"""
import json
import os
import sys


def emit(kind, **d):
    print("@@" + json.dumps({"type": kind, **d}, ensure_ascii=False), flush=True)


def open_device():
    from calibre.customize.ui import device_plugins, disabled_device_plugins
    from calibre.devices.scanner import DeviceScanner
    scanner = DeviceScanner()
    scanner.scan()
    disabled = {p.name for p in disabled_device_plugins()}
    for dev in device_plugins():
        if dev.name in disabled:
            continue
        try:
            ok, det = scanner.is_device_connected(dev)
        except Exception:
            continue
        if not ok:
            continue
        try:
            dev.reset(detected_device=det)
            dev.open(det, None)
            return dev
        except Exception as e:
            emit("log", message=f"{dev.name}: {e}")
    return None


def detect():
    dev = open_device()
    if not dev:
        emit("device", found=False)
        return 1
    info = dev.get_device_information()
    total = dev.total_space()[0]
    free = dev.free_space()[0]
    emit("device", found=True, driver=dev.name, name=info[0], mount=getattr(dev, "_main_prefix", None),
         total=total, free=free)
    return 0


def send(author, files):
    from calibre.ebooks.metadata.meta import get_metadata, set_metadata
    dev = open_device()
    if not dev:
        emit("error", message="calibre can't see a Kindle. Plug it in (and close calibre if it's open).")
        return 2
    emit("device", found=True, driver=dev.name, name=dev.get_device_information()[0], mount=getattr(dev, "_main_prefix", None))
    import shutil
    import tempfile
    tmp = tempfile.mkdtemp(prefix="mk-calibre-")
    paths, names, metas = [], [], []
    for f in files:
        ext = os.path.splitext(f)[1].lower().lstrip(".")
        # work on a copy so the file in ~/Documents/Kindle is never changed
        p = os.path.join(tmp, os.path.basename(f))
        shutil.copyfile(f, p)
        with open(p, "rb") as s:
            mi = get_metadata(s, ext)
        if author:
            mi.authors = [author]
            mi.author_sort = author
        if not mi.title or mi.title.lower() == "unknown":
            mi.title = os.path.splitext(os.path.basename(f))[0]
        with open(p, "r+b") as s:  # what calibre's GUI does before uploading
            set_metadata(s, mi, stream_type=ext)
        if mi.cover_data and mi.cover_data[1]:
            from calibre.utils.img import scale_image
            data = mi.cover_data[1]
            w, h, thumb = scale_image(data, width=330, height=470)
            mi.thumbnail = (w, h, thumb)
        paths.append(p)
        names.append(os.path.basename(f))
        metas.append(mi)
        emit("progress", stage="prepare", file=os.path.basename(f))
    booklists = (dev.books(), None, None)
    locations = dev.upload_books(paths, names, on_card=None, end_session=False, metadata=metas)
    dev.add_books_to_metadata(locations, metas, booklists)
    dev.sync_booklists(booklists, end_session=True)
    shutil.rmtree(tmp, ignore_errors=True)
    out = [loc[0] if isinstance(loc, (tuple, list)) else str(loc) for loc in locations]
    emit("done", files=out)
    return 0


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    if argv[0] == "detect":
        return detect()
    if argv[0] == "send":
        return send(argv[1], argv[2:])
    print(__doc__)
    return 1


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--":
        args = args[1:]
    sys.exit(main(args))
