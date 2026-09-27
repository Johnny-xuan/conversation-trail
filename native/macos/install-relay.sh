#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
INSTALL_DIR="$HOME/Library/Application Support/Conversation Trail"
RELAY_BINARY="$INSTALL_DIR/conversation-trail-relay"
HOST_NAME="com.johnny.conversation_trail_relay"
HOSTS_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
HOST_MANIFEST="$HOSTS_DIR/$HOST_NAME.json"
EXTENSION_ID=${1:-}

if [[ -z "$EXTENSION_ID" ]]; then
  EXTENSION_ID=$(python3 - "$PROJECT_DIR/manifest.json" <<'PY'
import base64
import hashlib
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
public_key = base64.b64decode(manifest.get("key", ""))
if public_key:
    digest = hashlib.sha256(public_key).digest()[:16]
    print("".join(chr(ord("a") + int(nibble, 16)) for byte in digest for nibble in f"{byte:02x}"))
PY
  )
fi

if [[ -z "$EXTENSION_ID" ]]; then
  EXTENSION_ID=$(python3 - "$PROJECT_DIR" <<'PY'
import json
import os
import pathlib
import sys

project = os.path.realpath(sys.argv[1])
chrome = pathlib.Path.home() / "Library/Application Support/Google/Chrome"
for preferences in sorted(chrome.glob("*/Preferences")):
    try:
        data = json.loads(preferences.read_text())
    except Exception:
        continue
    for extension_id, entry in data.get("extensions", {}).get("settings", {}).items():
        path = entry.get("path")
        if path and os.path.realpath(path) == project:
            print(extension_id)
            raise SystemExit
PY
  )
fi

if [[ ! "$EXTENSION_ID" =~ '^[a-p]{32}$' ]]; then
  cat >&2 <<EOF
没有找到 Conversation Trail 的 Chrome 扩展 ID。
请确认 manifest.json 包含开发公钥，或显式传入扩展 ID：
  ./native/macos/install-relay.sh <扩展 ID>
EOF
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$HOSTS_DIR"

"$SCRIPT_DIR/build-relay.sh"
install -m 755 "$PROJECT_DIR/dist/conversation-trail-relay" "$RELAY_BINARY"

python3 - "$HOST_MANIFEST" "$HOST_NAME" "$RELAY_BINARY" "$EXTENSION_ID" <<'PY'
import json
import pathlib
import sys

manifest_path, host_name, binary_path, extension_id = sys.argv[1:]
payload = {
    "name": host_name,
    "description": "Conversation Trail relay for Local Audio Engine",
    "path": binary_path,
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{extension_id}/"],
}
pathlib.Path(manifest_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
PY

echo "已安装 Conversation Trail relay"
echo "Chrome 扩展 ID: $EXTENSION_ID"
echo "Relay: $RELAY_BINARY"
echo "Local Audio Engine 保持独立，不包含任何 Chrome 配置。"
