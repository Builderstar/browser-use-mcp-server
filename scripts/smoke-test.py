#!/usr/bin/env python3
"""Smoke-test the browser-use-mcp launcher over stdio.

Sends an MCP `initialize` request followed by `tools/list`, prints the
responses, then exits. If we get a non-empty tools array back, the server
is up and exposing browser-use commands.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

LAUNCHER = Path(__file__).resolve().parent.parent / "bin" / "browser-use-mcp"

INIT = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "smoke-test", "version": "0.0.1"},
    },
}
INITIALIZED = {"jsonrpc": "2.0", "method": "notifications/initialized"}
LIST_TOOLS = {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}


def send(proc: subprocess.Popen, msg: dict) -> None:
    line = json.dumps(msg) + "\n"
    assert proc.stdin is not None
    proc.stdin.write(line.encode())
    proc.stdin.flush()


def pump_stderr(proc: subprocess.Popen) -> None:
    assert proc.stderr is not None
    for line in proc.stderr:
        sys.stderr.write("[server-stderr] " + line.decode(errors="replace"))


def main() -> int:
    if not LAUNCHER.exists():
        print(f"launcher not found: {LAUNCHER}", file=sys.stderr)
        return 2

    env = os.environ.copy()
    proc = subprocess.Popen(
        [str(LAUNCHER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    t = threading.Thread(target=pump_stderr, args=(proc,), daemon=True)
    t.start()

    try:
        send(proc, INIT)
        # Read until we see id=1 response
        init_resp = read_response(proc, expect_id=1, timeout=30)
        print("initialize response:", json.dumps(init_resp)[:500])

        send(proc, INITIALIZED)
        send(proc, LIST_TOOLS)
        tools_resp = read_response(proc, expect_id=2, timeout=30)
        tools = tools_resp.get("result", {}).get("tools", [])
        print(f"tools/list returned {len(tools)} tools")
        for t in tools[:25]:
            print("  -", t.get("name"))
        if len(tools) > 25:
            print(f"  ... and {len(tools) - 25} more")
        return 0 if tools else 1
    finally:
        try:
            proc.stdin.close()  # type: ignore[union-attr]
        except Exception:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()


def read_response(proc: subprocess.Popen, expect_id: int, timeout: float) -> dict:
    """Read JSON-RPC lines from stdout until we get the matching id."""
    assert proc.stdout is not None
    deadline = time.monotonic() + timeout
    while True:
        if time.monotonic() > deadline:
            raise TimeoutError(f"timed out waiting for response id={expect_id}")
        line = proc.stdout.readline()
        if not line:
            rc = proc.poll()
            raise RuntimeError(
                f"server exited (rc={rc}) before responding to id={expect_id}"
            )
        line_s = line.decode(errors="replace").strip()
        if not line_s:
            continue
        try:
            msg = json.loads(line_s)
        except json.JSONDecodeError:
            sys.stderr.write(f"[non-json stdout] {line_s}\n")
            continue
        if isinstance(msg, dict) and msg.get("id") == expect_id:
            return msg
        # ignore notifications/other ids
        sys.stderr.write(f"[ignored msg] {line_s[:200]}\n")


if __name__ == "__main__":
    sys.exit(main())
