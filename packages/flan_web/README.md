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
