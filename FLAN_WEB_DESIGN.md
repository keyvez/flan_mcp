# flan_web — design proposal

> **Status: implemented.** Steps 1–3 below are built:
> - `flan_server`: `/ws` WebSocket route, `web_queue`, and
>   `/api/web-messages` (+ `/consume`) endpoints.
> - `flan_mcp`: `process_queue` / `get_user_message` now also drain the
>   server-side web queue.
> - `flan_web`: the React/TypeScript package
>   (`packages/flan_web`) — `FlanProvider`, message overlay, annotation
>   canvas, and DOM inspector.
>
> Still open: the Babel/Vite `data-flan-source` plugin (the package reads
> the attribute but nothing stamps it yet), and wiring `flan_web` into
> the Remotion site. The original proposal text is kept below for context.

Goal: let a React/web app (the Remotion promo site) send annotated
feedback to an AI agent, the way `flan_flutter` does for Flutter apps —
and also wire `flan_flutter` into the tow Flutter apps.

This is a **cross-repo change to `~/dev/flan_mcp`** plus a new package.
Writing it up for review before modifying the Flan framework.

## Why flan_web can't just reuse flan_flutter's transport

`flan_flutter` ↔ agent works like this:
- `flan_flutter` registers Dart VM **service extensions** via
  `dart:developer` and posts `postEvent` notifications.
- The `flan_mcp` server connects to the running app over the **Dart VM
  Service protocol** and calls those extensions.
- The user-message **queue lives inside the Flutter app**
  (`UserMessageService`); the MCP `process_queue` tool drains it through
  a VM-service extension.

A web app has no Dart VM and cannot register VM-service extensions.
There is no DOM equivalent. So flan_web needs a different transport —
and, critically, **a server-side message queue**, because the web app
can't host one the agent can reach the way a Flutter app does.

## What already exists in the Flan server (good news)

- The Rust `flan_server` is an **Axum HTTP server** (port ~4050) with
  routes incl. `/api/register-channel`, `/api/flush`, `/api/status`,
  `/api/test-send`.
- `Cargo.toml` already depends on `tungstenite` (WebSocket lib, used as
  a client today).
- `UserMessageService` has a `suppressVmEvents` flag for "when a
  flan-channel handles delivery" — Flan already anticipates non-VM
  channels.

But `/api/register-channel` routes to **terminal panes**, not a message
queue, and there is no server-side queue today.

## Proposed design

### 1. Server: a web-channel message queue + WebSocket (Rust, flan_server)

- Add `SharedState.web_queue: RwLock<Vec<WebMessage>>` — an in-memory
  queue of annotated messages from web clients.
- Add `GET /ws` — an Axum WebSocket route (`axum::extract::ws`). The web
  client connects here. Server → client: agent status, heartbeat,
  "listening" state. Client → server: queued annotated messages.
- Messages arriving on the socket are appended to `web_queue`.
- Add `GET /api/web-messages` (peek) and `POST /api/web-messages/consume`
  (drain) — or fold into existing flush plumbing.

### 2. MCP server: drain the web queue (Dart, flan_mcp)

- `process_queue` / `get_user_message` already drains the Flutter app's
  queue. Extend them to also pull from the server's `web_queue` via the
  new HTTP endpoint, so the agent gets web + Flutter messages uniformly.
- Same message shape (`queueId`, `type`, `text`, `timestamp`, plus
  web-specific `annotations`, `selector`, `sourceHint`).

### 3. flan_web package (new — React/TypeScript)

A small React library mirroring `flan_flutter`'s in-app command center:
- `<FlanProvider>` — opens the `/ws` connection, exposes status.
- **Inspector** (`Ctrl+Shift+H`) — hover/lock DOM elements; report
  `tagName`, CSS selector path, React component name (via DevTools hook
  or `data-flan-source` build-time annotations), bounding box.
- **Annotations** (`Ctrl+Shift+A`) — draw rectangles, label them; each
  paired with the DOM element underneath.
- **Message overlay** (double-tap `Alt`) — free-form text + sketch.
- Sends batches over the WebSocket as `WebMessage`s.

The web equivalent of "Dart source file:line" is weaker — the DOM
doesn't carry source locations. Options: a Vite/Babel plugin that stamps
`data-flan-source="file:line"` on JSX elements, or settle for component
name + selector. **Recommend the Babel plugin** for parity.

### 4. Wire-up

- Remotion site: wrap the app in `<FlanProvider>`.
- Flutter apps (tower, customer): add `flan_flutter`, init `FlanBinding`
  in `main.dart` — this part works as designed today, no new protocol.

## Scope / risk

- Server change is real Rust work in someone's framework — a new
  subsystem (queue + WS), needs care so it doesn't break the VM-service
  path. **Should be reviewed, not built blind.**
- `flan_web` is ~15–20 small modules (inspector, annotation canvas,
  overlay, ws client) — a few days.
- The source-location parity (Babel plugin) is its own sub-project.

## Recommendation

Build it in this order, checking in after each:
1. Flan server: `/ws` route + `web_queue` + consume endpoint (smallest
   testable unit — verify with a `wscat` script).
2. MCP `process_queue` extension to drain `web_queue`.
3. `flan_web` React package — message overlay first (simplest), then
   annotations, then inspector.
4. Wire into the Remotion site.
5. Separately: `flan_flutter` into the tow Flutter apps.

Each step is independently verifiable. Step 1 modifies the Flan
framework — confirm the approach before I start there.
