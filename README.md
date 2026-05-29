# browser-use-mcp-server

A launcher that runs the [browser-use](https://github.com/browser-use/browser-use)
MCP server with a **headed** Chromium on Linux machines that have no display
server, by auto-managing an Xvfb virtual display.

This exists because most browser MCP servers run headless, and many sites
(notably anything behind Cloudflare Turnstile) treat headless browsers
differently. Running headed Chromium under Xvfb in a container or on a
headless VM gives you the fingerprint of a normal browser without needing
a real screen.

The browser automation itself is all done by `browser-use`. This project is
~150 lines of launcher script around it.

## What it provides

When wired into an MCP client (OpenCode, Claude Desktop, Cursor, etc.), the
agent gets 16 tools: `browser_navigate`, `browser_click`, `browser_type`,
`browser_get_state` (indexed-DOM view), `browser_extract_content`,
`browser_get_html`, `browser_screenshot`, `browser_scroll`, `browser_go_back`,
`browser_list_tabs`, `browser_switch_tab`, `browser_close_tab`,
`retry_with_browser_use_agent`, `browser_list_sessions`,
`browser_close_session`, `browser_close_all`.

The browser persists across tool calls within a session.

## Requirements

- Linux (tested on Ubuntu 24.04). macOS / Windows: untested; the launcher
  will run but Xvfb-spawn won't fire because they have their own display.
- Python 3.11+.
- ~1.5 GB disk for Chromium + the venv.
- `sudo` for two apt steps during install (Xvfb and Chromium's native libs).

## Install

```bash
git clone https://github.com/Builderstar/browser-use-mcp-server.git
cd browser-use-mcp-server
bash scripts/install.sh
```

Flags: `--skip-apt` (no system packages), `--skip-chrome` (no Chromium download).

Pinned to `browser-use==0.12.9`. Override with `BROWSER_USE_VERSION=0.13.0 bash scripts/install.sh`.

## Verify

```bash
python3 scripts/smoke-test.py    # boots the server, lists the 16 tools
python3 scripts/e2e-test.py      # navigates Chromium to example.com via MCP
```

## Wire into an MCP client

OpenCode (`~/.config/opencode/opencode.json`):

```jsonc
{
  "mcp": {
    "browser-use": {
      "type": "local",
      "command": ["/absolute/path/to/browser-use-mcp-server/bin/browser-use-mcp"],
      "enabled": true,
      "timeout": 60000
    }
  }
}
```

Claude Desktop (`claude_desktop_config.json`):

```jsonc
{
  "mcpServers": {
    "browser-use": {
      "command": "/absolute/path/to/browser-use-mcp-server/bin/browser-use-mcp"
    }
  }
}
```

Same shape for Cursor and other MCP clients — `command` is the absolute path
to `bin/browser-use-mcp`.

## How it works

On startup the launcher:

1. Checks `$DISPLAY`. If it points to a working X server, uses it.
2. Otherwise spawns `Xvfb` on the first free display number in `:99..:199`
   and exports `DISPLAY` for the child process.
3. Execs `browser-use --headed --mcp`, which is the stdio MCP server
   provided by browser-use upstream.
4. Forwards SIGINT/SIGTERM/SIGHUP to the child; on exit, stops Xvfb and
   removes its lockfile.
5. Sets `PR_SET_PDEATHSIG=SIGTERM` so if the parent (your MCP client) is
   killed with `-9`, the launcher and everything under it (Xvfb, Chromium)
   exits cleanly instead of leaking.

## Environment variables

| Var | Effect |
|---|---|
| `BROWSER_USE_MCP_HEADLESS=1` | Skip Xvfb. Run without `--headed`. |
| `BROWSER_USE_MCP_DISPLAY=:99` | Force a specific X display number. |
| `BROWSER_USE_MCP_SCREEN` | Xvfb geometry, default `1920x1080x24`. |
| `BROWSER_USE_MCP_EXTRA_ARGS` | Whitespace-split args appended to `browser-use`. e.g. `--profile Default` to reuse a Chrome profile, or `--cdp-url ws://...` to attach to an existing Chrome. |
| `BROWSER_USE_HOME` | Override browser-use's state directory. Default `~/.browser-use`. |
| `DISPLAY` | If set and live, reused instead of spawning Xvfb. |

## What this defeats and what it doesn't

Defeats:
- Naive headless-browser detection (`navigator.webdriver`, missing
  `window.chrome`, etc., because Chromium is actually headed).
- Low-risk Cloudflare Turnstile checkbox challenges. Verified against
  scimagojr.com: the "Verify you are human" checkbox passes on one click.

Does **not** defeat:
- hCaptcha, reCAPTCHA v2/v3 with non-trivial scores.
- Fingerprint matchers (TLS, font enumeration, canvas, WebGL).
- IP-reputation systems (datacenter / VPN ranges).

For those, escape hatches:

- Use a real Chrome profile: `BROWSER_USE_MCP_EXTRA_ARGS="--profile Default"`.
- Attach to an external Chrome over CDP: `BROWSER_USE_MCP_EXTRA_ARGS="--cdp-url ws://..."`.
- Use [browser-use Cloud](https://browser-use.com).

## Limitations and known issues

- **stdio purity**: all launcher logs go to stderr. Anything on stdout other
  than JSON-RPC would break the handshake. The launcher enforces this.
- **One MCP server = one browser**. Multiple concurrent client sessions
  spawn separate launchers (and separate Xvfb / Chromium), on distinct
  display numbers and browser-use sessions. They don't share state.
- **State persists** across restarts in `~/.browser-use/`. Cookies, history,
  cached profile. Delete `~/.browser-use/default.*` to start fresh; keep
  `config.json`.
- **No `browser_eval` / JS execution tool**. `browser-use --mcp` deliberately
  exposes only high-level verbs. If you hit a case where raw JS is the only
  way out, `retry_with_browser_use_agent` is the upstream-provided escape
  hatch (slower, uses an LLM internally).
- **Cosmetic Cloudflare quirk**: page title may stay `"Just a moment..."`
  after the challenge clears. Don't gate readiness checks on `<title>`;
  check URL or DOM content instead.
- **Geographic IP shaping is real**: if your egress IP geolocates to
  country X, you'll get country X's version of localised sites (YouTube,
  Amazon, Google).
- **macOS / Windows**: untested. Xvfb is Linux-only. On those platforms
  the launcher will use your existing display, so headed mode works only
  if you're on a Linux desktop or via WSL with a configured display.

## Manual cleanup if something leaks

```bash
pkill -f browser-use-mcp
pkill -f "browser-use --mcp"
pkill -f "Xvfb :"          # be careful, only kills Xvfbs you spawned
rm -f /tmp/.X[0-9]*-lock
```

## Project layout

```
.
├── bin/browser-use-mcp         # the launcher
├── scripts/
│   ├── install.sh              # one-shot installer
│   ├── smoke-test.py           # tools/list sanity check
│   ├── e2e-test.py             # navigate + state through MCP
│   └── test-pdeathsig.sh       # verifies launcher dies with its parent
├── .github/workflows/smoke.yml # CI: smoke test on Ubuntu
├── LICENSE
└── README.md
```

## Docker

Not shipped in this release. The natural fit for a containerised browser MCP
server is HTTP/SSE transport rather than stdio (so the container can outlive
client sessions), and we want to get that right rather than ship a stdio
container that's only marginally useful. Tracking as a follow-up.

## Contributing

Issues and PRs welcome. If you're reporting that a specific site fails,
include:

- The site URL (or a description if private).
- What `browser_get_state` returned (or the page title).
- Whether `BROWSER_USE_MCP_EXTRA_ARGS="--profile Default"` helps.

## Attribution

All of the browser automation in this project is provided by
[browser-use](https://github.com/browser-use/browser-use) (MIT). This
repository contains only the Xvfb-aware launcher, install script, tests,
and packaging. If browser-use is useful to you, consider supporting them.

## License

MIT. See [LICENSE](LICENSE).
