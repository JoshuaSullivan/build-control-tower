# Build Control Tower

An MCP server that **serializes builds across multiple concurrent agents** so
they don't overload your machine. When several agents each try to build a large
project at once, everything slows to a crawl. Build Control Tower makes them
take turns: one build runs at a time, the rest wait in a queue.

It works for both command-line `xcodebuild`/`swift build` and builds started
inside Xcode — the server watches system CPU to notice builds it didn't grant
(for example, a manual ⌘B in Xcode) and holds the queue while they run.

It runs as a **single long-lived HTTP daemon** on localhost. Every agent on the
machine connects to that one daemon, so they all share one build queue. (Each
agent gets its own MCP session; the shared state is the queue, not the session.)

See [`tech-spec.md`](tech-spec.md) for the full design.

## Requirements

- macOS 14 or later
- Swift 6.2 / Xcode 26 or later (to build it)

## Install

```sh
git clone https://github.com/JoshuaSullivan/build-control-tower.git
cd build-control-tower
./build.sh                             # tests, builds release, installs to ~/.local/bin
```

`./build.sh` installs to `~/.local/bin` by default (a per-user location — no
`sudo`, consistent with the per-user launchd agent). To change it:

```sh
./build.sh --prefix /usr/local/bin     # install somewhere else
./build.sh --no-install                # build only, leave the binary in .build
```

If the install directory isn't on your `PATH`, the script prints the line to add
it. For the auto-starting daemon you don't need it on `PATH` at all — launchd and
the agents invoke it by absolute path / HTTP URL. See below.

## Run the daemon

The daemon must be running for agents to connect. It listens on
`http://127.0.0.1:7373/mcp` (set `BCT_PORT` to change the port).

**Auto-start at login (recommended).** Install it as a launchd agent — this
installs the binary to `~/.local/bin`, starts it now, and relaunches it at every
login (and if it crashes):

```sh
./build.sh --install-agent
```

**Run it manually instead:**

```sh
~/.local/bin/BuildControlTower
```

### Managing the launchd agent

Because the agent uses `KeepAlive`, a plain `kill <pid>` **does not stop it** —
launchd immediately relaunches it. Use `bootout`:

```sh
# Stop it now (stays stopped until re-installed):
launchctl bootout gui/$(id -u)/com.build-control-tower.daemon

# Start / restart it:
launchctl kickstart -k gui/$(id -u)/com.build-control-tower.daemon

# Status and logs:
launchctl print gui/$(id -u)/com.build-control-tower.daemon
tail -f ~/Library/Logs/build-control-tower.log

# Remove it entirely (stop + delete the LaunchAgent):
./build.sh --uninstall-agent
```

## Register with agents

The daemon is a single shared endpoint: `http://127.0.0.1:7373/mcp`. Point
**every** agent on the machine at that same URL so they all share one queue.
Because the queue is machine-global, register it globally (user-level), not
per-project.

### GitHub Copilot CLI

```sh
copilot mcp add --transport http build-control-tower http://127.0.0.1:7373/mcp
```

Or, inside an interactive `copilot` session, run `/mcp add` and choose the
**HTTP** type. Either path writes to `~/.copilot/mcp-config.json`:

```json
{
  "mcpServers": {
    "build-control-tower": {
      "type": "http",
      "url": "http://127.0.0.1:7373/mcp",
      "tools": ["*"]
    }
  }
}
```

### GitHub Copilot in VS Code

Add it once, globally, so it's available in every workspace:

```sh
code --add-mcp '{"name":"build-control-tower","type":"http","url":"http://127.0.0.1:7373/mcp"}'
```

Or run **MCP: Add Server** from the Command Palette (⇧⌘P) → **HTTP** → paste the
URL above → choose **Global**. To scope it to a single project instead, commit a
`.vscode/mcp.json` — note the root key is `servers`, **not** `mcpServers`:

```json
{
  "servers": {
    "build-control-tower": {
      "type": "http",
      "url": "http://127.0.0.1:7373/mcp"
    }
  }
}
```

