#!/usr/bin/env bash
# Engine tests without UI: optimise generated PNG/JPEG/GIF/MOV/PDF with the quality search, then the
# presets, SSIM gate, keep-original rule, metadata stripping, blur, auto-name and CLI checks.
#   scripts/test-engine.sh [path/to/Pinch binary]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/build/Build/Products/Debug/Pinch.app/Contents/MacOS/Pinch}"
T="$(mktemp -d "${TMPDIR:-/tmp}/pinch-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export CFFIXED_USER_HOME="$T/home"
# Debug builds are slow; give the search the time a Release build would need.
export PINCH_TIME_SCALE="${PINCH_TIME_SCALE:-8}"
mkdir -p "$CFFIXED_USER_HOME"
FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

"$BIN" -make-samples "$T" || { echo "FAIL make-samples"; exit 1; }
ffmpeg -y -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -t 3 -c:v libx264 -crf 12 -pix_fmt yuv420p "$T/clip.mov"

opens() {  # file still opens
  case "$1" in
    *.png|*.jpg) sips -g pixelWidth "$1" >/dev/null 2>&1 ;;
    *.gif) gifsicle --info "$1" >/dev/null 2>&1 ;;
    *.mov) ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$1" >/dev/null 2>&1 ;;
    *.pdf) gs -q -dNODISPLAY -dNOSAFER -dBATCH -dNOPAUSE -sDEVICE=nullpage "$1" >/dev/null 2>&1 ;;
  esac
}

for f in photo.png photo.jpg ui-dashboard.png ui-editor.png photo-a.jpg anim.gif clip.mov report.pdf; do
  before=$(stat -f%z "$T/$f")
  out=$("$BIN" -optimise "$T/$f" 2>&1); rc=$?
  after=$(stat -f%z "$T/$f")
  if [ $rc -eq 0 ] && [ "$after" -lt "$before" ] && opens "$T/$f"; then
    pass "optimise $f: $before -> $after bytes ($out)"
  else fail "optimise $f: before=$before after=$after rc=$rc $out"; fi
done

# Optimised output must carry the marker.
if xattr -p pinch.optimisation.status "$T/photo.png" >/dev/null 2>&1; then pass "marker xattr set"; else fail "marker xattr set"; fi

# Lossless is never smaller than Visually identical on a screenshot.
cp "$T/ui-settings.png" "$T/l.png"; cp "$T/ui-settings.png" "$T/i.png"
"$BIN" -optimise "$T/l.png" -preset lossless >/dev/null; "$BIN" -optimise "$T/i.png" >/dev/null
[ "$(stat -f%z "$T/i.png")" -le "$(stat -f%z "$T/l.png")" ] && pass "identical png <= lossless png" || fail "identical png <= lossless png"

# Optimise harder is at least as small.
cp "$T/photo-b.jpg" "$T/n.jpg"; cp "$T/photo-b.jpg" "$T/a.jpg"
"$BIN" -optimise "$T/n.jpg" >/dev/null; "$BIN" -optimise "$T/a.jpg" -aggressive >/dev/null
[ "$(stat -f%z "$T/a.jpg")" -le "$(stat -f%z "$T/n.jpg")" ] && pass "harder jpg <= normal jpg" || fail "harder jpg <= normal jpg"

# Blur via the CLI path too.
cp "$T/secrets.png" "$T/s.png"
out=$("$BIN" -optimise "$T/s.png" -blur -blurOn YES 2>&1)
case "$out" in *"hidden=2"*) pass "cli blur hid 2 regions";; *) fail "cli blur: $out";; esac

# The public command line, end to end.
mkdir -p "$T/in" "$T/outdir"; cp "$T/ui-editor.png" "$T/photo-b.jpg" "$T/in/"
out=$("$BIN" optimise "$T/in" --preset chat --out "$T/outdir" 2>&1); rc=$?
if [ $rc -eq 0 ] && [ -s "$T/outdir/ui-editor.png" ] && [ -s "$T/outdir/photo-b.jpg" ] && [ "$(stat -f%z "$T/in/photo-b.jpg")" -gt "$(stat -f%z "$T/outdir/photo-b.jpg")" ]; then pass "pinch optimise --preset chat --out"; else fail "pinch optimise: rc=$rc $out"; fi
"$BIN" optimise "$T/nothing.png" >/dev/null 2>&1; [ $? -ne 0 ] && pass "pinch optimise: missing file fails" || fail "pinch optimise: missing file fails"
"$BIN" presets | grep -q "Visually identical" && pass "pinch presets lists presets" || fail "pinch presets"

"$BIN" -selftest "$T" || FAIL=1
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
