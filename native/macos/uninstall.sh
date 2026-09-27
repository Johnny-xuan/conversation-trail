#!/bin/zsh
set -euo pipefail

HOST_NAME="com.johnny.conversation_trail_relay"
rm -f "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/$HOST_NAME.json"
rm -rf "$HOME/Library/Application Support/Conversation Trail"
echo "已移除 Conversation Trail relay；Local Audio Engine 不受影响"
