#!/usr/bin/env bash
#
# Build Control Tower — build & deploy helper.
#
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.build-control-tower.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/build-control-tower.log"
DOMAIN="gui/$(id -u)"
PORT="${BCT_PORT:-7373}"

# Per-user install location by default: this is a per-user daemon (its launchd
# agent and config live under $HOME), so no sudo and no /usr/local ownership
# fights. Override with --prefix; opt out with --no-install.
DEFAULT_INSTALL_DIR="$HOME/.local/bin"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
RUN_TESTS=1
INSTALL_AGENT=0
SKIP_INSTALL=0

usage() {
    cat <<USAGE
Build Control Tower — build & deploy helper.

Usage:
  ./build.sh                    Run tests, build the release binary, and install
                                it to $DEFAULT_INSTALL_DIR.
  ./build.sh --prefix DIR       Install into DIR instead of the default.
  ./build.sh --no-install       Build only; leave the binary in .build.
  ./build.sh --install-agent    Install + start a launchd agent that auto-starts
                                the daemon at login (honors --prefix).
  ./build.sh --uninstall-agent  Stop the daemon and remove the launchd agent.
  ./build.sh --skip-tests       Build without running the test suite first.

  --install DIR is accepted as an alias for --prefix DIR.

Environment:
  BCT_PORT   Port the daemon listens on (default 7373); baked into the agent.
USAGE
}

write_agent_plist() {
    local bin="$1"
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$bin</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>BCT_PORT</key>
        <string>$PORT</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
PLIST
}

bootstrap_agent() {
    launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
    if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
        # Fall back to the legacy launchctl API on older systems.
        launchctl unload "$PLIST" 2>/dev/null || true
        launchctl load -w "$PLIST"
    fi
    launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true
}

uninstall_agent() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null \
        || launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Stopped and removed the launchd agent ($LABEL); it will no longer auto-start."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix|--install)
            INSTALL_DIR="${2:-}"
            [[ -n "$INSTALL_DIR" ]] || { echo "error: $1 requires a directory" >&2; exit 2; }
            shift 2
            ;;
        --no-install) SKIP_INSTALL=1; shift ;;
        --install-agent) INSTALL_AGENT=1; shift ;;
        --uninstall-agent) uninstall_agent; exit 0 ;;
        --skip-tests) RUN_TESTS=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

# The launchd agent needs a stable binary path on disk, so it can't skip install.
if [[ "$INSTALL_AGENT" -eq 1 && "$SKIP_INSTALL" -eq 1 ]]; then
    echo "error: --no-install cannot be combined with --install-agent (the agent needs an installed binary)" >&2
    exit 2
fi

# --no-install wins: build only, leave the binary in .build.
if [[ "$SKIP_INSTALL" -eq 1 ]]; then
    INSTALL_DIR=""
fi

if [[ "$RUN_TESTS" -eq 1 ]]; then
    echo "==> Running tests..."
    swift test
fi

echo "==> Building release binary..."
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/BuildControlTower"
[[ -x "$BIN" ]] || { echo "error: expected binary not found at $BIN" >&2; exit 1; }

INSTALL_ON_PATH=1
if [[ -n "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    cp "$BIN" "$INSTALL_DIR/"
    BIN="$INSTALL_DIR/BuildControlTower"
    echo "==> Installed to $BIN"
    [[ ":$PATH:" == *":$INSTALL_DIR:"* ]] || INSTALL_ON_PATH=0
fi

if [[ "$INSTALL_AGENT" -eq 1 ]]; then
    write_agent_plist "$BIN"
    bootstrap_agent
    cat <<EOF

Build Control Tower is running and will auto-start at login.
  Endpoint: http://127.0.0.1:$PORT/mcp
  Logs:     $LOG_FILE

Register every agent with the SAME daemon (pick your client):
  GitHub Copilot CLI:
    copilot mcp add --transport http build-control-tower http://127.0.0.1:$PORT/mcp
  VS Code (Copilot):
    code --add-mcp '{"name":"build-control-tower","type":"http","url":"http://127.0.0.1:$PORT/mcp"}'
  Claude Code:
    claude mcp add --transport http build-control-tower http://127.0.0.1:$PORT/mcp

Manage the daemon:
  Stop it (and disable auto-start until re-installed):
    launchctl bootout $DOMAIN/$LABEL
    # NOTE: a plain 'kill <pid>' does NOT stick — KeepAlive relaunches it. Use bootout.
  Restart it:
    launchctl kickstart -k $DOMAIN/$LABEL
  Status / logs:
    launchctl print $DOMAIN/$LABEL
    tail -f $LOG_FILE
  Remove entirely:
    ./build.sh --uninstall-agent
EOF
    exit 0
fi

if [[ "$INSTALL_ON_PATH" -eq 0 ]]; then
    cat <<EOF

Note: $INSTALL_DIR is not on your PATH. Either use the full path shown below,
or add it to your shell profile:
  echo 'export PATH="$INSTALL_DIR:\$PATH"' >> ~/.zshrc && source ~/.zshrc
EOF
fi

cat <<EOF

Build Control Tower is ready.
  Binary: $BIN

Start the shared daemon (listens on http://127.0.0.1:$PORT/mcp; set BCT_PORT to change):
  "$BIN"

Or install it as an auto-starting launchd agent (recommended):
  ./build.sh --install-agent

Then point every agent at the SAME daemon (pick your client):
  GitHub Copilot CLI:
    copilot mcp add --transport http build-control-tower http://127.0.0.1:$PORT/mcp
  VS Code (Copilot):
    code --add-mcp '{"name":"build-control-tower","type":"http","url":"http://127.0.0.1:$PORT/mcp"}'
  Claude Code:
    claude mcp add --transport http build-control-tower http://127.0.0.1:$PORT/mcp

…or add to any MCP client config (VS Code's .vscode/mcp.json uses "servers", not "mcpServers"):
  {
    "mcpServers": {
      "build-control-tower": {
        "type": "http",
        "url": "http://127.0.0.1:$PORT/mcp"
      }
    }
  }
EOF
