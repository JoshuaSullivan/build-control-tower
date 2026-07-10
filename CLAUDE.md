# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Swift Package Manager executable; the SDK is fetched on first build.

```sh
swift build                                  # debug build
swift test                                   # full test suite (Swift Testing)
swift test --filter onlyOneGrantAtATime      # a single test
./build.sh                                   # test + release build, prints MCP registration snippet
./build.sh --install ~/.local/bin            # also install the binary to a stable path
```

## Stack & layout

- **Swift 6.2 / macOS 14**, strict concurrency. A command-line executable (not an iOS app), so the iOS-specific defaults in the global CLAUDE.md don't apply here.
- Depends only on the official [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk), pinned with `.upToNextMinor(from: "0.12.1")` — it's pre-1.0, so **don't loosen the pin** without checking for API breaks. The dependency compiles into the binary; there is no runtime dependency (e.g. no Node).
- Source is one type per file under `Sources/BuildControlTower/`. The two pure cores — `QueueState` (the advancement state machine) and `SystemBuildProbe.isBuildActive` (the `ps` parser) — take time and the "build active" signal as plain parameters, so they're unit-tested directly without a clock or real processes. `BuildQueue` (an `actor`) wraps `QueueState` with the real clock + probe and is the *only* mutator, which is what enforces the single-grant invariant across concurrent MCP calls.

## Hard constraint: stdout is the JSON-RPC channel

The server speaks MCP over stdio. **Never write to stdout** except through the SDK's transport — a stray `print` corrupts the protocol stream and breaks every client. Send diagnostics to stderr only.

## What we're building

**Build Control Tower** is an MCP server that serializes builds across multiple concurrent agents. The problem it solves: when several agents each try to build a large project (`xcodebuild` on the command line, or via the Xcode MCP) at the same time, they overload the machine and every build slows to a crawl. The control tower forces builds to run one at a time.

## Core design (from `tech-spec.md`)

The server maintains a single global build queue and exposes four tools (defined in `ToolCatalog`): `request_build`, `build_status`, `finish_build`, `queue_status`. The flow:

1. **Schedule** (`request_build`) — the agent's request is appended to the queue and gets a ticket id. If nothing is building, the head of the queue is granted immediately.
2. **Poll** (`build_status`) — a queued agent re-checks its ticket until `GRANTED`. This call also drives a reconcile, so an actively-waiting agent helps advance the queue faster than the background poll.
3. **Report completion** (`finish_build`) — releases the slot so the next request is granted.

### Two mechanisms advance the queue

- **Explicit release (fast path).** The completion call immediately advances the queue and grants the next request. This is the common case and is what keeps throughput high — agents should not idle waiting on the poll.
- **Slow poll (1–5 min safety net).** A background loop inspects live process/CPU state to cover the two cases the fast path cannot:
  - **External-build guard** — withhold the next grant while a `swift`/`xcodebuild` process is consuming significant CPU that did *not* originate from the queue (e.g. a manual build in Xcode).
  - **Stale-grant reclaim** — if a grant is outstanding but the agent has gone silent (crashed / never reported done) *and* no build CPU has been observed for a grace window, reclaim the grant and advance.

### Invariants to preserve

- At most one build holds a grant at any time.
- The poll is **state-aware**: it only *advances* when no grant is outstanding, and only *reclaims* (never re-grants) while a grant is outstanding. Advancing on "no build detected" without checking grant state causes a double-grant during the window between granting an agent and its build ramping up CPU.
- The stale-grant grace window must be longer than one poll interval, so a slow-to-start build (low-CPU dependency resolution / indexing) is not mistaken for a dead agent.
- The process/CPU check is an out-of-band safety net layered on top of the queue, not a replacement for the explicit release.
