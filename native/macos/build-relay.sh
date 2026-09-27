#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
OUTPUT="$PROJECT_DIR/dist/conversation-trail-relay"
TARGET_ARCH=${LOCAL_AUDIO_ENGINE_ARCH:-$(uname -m)}
SIGNING_IDENTITY=${LOCAL_AUDIO_ENGINE_SIGNING_IDENTITY:--}
SIGNING_OPTIONS=()
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGNING_OPTIONS=(--options runtime --timestamp)
fi

mkdir -p "$PROJECT_DIR/dist"
swiftc \
  -O \
  -parse-as-library \
  -target "$TARGET_ARCH-apple-macosx13.0" \
  -framework AppKit \
  -framework Network \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker "$SCRIPT_DIR/Resources/Relay-Info.plist" \
  "$SCRIPT_DIR/Relay/main.swift" \
  -o "$OUTPUT"
chmod 755 "$OUTPUT"
codesign --force --sign "$SIGNING_IDENTITY" "${SIGNING_OPTIONS[@]}" "$OUTPUT"
echo "已生成 relay: $OUTPUT"
