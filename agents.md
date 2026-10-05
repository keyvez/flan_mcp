# Flan MCP — Agent Notes

## Project Structure

- **Monorepo** with two publishable packages under `packages/`:
  - `flan_flutter` — Flutter SDK that adds overlay UI (inspector, annotations, queue panel, error dot) and VM service extensions
  - `flan_mcp` — Dart MCP server that connects to a running Flutter app via VM service and exposes tools to AI agents
- Example app at `packages/flan_mcp/example/` (standard Flutter counter app with Flan enabled)

## Architecture (3-Layer Pattern)

When adding a new feature that bridges Flutter and MCP:

1. **Flutter binding** (`packages/flan_flutter/lib/src/binding/flan_binding.dart`) — Register a VM service extension (e.g. `flan.getErrors`)
2. **Connector** (`packages/flan_mcp/lib/src/vm_service/vm_service_connector.dart`) — Add a method that calls the extension (e.g. `getErrors()`)
3. **MCP context** (`packages/flan_mcp/lib/src/vm_service/vm_service_context.dart`) — Register the MCP tool with `McpServer.registerTool()` including description, annotations, input schema, and callback

## Key Files

- `packages/flan_flutter/lib/src/overlay/flan_overlay_widget.dart` — Main overlay widget (~1400+ lines). Handles keyboard shortcuts, annotation drafts, queue panel, error panel, inspector overlay, text message overlay
- `packages/flan_flutter/lib/src/services/annotation_service.dart` — Annotation CRUD, draw state machine
- `packages/flan_flutter/lib/src/services/user_message_service.dart` — Message queue with persistence to SharedPreferences
- `packages/flan_flutter/lib/src/services/error_interceptor.dart` — Captures FlutterError.onError and platform errors
- `packages/flan_flutter/lib/src/services/screenshot_service.dart` — Screenshot capture with RepaintBoundary support

## Overlay Widget Concepts

- **Annotation draft**: When annotations are drawn, a draft message is auto-queued via `_upsertQueuedAnnotationDraft()`. The draft includes a cropped thumbnail captured asynchronously.
- **Generation counters**: `_draftThumbnailGeneration` prevents stale async thumbnails; `_agentConsumeGeneration` detects when agent consumed messages.
- **Suppression flags**: `_suppressAnnotationDraftUpsert` and `_isSendingToAgent` prevent re-entrant draft creation during edits/sends.
- **RepaintBoundary**: App content is wrapped in `RepaintBoundary(key: _appContentKey)` so screenshots capture only the app layer without annotation/overlay UI.
- **Annotations only render while annotation mode is active** — they disappear when mode exits but are preserved in the queue draft.

## Keyboard Shortcuts

- `Ctrl+Shift+H` — Toggle inspector mode
- Double-tap `Ctrl` — Toggle annotation mode
- Double-tap `Alt` — Open text message overlay
- `Ctrl+Shift+Enter` — Send to agent
- `Ctrl+Shift+L` — Hot reload (add `Alt` for a hot restart)
- `Escape` — Dismisses (in priority order): error panel > queue panel > text overlay > inspector mode > annotation mode (cancels drawing first, then exits)

## Queue System

- Messages flow: User action -> `userMessageService.sendMessage()` -> VM extension event `flan.userMessageQueued` -> MCP connector drains via `consumeUserMessages` -> `process_queue` or `get_user_message` tool returns to agent
- Queue persists to SharedPreferences across hot reload/restart
- `process_queue` signals `setAgentListening(true)` to block Flutter UI interactions while agent is consuming

## Watched ports (server/flan_server/src/watch.rs)

Non-Flutter web dev servers get into the TUI by being named: `flan-tui --watch <port>`,
`FLAN_WATCH_PORTS`, or `POST /api/watch-ports`. Persisted in `~/.flan/watched_ports.json`.
Each watched port gets a discovery row (`device: web:<port>`, `app_id: web:<port>:<folder>`)
and an injecting reverse proxy on `<port> + 40000` that serves the page with `/flan.js`
(the standalone `flan_web` bundle, `npm run build:standalone`, embedded via `include_str!`).

