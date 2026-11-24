#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="$PWD/build/Build/Products/Debug/Pinch.app"
scratch=$(mktemp -d "$PWD/build/qa-run.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
app="$scratch/PinchQA.app"
mkdir -p "$app/Contents/MacOS" "$scratch/home" "$scratch/tmp"
cp "$source_app/Contents/Info.plist" "$app/Contents/Info.plist"
cp "$source_app"/Contents/MacOS/* "$app/Contents/MacOS/"
cp -R "$source_app/Contents/Resources" "$app/Contents/Resources"
plutil -remove LSUIElement "$app/Contents/Info.plist"
plutil -insert LSBackgroundOnly -bool YES "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string local.Pinch.RenderTests "$app/Contents/Info.plist"
export CFFIXED_USER_HOME="$scratch/home" TMPDIR="$scratch/tmp/"
case "${1:-all}" in
    all) "$app/Contents/MacOS/Pinch" -qa "$PWD/qa" -perf -check-handoff ;;
    intro) "$app/Contents/MacOS/Pinch" -intro-preview "$PWD/qa" ;;
    *) exit 64 ;;
esac
