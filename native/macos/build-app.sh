#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Local Audio Engine"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
SIGNING_IDENTITY=${LOCAL_AUDIO_ENGINE_SIGNING_IDENTITY:-}
TARGET_ARCH=${LOCAL_AUDIO_ENGINE_ARCH:-$(uname -m)}

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development:/{print $2; exit}')
fi
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
SIGNING_OPTIONS=()
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGNING_OPTIONS=(--options runtime --timestamp)
fi

if [[ -e "$APP_BUNDLE" ]]; then
  mv "$APP_BUNDLE" "$DIST_DIR/$APP_NAME.previous.$(date +%s).app"
fi

mkdir -p "$MACOS_DIR"

swiftc \
  -O \
  -parse-as-library \
  -target "$TARGET_ARCH-apple-macosx13.0" \
  -framework AppKit \
  -framework Accelerate \
  -framework AVFAudio \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework Network \
  -framework ScreenCaptureKit \
  -framework SwiftUI \
  "$SCRIPT_DIR/Engine/AudioFrame.swift" \
  "$SCRIPT_DIR/Engine/AudioEnergyAnalyzer.swift" \
  "$SCRIPT_DIR/Engine/SystemAudioAnalyzer.swift" \
  "$SCRIPT_DIR/Engine/AudioEngineServer.swift" \
  "$SCRIPT_DIR/App/LocalAudioEngineApp.swift" \
  -o "$MACOS_DIR/$APP_NAME"

python3 - "$CONTENTS/Info.plist" <<'PY'
import plistlib
import sys

payload = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": "Local Audio Engine",
    "CFBundleExecutable": "Local Audio Engine",
    "CFBundleIdentifier": "com.johnny.local-audio-engine",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "Local Audio Engine",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": True,
    "NSAudioCaptureUsageDescription": "Local Audio Engine 只在本机分析系统声音的强弱，并向已授权的本地客户端提供实时声浪数据。",
    "NSScreenCaptureUsageDescription": "macOS 通过屏幕与系统音频录制权限提供系统声音；Local Audio Engine 不读取、保存或上传屏幕画面。",
}
with open(sys.argv[1], "wb") as file:
    plistlib.dump(payload, file, sort_keys=False)
PY

chmod 755 "$MACOS_DIR/$APP_NAME"
codesign --force --deep --sign "$SIGNING_IDENTITY" "${SIGNING_OPTIONS[@]}" "$APP_BUNDLE"

python3 - "$DIST_DIR" "$APP_NAME" <<'PY'
import pathlib
import shutil
import sys

dist = pathlib.Path(sys.argv[1])
app_name = sys.argv[2]
for candidate in dist.glob(f"{app_name}.previous.*.app"):
    shutil.rmtree(candidate, ignore_errors=True)
PY

echo "已生成中心音频服务: $APP_BUNDLE"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "警告：没有找到 Apple Development 证书，当前使用临时签名；重新构建后 macOS 可能要求再次授权。"
else
  echo "代码签名: $SIGNING_IDENTITY"
fi
echo "该 App 不包含 Conversation Trail 或 Chrome 配置。"
