# flan_mcp

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
[![flan_mcp pub.dev badge](https://img.shields.io/pub/v/flan_mcp)](https://pub.dev/packages/flan_mcp)

The MCP server component of [Flan](https://github.com/keyvez/flan-mcp). Connects AI coding agents (Cursor, Claude Code, Copilot, Gemini CLI, etc.) to running Flutter applications.

This package provides the MCP server that translates agent tool calls into Flutter VM service extension calls. It's the bridge between your AI tool and your running app.

For the full documentation, including the in-app command center, widget inspector, annotations, and the developer-agent feedback loop, see the [main README](https://github.com/keyvez/flan-mcp).

## Installation

Activate as a global tool (recommended):

```bash
dart pub global activate flan_mcp
```

Or add as a dev-dependency:

```bash
dart pub add dev:flan_mcp
```

## Configuration

Add to your AI tool's MCP configuration:

### Cursor

```json
{
  "mcpServers": {
    "flan": {
      "command": "flan_mcp",
      "args": []
    }
  }
}
```

### Claude Code

```bash
claude mcp add --transport stdio flan -- flan_mcp
```

### Copilot

```json
{
  "servers": {
    "flan": {
      "command": "flan_mcp",
      "args": []
    }
  }
}
```

### Gemini CLI

```json
{
  "mcpServers": {
    "flan": {
      "command": "flan_mcp",
      "args": []
    }
  }
}
```

## Available Tools

### Connection
| Tool | Description |
|------|-------------|
| `connect` | Connect to a Flutter app via VM service URI |
| `disconnect` | Disconnect from the app |

### Interaction
| Tool | Description |
|------|-------------|
| `tap` | Tap an element by key, text, widget type, or coordinates |
| `enter_text` | Type into a text field |
| `scroll_to` | Scroll until an element is visible |

### Inspection
| Tool | Description |
|------|-------------|
| `get_interactive_elements` | List all interactive UI elements on screen |
| `take_screenshots` | Capture screenshots of all views |
| `get_logs` | Retrieve application logs |
| `inspect_widget_at` | Inspect a widget at specific coordinates |
| `get_inspector_selection` | Get the currently selected widget's details |

### Inspector & Annotations
| Tool | Description |
|------|-------------|
| `enable_inspector` / `disable_inspector` | Toggle widget inspector mode |
| `enable_annotations` / `disable_annotations` | Toggle annotation mode |
| `get_annotations` | Retrieve all annotations |
| `add_annotation` | Create an annotation programmatically |
| `clear_annotations` | Remove all annotations |

### User Communication
| Tool | Description |
|------|-------------|
| `get_user_message` | Retrieve queued messages from the app user |
| `process_queue` | Drain queued user messages in one run, then stop when idle |

> **Note:** `process_queue` is not triggered automatically — the agent must call it explicitly to consume pending messages. Flan emits notifications when new messages arrive, but the agent still needs to invoke `process_queue` (or `get_user_message`) to retrieve them.

`connect` also accepts an optional `sampling_push` boolean to enable server-initiated `sampling/createMessage` nudges when user messages arrive (capability-gated by client support).

### Development
| Tool | Description |
|------|-------------|
| `hot_reload` | Apply code changes without losing state |
| `hot_restart` | Full restart, resets all state |

## Requirements

- Dart SDK >= 3.10
- The Flutter app must include `flan_flutter` and initialize `FlanBinding`

## License

Apache License 2.0 - see the [LICENSE](../../LICENSE) file for details.

Originally created by [LeanCode](https://leancode.co). Fork maintained by [keyvez](https://github.com/keyvez).
