# 0.6.1

- Add `flan.getErrors` VM service extension for runtime error inspection
- Fix annotations persisting on screen after exiting annotation mode
- Add Escape key handling to close the queue panel

# 0.5.0

- Emit VM extension event `flan.userMessageQueued` whenever a user message is queued for the agent
- Persist unprocessed user-message queue to survive hot reload, hot restart, and full app restarts
- Make programmatic inspect side-effect-free (no inspector/annotation UI toggling) and faster for large apps
- Add micro-profiler logs for programmatic inspect calls (`inspectAtForAgent`)
- Keep annotations visible after queueing and allow deleting queued messages from the in-app queue panel
- Show compact queue thumbnails for selected/inspected widgets (with screenshot fallback) in the queued messages panel
- Add editable queued annotation chips in queue panel and clear on-screen annotations after queue is fully processed
- Improve queue badge visibility with explicit `Q` marker and counter bubble
- Show green queue badge border when a push-capable MCP host is connected

# 0.4.0

- Add in-app command center with widget inspector, annotations, and message overlay
- Widget inspector (`Ctrl+Shift+H`): select widgets, view source location, send messages to agent
- Annotation mode (`Ctrl+Shift+A`): draw and label rectangles, auto-correlate with widgets
- Text message overlay (double-tap `Alt`): free-form text and drawing tools to communicate with agent
- Agent listening status indicator in the app
- Optimize `watch_flan` to use event-driven waiting instead of busy-polling
- Detect and handle unexpected connection loss (WebSocket close)
- Suppress redundant logging notifications while `watch_flan` is active

# 0.3.0

- Add screenshot resizing configuration
- Fix SIGTERM handling on Windows
- Add GitHub Copilot support
- Require Dart 3.10 for the MCP server
- Fix `hot_reload` tool response handling

# 0.2.4

- Add CI workflow with analyze, format, and version checks
- Add version generation script with validation and robustness
- Replace example symlinks with actual directories in both packages
- Improve project structure and dependencies

# 0.2.3

- Add example symlinks for improved pub.dev package scoring
- Fix documentation lints for angle brackets in code references

# 0.2.2

- Add compatibility for Copilot `initialize` call
- Make configuration parameter optional in `FlanBinding.ensureInitialized()`

# 0.2.1

- Update README

# 0.2.0

- Support tapping by widget type
- Support tapping by coordinates
- Return more info in `get_interactive_elements`
- Add hot reload tool, and return logs only since last hot reload
- `get_interactive_elements` returns only hittable elements now
- The tools have better naming to conform to the MCP implementations
- `scroll_to` does not assume that the widget is in the tree
- `Text` is a stopwidget now

# 0.1.0

- Initial version of Flan MCP
- Support for getting the interactive widget tree
- Support for entering text
- Support for tapping and scrolling
- Support for getting logs from `logging` package
