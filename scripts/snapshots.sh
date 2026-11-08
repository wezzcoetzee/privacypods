#!/bin/sh
# Renders every UI surface in a fixed set of states to PNGs in <output-dir>.
#
# Windows and menus flash on screen while they are captured, and the overlay snapshot covers
# part of the main display for about a second. Nothing real is blurred, read or locked.
#
# The test host has no Screen Recording grant of its own, so this script does the capturing:
# the harness writes screencapture arguments to <output-dir>/.request and waits for it to go.
# Run it from a terminal that has Screen Recording.
set -eu
mkdir -p "${1:?usage: scripts/snapshots.sh <output-dir>}"
out="$(cd "$1" && pwd)"
cd "$(dirname "$0")/.."
rm -f "$out/.request" "$out/.done"

(
  while [ ! -f "$out/.done" ]; do
    if [ -f "$out/.request" ]; then
      tr '\n' '\0' < "$out/.request" | xargs -0 screencapture || echo "capture failed: $(tail -1 "$out/.request")" >&2
      rm -f "$out/.request"
    fi
    sleep 0.1
  done
) &
watcher=$!
trap 'touch "$out/.done"; wait $watcher 2>/dev/null; rm -f "$out/.done" "$out/.request"' EXIT

xcodegen generate --quiet
TEST_RUNNER_PRIVACYPODS_SNAPSHOT_DIR="$out" xcodebuild -project PrivacyPods.xcodeproj -scheme PrivacyPods \
  -configuration Debug -destination 'platform=macOS' test \
  -only-testing:PrivacyPodsTests/UISnapshots \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -E 'error:|TEST (FAILED|SUCCEEDED)' || true
ls "$out"
