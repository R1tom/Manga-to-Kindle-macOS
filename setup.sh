#!/bin/bash
# (Re)creates the Python environment used by "Manga to Kindle.app".
set -euo pipefail
cd "$(dirname "$0")"
UV="${UV:-$HOME/.local/bin/uv}"
[ -d venv ] || "$UV" venv -p 3.12 venv
"$UV" pip install -p venv/bin/python "Pillow>=11.3.0" psutil requests "python-slugify>=8.0.4,<9" packaging \
  mozjpeg-lossless-optimization natsort numpy PyMuPDF websockets
[ -d kcc-src ] || git clone --depth 1 -b v12.0.0 https://github.com/ciromattia/kcc.git kcc-src
[ -x bin/kindlegen ] || echo "bin/kindlegen missing: extract it from Kindle Previewer (KFXGen/bin/kindlegen)"
echo ok