### Claude Code

```sh
claude mcp add --transport http build-control-tower http://127.0.0.1:7373/mcp
```

### Any other MCP client

Add an HTTP server entry pointing at the same URL:

```json
{
  "mcpServers": {
    "build-control-tower": {
      "type": "http",
      "url": "http://127.0.0.1:7373/mcp"
    }
  }
}
```

## How an agent uses it

1. **`request_build`** — join the queue. Pass `agent` (who you are) and `task`
   (what you're building) so a human can tell concurrent agents apart; both are
   optional but strongly encouraged. Returns a ticket id and whether you're
   cleared to build now (`GRANTED`) or `QUEUED`.
2. **`build_status`** — if queued, poll with your ticket (~every 30–60s) until it
   reports `GRANTED`, then run your build.
3. **`build_heartbeat`** — while the build runs, check in with your ticket and an
   optional `progress` estimate (0–100). The interval is quoted to the agent in
   the `GRANTED` reply and repeated in every heartbeat reply — it's a third of
   this daemon's stale window (~120s at the default `BCT_GRACE_SECONDS=360`), so
   agents are told to use the number they were given rather than assume one.
   This is what tells the
   tower a long or quiet build is alive rather than abandoned, and the progress
   value is shown to other agents and to monitoring tools.
4. **`finish_build`** — always call this when the build finishes (or if you
   abandon a queued request). It immediately hands the slot to the next agent.
5. **`queue_status`** — inspect who's building and who's waiting.

If a granted agent crashes and never calls `finish_build`, a background poll
reclaims the abandoned slot once the agent has been silent (no heartbeat, no
status poll) *and* no build CPU has been seen for a grace window, so the queue
can't deadlock. Heartbeats only ever extend a grant — a missed one never
reclaims a slot on its own while a build is visibly running.

## Monitoring

`GET http://127.0.0.1:7373/status` returns the same queue view as `queue_status`
as JSON, for a menu-bar app or any out-of-band monitor. `active` is absent when
nothing holds the slot; `agent`, `task`, and `progress` are absent when the agent
didn't report them (so "no estimate yet" is distinguishable from `0`):

```json
{
  "active": {
    "id": "8B0E…",
    "agent": "claude-A",
    "task": "xcodebuild Teams iOS",
    "progress": 45,
    "elapsedSeconds": 90,
    "secondsSinceHeartbeat": 20
  },
  "waiting": [
    { "id": "7C02…", "agent": "claude-B", "task": "swift test", "waitingSeconds": 240 }
  ]
}
```

## Configuration

Tunable at launch via environment variables (all optional):

| Variable            | Default | Meaning                                                        |
| ------------------- | ------- | -------------------------------------------------------------- |
| `BCT_PORT`          | `7373`  | Localhost TCP port the daemon listens on.                      |
| `BCT_POLL_SECONDS`  | `120`   | Background safety-net poll interval.                           |
| `BCT_GRACE_SECONDS` | `360`   | Silence before a grant is reclaimed (kept > poll). Agents are told to heartbeat at a third of this. |
| `BCT_CPU_THRESHOLD` | `40`    | Combined compiler `%CPU` above which a build counts as active. |

**Making them stick.** Whatever is set when you run `./build.sh --install-agent`
is baked into the launchd plist, so it survives logout and reboot:

```sh
BCT_GRACE_SECONDS=900 ./build.sh --install-agent   # agents now told to beat every 300s
```

Variables you don't set are omitted from the plist, leaving the daemon's own
defaults in charge so they can change between releases. The daemon logs the
values actually in force on startup — useful for a long-running agent whose
launch environment you no longer remember:

```sh
grep Configuration: ~/Library/Logs/build-control-tower.log
# Configuration: port 7373, poll 120s, stale-grant grace 900s (heartbeat cadence 300s), CPU threshold 40%
```

## Development

```sh
swift build                                  # debug build
swift test                                   # run the suite
swift test --filter onlyOneGrantAtATime      # run a single test
```

## License

MIT — see [LICENSE](LICENSE).
