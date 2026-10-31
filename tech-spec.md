# Build Control Tower

Using multiple agents simultaneously is a great way to speed up development, but the ability to build very large projects becomes a bottleneck. If 2 agents try to build simultaneously, they will overload the system and everything will slow to a crawl.

My solution is to make a new MCP server that acts as a control tower for builds, either through the comandline with xcodebuild or in Xcode via the Xcode MCP.

I'm thinking we want to have functionality that allows an agent to schedule a build with the MCP server, which adds its request to a global queue. If no build is currently happening, the agent at the top of the queue is given permission to build. Once the build completes, the agent calls the MCP to tell it that it is done.

Before giving an agent permission, the tool should look at active processes for either Xcode or a swift build process being active (using a large amount of CPU).

Detection uses `ps -Awwxo %cpu=,ucomm=,args=`: exact executable basenames avoid
matching wrappers, shell arguments, or unrelated paths. Build-driving
`xcodebuild` invocations count regardless of CPU, but informational queries
(`-list`, `-showBuildSettings`, etc.) do not. Otherwise only non-indexing
compiler CPU is summed against the threshold. Persistent `SWBBuildService` /
`XCBBuildService` processes are ignored, even when busy; their compiler children
are inspected instead. Index-only flags (`-index-file`, `-index-file-path`,
`-fsyntax-only`, `-typecheck`) and Xcode's `/Index.noindex/Build/` outputs are
excluded. Normal compilation's `-index-store-path` and `-index-unit-output-path`
are not exclusions. This is intentionally a best-effort process safety net;
there is no status-only Xcode MCP tool, and polling `GetBuildLog` from the daemon
would introduce an Xcode dependency and additional log materialization.

## Queue advancement

There are two mechanisms that advance the queue, and they play different roles:

1. **Explicit release (fast path).** When a build finishes, the agent calls the MCP to report it's done. This immediately advances the queue and grants the next request. This is the common case and keeps throughput high — we do not want agents idling while waiting on a slow poll.

2. **Slow poll (1–5 min safety net).** A background poll checks live process/CPU state for the two failure cases the fast path can't cover:
   - **External-build guard:** if a `swift`/`xcodebuild` process is consuming significant CPU that did *not* originate from the queue (e.g. a manual ⌘B in Xcode), withhold the next grant until it clears.
   - **Stale-grant reclaim:** if a grant is outstanding but the agent has gone silent (crashed or never reported done) *and* no build CPU has been observed for a grace window, reclaim the grant and advance.

The poll must be state-aware: it only *advances* when no grant is outstanding, and only *reclaims* (never re-grants) while a grant is outstanding. The grace window before reclaiming must be longer than one poll interval, so a slow-to-start build (low-CPU dependency resolution / indexing) is not mistaken for a dead agent.

## Heartbeats

A granted agent is otherwise invisible until it finishes, so a long or low-CPU build looks identical to a crashed one. Agents therefore check in with `build_heartbeat` while their build runs, roughly three times per grace window, optionally carrying their own 0–100 estimate of how far along the build is. The estimate is attached to the active ticket and shown in `queue_status` and the `/status` JSON, so other agents and a monitoring UI can see who is building what and how it's going. Agents are pushed to supply it but never required to; a rough guess is more useful than silence.

The silence clock the reclaim measures runs from the last sign of life, not the grant time, and *any* call naming the ticket counts — a status poll is proof of life just as much as a heartbeat. Heartbeats can only ever prolong a grant: a missed one never reclaims a slot on its own, because the `!buildActive` guard still has to agree that nothing is building. Reclaiming on silence alone would let the tower cut off a live build whose agent was just slow to report, which is precisely the double-build it exists to prevent.

### Instructions are stricter than the protocol — on purpose

The daemon tolerates an agent that never heartbeats (the `!buildActive` guard covers it whenever the build is visibly burning CPU), but the agent-facing text — the `initialize` instructions, the tool descriptions, and every ticket reply — states the heartbeat as a **requirement** of holding the slot, with the consequence spelled out concretely: the slot is reclaimed and granted to another agent *while your build is still running*. Hedged wording ("heartbeats protect a long or quiet build") reads to a model as "probably won't happen to me", and it stops checking in.

The larger cause is mechanical rather than motivational: an agent that runs `xcodebuild` as a single blocking foreground call has no turn in which to call anything, so the heartbeat isn't refused, it's unreachable. The instructions therefore prescribe the shape of the build — background it against a log file, or bound the wait below the quoted interval, then loop (check status → heartbeat → wait) — and say to decide this *before* taking the slot. The `GRANTED`, `QUEUED`, and reclaimed-ticket replies each restate the interval and the consequence, so the requirement is in front of the agent at the moment it chooses its next action rather than only in instructions it read once at connect time.

Progress must not require full-log polling. Estimate it cheaply from elapsed time
or a bounded tail/incremental read of the existing output log; omit it when
unknown. `GetBuildLog` can materialize a large file on every call even with a
filtered inline response. Agent-facing instructions therefore require extracting
the needed status/diagnostic excerpt and immediately deleting each generated
temporary snapshot and any temporary copies before the next poll, including
failure/cancellation/interruption paths. Only exact tool-returned or agent-created
temporary paths may be deleted, never original Xcode logs or result bundles.
A live redirected output log is different: keep one unique file while its writer
runs, and delete it only after the writer exits and diagnostics have been
extracted. Heartbeats themselves never fetch logs.