## Peer hosts (server/flan_server/src/lib.rs)

Discovery reads the local process table, so a `flutter run` on another machine
(e.g. a build host) is invisible to it. The remote-app registry is not a
substitute: an app lands there only when it *flushes*, so one that is running but
hasn't been talked to yet has no row, and the row it eventually gets is a stub —
pid 0, no cwd, no device.

Each host already runs a flan server that can see itself. List the others in
`~/.flan/peers.json` (a JSON array of base URLs; a bare host gets `:4050`) or in
`FLAN_PEERS` as a comma-separated list, and every discovery tick asks each one
for its apps and labels them with the peer's host:

```json
["http://m1.follow-ionian.ts.net:4050"]
```

Peers are polled via `GET /api/flutter-apps?local=1`. That parameter is what lets
two servers list each other without recursing — it answers from the process table
alone, consulting neither peers nor the registry. This machine is skipped if it
names itself. A peer's last good answer is reused for 45s so a dropped request
doesn't blink its rows out of the list.

A port identifies an app only *on the same host*: two machines both running
`--web-port 5005` are two apps, and merging on the bare port hid whichever came
second.

### Flushes relay the other way

Discovery **pulls**; a flush **pushes** to the one server named by
`FLAN_SERVER_URL`, which `wt` points at the worktree's *own* flan server. So an
app on the build host and the agent it is linked to on another machine could see
each other through peer discovery and still never exchange a word: the app posted
to its local server, which had no agent, and logged `Flush failed: no linked
receiver`.

A flush that resolves no local receiver is therefore relayed to each peer in
turn, and the first one to accept it wins — a message reaches one agent, not
every agent on the tailnet. The response carries `relayed_to`.

Loop prevention is the `relayed_from` field: a relayed flush is never relayed
on. Two servers listing each other would otherwise hand one message back and
forth until a timeout. `mark_relayed` stamps it, and refuses a payload that
isn't a JSON object rather than forwarding one unstamped.

This means **peering must be configured on both machines** — the build host needs
its own `~/.flan/peers.json` pointing back at wherever the agents run. Peers are
reported by `GET /api/peers`, which distinguishes "that host is running nothing"
(`reachable: true, app_count: 0`) from "I could not ask" (`reachable: false`).
The TUI logs each change of state, because an unreachable peer and an idle one
otherwise look identical and the feature reads as broken.

## Hot reload from flan (server/flan_server/src/lib.rs)

`POST /api/hot-reload {pid | app_id, full_restart?}`, and `R` in the TUI on the
selected app. Two mechanisms, and the row decides which:

**The signal.** `flutter run`'s TerminalHandler installs handlers for SIGUSR1
(hot reload) and SIGUSR2 (hot restart) — `flutter run --pid-file` documents them
as the supported way for another process to ask. The target is the **tool**
process, the `dart … flutter_tools.snapshot run` that owns the incremental
compiler, which is exactly what `discover_flutter_apps` already records as
`FlutterApp::pid`. Signalling the app process does nothing.

**SIGUSR1's default disposition is to terminate**, and flutter_tools installs the
handlers only for a resident run whose device supports the service protocol *and*
restart. A `--release`, `--profile`, `--no-resident` or `--trace-startup` run
would be killed by the very signal meant to reload it, so
`command_line_accepts_reload_signal` re-reads the command line and refuses
anything else. Never signal a pid without that check.

The signal is preferred because it is one syscall, needs no handshake, and still
works when a VM service port accepts a connection and then stalls (the
auth-gated native-macOS case `peek_flan` guards against).

