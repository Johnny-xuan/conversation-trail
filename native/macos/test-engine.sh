#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

swiftc -O -parse-as-library \
  -framework Accelerate \
  "$SCRIPT_DIR/Engine/AudioFrame.swift" \
  "$SCRIPT_DIR/Engine/AudioEnergyAnalyzer.swift" \
  "$PROJECT_DIR/tests/AudioEnergyAnalyzerTests.swift" \
  -o "$TEST_DIR/energy-tests"
"$TEST_DIR/energy-tests"
