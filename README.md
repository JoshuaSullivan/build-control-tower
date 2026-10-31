# Build Control Tower

An MCP server that **serializes builds across multiple concurrent agents** so
they don't overload your machine. When several agents each try to build a large
project at once, everything slows to a crawl. Build Control Tower makes them
take turns: one build runs at a time, the rest wait in a queue.

It works for both command-line `xcodebuild`/`swift build` and builds started
inside Xcode — the server checks process names and arguments to notice builds it
didn't grant (for example, a manual ⌘B in Xcode) and holds the queue while they run.
Build-driving `xcodebuild` commands count even at low CPU; otherwise non-indexing
compiler processes must exceed the combined CPU threshold. Busy Xcode build
services, indexing/type-checking commands, and queries such as `xcodebuild -list`
or `-showBuildSettings` do not block the queue. Normal builds that also write
index data still count. This remains a best-effort safety net, not an Xcode MCP
dependency or a replacement for tickets and heartbeats.

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

   The agent-facing text presents this as **mandatory**, and tells agents to run
   the build in the background against a log (or with a wait shorter than the
   interval) rather than as one blocking call — an agent that blocks on the build
   gets no turn in which to check in, which is the main reason heartbeats get
   skipped in practice. That's deliberately stricter than the daemon's own rule
   (below); see [`tech-spec.md`](tech-spec.md) › "Heartbeats".

   **Use a low-cost monitor.** Routine queue/progress polling, heartbeats, and log
   cleanup do not need an expensive reasoning model. When the client supports
   delegation and model selection, prefer one inexpensive agent such as **Luna
   at medium reasoning effort**, reused for the whole build. Hand off the existing
   ticket, quoted interval, build handle, and exact log paths, with one owner for
   heartbeats, `finish_build`, and cleanup. Confirm tool and build/log access
   before handing off. The monitor must not request another ticket or start
   another build; notify the parent when `GRANTED`, on completion, actionable
   failure, or a yield/stop request. If delegation or that model is unavailable,
   use the lowest-cost suitable option without delaying or skipping heartbeats.

   **Keep log polling bounded.** A heartbeat needs no log fetch; estimate progress
   from elapsed time or a bounded tail/incremental read of the existing output
   log, and omit it when unknown. Do not repeatedly call `GetBuildLog` or copy
   full logs just for progress: each call can create a multi-megabyte file even
   if the inline response is filtered. After any fetch, extract the status or
   diagnostic lines needed and **immediately delete that call's generated
   temporary log file and any temporary copies before the next poll**, including
   on failure, cancellation, or interruption. Delete only exact temporary paths
   returned by the tool or created by you, never Xcode's original logs or result
   bundles. For command-line builds, use one unique output log, do not delete or
   truncate it while the writer is running, and remove it after the writer exits
   and needed diagnostics have been extracted. Retain a small diagnostic excerpt,
   not a full log per poll.
4. **`finish_build`** — always call this when the build finishes (or if you
   abandon a queued request). It immediately hands the slot to the next agent.
5. **`queue_status`** — inspect who's building and who's waiting.

If a granted agent crashes and never calls `finish_build`, a background poll
reclaims the abandoned slot once the agent has been silent (no heartbeat, no
status poll) *and* no build CPU has been seen for a grace window, so the queue
can't deadlock. Heartbeats only ever extend a grant — a missed one never
reclaims a slot on its own while a build is visibly running.

## Priority pre-emption

When a human needs one build to run *now*, it can jump the queue and interrupt
whatever is building:

- **`request_priority_build`** — an agent's own route in. Its description gates
  it hard to "only when your human explicitly asked", because an agent that
  self-declares priority for its own work makes the queue meaningless.
- **`POST /promote`** with `{"ticket": "<uuid>"}` — the human's route in, for the
  monitor app. Promotes a waiting build and pre-empts the running one. Returns
  the updated `/status` snapshot, `404` if the ticket isn't waiting (already
  finished, or already holding the slot), `400` for a malformed body.

