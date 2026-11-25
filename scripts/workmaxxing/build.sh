#!/bin/bash
# Build Workmaxxing and install it to /Applications.
#
#   WORKMAXXING_SIGN_IDENTITY="My Local Signing" scripts/workmaxxing/build.sh
#
# Builds the optimized Release app under its own tag (wm), separate from any
# debug tag used for testing. WORKMAXXING_CONFIG=Debug builds a debug copy.
#
# Quits the running app first: rebuilding under a running copy can crash it.
# Build output goes to a temp file; never redirect into reload.sh's own log
# (/tmp/cmux-reload-<tag>.log), which it prints on failure.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/../.."
TAG="${WORKMAXXING_TAG:-wm}"
CONFIG="${WORKMAXXING_CONFIG:-Release}"
OUT="$(mktemp -t workmaxxing-build)"
RELEASE_FLAG=()
[ "$CONFIG" = "Release" ] && RELEASE_FLAG=(--release)
CMUX_DEV_APP_DISPLAY_NAME="Workmaxxing" \
CMUX_DEV_SIGN_IDENTITY="${WORKMAXXING_SIGN_IDENTITY:--}" \
CMUX_DEV_BACKEND_MODE=local \
  ./scripts/reload.sh --tag "$TAG" "${RELEASE_FLAG[@]}" >"$OUT" 2>&1
rc=$?
grep -E "error:" "/tmp/cmux-reload-$TAG.log" 2>/dev/null | sort -u | head -20
if [ $rc -ne 0 ] || ! grep -q "BUILD SUCCEEDED" "/tmp/cmux-reload-$TAG.log" 2>/dev/null; then
  echo "build failed (exit $rc); details in $OUT" >&2
  exit 1
fi
WORKMAXXING_TAG="$TAG" WORKMAXXING_CONFIG="$CONFIG" "$DIR/install.sh"
