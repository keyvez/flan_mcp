# Flan

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
[![flan_mcp pub.dev badge](https://img.shields.io/pub/v/flan_mcp)](https://pub.dev/packages/flan_mcp)

**Give your AI agent eyes and hands inside your Flutter app — and let your app talk back.**

Flan connects AI coding agents (Cursor, Claude Code, Copilot, Gemini CLI, etc.) to running Flutter applications. The agent can see the widget tree, tap buttons, enter text, scroll, take screenshots, and hot reload — but that's only half the story.

Flan also gives **you**, the developer, a built-in command center inside your running app. Select a widget, draw an annotation, type a message — and send it directly to the agent. Instead of describing what you want in a chat window, you point at it.

![](https://github.com/keyvez/flan-mcp/blob/master/promo.gif)

## Why Flan

**Inversion of control.** Traditional AI coding tools require you to describe UI problems in words: "the button on the settings page isn't aligned right." With Flan, you open the app, point at the button, and type "fix this alignment." The agent receives the exact widget type, its position, its ancestor path, and the source file and line number where it's defined. No guessing, no searching.

**Minimal footprint.** Flan exposes a small, opinionated set of tools that return only actionable data. This keeps agent prompts focused and context windows lean.

**Two-way communication.** The agent can drive your app, and your app can drive the agent. You're not limited to the agent's initiative — you can interrupt, redirect, and give precise visual feedback at any time.

## Flan vs Flutter MCP

The official [Dart & Flutter MCP server](https://docs.flutter.dev/ai/mcp-server) focuses on **development-time** tasks: searching pub.dev, managing dependencies, analyzing code, and inspecting runtime errors. It drives UI through Flutter Driver, which requires extra instrumentation.

Flan focuses on **runtime interaction** and **developer-agent collaboration**: tapping buttons, entering text, taking screenshots, and — critically — letting the developer send targeted feedback from inside the running app. Use Flutter MCP to scaffold your project, use Flan to build and refine the UI with a live feedback loop.

## Key Features

### Agent-Side Tools

The AI agent can programmatically interact with your running app:

| Tool | Description |
|------|-------------|
| `connect` | Connect to a Flutter app via its VM service URI |
| `disconnect` | Disconnect from the currently connected app |
| `get_interactive_elements` | List all interactive UI elements visible on screen |
| `tap` | Tap an element by key, text, widget type, or coordinates |
| `enter_text` | Type into a text field |
| `scroll_to` | Scroll until an element is visible |
| `take_screenshots` | Capture screenshots of all views |
| `get_logs` | Retrieve application logs (via Dart `logging` package) |
| `hot_reload` | Apply code changes without losing state |
| `hot_restart` | Full restart, resets all state |
| `enable_inspector` | Programmatically activate widget inspector |
| `disable_inspector` | Deactivate widget inspector |
| `inspect_widget_at` | Inspect a widget at specific coordinates (cheaper than a screenshot) |
| `get_inspector_selection` | Get the currently selected widget's details |
| `enable_annotations` | Activate annotation drawing mode |
| `disable_annotations` | Deactivate annotation mode |
| `get_annotations` | Retrieve all drawn annotations |
| `add_annotation` | Create an annotation programmatically |
| `clear_annotations` | Remove all annotations |
| `get_user_message` | Retrieve queued messages from the app user |
| `watch_flan` | Block and wait for the next user message (long-polling) |

### In-App Command Center

The real power of Flan is what happens inside the running app. With `flan_flutter` initialized, you get a full overlay system controlled by keyboard shortcuts:

#### Widget Inspector (`Ctrl+Shift+H`)

Activate the inspector and hover over any widget to highlight it. Click to lock your selection. Flan shows you:

- **Widget type** (e.g., `ElevatedButton`, `Text`, `Container`)
- **Full ancestor path** (e.g., `MaterialApp > Scaffold > Column > ElevatedButton`)
- **Source location** — the exact file, line, and column where the widget is created
- **Bounds** — position and size on screen
- **ValueKey** and **extracted text**, if present

With a widget selected, a text input appears. Type a message like "make this red" or "add padding here" and press **Enter**. The agent receives your message alongside all the widget metadata — it knows exactly what you're pointing at and where to find it in the code.

Use the **scroll wheel** or **arrow keys** to cycle through overlapping widgets at the same position.

#### Annotations (`Ctrl+Shift+A`)

Switch to annotation mode to draw directly on the app. Drag to create a rectangle, then type a label. Use annotations to:

- Mark multiple areas that need attention
- Circle a layout issue and describe it
- Sketch where a new element should go

When you send annotations to the agent, each one is paired with the widget underneath it, including source location. The agent can correlate your visual markup with specific code locations.

Click an existing annotation to edit its text, or leave it empty to delete it.

#### Text Message Overlay (double-tap `Alt`)

For free-form communication, double-tap the **Alt** (or **Option**) key. A full-screen overlay appears with:

- A **text input** for typing instructions to the agent
- **Drawing tools** — pencil, text, eraser, move — for sketching on the app background
- A **status indicator** showing whether the agent is listening (green) or disconnected (red)
- A **shortcuts panel** showing all available keyboard commands

Press **Enter** to send. If you've drawn anything, the sketch is captured as an image and sent alongside your text.

#### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+H` | Toggle widget inspector |
| `Ctrl+Shift+A` | Toggle annotation mode |
| `Ctrl+Shift+Enter` | Send current selection/annotations to agent |
| `Alt+Alt` (double-tap) | Open text message overlay |
| `Escape` | Dismiss active mode or unlock selection |
| `Scroll wheel` | Cycle through overlapping widgets (in inspector) |
| `Arrow Up/Down` | Cycle through overlapping widgets (in inspector) |

### The Feedback Loop

Here's what a typical workflow looks like:

1. **You** run the Flutter app and ask the agent to `connect`
2. **Agent** calls `watch_flan` and waits for your input
3. **You** press `Ctrl+Shift+H`, hover over a misaligned card, click it, and type: "this card should have 16px padding on all sides"
4. **Agent** receives the message with the exact widget, its source file and line number, and your instruction
5. **Agent** edits the code, calls `hot_reload`, verifies the change with `inspect_widget_at`
6. **Agent** calls `watch_flan` again, listening for your next instruction
7. **You** check the result and either approve or point at the next thing to fix

The agent doesn't need to take expensive screenshots or traverse the full widget tree to understand what you want. You've already pointed at it.

## Quick Start

1. **Prepare your Flutter app** — Add `flan_flutter` and initialize `FlanBinding` in your `main.dart`
2. **Install the MCP server** — `dart pub global activate flan_mcp`
3. **Configure your AI tool** — Add the `flan_mcp` command to your tool's MCP configuration
4. **Run your app in debug mode** — Copy the VM service URI from the console (e.g., `ws://127.0.0.1:12345/ws`)
5. **Connect and interact** — Ask the agent to connect, then start pointing at things

## Installation

### 1. Add MCP Server Package

```bash
dart pub global activate flan_mcp
```

> [!NOTE]
> You can also install as a dev-dependency:
>
> ```bash
> dart pub add dev:flan_mcp
> ```
>
> Then invoke as `dart run flan_mcp`. You may need to set the working directory:
> `cd ${workspaceFolder}/packages/mypackage && dart run flan_mcp`
>
> If this doesn't work, use the global tool method above.

### 2. Add Flutter Package

```bash
flutter pub add flan_flutter
```

## Flutter App Integration

Initialize `FlanBinding` in your app. This registers the VM service extensions that the MCP server communicates with, and activates the in-app command center overlay.

### Basic Setup

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flan_flutter/flan_flutter.dart';

void main() {
  // Initialize Flan only in debug mode
  if (kDebugMode) {
    FlanBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }

  runApp(const MyApp());
}
```

That's it. The inspector, annotations, and message overlay are now available via keyboard shortcuts whenever the app runs in debug mode.

### Custom Design System

If you use custom widgets, configure Flan to recognize them:

```dart
FlanBinding.ensureInitialized(
  FlanConfiguration(
    // Mark your custom widgets as interactive
    isInteractiveWidget: (type) =>
        type == MyPrimaryButton ||
        type == MyTextField ||
        type == MyCheckbox,

    // Extract text from custom widgets
    extractText: (widget) {
      if (widget is MyText) return widget.data;
      if (widget is MyTextField) return widget.controller?.text;
      return null;
    },
  ),
);
```

**Why `isInteractiveWidget`?** A typical screen has hundreds of widgets. When the agent calls `get_interactive_elements`, Flan filters down to only actionable targets: buttons, text fields, switches, etc. If your custom `MyPrimaryButton` wraps a `GestureDetector`, Flan won't know it's tappable unless you tell it.

**Why `extractText`?** Text extraction serves element discovery (widgets with text appear in the interactive elements list) and text-based matching (the agent can `tap(text: "Submit")`). By default, Flan extracts from `Text`, `RichText`, `EditableText`, `TextField`, and `TextFormField`.

### Log Collection

Flan collects logs via Dart's [`logging`](https://pub.dev/packages/logging) package. If your app doesn't use `logging`, `get_logs` will be empty. Bridge your existing logging solution if needed.

### Screenshot Sizing

By default, screenshots are downscaled to fit within 2000x2000 physical pixels. Override via `maxScreenshotSize` in `FlanConfiguration` (set to `null` to disable).

## Tool Configuration

Add the MCP server to your AI coding assistant's configuration.

### Cursor

[![Install MCP Server](https://cursor.com/deeplink/mcp-install-dark.svg)](https://cursor.com/en-US/install-mcp?name=flan&config=eyJlbnYiOnt9LCJjb21tYW5kIjoiZmxhbl9tY3AifQ%3D%3D)

Or manually add to `.cursor/mcp.json` or `~/.cursor/mcp.json`:

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

Add to your `mcp.json`:

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

Add to `~/.gemini/settings.json`:

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

### Google Antigravity

Open the MCP store, click "Manage MCP Servers", then "View raw config" and add to `mcp_config.json`:

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

## Example Scenarios

### Point-and-Fix UI

> Press `Ctrl+Shift+H`, click the misaligned text, type "center this vertically in its container", press Enter.

The agent receives the `Text` widget's source location (`lib/screens/home.dart:47:12`), its current bounds, and your instruction. It opens the file, makes the fix, and hot reloads.

### Annotate a Layout Problem

> Press `Ctrl+Shift+A`, draw a rectangle around the overflowing card, label it "this overflows on small screens". Draw another around the spacing below it, label it "reduce this gap". Press `Ctrl+Shift+Enter`.

The agent receives both annotations with the widgets underneath and can address multiple issues in one pass.

### Verify a New Feature

> "I just implemented the Forgot Password flow. Connect to the app, navigate to login, tap 'Forgot Password', enter a valid email, submit, and check the logs."

### Smoke Test After Refactoring

> "I refactored the navigation. Connect to the app, cycle through all tabs, and verify each screen loads without log errors."

### Debug an Unresponsive Button

> "The 'Clear Cache' button on Settings doesn't work. Connect, navigate there, find the button, tap it, and check what happens in the logs."

## How It Works

1. **Initialization**: `FlanBinding` registers VM service extensions (`ext.flutter.flan.*`) and installs the command center overlay
2. **Connection**: The MCP server connects to your app's VM Service URL via WebSocket
3. **Agent actions**: When the agent calls a tool (like `tap`), the MCP server translates it into a VM service extension call
4. **User actions**: When you select a widget or send a message, it's queued for the agent to retrieve via `watch_flan`
5. **Hot reload**: The agent can apply code changes and verify them without restarting the app

## Assumptions & Limitations

- **Prefer pasting the VM Service URI manually**: Copy the `ws://.../ws` URI from `flutter run` output and paste it to the agent.

- **The agent may not know your app**: Flan can see the widget tree and interact with elements, but doesn't automatically understand your product flows. Provide context in prompts for reliable navigation.

- **Debug mode only**: Flan relies on the VM Service, which is only available in debug and profile mode. It will not work in release builds.

- **Interactions may vary**: Some actions use best-effort simulation of gestures. Depending on platform, custom widgets, or overlays, results may vary. Expose clear widget keys and configure `FlanConfiguration` for your design system.

## Relay Server

The `flan_relay` server provides a camera relay for streaming device camera feeds to the agent. It runs as a standalone binary.

### Starting the Relay Server

```bash
./server/flan_relay/target/release/flan_relay --port 8080 --camera 1 --debug
```

| Flag | Description |
|------|-------------|
| `--port` | Port to listen on (e.g., `8080`) |
| `--camera` | Camera device index (e.g., `1`) |
| `--debug` | Enable debug logging |

### Stopping the Relay Server

Find the process and kill it:

```bash
# Find the relay server process
ps aux | grep flan_relay

# Stop it gracefully
kill <PID>
```

Or stop it in one command:

```bash
pkill -f flan_relay
```

## Troubleshooting

- **"Not connected to any app"**: The agent must call `connect` with the VM Service URI first.
- **Finding the URI**: Run `flutter run` in debug mode. Look for `ws://127.0.0.1:PORT/ws` in the output.
- **Elements not found**: Ensure widgets are visible and custom widgets are configured in `FlanConfiguration`.
- **Agent not receiving messages**: Make sure the agent has called `watch_flan`. The green dot in the message overlay confirms the agent is listening.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

Originally created by [LeanCode](https://leancode.co). Fork maintained by [keyvez](https://github.com/keyvez).
