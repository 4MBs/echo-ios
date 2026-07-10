#!/bin/bash
# Package a built .app into an unsigned .ipa (for SideStore/AltStore, which
# re-sign on device with a free Apple ID).
#   make_unsigned_ipa.sh <path/to/MossLive.app> <output.ipa>
set -euo pipefail

APP_PATH="$1"
OUTPUT="$2"

[ -d "$APP_PATH" ] || { echo "error: app bundle not found at $APP_PATH" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload"
cp -R "$APP_PATH" "$WORK/Payload/"

# Strip any code-signature leftovers; SideStore replaces them anyway.
rm -rf "$WORK/Payload/$(basename "$APP_PATH")/_CodeSignature" || true

(cd "$WORK" && zip -qry ipa.zip Payload)
mv "$WORK/ipa.zip" "$OUTPUT"
echo "unsigned ipa: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
