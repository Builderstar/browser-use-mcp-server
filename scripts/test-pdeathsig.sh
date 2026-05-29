#!/usr/bin/env bash
# Simulate `opencode kill -9` and verify the browser-use stack tears itself down.
#
# Plan:
#   1. Start a parent shell that launches the MCP launcher (no MCP traffic; we
#      just want the browser stack alive).
#   2. Send `browser_navigate` so Chromium actually spawns.
#   3. SIGKILL the parent shell (simulates opencode crash / kill -9).
#   4. Wait a few seconds, then check that:
#        - the launcher process is gone
#        - Xvfb on its display is gone
#        - all Chromium processes parented to it are gone (or crashpad-orphans only)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$PROJECT_DIR/bin/browser-use-mcp"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

echo ">> starting parent shell + launcher in background"
# We use a subshell so we have a single PID to kill. Pipe a valid MCP init+navigate.
bash -c '
    INIT=$(printf "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}\n")
    INITED=$(printf "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n")
    NAV=$(printf "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_navigate\",\"arguments\":{\"url\":\"https://example.com\"}}}\n")
    # Feed inputs then sleep forever to keep the pipe open and the server running.
    { printf "%s" "$INIT"; sleep 1; printf "%s" "$INITED"; sleep 1; printf "%s" "$NAV"; sleep 600; } \
        | exec "$1"
' _ "$LAUNCHER" >"$LOG" 2>&1 &
PARENT=$!
echo "   parent pid=$PARENT"

echo ">> waiting 20s for Chromium to come up..."
for _ in $(seq 1 40); do
    if ps --ppid "$PARENT" -o pid,cmd 2>/dev/null | grep -q browser-use-mcp; then
        # find chrome under it
        if pgrep -P $(pgrep -P $(pgrep -P "$PARENT" -f browser-use-mcp || echo 0) -f browser-use || echo 0) chrome >/dev/null 2>&1; then
            break
        fi
    fi
    sleep 0.5
done

echo ">> tree before kill:"
pstree -p "$PARENT" 2>/dev/null || ps -ef | grep -E "browser-use-mcp|Xvfb|chrome" | grep -v grep | grep -v playwright

echo ">> SIGKILLing parent ($PARENT)"
kill -9 "$PARENT" 2>/dev/null || true

echo ">> waiting 8s for cascade cleanup..."
sleep 8

echo ">> tree after:"
LEFTOVER=$(ps -ef | grep -E "browser-use-mcp|Xvfb :|chrome" | grep -v grep | grep -v playwright | grep -v "user-data-dir=$HOME/.config/google" || true)
# Crashpad orphans are OK; they exit ~10s after Chrome dies.
echo "$LEFTOVER"

# Count non-crashpad leftovers
REAL_LEFTOVER=$(printf '%s' "$LEFTOVER" | grep -v crashpad || true)
if [[ -z "$REAL_LEFTOVER" ]]; then
    echo "PASS: no non-crashpad leftovers from killed launcher"
    exit 0
else
    echo "FAIL: leftover processes:"
    printf '%s\n' "$REAL_LEFTOVER"
    exit 1
fi
