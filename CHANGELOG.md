# 0.4.0

- Add in-app command center with widget inspector, annotations, and message overlay
- Widget inspector (`Ctrl+Shift+H`): select widgets, view source location, send messages to agent
- Annotation mode (`Ctrl+Shift+A`): draw and label rectangles, auto-correlate with widgets
- Text message overlay (double-tap `Alt`): free-form text and drawing tools to communicate with agent
- Add `watch_flan` tool for agents to listen for user messages (long-polling)
- Add `inspect_widget_at` tool for lightweight coordinate-based widget inspection
- Add `hot_restart` tool for full app restart
- Add `enable_inspector`, `disable_inspector`, `get_inspector_selection` tools
- Add `enable_annotations`, `disable_annotations`, `get_annotations`, `add_annotation`, `clear_annotations` tools
- Add `get_user_message` tool for retrieving queued user messages
- Agent listening status indicator in the app
- Overhaul documentation with full feature coverage

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