The daemon **cannot interrupt an agent mid-build** — MCP is pull-based, so the
holder only hears about it on its next check-in. Pre-emption is therefore
adaptive:

- **No build CPU visible** — the holder isn't really building, so the slot moves
  immediately.
- **A build is clearly running** — the grant is *asked* to stand down. The holder
  learns on its next `build_heartbeat` / `build_status`, kills its build, and
  calls `finish_build`. If it never complies within `BCT_YIELD_SECONDS`, the slot
  is taken anyway.

Either way the pre-empted ticket stays valid and goes to the **head of the
queue**, so it resumes first — the interruption costs it its turn and nothing
more. The waiting line is ordered pre-empted → priority → normal, FIFO within
each group.

Two further rules:

- A priority request **overrides the external-build guard**: it is granted even
  while a manual Xcode ⌘B is burning CPU, since no ticket exists that could yield
  to it.
- A priority grant is **not itself pre-emptible**. A second priority request
  waits its turn rather than starting a chain of interruptions that discards more
  work at every link.

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
    "secondsSinceHeartbeat": 20,
    "priority": false,
    "yieldRequestedSecondsAgo": 12
  },
  "waiting": [
    {
      "id": "7C02…",
      "agent": "claude-B",
      "task": "swift test",
      "waitingSeconds": 240,
      "priority": true,
      "preempted": false
    }
  ]
}
```

`priority` marks a build that jumped the queue. `yieldRequestedSecondsAgo` is
present only while a build has been asked to stand down for a priority request —
it is living on borrowed time until its agent complies or `BCT_YIELD_SECONDS`
passes. `preempted` marks a waiting ticket that lost the slot and is waiting to
resume.

Note that `secondsSinceHeartbeat` measures the last *sign of life*, not strictly
the last `build_heartbeat` — a `build_status` poll refreshes it too. Polling
`/status` is side-effect-free: it neither extends a grant nor advances the queue.

`GET http://127.0.0.1:7373/config` returns the tuning this daemon was actually
launched with, so a monitor can derive its own staleness thresholds from real
policy rather than assuming the defaults:

```json
{
  "version": "0.3.0",
  "port": 7373,
  "pollSeconds": 120,
  "staleGrantGraceSeconds": 360,
  "recommendedHeartbeatSeconds": 120,
  "cpuThresholdPercent": 40,
  "yieldDeadlineSeconds": 180
}
```

These values cannot change while the process lives, so fetch once and re-fetch
only after a reconnect — that implies a restart, which is the only way they move.
A monitor pointed at an older daemon gets a `404` here and should fall back to the
defaults above.

## Configuration

Tunable at launch via environment variables (all optional):

| Variable            | Default | Meaning                                                        |
| ------------------- | ------- | -------------------------------------------------------------- |
| `BCT_PORT`          | `7373`  | Localhost TCP port the daemon listens on.                      |
| `BCT_POLL_SECONDS`  | `120`   | Background safety-net poll interval.                           |
| `BCT_GRACE_SECONDS` | `360`   | Silence before a grant is reclaimed (kept > poll). Agents are told to heartbeat at a third of this. |
| `BCT_CPU_THRESHOLD` | `40`    | Combined compiler `%CPU` above which a build counts as active. |
| `BCT_YIELD_SECONDS` | `180`   | How long a pre-empted build has to release the slot before it's taken. Defaults to 1.5× the heartbeat cadence and is floored at 1×, so the holder always gets at least one check-in in which to comply. |

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
# Configuration: port 7373, poll 120s, stale-grant grace 900s (heartbeat cadence 300s), yield deadline 450s, CPU threshold 40%
```

## Development

```sh
swift build                                  # debug build
swift test                                   # run the suite
swift test --filter onlyOneGrantAtATime      # run a single test
```

## License

MIT — see [LICENSE](LICENSE).
