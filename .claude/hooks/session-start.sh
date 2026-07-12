#!/bin/bash
# SessionStart hook — Claude Code on the web / remote sessions only.
#
# This repo is an iOS 26 project: there is nothing to "install" on the Linux
# containers that web sessions run in (no Swift toolchain, and the network
# policy blocks download.swift.org). Instead this hook:
#   1. validates the NLU JSON resources (the only meaningful check that can
#      run without Xcode), and
#   2. prints the environment constraints so they land in Claude's context
#      at session start.
set -uo pipefail

# Local (Mac) sessions: Xcode is available, nothing to do.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

if RESULT=$(python3 scripts/validate_resources.py 2>&1); then
  STATUS="PASS"
else
  STATUS="FAIL"
fi

echo "[session-start] Remote Linux session: NO Swift/Xcode here. Do not run xcodebuild/swift; compile+test verification happens in CI (ios-coreml-parity.yml) or on the user's Mac."
echo "[session-start] Runnable check: python3 scripts/validate_resources.py — current status: ${STATUS}"
echo "${RESULT}" | tail -n 5
