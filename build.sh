#!/usr/bin/env bash
#
# Build Control Tower — build & deploy helper.
#
# Usage:
#   ./build.sh                  Run tests, then build the release binary.
#   ./build.sh --install DIR    Also copy the binary into DIR (e.g. ~/.local/bin).
#   ./build.sh --skip-tests     Build without running the test suite first.
#
# On success it prints the absolute binary path and a ready-to-paste MCP
# registration snippet.

set -euo pipefail
cd "$(dirname "$0")"

INSTALL_DIR=""
RUN_TESTS=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)
            INSTALL_DIR="${2:-}"
            [[ -n "$INSTALL_DIR" ]] || { echo "error: --install requires a directory" >&2; exit 2; }
            shift 2
            ;;
        --skip-tests)
            RUN_TESTS=0
            shift
            ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

if [[ "$RUN_TESTS" -eq 1 ]]; then
    echo "==> Running tests..."
    swift test
fi

echo "==> Building release binary..."
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/BuildControlTower"
[[ -x "$BIN" ]] || { echo "error: expected binary not found at $BIN" >&2; exit 1; }

if [[ -n "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    cp "$BIN" "$INSTALL_DIR/"
    BIN="$INSTALL_DIR/BuildControlTower"
    echo "==> Installed to $BIN"
fi

cat <<EOF

Build Control Tower is ready.
  Binary: $BIN

Start the shared daemon (listens on http://127.0.0.1:7373/mcp; set BCT_PORT to change):
  "$BIN"

Then point every agent at the SAME daemon:
  claude mcp add --transport http build-control-tower http://127.0.0.1:7373/mcp

…or add to your MCP client config:
  {
    "mcpServers": {
      "build-control-tower": {
        "type": "http",
        "url": "http://127.0.0.1:7373/mcp"
      }
    }
  }

The daemon must be running for agents to connect. To keep it alive across
logins, run it under launchd (a LaunchAgent) or your process manager of choice.
EOF
