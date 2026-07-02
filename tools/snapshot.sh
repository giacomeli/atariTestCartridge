#!/bin/sh
# Opens the ROM in Stella, captures a screenshot of the emulator
# window only, then closes the emulator. Used for automated visual
# verification during development.
#
# usage: snapshot.sh <rom> <outdir> [extra stella args...]

ROM="$1"
OUTDIR="$2"
shift 2

DIR="$(cd "$(dirname "$0")/.." && pwd)"
STELLA="$DIR/tools/stella/Stella.app/Contents/MacOS/Stella"
WINID="$DIR/tools/winid"

if [ ! -x "$WINID" ]; then
    clang -framework Foundation -framework CoreGraphics \
        -o "$WINID" "$DIR/tools/winid.m" || exit 1
fi

mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.png

pkill -x Stella 2>/dev/null
sleep 1

"$STELLA" -fullscreen 0 -center 1 -autopause 0 "$@" "$ROM" > "$OUTDIR/stella.log" 2>&1 &
PID=$!
sleep 4

# the window can take a while to appear on cold starts: retry
ID=""
for _ in 1 2 3 4 5 6; do
    ID=$("$WINID" Stella)
    [ -n "$ID" ] && break
    sleep 1
done
if [ -n "$ID" ]; then
    sleep 1
    screencapture -x -o -l"$ID" "$OUTDIR/stella.png"
else
    echo "Stella window not found" >&2
fi

kill $PID 2>/dev/null
wait $PID 2>/dev/null
ls -la "$OUTDIR"
