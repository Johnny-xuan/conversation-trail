#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
APP_NAME="Local Audio Engine"
SOURCE_APP="$PROJECT_DIR/dist/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
LAUNCH_SERVICES="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

osascript -e 'tell application id "com.johnny.local-audio-engine" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
  sleep 0.1
done

"$SCRIPT_DIR/build-app.sh"
mkdir -p "$INSTALL_DIR"

if [[ -d "$INSTALLED_APP" ]]; then
  "$LAUNCH_SERVICES" -u "$INSTALLED_APP" >/dev/null 2>&1 || true
fi

python3 - "$SOURCE_APP" "$INSTALLED_APP" <<'PY'
import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(source, destination, symlinks=True)
PY

"$LAUNCH_SERVICES" -u "$SOURCE_APP" >/dev/null 2>&1 || true
"$LAUNCH_SERVICES" -f "$INSTALLED_APP" >/dev/null
codesign --verify --deep --strict "$INSTALLED_APP"
open "$INSTALLED_APP"

echo "已安装并打开: $INSTALLED_APP"
echo "Local Audio Engine 以后将从固定路径运行，便于 macOS 保持系统音频授权。"
