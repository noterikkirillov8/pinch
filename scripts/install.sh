#!/usr/bin/env bash
# Builds Pinch (Release, signed with a local certificate when you have one, ad hoc otherwise),
# installs it in /Applications and starts it. NO_OPEN=1 skips launching.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData/PinchRel"
BUILT="${DERIVED}/Build/Products/Release/Pinch.app"
TARGET="/Applications/Pinch.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

# The author's local identity when present; ad-hoc signing for everyone else.
IDENTITY="Erik Local Signing"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || IDENTITY="-"

echo "Building (Release)..."
cd "${REPO_ROOT}/Pinch"
xcodegen >/dev/null
xcodebuild -scheme Pinch -configuration Release -derivedDataPath "${DERIVED}" CODE_SIGN_IDENTITY="${IDENTITY}" -quiet build

echo "Quitting Pinch..."
osascript -e 'tell application id "com.erikkirillov.Pinch" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x Pinch >/dev/null || break; sleep 1; done
pkill -x Pinch 2>/dev/null || true

echo "Installing in ${TARGET}..."
rm -rf "${TARGET}"
ditto "${BUILT}" "${TARGET}"
"${LSREGISTER}" -u "${BUILT}" >/dev/null 2>&1 || true
"${LSREGISTER}" -f "${TARGET}" >/dev/null 2>&1 || true
if [ -n "${NO_OPEN:-}" ]; then echo "Installed ${TARGET} (NO_OPEN set: not started)."; exit 0; fi
open "${TARGET}"
echo "Pinch is running from ${TARGET}."
