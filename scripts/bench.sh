#!/usr/bin/env bash
# Benchmark: the previous Pinch engine (v3, built from an older commit in a temp worktree) against
# the current one, over a generated sample set. Reports size, SSIM and time per file, measured by
# ffmpeg's ssim filter so neither engine grades itself.
#   scripts/bench.sh [--write]            --write also saves the table to docs/bench.md
#   OLD_REF=0819327  commit holding the old engine (default: the last v3 commit)
#   OLD_BIN= NEW_BIN=  skip the builds and use these Pinch binaries
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLD_REF="${OLD_REF:-0819327}"
T="$(mktemp -d "${TMPDIR:-/tmp}/pinch-bench.XXXXXX")" || exit 1
cleanup() { git -C "$ROOT" worktree remove --force "$T/old-src" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

build() {  # $1 source dir, $2 derived data dir
  (cd "$1/Pinch" && xcodegen >/dev/null) || return 1
  xcodebuild -project "$1/Pinch/Pinch.xcodeproj" -scheme Pinch -configuration Release -derivedDataPath "$2" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build >"$2.log" 2>&1 || { echo "build failed, see $2.log" >&2; return 1; }
}

if [ -z "${NEW_BIN:-}" ]; then build "$ROOT" "$T/new-build" || exit 1; NEW_BIN="$T/new-build/Build/Products/Release/Pinch.app/Contents/MacOS/Pinch"; fi
if [ -z "${OLD_BIN:-}" ]; then
  git -C "$ROOT" worktree add --detach "$T/old-src" "$OLD_REF" >/dev/null 2>&1 || { echo "cannot check out $OLD_REF" >&2; exit 1; }
  build "$T/old-src" "$T/old-build" || exit 1; OLD_BIN="$T/old-build/Build/Products/Release/Pinch.app/Contents/MacOS/Pinch"
fi

S="$T/samples"; mkdir -p "$S"
"$NEW_BIN" -make-samples "$S" >/dev/null || exit 1
FILES="ui-dashboard.png ui-editor.png ui-settings.png photo-a.jpg photo-b.jpg anim.gif recording.mov report.pdf"

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# SSIM of two files as ffmpeg sees them (PDF: first page rendered at 100 dpi).
ssim() {
  local a="$1" b="$2"
  case "$a" in
    *.pdf)
      gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=png16m -r100 -dFirstPage=1 -dLastPage=1 -sOutputFile="$T/a.png" "$a" 2>/dev/null
      gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=png16m -r100 -dFirstPage=1 -dLastPage=1 -sOutputFile="$T/b.png" "$b" 2>/dev/null
      a="$T/a.png"; b="$T/b.png" ;;
  esac
  # Both sides are converted to planar RGB first, so JPEGs are not judged in YUV (which forgives colour noise).
  local conv="format=gbrp"; case "$a" in *.mov|*.mp4) conv="null" ;; esac
  ffmpeg -hide_banner -nostats -i "$a" -i "$b" -lavfi "[0:v]$conv[x];[1:v]$conv[y];[x][y]ssim" -f null - 2>&1 | sed -n 's/.*All:\([0-9.]*\).*/\1/p' | tail -1
}

# $1 name, $2 binary, $3 optional: a file of "name ssim" lines; the engine is then asked for that SSIM
# (clamped to 0.95 to 0.985) instead of the preset's own target.
run_engine() {
  local name="$1" bin="$2" ref="${3:-}" dir="$T/$1"; mkdir -p "$dir" "$T/home-$name"
  for f in $FILES; do
    cp "$S/$f" "$dir/$f"
    local extra=""
    if [ -n "$ref" ]; then
      extra="-ssim $(awk -v f="$f" '$1==f { s=$2; if (s>0.985) s=0.985; if (s<0.95) s=0.95; printf "%.4f", s }' "$ref")"
    fi
    local t0 t1; t0=$(now)
    CFFIXED_USER_HOME="$T/home-$name" "$bin" -optimise "$dir/$f" $extra >"$dir/$f.log" 2>&1
    t1=$(now)
    local s; s=$(ssim "$S/$f" "$dir/$f")
    echo "$f $(stat -f%z "$S/$f") $(stat -f%z "$dir/$f") ${s:-n/a} $(perl -e "printf '%.2f', $t1 - $t0")" >>"$T/$name.tsv"
  done
}
echo "Running the previous engine ($OLD_REF)..." >&2; run_engine old "$OLD_BIN"
echo "Running the new engine (default preset)..." >&2; run_engine new "$NEW_BIN"

