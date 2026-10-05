# flan_web

The React-side command center for [Flan](https://github.com/keyvez/flan-mcp).

`flan_web` lets a web app send **annotated UI feedback** to an AI coding
agent through the Flan MCP server — the same inversion-of-control loop
[`flan_flutter`](../flan_flutter) gives Flutter apps. Instead of
describing a UI problem in a chat window, you point at it: select a DOM
element, draw an annotation, or type a message, and it's delivered to
your agent with the element's CSS selector, source hint, and component
name attached.

## How it differs from flan_flutter

A web app has no Dart VM, so it can't register VM-service extensions or
host its own message queue the way a Flutter app does. Instead:

- `flan_web` opens a **WebSocket** to the Flan server's `/ws` endpoint.
- Annotated messages are buffered in a **server-side queue**
  (`flan_server`).
- The MCP server's `process_queue` / `get_user_message` tools drain that
  queue, so the agent receives web and Flutter feedback uniformly.

## Install

```sh
npm install flan_web
```

`react` and `react-dom` (>=18) are peer dependencies.

## Usage

Wrap your app in `<FlanProvider>` and drop `<FlanCommandCenter />` once
near the root:

```tsx
import { FlanProvider, FlanCommandCenter } from 'flan_web';

function Root() {
  return (
    <FlanProvider serverUrl="ws://127.0.0.1:4050/ws">
      <App />
      <FlanCommandCenter />
    </FlanProvider>
  );
}
```

`serverUrl` defaults to `ws://127.0.0.1:4050/ws` (the Flan server's
default port). Pass `enabled={false}` to disable the command center in
production builds.

## Any web app, no code changes: watched ports

The Flan server (and `flan-tui`) can instrument a plain dev server —
wrangler, vite, Rails, anything that serves HTML — without the app
importing `flan_web` at all. Name its port once:

```sh
flan-tui --watch 9689            # or: FLAN_WATCH_PORTS=9689 flan-tui
curl -X POST localhost:4050/api/watch-ports -d '{"port":9689}'   # at runtime
```

Ports persist in `~/.flan/watched_ports.json`. For each one the server:

- lists the listener as an app row (`career-site (web:9689) :49689`), so
  it can be linked to an agent like a Flutter app;
- opens a reverse proxy on the port plus 40000 (`:9689` → `:49689`) that
  injects the standalone overlay bundle (`/flan.js`) into every HTML page
  and strips `Content-Security-Policy` in dev.

Open the app through the proxy URL — only pages loaded that way carry the
overlay. Messages flush with the app id `web:<port>:<folder>` and reach the
agent linked to that row. WebSocket upgrades (HMR, live reload) are
tunnelled through untouched.

The bundle lives at `server/flan_server/static/flan.js` and is embedded at
compile time. Rebuild it after changing `flan_web`:

```sh
cd packages/flan_web && npm run build:standalone
```

## Shortcuts

| Shortcut          | Action                                          |
|-------------------|-------------------------------------------------|
| double-tap `Alt`  | Message overlay — free-form text                |
| `Ctrl+Shift+A`    | Annotation mode — drag labeled rectangles       |
| `Ctrl+Shift+H`    | Inspector — hover/lock a DOM element            |
| `Esc`             | Close the active overlay                        |

## Source locations

The DOM has no built-in equivalent of Flutter's "source file:line". For
parity, `flan_web` reads a `data-flan-source` attribute if present:

```html
<button data-flan-source="src/Settings.tsx:42">Save</button>
```

A Babel/Vite plugin can stamp these on every JSX element at build time.
Without it, `flan_web` falls back to the React component display name
(via the React DevTools fiber) plus the CSS selector.

## API

- `<FlanProvider>` — opens the transport, exposes status via context.
- `<FlanCommandCenter>` — mounts shortcuts + all overlays.
- `useFlan()` — `{ status, queued, mode, setMode, send }`.
- `<MessageOverlay>`, `<AnnotationOverlay>`, `<InspectorOverlay>` —
  individual surfaces, if you want to compose them yourself.
- `FlanTransport` — the reconnecting WebSocket client, usable standalone.

## License

Apache-2.0
