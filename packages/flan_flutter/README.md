# flan_flutter

![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)
[![flan_flutter pub.dev badge](https://img.shields.io/pub/v/flan_flutter)](https://pub.dev/packages/flan_flutter)

The Flutter SDK component of [Flan](https://github.com/keyvez/flan-mcp). Add this to your Flutter app to enable AI agent interaction and the in-app command center.

`flan_flutter` does two things:

1. **Registers VM service extensions** that let the MCP server inspect and interact with your app
2. **Installs the command center overlay** — a widget inspector, annotation tools, and a message system that lets you talk directly to the AI agent from inside your running app

## Installation

```bash
flutter pub add flan_flutter
```

## Setup

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flan_flutter/flan_flutter.dart';

void main() {
  if (kDebugMode) {
    FlanBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }

  runApp(const MyApp());
}
```

## In-App Command Center

Once initialized, the command center is available via keyboard shortcuts:

### Widget Inspector (`Ctrl+Shift+H`)

Hover over any widget to highlight it. Click to lock your selection. Flan shows:

- **Widget type** — `ElevatedButton`, `Text`, `Container`, etc.
- **Ancestor path** — `MaterialApp > Scaffold > Column > ElevatedButton`
- **Source location** — exact file, line, and column where the widget is created
- **Bounds, key, and text content**

With a widget selected, type a message and press **Enter** to send it to the AI agent along with all the widget metadata. The agent knows exactly what you're pointing at and where to find it in the code.

Use the **scroll wheel** or **arrow keys** to cycle through overlapping widgets.

### Annotations (`Ctrl+Shift+A`)

Draw rectangles on the app and label them. Each annotation is paired with the widget underneath it. Send all annotations to the agent with `Ctrl+Shift+Enter` — the agent receives your visual markup correlated with source code locations.

Click an existing annotation to edit or delete it.

### Text Message Overlay (double-tap `Alt`)

A full-screen overlay for free-form communication. Includes:

- Text input for typing instructions
- Drawing tools (pencil, text, eraser, move) for sketching on the app
- Agent connection status indicator
- Keyboard shortcut reference

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+H` | Toggle widget inspector |
| `Ctrl+Shift+A` | Toggle annotation mode |
| `Ctrl+Shift+Enter` | Send selection/annotations to agent |
| `Alt+Alt` (double-tap) | Open text message overlay |
| `Escape` | Dismiss active mode |
| `Scroll wheel` | Cycle overlapping widgets (inspector) |
| `Arrow Up/Down` | Cycle overlapping widgets (inspector) |

## Custom Design System

Configure Flan to recognize your custom widgets:

```dart
FlanBinding.ensureInitialized(
  FlanConfiguration(
    isInteractiveWidget: (type) =>
        type == MyPrimaryButton ||
        type == MyTextField,

    extractText: (widget) {
      if (widget is MyText) return widget.data;
      return null;
    },
  ),
);
```

### `isInteractiveWidget`

A typical screen has hundreds of widgets. `get_interactive_elements` filters to only actionable targets: buttons, text fields, switches, etc. Use this callback to include your custom interactive widgets.

### `extractText`

Extract text from custom widgets for element discovery and text-based matching (`tap(text: "Submit")`). By default, Flan extracts from `Text`, `RichText`, `EditableText`, `TextField`, and `TextFormField`.

### Screenshot Sizing

Screenshots are downscaled to 2000x2000 physical pixels by default. Override via `maxScreenshotSize` in `FlanConfiguration` (set to `null` to disable).

### Log Collection

Flan collects logs via Dart's [`logging`](https://pub.dev/packages/logging) package. If your app doesn't use `logging`, `get_logs` will be empty.

## How It Works

`FlanBinding` extends `WidgetsFlutterBinding` and:

1. Registers VM service extensions (`ext.flutter.flan.*`) for each tool
2. Installs a global overlay with the inspector, annotation, and message UI
3. Listens for keyboard shortcuts to activate each mode
4. Queues user messages and emits VM extension events so the MCP server can drain them immediately

The command center overlay is entirely self-contained — it doesn't interfere with your app's widget tree or state management.

## License

Apache License 2.0 - see the [LICENSE](../../LICENSE) file for details.

Originally created by [LeanCode](https://leancode.co). Fork maintained by [keyvez](https://github.com/keyvez).
