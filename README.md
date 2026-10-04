# Manga to Kindle (macOS)

A native SwiftUI Mac app that searches and downloads manga (driving [HaruNeko](https://github.com/manga-download/haruneko) hidden in
the background), merges the chapters in order into one book, converts it with [Kindle Comic Converter](https://github.com/ciromattia/kcc)
for the Kindle Paperwhite 11th gen (lossless 16-gray AZW3), and copies it to the Kindle over USB.

## Features
- Search every HaruNeko source at once; sources ranked by how many chapters they have in your language.
- Download → convert → send to Kindle automatically; books over ~600 MB are split into parts.
- Failed chapters are fetched from the next best source automatically (only the missing ones); one book in the end.
- Survives quitting the app or restarting the Mac: downloads resume where they stopped.
- Handles blocked sites: fresh API token on MangaHub-family rate limits; Cloudflare checks via a hidden browser or a “Verify Now” prompt.
- Status panel: every manga's Download / Convert / Kindle step with progress and done/failed state.
- “Downloaded” and “On Kindle” views (convert what you already have; list/delete books on the Kindle), safe eject, auto-eject before sleep.

## Layout
- `app/` — SwiftUI app (`Sources/*.swift`), built with `swiftc` by `app/build.sh` (no Xcode project).
- `engine/` — Python helpers the app runs: `mangamerge.py` (scan/merge/KCC), `haru.py` + `haru_page.js` (HaruNeko over the
  Chrome DevTools Protocol), `kindle.py` (detect/send/list/delete/eject), `calibre_send.py`, vendored `kindleunpack` (GPLv3).

## Build
```sh
./setup.sh                 # Python 3.12 venv (uv) + KCC v12.0.0 clone into kcc-src/
# put kindlegen at bin/kindlegen (extract from Kindle Previewer: pkgutil --expand-full, KFXGen/bin/kindlegen)
cd app && ./build.sh       # → app/build/Manga to Kindle.app
```
Requires HaruNeko at `/Applications/HakuNeko.app`.
