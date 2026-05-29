#!/usr/bin/env python3
"""End-to-end test: navigate to example.com and read back the page state."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

LAUNCHER = Path(__file__).resolve().parent.parent / "bin" / "browser-use-mcp"


def msg(_id, method, params=None):
    m = {"jsonrpc": "2.0", "id": _id, "method": method}
    if params is not None:
        m["params"] = params
    return m


def notify(method, params=None):
    m = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        m["params"] = params
    return m


def send(proc, m):
    proc.stdin.write((json.dumps(m) + "\n").encode())
    proc.stdin.flush()


def read_until(proc, expect_id, timeout):
    deadline = time.monotonic() + timeout
    while True:
        if time.monotonic() > deadline:
            raise TimeoutError(f"timeout id={expect_id}")
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError(f"server died before id={expect_id}, rc={proc.poll()}")
        s = line.decode(errors="replace").strip()
        if not s:
            continue
        try:
            m = json.loads(s)
        except json.JSONDecodeError:
            sys.stderr.write(f"[non-json] {s}\n")
            continue
        if isinstance(m, dict) and m.get("id") == expect_id:
            return m
        sys.stderr.write(f"[skip] {s[:160]}\n")


def pump_stderr(proc):
    for line in proc.stderr:
        sys.stderr.write("[srv] " + line.decode(errors="replace"))


def main():
    p = subprocess.Popen(
        [str(LAUNCHER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=os.environ.copy(),
    )
    threading.Thread(target=pump_stderr, args=(p,), daemon=True).start()
    try:
        send(
            p,
            msg(
                1,
                "initialize",
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "e2e", "version": "0"},
                },
            ),
        )
        read_until(p, 1, 30)
        send(p, notify("notifications/initialized"))

        print(">> browser_navigate https://example.com")
        send(
            p,
            msg(
                2,
                "tools/call",
                {
                    "name": "browser_navigate",
                    "arguments": {"url": "https://example.com"},
                },
            ),
        )
        nav = read_until(p, 2, 90)
        print("   nav result:", json.dumps(nav.get("result", {}))[:400])

        print(">> browser_get_state")
        send(p, msg(3, "tools/call", {"name": "browser_get_state", "arguments": {}}))
        state = read_until(p, 3, 60)
        # extract text content from MCP tool result envelope
        result = state.get("result", {})
        content = result.get("content", [])
        text = ""
        for c in content:
            if c.get("type") == "text":
                text += c.get("text", "")
        # truncate for printability
        if len(text) > 1200:
            text = text[:1200] + f"... [truncated, total {len(text)} chars]"
        print("   state:\n", text)

        # cleanly close the browser
        print(">> browser_close_all")
        send(p, msg(4, "tools/call", {"name": "browser_close_all", "arguments": {}}))
        read_until(p, 4, 30)
        return 0
    finally:
        try:
            p.stdin.close()
        except Exception:
            pass
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()


if __name__ == "__main__":
    sys.exit(main())
