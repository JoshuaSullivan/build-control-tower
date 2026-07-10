# Build Control Tower

An MCP server that **serializes builds across multiple concurrent agents** so
they don't overload your machine. When several agents each try to build a large
project at once, everything slows to a crawl. Build Control Tower makes them
take turns: one build runs at a time, the rest wait in a queue.

It works for both command-line `xcodebuild`/`swift build` and builds started
inside Xcode — the server watches system CPU to notice builds it didn't grant
(for example, a manual ⌘B in Xcode) and holds the queue while they run.

See [`tech-spec.md`](tech-spec.md) for the full design.

## Requirements

- macOS 14 or later
- Swift 6.2 / Xcode 26 or later (to build it)

## Install

```sh
git clone <your-remote> build-control-tower
cd build-control-tower
./build.sh --install ~/.local/bin      # runs tests, builds release, installs the binary
```

`build.sh` prints a ready-to-paste registration snippet. To register with Claude
Code:

```sh
claude mcp add build-control-tower ~/.local/bin/BuildControlTower
```

…or add it to any MCP client config:

```json
{
  "mcpServers": {
    "build-control-tower": { "command": "/absolute/path/to/BuildControlTower" }
  }
}
```

Point every agent that shares the machine at the **same** server so they share
one queue.

## How an agent uses it

1. **`request_build`** — join the queue. Returns a ticket id and whether you're
   cleared to build now (`GRANTED`) or `QUEUED`.
2. **`build_status`** — if queued, poll with your ticket (~every 30–60s) until it
   reports `GRANTED`, then run your build.
3. **`finish_build`** — always call this when the build finishes (or if you
   abandon a queued request). It immediately hands the slot to the next agent.
4. **`queue_status`** — inspect who's building and who's waiting.

If a granted agent crashes and never calls `finish_build`, a background poll
reclaims the abandoned slot once it has been idle (no build CPU) past a grace
window, so the queue can't deadlock.

## Configuration

Tunable at launch via environment variables (all optional):

| Variable            | Default | Meaning                                                        |
| ------------------- | ------- | -------------------------------------------------------------- |
| `BCT_POLL_SECONDS`  | `120`   | Background safety-net poll interval.                           |
| `BCT_GRACE_SECONDS` | `360`   | Idle time before a silent grant is reclaimed (kept > poll).    |
| `BCT_CPU_THRESHOLD` | `40`    | Combined compiler `%CPU` above which a build counts as active. |

## Development

```sh
swift build                                  # debug build
swift test                                   # run the suite
swift test --filter onlyOneGrantAtATime      # run a single test
```
