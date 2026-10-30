#!/bin/bash
set -euo pipefail

source_image="$1"
output_icon="$2"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/usage-meter-icon.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset"

make_png() {
  local name="$1" size="$2"
  sips -z "$size" "$size" "$source_image" --out "$iconset/$name" >/dev/null
}

make_png icon_16x16.png 16
make_png icon_16x16@2x.png 32
make_png icon_32x32.png 32
make_png icon_32x32@2x.png 64
make_png icon_128x128.png 128
make_png icon_128x128@2x.png 256
make_png icon_256x256.png 256
make_png icon_256x256@2x.png 512
make_png icon_512x512.png 512
make_png icon_512x512@2x.png 1024

python3 - "$iconset" "$output_icon" <<'PY'
from pathlib import Path
import struct, sys
source, output = map(Path, sys.argv[1:])
entries = [('icp4','icon_16x16.png'), ('icp5','icon_32x32.png'), ('icp6','icon_32x32@2x.png'), ('ic07','icon_128x128.png'), ('ic08','icon_256x256.png'), ('ic09','icon_512x512.png'), ('ic10','icon_512x512@2x.png')]
payload = b''.join(kind.encode() + struct.pack('>I', len(data := (source / name).read_bytes()) + 8) + data for kind, name in entries)
output.write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
PY