**The signal has no reply, so flan reads the tool's stdout instead.**
flutter_tools prints "Restarted application in 223ms." — or three pages of
compile errors — and carries on, and a restart that compiled nothing was being
reported as "requested". But `flutter run` under `wt` (or nohup, or systemd) has
its stdout on a *file*: `/proc/<pid>/fd/1` on Linux, `lsof -p <pid> -d 1` on
macOS. `hot_reload_local` notes that file's length BEFORE signalling — otherwise
the previous reload's success line answers for this one — and then watches what
is appended for up to 12s. `verdict_from_output` classifies it: a line with
`: Error:` or "Hot reload rejected" is a failure, so is "Ignoring signal" (a
request dropped while busy) and "No client connected" (a web app compiled for
nobody, which from the page's side is nothing happening); "Restarted application
in …" and "Reloaded N of M libraries" are success. Anything else is *silent*,
and silence falls back to the old "requested" wording rather than inventing a
verdict — which is also what happens when stdout is a TTY or a pipe and there is
nothing to read. Note what must NOT match: this app's log is full of DWDS noise
("ERROR - …", "Error thrown by handler."), and reading that as a verdict would
fail every reload.

**The VM service.** For an app we have a URI for but no signalable pid.
flutter_tools *registers* a `reloadSources` service (`hotRestart` for a full
restart) on the VM service, and invoking it returns success or the compile error.
The VM's own `reloadSources` RPC is not a substitute — a Flutter app's VM has no
compiler, so nothing would recompile the sources. The registered service is
exposed to other clients under a per-client prefix (`s0.reloadSources`) that is
only learnable from a `ServiceRegistered` event on the `_Service` stream, which
is replayed to each client as it subscribes: subscribe first, then watch for the
name. A read timeout there means "not yet", not failure — conflating the two
reported `Resource temporarily unavailable` instead of naming the missing
service.

**From inside the app.** The overlay cannot reload itself — there is no
compiler in the process — so it asks its own relay: `Ctrl+Shift+L` (with `Alt`
for a restart), or right-click the Q badge for the menu. Identity is whatever
the app has: `FLAN_APP_ID` if it was defined, else the VM service URI it already
sends on every flush, both of which `/api/hot-reload` resolves against the
discovery row. This request is never relayed to a peer: the relay beside the app
is the one with the pid.

The reply is shown verbatim, which is why `FlanServerClient` decodes every
response from `bodyBytes` as UTF-8. `response.body` picks its codec from the
Content-Type charset and falls back to **latin1** when there is none — and the
relay sends a bare `application/json`, so "Hot reload requested — SIGUSR1 → pid
4242" reached the banner as mojibake.

A signalled reload reports whatever the tool printed — including the compile
error that stopped it — and says only "requested" when its stdout gave nothing
to read. On web the page has no VM service, so the relay recompiles on the host
and the browser only picks it up if the Dart debug client is attached;
otherwise the banner carries flutter's own "Recompile complete. No client
connected." and the page needs a refresh.

**An app on a peer is neither.** Only that host's own flan server can see its
`flutter run` pid, and the loopback VM service URI it reported means nothing
here, so the request is handed to the peer's `/api/hot-reload` — stamped
`relayed_from`, for the same reason a relayed flush is, and a relayed request is
never relayed on.

## Testing Notes

- Annotation queue tests: `test/flan_overlay_annotation_queue_test.dart` (7 tests)
- Overlay widget tests: `test/flan_overlay_widget_test.dart` (~35 tests)
- **Known pre-existing failure**: "tapping error dot shows error panel" test fails with `FlutterError.onError` assertion and poisons subsequent tests in the same run. Use `--name` filter to exclude error panel tests when running the full suite.
- `ScreenshotService.takeScreenshotFromBoundary()` always fails in test env (`Invalid image dimensions`) — this is expected, it falls back to `takeScreenshots()`.

## Publishing

Both packages publish to pub.dev independently. Workflow:
1. Bump `version:` in both `pubspec.yaml` files
2. Update both `CHANGELOG.md` files
3. Commit, push
4. `dart pub publish --force` from each package directory

Current version: **0.6.1**
