# Build Control Tower

Using multiple agents simultaneously is a great way to speed up development, but the ability to build very large projects becomes a bottleneck. If 2 agents try to build simultaneously, they will overload the system and everything will slow to a crawl.

My solution is to make a new MCP server that acts as a control tower for builds, either through the comandline with xcodebuild or in Xcode via the Xcode MCP.

I'm thinking we want to have functionality that allows an agent to schedule a build with the MCP server, which adds its request to a global queue. If no build is currently happening, the agent at the top of the queue is given permission to build. Once the build completes, the agent calls the MCP to tell it that it is done.

Before giving an agent permission, the tool should look at active processes for either Xcode or a swift build process being active (using a large amount of CPU).

## Queue advancement

There are two mechanisms that advance the queue, and they play different roles:

1. **Explicit release (fast path).** When a build finishes, the agent calls the MCP to report it's done. This immediately advances the queue and grants the next request. This is the common case and keeps throughput high — we do not want agents idling while waiting on a slow poll.

2. **Slow poll (1–5 min safety net).** A background poll checks live process/CPU state for the two failure cases the fast path can't cover:
   - **External-build guard:** if a `swift`/`xcodebuild` process is consuming significant CPU that did *not* originate from the queue (e.g. a manual ⌘B in Xcode), withhold the next grant until it clears.
   - **Stale-grant reclaim:** if a grant is outstanding but the agent has gone silent (crashed or never reported done) *and* no build CPU has been observed for a grace window, reclaim the grant and advance.

The poll must be state-aware: it only *advances* when no grant is outstanding, and only *reclaims* (never re-grants) while a grant is outstanding. The grace window before reclaiming must be longer than one poll interval, so a slow-to-start build (low-CPU dependency resolution / indexing) is not mistaken for a dead agent.

## Transport: one shared daemon over HTTP

The queue only serializes builds if every agent talks to the **same** queue. A stdio MCP server can't guarantee that — each client spawns its own process, hence its own in-memory queue — so the control tower runs as a single long-lived **HTTP daemon** bound to `127.0.0.1` (Streamable HTTP via the MCP SDK's `StatefulHTTPServerTransport`, served by Hummingbird). Every agent registers the daemon's URL and shares the one queue.

Each connected client gets its own MCP session (one `Server` + transport per session, so JSON-RPC ids and SSE streams stay isolated per client), but all sessions share the single `BuildQueue`. The stateful transport — not the stateless one — is required precisely for that isolation: stateless routing by bare JSON-RPC id would misroute responses between two agents that both number their requests from 1.

Consequences to keep in mind:
- The daemon must be running before agents connect (it is not auto-spawned the way a stdio server is). Run it under launchd or a process manager.
- The queue is in-memory, so a daemon restart clears it. Acceptable for a session-scoped tool; agents simply re-request.
- Sessions that vanish without a `DELETE` currently leak their per-session `Server`/transport. Fine for a handful of agents; add idle-session reaping if that changes.