Routine monitoring should use a low-cost model, not repeated expensive reasoning
turns. When supported by the client, the instructions recommend one reusable
monitoring agent such as Luna at medium reasoning effort. It receives the existing
ticket, cadence, build handle, and exact log paths, with explicit ownership of
heartbeats, release, and cleanup; it neither requests another ticket nor starts
another build. The monitor must have the necessary tool and build/log access.
Only grants, completion, actionable failures, and yield/stop requests need to
wake the parent. This is client guidance, not daemon-enforced model selection
or a pricing guarantee, and unsupported delegation must never delay heartbeats.

Keep the two layers distinct when editing: the daemon's leniency is a safety property (never yank a live build), while the instructions' insistence is a behavioural nudge. Softening the text to match the code would reintroduce exactly the silence this section exists to prevent.

## Priority pre-emption

A human sometimes needs one build to run *now*, ahead of whatever is building. Two routes feed the same mechanism: the `request_priority_build` tool (an agent acting on its human's explicit instruction) and `POST /promote` (the monitor app, on a human's click).

The hard constraint is that **the daemon cannot interrupt a running agent**. MCP is pull-based — there is no way to push a "stop" — so a pre-empted holder only learns of it when it next calls `build_heartbeat` or `build_status`, and an agent that launched its build as a blocking foreground call has no turn in which to call anything at all. Pre-emption is therefore cooperative, and its latency is bounded by the holder's check-in interval. This is what makes the heartbeat rules above load-bearing rather than merely tidy: an agent that doesn't check in *cannot be told to stop*.

So the transfer is adaptive, keyed on the same `buildActive` reading the rest of the reconcile uses:

- **No build CPU** — the holder isn't really building, so there is nothing to interrupt and the slot moves immediately.
- **Build CPU visible** — the grant is marked `yieldRequestedAt` rather than seized. The holder is told to stop at its next check-in and hands over with a normal `finish_build`, which is the same fast path that already advances the queue. Only if it stays silent past `yieldDeadline` is the slot taken by force.

`yieldDeadline` must therefore exceed one heartbeat interval, or the slot would be seized before the agent could possibly have been told — the cooperative path would never once succeed, and every pre-emption would produce the overlapping builds the tower exists to prevent. It defaults to 1.5× the cadence and `fromEnvironment` floors any override at 1×, mirroring how the grace window is kept longer than the poll interval.

A pre-empted ticket is re-queued rather than dropped (unlike a stale reclaim, where the agent is presumed dead) and carries `preemptedAt`, which does two jobs: it ranks the ticket ahead of everything else so the interrupted build resumes first, and it makes the owner's next check-in report `.preempted` instead of a bland `.queued`. `BuildQueue` clears the marker once it has been reported, so the alarm is raised exactly once, in a reply the agent asked for — repeating it for the rest of an ordinary wait would just be shouting at an agent that already stopped.

Ordering generalises FIFO to a rank: pre-empted (0) → priority (1) → normal (2), FIFO within each. `enqueue` inserts at the end of the ticket's own rank group, so the common case — a normal request joining the back — is unchanged.

Two rules bound the blast radius:

- **Priority overrides the external-build guard.** A manual ⌘B owns no ticket and cannot be asked to yield, and the human has explicitly asked for this build now, so the guard gives way rather than deadlocking the request it was meant to protect.
- **A priority grant is not itself pre-emptible.** A second priority request waits at rank 1 instead of interrupting the first, which would start a chain discarding more work at every link.

One ordering detail is load-bearing in the implementation: the displaced ticket is re-queued *after* the advance, not before. Enqueuing first would put it at rank 0 — the head — and hand the slot straight back to the build being pre-empted.

`POST /promote` is the daemon's only mutating endpoint. It is unauthenticated like the read-only ones and safe on the same grounds: the listener is bound to `127.0.0.1`, so a caller is already running as this user and could stop the daemon outright. It only *marks* the ticket; the pre-emption itself happens in the following `reconcile`, which is where the build-CPU reading lives.

## Transport: one shared daemon over HTTP

The queue only serializes builds if every agent talks to the **same** queue. A stdio MCP server can't guarantee that — each client spawns its own process, hence its own in-memory queue — so the control tower runs as a single long-lived **HTTP daemon** bound to `127.0.0.1` (Streamable HTTP via the MCP SDK's `StatefulHTTPServerTransport`, served by Hummingbird). Every agent registers the daemon's URL and shares the one queue.

Each connected client gets its own MCP session (one `Server` + transport per session, so JSON-RPC ids and SSE streams stay isolated per client), but all sessions share the single `BuildQueue`. The stateful transport — not the stateless one — is required precisely for that isolation: stateless routing by bare JSON-RPC id would misroute responses between two agents that both number their requests from 1.

Alongside `/mcp`, two read-only JSON endpoints serve out-of-band monitors that have no reason to speak MCP: `/status` renders the live queue, and `/config` publishes the tuning in force. Both are session-free and side-effect-free — in particular `/status` calls `snapshot()` without driving a reconcile, so a menu-bar app polling every few seconds can never extend a grant or advance the queue as a side effect of watching it.

`/config` exists because the timing policy is per-install: a monitor that hardcodes the 360-second grace silently disagrees with any daemon launched with `BCT_GRACE_SECONDS`, and would then flag healthy builds as stale (or miss ones genuinely at risk). Publishing `staleGrantGraceSeconds` and the derived `recommendedHeartbeatSeconds` lets a client's health verdict track this daemon's actual behaviour. The values are immutable for the process lifetime, so clients fetch once and re-fetch only on reconnect.

Consequences to keep in mind:
- The daemon must be running before agents connect (it is not auto-spawned the way a stdio server is). Run it under launchd or a process manager.
- The queue is in-memory, so a daemon restart clears it. Acceptable for a session-scoped tool; agents simply re-request.
- Sessions that vanish without a `DELETE` currently leak their per-session `Server`/transport. Fine for a handful of agents; add idle-session reaping if that changes.