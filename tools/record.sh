#!/bin/sh
# Regenerates the media in docs/:
#   docs/00-device.gif    terminal recording (asciinema + agg)
#   docs/01-primitive.png window capture of the triangle example (screencapture -l)
#
# Requirements: asciinema 3 (`cargo install --locked asciinema`),
# agg (`cargo install --locked --git https://github.com/asciinema/agg`), swiftc.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$root"
zig build

asciinema rec --headless --overwrite --window-size 80x24 --idle-time-limit 1.5 \
    -c "$root/tools/type-and-run.sh $root zig build run-00-device" "$tmp/00-device.cast"
agg --font-size 16 --theme monokai "$tmp/00-device.cast" docs/00-device.gif

swiftc -O tools/windowid.swift -o "$tmp/windowid"
./zig-out/bin/01-primitive >/dev/null 2>&1 &
pid=$!
sleep 3
screencapture -x -l"$("$tmp/windowid" "$pid")" docs/01-primitive.png
kill "$pid"
sips -Z 640 docs/01-primitive.png >/dev/null
