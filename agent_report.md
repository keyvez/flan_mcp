# Agent Report — 2026-02-18

## Session Summary

QA review and bug fixes for the Flan MCP Flutter overlay system, plus a new MCP tool for error inspection.

## Changes Made

### 1. `get_errors` MCP Tool (committed as 57acd63)

Added a new tool that exposes intercepted Flutter errors and unhandled exceptions to coding agents, so they can check for runtime errors after making changes and hot reloading without the developer having to manually report them.

**Files modified:**
- `packages/flan_flutter/lib/src/binding/flan_binding.dart` — Added `flan.getErrors` VM service extension
- `packages/flan_mcp/lib/src/vm_service/vm_service_connector.dart` — Added `getErrors()` method
- `packages/flan_mcp/lib/src/vm_service/vm_service_context.dart` — Registered `get_errors` MCP tool with formatting

### 2. Fix: Annotations Persisting on Screen (committed as 8fb378f)

**Bug:** When a user exited annotation mode (via Escape, double-Ctrl, or mode switch), the orange annotation rectangles remained rendered on screen in read-only mode with no way to dismiss them.

**Root cause:** Lines 1164-1181 in `flan_overlay_widget.dart` explicitly rendered annotations via `AnnotationPainter` even when annotation mode was disabled.

**Fix:** Removed the read-only annotation rendering block. Annotations are now only visible while annotation mode is active. The annotation data is already preserved in the queue as a draft message with a cropped thumbnail, so no data is lost.

**Files modified:**
- `packages/flan_flutter/lib/src/overlay/flan_overlay_widget.dart` — Removed read-only annotation rendering
- `packages/flan_flutter/test/flan_overlay_widget_test.dart` — Updated test to verify new behavior

### 3. Fix: Escape Key Closes Queue Panel (committed as 8fb378f)

**Bug:** The queue panel had no keyboard shortcut to dismiss it. Pressing Escape while the queue panel was open did nothing.

**Fix:** Added `_showQueuedMessagesPanel` check to the Escape key handler chain, between error panel and text message overlay checks.

**File modified:**
- `packages/flan_flutter/lib/src/overlay/flan_overlay_widget.dart`

### 4. Version Bump & Publish (committed as f1d63ab)

Bumped both packages from 0.6.0 to 0.6.1, updated changelogs, and published to pub.dev.

- `flan_flutter` 0.6.1 — https://pub.dev/packages/flan_flutter
- `flan_mcp` 0.6.1 — https://pub.dev/packages/flan_mcp

## QA Findings

### Bugs Found (all fixed)

| # | Bug | Severity | Status |
|---|-----|----------|--------|
| 1 | Annotations persist on screen after Escape exits annotation mode | Medium | Fixed |
| 2 | Double-Ctrl toggle doesn't clear annotations | Medium | Fixed (same root cause) |
| 3 | Switching to inspector mode leaves annotations on screen | Medium | Fixed (same root cause) |
| 4 | Opening text message overlay leaves annotations on screen | Medium | Fixed (same root cause) |
| 5 | No way to dismiss queue panel with keyboard | Low | Fixed |

### Pre-existing Issues (not addressed)

- **Error panel test (`FlutterError.onError`):** The "tapping error dot shows error panel" test fails with a `FlutterError.onError` assertion and poisons subsequent tests in the same run. This is a test isolation issue, not a runtime bug.
- **Unused methods:** `_createIssueFromError` and `_editQueuedAnnotation` are declared but unreferenced (dart analyze warnings). These appear to be reserved for future use.

## Test Results

- `flan_overlay_annotation_queue_test.dart` — 7/7 passed
- `flan_overlay_widget_test.dart` (excluding pre-existing error panel failure) — All relevant tests passed
- `flan_mcp` tests — 19/19 passed
- `dart analyze` — No new issues (2 pre-existing unused element warnings)

## Commits

| Hash | Message |
|------|---------|
| `57acd63` | feat: Add get_errors MCP tool for runtime error inspection |
| `8fb378f` | Fix annotations persisting on screen after exiting annotation mode |
| `f1d63ab` | feat: Release 0.6.1 — get_errors tool and annotation UX fixes |
