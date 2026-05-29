#!/usr/bin/env bash
# One-shot installer for browser-use-mcp-server on Linux.
#
# Idempotent. Re-runs safely. Sudo is requested only for the two apt steps
# (Xvfb and Chromium's native libs); everything else lives in the project
# directory.
#
# Usage:
#   bash scripts/install.sh                # full install
#   bash scripts/install.sh --skip-apt     # skip system packages (CI / pre-baked)
#   bash scripts/install.sh --skip-chrome  # skip Chromium download
set -euo pipefail

# Pin the browser-use version we've tested. Bump deliberately; the launcher
# assumes the --headed and --mcp flags are top-level (true in 0.12.x).
BROWSER_USE_VERSION="${BROWSER_USE_VERSION:-0.12.9}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="$PROJECT_DIR/.venv"
SKIP_APT=0
SKIP_CHROME=0
for arg in "$@"; do
    case "$arg" in
        --skip-apt) SKIP_APT=1 ;;
        --skip-chrome) SKIP_CHROME=1 ;;
        -h|--help)
            sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

# --- platform check --------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
    die "this installer only supports Linux. On macOS/Windows, follow the manual steps in README.md."
fi

# --- 1. Xvfb (only needed when no real $DISPLAY) ---------------------------
if [[ "$SKIP_APT" -eq 0 ]]; then
    if ! command -v Xvfb >/dev/null 2>&1; then
        log "installing Xvfb (apt)"
        if command -v sudo >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y --no-install-recommends xvfb xauth
        else
            apt-get update
            apt-get install -y --no-install-recommends xvfb xauth
        fi
    else
        log "Xvfb already installed, skipping"
    fi
else
    log "--skip-apt set, not installing Xvfb"
fi

# --- 2. uv (Python package manager) ----------------------------------------
if ! command -v uv >/dev/null 2>&1; then
    log "installing uv"
    curl -fsSL https://astral.sh/uv/install.sh | sh
    # uv's installer drops it in ~/.local/bin or ~/.cargo/bin
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    command -v uv >/dev/null 2>&1 || die "uv install ran but binary not on PATH. Re-source your shell or set PATH manually, then re-run."
else
    log "uv already installed ($(uv --version))"
fi

# --- 3. project venv -------------------------------------------------------
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    log "creating venv at $VENV_DIR"
    uv venv --python 3.12 "$VENV_DIR"
else
    log "venv exists, reusing"
fi

# --- 4. browser-use[cli] ---------------------------------------------------
log "installing browser-use[cli]==$BROWSER_USE_VERSION"
uv pip install --python "$VENV_DIR/bin/python" "browser-use[cli]==$BROWSER_USE_VERSION"

# --- 5. Chromium + its system libs -----------------------------------------
if [[ "$SKIP_CHROME" -eq 0 ]]; then
    if [[ ! -d "$HOME/.cache/ms-playwright" ]] || [[ -z "$(ls -A "$HOME/.cache/ms-playwright" 2>/dev/null)" ]]; then
        log "installing Chromium via browser-use (this calls apt and downloads ~300MB)"
        # `browser-use install` shells out to apt for native deps; requires sudo.
        "$VENV_DIR/bin/browser-use" install
    else
        log "Chromium cache exists at ~/.cache/ms-playwright, skipping download"
        log "  (delete that dir and re-run if you want a fresh install)"
    fi
else
    log "--skip-chrome set, not installing Chromium"
fi

# --- 6. sanity check -------------------------------------------------------
log "running browser-use doctor"
"$VENV_DIR/bin/browser-use" doctor || warn "doctor reported warnings; not all checks need to pass for basic use"

chmod +x "$PROJECT_DIR/bin/browser-use-mcp"

log "done."
cat <<EOF

Next steps:

  1. Verify the launcher boots and lists MCP tools:
     python3 $PROJECT_DIR/scripts/smoke-test.py

  2. Wire it into your MCP client. For OpenCode, in ~/.config/opencode/opencode.json:

     {
       "mcp": {
         "browser-use": {
           "type": "local",
           "command": ["$PROJECT_DIR/bin/browser-use-mcp"],
           "enabled": true,
           "timeout": 60000
         }
       }
     }

  3. Restart the client.

EOF
