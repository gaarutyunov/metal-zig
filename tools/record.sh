#!/bin/sh
# Regenerates the media in docs/:
#   docs/00-device.gif    terminal recording (asciinema + agg)
#   docs/<example>.png   window captures of the windowed examples (screencapture -l)
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
for example in 00-window 01-primitive 02-argbuffers 03-animation 04-instancing \
    05-perspective 06-lighting 07-texturing 08-compute 09-compute-to-render; do
    ./zig-out/bin/$example >/dev/null 2>&1 &
    pid=$!
    sleep 3
    screencapture -x -l"$("$tmp/windowid" "$pid")" docs/$example.png
    kill "$pid"
    sips -Z 640 docs/$example.png >/dev/null
done