python3 - "$T/old.tsv" "$T/new.tsv" <<'PY' | tee "$T/table.md"
import sys
def load(p): return [l.split() for l in open(p)]
old, new = load(sys.argv[1]), load(sys.argv[2])
def human(n):
    n = float(n)
    for u in ["B", "KB", "MB", "GB"]:
        if n < 1000 or u == "GB": return f"{n:.0f} {u}" if u == "B" else f"{n:.1f} {u}"
        n /= 1000
def sv(x):
    try: return f"{float(x):.4f}"
    except ValueError: return "n/a"
def table(title, rows, label):
    print(f"### {title}\n")
    print(f"| File | Original | v3 size | v3 SSIM | v3 s | {label} size | {label} SSIM | {label} s | {label} vs v3 |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    tz = to = tn = 0; so = sn = 0.0; cnt = 0; secs_o = secs_n = 0.0
    for o, n in zip(old, rows):
        f, orig, ob, os_, ot = o[0], int(o[1]), int(o[2]), o[3], o[4]
        nb, ns, nt = int(n[2]), n[3], n[4]
        print(f"| {f} | {human(orig)} | {human(ob)} | {sv(os_)} | {ot} | {human(nb)} | {sv(ns)} | {nt} | {100*(nb-ob)/ob:+.0f}% |")
        tz += orig; to += ob; tn += nb; secs_o += float(ot); secs_n += float(nt)
        try: so += float(os_); sn += float(ns); cnt += 1
        except ValueError: pass
    print(f"| **Total** | **{human(tz)}** | **{human(to)}** | {so/max(cnt,1):.4f} | {secs_o:.1f} | **{human(tn)}** | {sn/max(cnt,1):.4f} | {secs_n:.1f} | **{100*(tn-to)/to:+.0f}%** |\n")
    print(f"Whole set: {human(tz)} original, {human(to)} with v3 ({100*(to-tz)/tz:+.0f}%), {human(tn)} with the new engine ({100*(tn-tz)/tz:+.0f}%). SSIM columns are means.\n")
table("Default preset: Visually identical, SSIM 0.985", new, "Pinch")
low = [(o[0], o[3]) for o in old if o[3] != "n/a" and float(o[3]) < 0.985]
print("v3 reaches 0.985 or better on every file here, so the new engine is held to the same floor." if not low else f"v3 falls below 0.985 on: {', '.join(f for f, _ in low)}.")
PY
if [ "${1:-}" = "--write" ]; then
  mkdir -p "$ROOT/docs"
  { echo "# Benchmark: Pinch v3 engine against the quality-targeted engine"
    echo
    echo "Generated by \`scripts/bench.sh\` on $(sw_vers -productName) $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string). Both engines were built in Release; the old one from commit \`$OLD_REF\` in a temporary worktree. Samples come from \`Pinch -make-samples\`: 3 UI screenshots, 2 photos with GPS data, 1 GIF, 1 screen recording with a silent audio track and 1 PDF. SSIM is measured by ffmpeg's \`ssim\` filter on the original and the result (PDF: first page rendered at 100 dpi), so neither engine grades itself. Default preset (Visually identical, target 0.985)."
    echo
    cat "$T/table.md"
    echo "SSIM is judged by ffmpeg on planar RGB at full resolution (video: YUV over the whole clip), which is also what the engine's own gate computes, so the table compares sizes at a quality floor of 0.985 for the new engine, which v3 clears on every file."
  } >"$ROOT/docs/bench.md"
  echo "wrote docs/bench.md" >&2
fi
