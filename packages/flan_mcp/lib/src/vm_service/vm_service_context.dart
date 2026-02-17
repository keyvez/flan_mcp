import 'dart:async';

import 'package:logging/logging.dart' as logging;
import 'package:flan_mcp/src/utils/num_parser.dart';
import 'package:flan_mcp/src/vm_service/vm_service_connector.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Context for managing VM service connection and registering MCP tools.
final class VmServiceContext {
  VmServiceContext()
    : connector = VmServiceConnector(),
      _logger = logging.Logger('VmServiceContext');

  final VmServiceConnector connector;
  final logging.Logger _logger;
  McpServer? _server;
  Timer? _pollTimer;

  /// Buffered messages consumed by the polling loop, available for
  /// retrieval via `get_user_message`.
  final List<Map<String, dynamic>> _bufferedMessages = [];

  /// Whether `watch_flan` is actively running.
  bool _isWaitingForMessages = false;

  /// Completer that `watch_flan` waits on. Completed by `_startPolling` when
  /// new messages arrive, so `watch_flan` doesn't need to poll independently.
  Completer<void>? _messageArrived;

  /// Starts polling the Flutter app for pending user messages.
  /// Consumed messages are buffered so `get_user_message` can retrieve them.
  /// When `watch_flan` is waiting, it wakes it up via [_messageArrived].
  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!connector.isConnected || _server == null) return;
      try {
        final response = await connector.consumeUserMessages();
        final messages = response['messages'] as List?;
        if (messages != null && messages.isNotEmpty) {
          for (final msg in messages) {
            _bufferedMessages.add(msg as Map<String, dynamic>);
          }

          // Wake up watch_flan if it's waiting
          if (_messageArrived != null && !_messageArrived!.isCompleted) {
            _messageArrived!.complete();
          }

          // Only send logging notification when watch_flan is NOT active,
          // since watch_flan will return the messages directly.
          if (!_isWaitingForMessages) {
            final count = messages.length;
            await _server!.sendLoggingMessage(
              LoggingMessageNotification(
                level: LoggingLevel.info,
                logger: 'flan-user',
                data:
                    '$count message(s) received from the Flutter app user. '
                    'Call the get_user_message tool to retrieve them.',
              ),
            );
          }
        }

        // Send heartbeat while watch_flan is waiting
        if (_isWaitingForMessages) {
          await connector.setAgentListening(true);
        }
      } catch (e) {
        // Silently ignore polling errors (app may have disconnected)
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Handles unexpected connection loss by cleaning up state and notifying
  /// the agent via a logging message.
  void _onConnectionLost() {
    _stopPolling();
    _isWaitingForMessages = false;
    // Wake up watch_flan if it's blocked so it can return an error.
    if (_messageArrived != null && !_messageArrived!.isCompleted) {
      _messageArrived!.complete();
    }
    _server?.sendLoggingMessage(
      LoggingMessageNotification(
        level: LoggingLevel.warning,
        logger: 'flan',
        data:
            'Connection to the Flutter app was lost. '
            'Use the connect tool to reconnect.',
      ),
    );
  }

  /// Registers all VM service related tools with the MCP server.
  void registerTools(McpServer server) {
    _server = server;
    connector.onDisconnect = _onConnectionLost;
    // Connection management tools
    server
      ..registerTool(
        'connect',
        description:
            'Connects to a Flutter app via its VM service URI. This must be called before using any other tools. The VM service URI is typically in the format ws://127.0.0.1:PORT/ws and can be found in the Flutter app output when running in debug mode.',
        annotations: const ToolAnnotations(title: 'Connect to App'),
        inputSchema: ToolInputSchema(
          properties: {
            'uri': JsonSchema.string(
              description:
                  'VM service URI (e.g., ws://127.0.0.1:8181/ws). This is printed in the Flutter app console when running in debug mode.',
            ),
          },
          required: ['uri'],
        ),
        callback: (args, extra) async {
          final uri = args['uri'] as String;
          _logger.info('Connecting to app at $uri');

          try {
            await connector.connect(uri);
            _startPolling();
            return CallToolResult(
              content: [
                TextContent(
                  text:
                      'Successfully connected to app at $uri\n\n'
                      'IMPORTANT: Now call the watch_flan tool '
                      'in the background to listen for messages from the '
                      'user in the Flutter app.',
                ),
              ],
            );
          } catch (err) {
            _logger.severe('Failed to connect to app', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: 'Failed to connect to app: $err')],
            );
          }
        },
      )
      ..registerTool(
        'disconnect',
        description:
            'Disconnects from the currently connected Flutter app. After disconnecting, you must call connect again to use any other tools.',
        annotations: const ToolAnnotations(title: 'Disconnect from App'),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Disconnecting from app');

          try {
            _stopPolling();
            await connector.disconnect();
            return CallToolResult(
              content: [
                const TextContent(text: 'Successfully disconnected from app'),
              ],
            );
          } catch (err) {
            _logger.severe('Error during disconnect', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: 'Error during disconnect: $err')],
            );
          }
        },
      )
      // Interactive elements inspection
      ..registerTool(
        'get_interactive_elements',
        description:
            'Returns interactive elements visible in the Flutter app UI tree. '
            'Each element includes type, text, key, bounds, and visibility. '
            'Use the filter parameters to reduce output. '
            'Requires an active connection via connect.',
        annotations: const ToolAnnotations(
          title: 'Get Interactive Elements',
          readOnlyHint: true,
          idempotentHint: true,
        ),
        inputSchema: ToolInputSchema(
          properties: {
            'types': JsonSchema.string(
              description:
                  'Comma-separated widget types to include '
                  '(e.g. "TextField,IconButton,ElevatedButton"). '
                  'If omitted, all interactive elements are returned.',
            ),
            'with_keys_only': JsonSchema.boolean(
              description:
                  'If true, only return elements that have a ValueKey.',
            ),
            'text_contains': JsonSchema.string(
              description:
                  'Only return elements whose text contains this substring '
                  '(case-insensitive).',
            ),
          },
        ),
        callback: (args, extra) async {
          _logger.info('Getting interactive elements');

          try {
            final response = await connector.getInteractiveElements();
            var elements = (response['elements'] as List<dynamic>)
                .cast<Map<String, dynamic>>();

            // Apply filters
            final typesFilter = args['types'] as String?;
            final withKeysOnly = args['with_keys_only'] as bool? ?? false;
            final textContains = args['text_contains'] as String?;

            if (typesFilter != null && typesFilter.isNotEmpty) {
              final allowed = typesFilter
                  .split(',')
                  .map((t) => t.trim())
                  .toSet();
              elements = elements
                  .where(
                    (e) =>
                        e['type'] != null &&
                        allowed.contains(e['type'] as String),
                  )
                  .toList();
            }

            if (withKeysOnly) {
              elements = elements
                  .where((e) => e['key'] != null && (e['key'] as String) != '')
                  .toList();
            }

            if (textContains != null && textContains.isNotEmpty) {
              final needle = textContains.toLowerCase();
              elements = elements.where((e) {
                final t = e['text'] as String?;
                return t != null && t.toLowerCase().contains(needle);
              }).toList();
            }

            // Format compact
            final buffer = StringBuffer()
              ..writeln('Found ${elements.length} element(s):\n');

            for (final element in elements) {
              buffer.writeln(_formatElement(element));
            }

            return CallToolResult(
              content: [TextContent(text: buffer.toString())],
            );
          } catch (err) {
            _logger.warning('Failed to get interactive elements', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      // Tap interaction
      ..registerTool(
        'tap',
        description:
            'Simulates a tap gesture on an element in the Flutter app that matches the given criteria. You can match elements by their key (a ValueKey<String>), by their text content (but not accessibility!), by their widget type, or by screen coordinates. Only one matching method should be used: either key, text, type, or coordinates. Prefer using the key if available, as it is more reliable. Limit yourself to elements from get_interactive_elements only if you can. Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Tap Element'),
        inputSchema: ToolInputSchema(
          properties: {
            'key': JsonSchema.string(
              description:
                  'The key of the element to tap. You can get the key of an element by calling get_interactive_elements.',
            ),
            'text': JsonSchema.string(
              description:
                  'The visible text content of the element to tap. Use this for elements that display text like buttons or labels.',
            ),
            'type': JsonSchema.string(
              description:
                  'The widget type name of the element to tap (e.g., "ElevatedButton", "IconButton"). Use this to match elements by their Flutter widget type.',
            ),
            'coordinates': JsonSchema.object(
              description:
                  'Screen coordinates to tap at. Use this to tap at a specific position on the screen.',
              properties: {
                'x': JsonSchema.number(
                  description:
                      'The x coordinate (horizontal position from left).',
                ),
                'y': JsonSchema.number(
                  description: 'The y coordinate (vertical position from top).',
                ),
              },
              required: ['x', 'y'],
            ),
          },
        ),
        callback: (args, extra) async {
          final matcher = _buildMatcher(args);
          _logger.info('Tapping with matcher: $matcher');

          try {
            final response = await connector.tap(matcher);
            final message = response['message'] as String?;

            return CallToolResult(
              content: [TextContent(text: message ?? 'Successfully tapped')],
            );
          } catch (err) {
            _logger.warning('Failed to tap', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      // Text input
      ..registerTool(
        'enter_text',
        description:
            'Enters text into a text field in the Flutter app that matches the given criteria. This simulates typing text into the field. Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Enter Text'),
        inputSchema: ToolInputSchema(
          properties: {
            'input': JsonSchema.string(
              description: 'The text to enter into the text field.',
            ),
            'key': JsonSchema.string(
              description:
                  'The key of the text field. You can get the key of an element by calling get_interactive_elements.',
            ),
          },
          required: ['input', 'key'],
        ),
        callback: (args, extra) async {
          final input = args['input'] as String;
          final matcher = _buildMatcher(args);
          _logger.info('Entering text into element with matcher: $matcher');

          try {
            final response = await connector.enterText(matcher, input);
            final message = response['message'] as String?;

            return CallToolResult(
              content: [
                TextContent(text: message ?? 'Successfully entered text'),
              ],
            );
          } catch (err) {
            _logger.warning('Failed to enter text', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      // Scroll to element
      ..registerTool(
        'scroll_to',
        description:
            'Scrolls the view until an element matching the given criteria becomes visible. You can match elements by their key (a ValueKey<String>) or by their visible text content. This is useful when you need to interact with elements that are not currently visible on screen. Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Scroll to Element'),
        inputSchema: ToolInputSchema(
          properties: {
            'key': JsonSchema.string(
              description:
                  'The key of the element to scroll to. You can get the key of an element by calling get_interactive_elements.',
            ),
            'text': JsonSchema.string(
              description:
                  'The visible text content of the element to scroll to.',
            ),
          },
        ),
        callback: (args, extra) async {
          final matcher = _buildMatcher(args);
          _logger.info('Scrolling to element with matcher: $matcher');

          try {
            final response = await connector.scrollToElement(matcher);
            final message = response['message'] as String?;

            return CallToolResult(
              content: [
                TextContent(
                  text: message ?? 'Successfully scrolled to element',
                ),
              ],
            );
          } catch (err) {
            _logger.warning('Failed to scroll to element', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      // Get logs
      ..registerTool(
        'get_logs',
        description:
            'Retrieves all application logs collected from the Flutter app since connection or since the last log retrieval. This includes debug messages, errors, and other log output from the running app. Requires an active connection established via connect.',
        annotations: const ToolAnnotations(
          title: 'Get Application Logs',
          readOnlyHint: true,
        ),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Getting application logs');

          try {
            final response = await connector.getLogs();
            final logs = response['logs'] as List;
            final count = response['count'] as int;

            if (count == 0) {
              return CallToolResult(
                content: [const TextContent(text: 'No logs collected')],
              );
            }

            // Format logs nicely
            final buffer = StringBuffer()
              ..writeln(
                'Collected $count log entr${count == 1 ? 'y' : 'ies'}:\n',
              );

            for (final log in logs) {
              buffer.writeln(log);
            }

            return CallToolResult(
              content: [TextContent(text: buffer.toString())],
            );
          } catch (err) {
            _logger.warning('Failed to get logs', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      // Take screenshots
      ..registerTool(
        'take_screenshots',
        description:
            'Takes screenshots of all views in the Flutter app. Returns base64-encoded PNG images that can be decoded and saved. This captures the current visual state of the app. Requires an active connection established via connect.',
        annotations: const ToolAnnotations(
          title: 'Take Screenshots',
          readOnlyHint: true,
        ),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Taking screenshots');

          try {
            final response = await connector.takeScreenshots();
            final screenshots = (response['screenshots'] as List<dynamic>)
                .cast<String>();

            if (screenshots.isEmpty) {
              return CallToolResult(
                content: [const TextContent(text: 'No screenshots captured')],
              );
            } else {
              return CallToolResult(
                content: screenshots
                    .map(
                      (screenshot) =>
                          ImageContent(data: screenshot, mimeType: 'image/png'),
                    )
                    .toList(),
              );
            }
          } catch (err) {
            _logger.warning('Failed to take screenshots', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      // Hot reload
      ..registerTool(
        'hot_reload',
        description:
            'Performs a hot reload of the Flutter app. This reloads the Dart code without restarting the app, preserving the current state. Useful after making code changes to see them reflected in the running app. Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Hot Reload'),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Performing hot reload');

          try {
            final result = await connector.hotReload();

            if (result.success) {
              return CallToolResult(
                content: [
                  const TextContent(text: 'Hot reload completed successfully'),
                ],
              );
            } else {
              // Hot reload was rejected — automatically try hot restart
              _logger.info(
                'Hot reload rejected (${result.details}), '
                'attempting hot restart...',
              );
              try {
                final restarted = await connector.hotRestart();
                if (restarted) {
                  return CallToolResult(
                    content: [
                      TextContent(
                        text:
                            'Hot reload was rejected: ${result.details ?? 'unknown reason'}\n'
                            'Automatically performed hot restart instead (app state was reset).',
                      ),
                    ],
                  );
                }
              } catch (_) {
                // Hot restart also failed, report the original reload failure
              }
              final reason = result.details != null
                  ? 'Hot reload rejected: ${result.details}\n\nHot restart also failed. The app may need a manual restart.'
                  : 'Hot reload failed. The app may need a full restart.';
              return CallToolResult(
                isError: true,
                content: [TextContent(text: reason)],
              );
            }
          } catch (err) {
            _logger.warning('Failed to perform hot reload', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: 'Hot reload failed: $err')],
            );
          }
        },
      )
      // Hot restart
      ..registerTool(
        'hot_restart',
        description:
            'Performs a hot restart of the Flutter app. Unlike hot reload, '
            'this fully restarts the app, resetting all state. Use this when '
            'hot reload is insufficient (e.g. after changing initializers, '
            'adding new fields, or modifying main()). '
            'Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Hot Restart'),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Performing hot restart');

          try {
            final restarted = await connector.hotRestart();

            if (restarted) {
              return CallToolResult(
                content: [
                  const TextContent(text: 'Hot restart completed successfully'),
                ],
              );
            } else {
              return CallToolResult(
                isError: true,
                content: [
                  TextContent(
                    text:
                        'Hot restart failed. The app may need a full restart.',
                  ),
                ],
              );
            }
          } catch (err) {
            _logger.warning('Failed to perform hot restart', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: 'Hot restart failed: $err')],
            );
          }
        },
      )
      // --- Inspector tools ---
      ..registerTool(
        'enable_inspector',
        description:
            'Enables widget inspector/highlight mode in the Flutter app. '
            'When active, hovering over the app highlights widgets and allows '
            'selection. Tap a widget to select it and get detailed information. '
            'Use scroll wheel or arrow keys to cycle through overlapping widgets. '
            'Inspector and annotation modes are mutually exclusive. '
            'Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Enable Inspector'),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Enabling inspector mode');

          try {
            final response = await connector.enableInspector();
            final message = response['message'] as String?;

            return CallToolResult(
              content: [TextContent(text: message ?? 'Inspector mode enabled')],
            );
          } catch (err) {
            _logger.warning('Failed to enable inspector', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      ..registerTool(
        'disable_inspector',
        description:
            'Disables widget inspector/highlight mode. '
            'Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Disable Inspector'),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Disabling inspector mode');

          try {
            final response = await connector.disableInspector();
            final message = response['message'] as String?;

            return CallToolResult(
              content: [
                TextContent(text: message ?? 'Inspector mode disabled'),
              ],
            );
          } catch (err) {
            _logger.warning('Failed to disable inspector', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      ..registerTool(
        'get_inspector_selection',
        description:
            'Gets the currently selected widget data from the inspector, '
            'including widget type, ancestor path, source location, bounds, '
            'key, and text content. Returns null if no widget is selected. '
            'Requires an active connection and inspector mode to be enabled.',
        annotations: const ToolAnnotations(
          title: 'Get Inspector Selection',
          readOnlyHint: true,
          idempotentHint: true,
        ),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Getting inspector selection');

          try {
            final response = await connector.getInspectorSelection();
            final selection = response['selection'];

            if (selection == null) {
              return CallToolResult(
                content: [
                  const TextContent(
                    text:
                        'No widget selected. Enable inspector mode and '
                        'tap a widget, or use inspect_widget_at.',
                  ),
                ],
              );
            }

            return CallToolResult(
              content: [
                TextContent(
                  text: _formatSelection(selection as Map<String, dynamic>),
                ),
              ],
            );
          } catch (err) {
            _logger.warning('Failed to get inspector selection', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      ..registerTool(
        'inspect_widget_at',
        description:
            'Programmatically inspects the widget at the given screen '
            'coordinates (x, y). Returns the selected widget data including '
            'type, ancestor path, source location, properties, and bounds. '
            'Does not require inspector mode to be enabled. '
            'Use this tool to verify changes after modifying a widget — '
            'it is much cheaper than taking a screenshot. '
            'Requires an active connection established via connect.',
        annotations: const ToolAnnotations(
          title: 'Inspect Widget At',
          readOnlyHint: true,
        ),
        inputSchema: ToolInputSchema(
          properties: {
            'x': JsonSchema.number(
              description: 'The x coordinate (horizontal position from left).',
            ),
            'y': JsonSchema.number(
              description: 'The y coordinate (vertical position from top).',
            ),
          },
          required: ['x', 'y'],
        ),
        callback: (args, extra) async {
          final x = parseRequiredDoubleArg(args, 'x');
          final y = parseRequiredDoubleArg(args, 'y');
          _logger.info('Inspecting widget at ($x, $y)');

          try {
            final response = await connector.inspectorSelectAt(x, y);
            final selection = response['selection'];

            if (selection == null) {
              return CallToolResult(
                content: [TextContent(text: 'No widget found at ($x, $y)')],
              );
            }

            return CallToolResult(
              content: [
                TextContent(
                  text: _formatSelection(selection as Map<String, dynamic>),
                ),
              ],
            );
          } catch (err) {
            _logger.warning('Failed to inspect widget', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      // --- Annotation tools ---
      ..registerTool(
        'enable_annotations',
        description:
            'Enables annotation/markup drawing mode in the Flutter app. '
            'When active, drag to draw a rectangle and type a label. '
            'Annotations are stored and can be retrieved with get_annotations. '
            'Inspector and annotation modes are mutually exclusive. '
            'Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Enable Annotations'),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Enabling annotation mode');

          try {
            final response = await connector.enableAnnotationMode();
            final message = response['message'] as String?;

            return CallToolResult(
              content: [
                TextContent(text: message ?? 'Annotation mode enabled'),
              ],
            );
          } catch (err) {
            _logger.warning('Failed to enable annotations', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      ..registerTool(
        'disable_annotations',
        description:
            'Disables annotation/markup drawing mode. '
            'Existing annotations are preserved and can still be retrieved. '
            'Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Disable Annotations'),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Disabling annotation mode');

          try {
            final response = await connector.disableAnnotationMode();
            final message = response['message'] as String?;

            return CallToolResult(
              content: [
                TextContent(text: message ?? 'Annotation mode disabled'),
              ],
            );
          } catch (err) {
            _logger.warning('Failed to disable annotations', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      ..registerTool(
        'get_annotations',
        description:
            'Retrieves all annotations drawn by the user in the Flutter app. '
            'Each annotation includes its id, bounds (x, y, width, height), '
            'text label, and timestamp. '
            'Requires an active connection established via connect.',
        annotations: const ToolAnnotations(
          title: 'Get Annotations',
          readOnlyHint: true,
          idempotentHint: true,
        ),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Getting annotations');

          try {
            final response = await connector.getAnnotations();
            final annotations = response['annotations'] as List;
            final count = response['count'] as int;

            if (count == 0) {
              return CallToolResult(
                content: [const TextContent(text: 'No annotations found')],
              );
            }

            final buffer = StringBuffer()
              ..writeln('Found $count annotation(s):\n');

            for (final annotation in annotations) {
              final a = annotation as Map<String, dynamic>;
              final bounds = a['bounds'] as Map<String, dynamic>;
              buffer.writeln(
                '[${a['id']}] "${a['text']}" '
                '@ (${(bounds['x'] as num).round()}, '
                '${(bounds['y'] as num).round()}) '
                '${(bounds['width'] as num).round()}x'
                '${(bounds['height'] as num).round()}',
              );
            }

            return CallToolResult(
              content: [TextContent(text: buffer.toString())],
            );
          } catch (err) {
            _logger.warning('Failed to get annotations', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      ..registerTool(
        'clear_annotations',
        description:
            'Clears all annotations from the Flutter app. '
            'Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Clear Annotations'),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Clearing annotations');

          try {
            final response = await connector.clearAnnotations();
            final message = response['message'] as String?;

            return CallToolResult(
              content: [TextContent(text: message ?? 'Annotations cleared')],
            );
          } catch (err) {
            _logger.warning('Failed to clear annotations', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      ..registerTool(
        'add_annotation',
        description:
            'Programmatically adds an annotation rectangle with a text label '
            'at the specified position and size. The annotation will be '
            'visible in the app and retrievable via get_annotations. '
            'Requires an active connection established via connect.',
        annotations: const ToolAnnotations(title: 'Add Annotation'),
        inputSchema: ToolInputSchema(
          properties: {
            'x': JsonSchema.number(
              description: 'The x coordinate of the top-left corner.',
            ),
            'y': JsonSchema.number(
              description: 'The y coordinate of the top-left corner.',
            ),
            'width': JsonSchema.number(
              description: 'The width of the annotation rectangle.',
            ),
            'height': JsonSchema.number(
              description: 'The height of the annotation rectangle.',
            ),
            'text': JsonSchema.string(
              description: 'The text label for the annotation.',
            ),
          },
          required: ['x', 'y', 'width', 'height', 'text'],
        ),
        callback: (args, extra) async {
          final x = parseRequiredDoubleArg(args, 'x');
          final y = parseRequiredDoubleArg(args, 'y');
          final width = parseRequiredDoubleArg(args, 'width');
          final height = parseRequiredDoubleArg(args, 'height');
          final text = args['text'] as String;
          _logger.info(
            'Adding annotation at ($x, $y) ${width}x$height: "$text"',
          );

          try {
            await connector.addAnnotation(
              x: x,
              y: y,
              width: width,
              height: height,
              text: text,
            );

            return CallToolResult(
              content: [
                TextContent(
                  text:
                      'Annotation added at ($x, $y) '
                      '${width}x$height: "$text"',
                ),
              ],
            );
          } catch (err) {
            _logger.warning('Failed to add annotation', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      // --- User message tool ---
      ..registerTool(
        'get_user_message',
        description:
            'Retrieves pending messages sent by the user from the Flutter app. '
            'The user can use the inspector (Ctrl+Shift+H) to select a widget '
            'and type a message, or use annotations (Ctrl+Shift+A) to draw on '
            'the screen. Messages include the selected widget details (type, '
            'path, source location, properties) and any user instructions. '
            'This tool consumes and returns those messages. '
            'IMPORTANT: When the message includes a widget selection, the '
            'widget details (type, source location, bounds) are already '
            'provided. After making requested changes, verify by using '
            'inspect_widget_at on the same coordinates to check the updated '
            'widget properties instead of taking a full screenshot, which '
            'consumes significantly more tokens. Only use take_screenshots '
            'for visual/layout issues that cannot be verified via properties. '
            'Requires an active connection established via connect.',
        annotations: const ToolAnnotations(
          title: 'Get User Message',
          readOnlyHint: true,
        ),
        inputSchema: const ToolInputSchema(properties: {}),
        callback: (args, extra) async {
          _logger.info('Getting user messages');

          try {
            // First check for messages buffered by the polling loop
            final allMessages = <Map<String, dynamic>>[];
            if (_bufferedMessages.isNotEmpty) {
              allMessages.addAll(_bufferedMessages);
              _bufferedMessages.clear();
            }

            // Also check for any new messages not yet polled
            final response = await connector.consumeUserMessages();
            final freshMessages = response['messages'] as List?;
            if (freshMessages != null && freshMessages.isNotEmpty) {
              for (final msg in freshMessages) {
                allMessages.add(msg as Map<String, dynamic>);
              }
            }

            if (allMessages.isEmpty) {
              return CallToolResult(
                content: [const TextContent(text: 'No pending user messages')],
              );
            }

            final buffer = StringBuffer()
              ..writeln('${allMessages.length} message(s) from user:\n');

            final contentList = <Content>[];

            for (final m in allMessages) {
              final text = m['text'] as String? ?? '(no text)';
              buffer.writeln(text);
              buffer.writeln();
            }

            contentList.add(TextContent(text: buffer.toString()));

            // Include images if present (screenshots and drawings)
            for (final m in allMessages) {
              final data = m['data'] as Map<String, dynamic>?;
              if (data != null) {
                if (data.containsKey('screenshot')) {
                  final screenshotBase64 = data['screenshot'] as String;
                  contentList.add(
                    ImageContent(data: screenshotBase64, mimeType: 'image/png'),
                  );
                }
                if (data.containsKey('drawingImage')) {
                  final drawingBase64 = data['drawingImage'] as String;
                  contentList.add(
                    ImageContent(data: drawingBase64, mimeType: 'image/png'),
                  );
                }
              }
            }

            return CallToolResult(content: contentList);
          } catch (err) {
            _logger.warning('Failed to get user messages', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          }
        },
      )
      // --- Long-polling user message tool ---
      ..registerTool(
        'watch_flan',
        description:
            'Waits for a message from the user in the Flutter app. This tool '
            'blocks until the user sends a message (by selecting a widget and '
            'typing in the inspector, or by sending annotations). '
            'IMPORTANT: Call this tool in the background immediately after '
            'connecting to a Flutter app, and again after handling each '
            'received message, to continuously listen for user input. '
            'When a message is received, it includes the selected widget '
            'details (type, path, source location, bounds) and the user\'s '
            'instructions. After making requested changes, verify by using '
            'inspect_widget_at on the same coordinates instead of taking a '
            'screenshot. Then call watch_flan again in the '
            'background to continue listening.',
        annotations: const ToolAnnotations(
          title: 'Watch Flan',
          readOnlyHint: true,
        ),
        inputSchema: ToolInputSchema(
          properties: {
            'timeout': JsonSchema.integer(
              description:
                  'Maximum time to wait in seconds. Defaults to 300 (5 minutes).',
            ),
          },
        ),
        callback: (args, extra) async {
          final timeoutSecs = (args['timeout'] as int?) ?? 300;
          _logger.info('Waiting for user message (timeout: ${timeoutSecs}s)');

          _isWaitingForMessages = true;

          // Signal the Flutter app that the agent is listening.
          if (connector.isConnected) {
            try {
              await connector.setAgentListening(true);
            } catch (_) {}
          }

          try {
            final deadline = DateTime.now().add(Duration(seconds: timeoutSecs));

            while (DateTime.now().isBefore(deadline)) {
              // Bail out immediately if the connection was lost.
              if (!connector.isConnected) {
                return CallToolResult(
                  isError: true,
                  content: [
                    const TextContent(
                      text:
                          'Connection to the Flutter app was lost. '
                          'Use the connect tool to reconnect.',
                    ),
                  ],
                );
              }

              // Check buffered messages (filled by _startPolling)
              if (_bufferedMessages.isNotEmpty) {
                final messages = List<Map<String, dynamic>>.from(
                  _bufferedMessages,
                );
                _bufferedMessages.clear();
                return _formatUserMessages(messages);
              }

              // Wait for the polling loop to signal new messages, or timeout.
              final remaining = deadline.difference(DateTime.now());
              if (remaining.isNegative) break;

              _messageArrived = Completer<void>();
              try {
                await _messageArrived!.future.timeout(
                  // Wake up at most every 2s to re-check deadline, but
                  // don't exceed the remaining timeout.
                  remaining < const Duration(seconds: 2)
                      ? remaining
                      : const Duration(seconds: 2),
                );
              } on TimeoutException {
                // Normal — just loop back to check deadline and buffer.
              }
            }

            return CallToolResult(
              content: [
                const TextContent(
                  text: 'Timed out waiting for a user message.',
                ),
              ],
            );
          } catch (err) {
            _logger.warning('Error waiting for user message', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          } finally {
            _isWaitingForMessages = false;
            _messageArrived = null;
            // Signal the Flutter app that the agent stopped listening.
            if (connector.isConnected) {
              try {
                await connector.setAgentListening(false);
              } catch (_) {}
            }
          }
        },
      );
  }

  /// Formats consumed user messages into a CallToolResult.
  CallToolResult _formatUserMessages(List<Map<String, dynamic>> messages) {
    final buffer = StringBuffer()
      ..writeln('${messages.length} message(s) from user:\n');

    final contentList = <Content>[];

    for (final m in messages) {
      final text = m['text'] as String? ?? '(no text)';
      buffer.writeln(text);
      buffer.writeln();
    }

    contentList.add(TextContent(text: buffer.toString()));

    // Include images if present (screenshots and drawings)
    for (final m in messages) {
      final data = m['data'] as Map<String, dynamic>?;
      if (data != null) {
        if (data.containsKey('screenshot')) {
          final screenshotBase64 = data['screenshot'] as String;
          contentList.add(
            ImageContent(data: screenshotBase64, mimeType: 'image/png'),
          );
        }
        if (data.containsKey('drawingImage')) {
          final drawingBase64 = data['drawingImage'] as String;
          contentList.add(
            ImageContent(data: drawingBase64, mimeType: 'image/png'),
          );
        }
      }
    }

    return CallToolResult(content: contentList);
  }

  /// Formats an inspector selection for display.
  String _formatSelection(Map<String, dynamic> selection) {
    final buffer = StringBuffer();

    final widgetType = selection['widgetType'];
    if (widgetType != null) {
      buffer.writeln('Widget: $widgetType');
    }

    final widgetPath = selection['widgetPath'];
    if (widgetPath != null) {
      buffer.writeln('Path: $widgetPath');
    }

    final sourceLocation = selection['sourceLocation'];
    if (sourceLocation != null) {
      buffer.writeln('Source: $sourceLocation');
    }

    final key = selection['key'];
    if (key != null) {
      buffer.writeln('Key: $key');
    }

    final text = selection['text'];
    if (text != null) {
      buffer.writeln('Text: "$text"');
    }

    final bounds = selection['bounds'];
    if (bounds != null && bounds is Map) {
      final x = (bounds['x'] as num).round();
      final y = (bounds['y'] as num).round();
      final w = (bounds['width'] as num).round();
      final h = (bounds['height'] as num).round();
      buffer.writeln('Bounds: ($x, $y) ${w}x$h');
    }

    return buffer.toString().trimRight();
  }

  /// Builds a widget matcher map from tool arguments.
  Map<String, dynamic> _buildMatcher(Map<String, dynamic> args) {
    final matcher = <String, dynamic>{};
    // Flatten coordinates for VM service (which only supports string->string)
    if (args['coordinates'] case final Map<String, dynamic> coordinates) {
      matcher['x'] = coordinates['x'];
      matcher['y'] = coordinates['y'];
    }
    if (args.containsKey('key')) {
      matcher['key'] = args['key'];
    }
    if (args.containsKey('text')) {
      matcher['text'] = args['text'];
    }
    if (args.containsKey('type')) {
      matcher['type'] = args['type'];
    }
    return matcher;
  }

  /// Formats an element compactly for display.
  String _formatElement(Map<String, dynamic> element) {
    final parts = <String>[];

    final type = element['type'];
    if (type != null) parts.add(type as String);

    final key = element['key'];
    if (key != null) parts.add('key="$key"');

    final text = element['text'];
    if (text != null && text != '') parts.add('text="$text"');

    final tooltip = element['tooltip'];
    if (tooltip != null && tooltip != '') parts.add('tooltip="$tooltip"');

    final enabled = element['enabled'];
    if (enabled != null && enabled != 'true') parts.add('enabled=$enabled');

    final data = element['data'];
    if (data != null && data != '' && text == null) parts.add('data="$data"');

    final bounds = element['bounds'];
    if (bounds != null && bounds is Map) {
      final x = (bounds['x'] as num).round();
      final y = (bounds['y'] as num).round();
      final w = (bounds['width'] as num).round();
      final h = (bounds['height'] as num).round();
      parts.add('@($x,$y ${w}x$h)');
    }

    final visible = element['visible'];
    if (visible == false) parts.add('HIDDEN');

    return parts.join(' | ');
  }
}
