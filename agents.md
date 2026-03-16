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
- `Escape` — Dismisses (in priority order): error panel > queue panel > text overlay > inspector mode > annotation mode (cancels drawing first, then exits)

## Queue System

- Messages flow: User action -> `userMessageService.sendMessage()` -> VM extension event `flan.userMessageQueued` -> MCP connector drains via `consumeUserMessages` -> `process_queue` or `get_user_message` tool returns to agent
- Queue persists to SharedPreferences across hot reload/restart
- `process_queue` signals `setAgentListening(true)` to block Flutter UI interactions while agent is consuming

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
