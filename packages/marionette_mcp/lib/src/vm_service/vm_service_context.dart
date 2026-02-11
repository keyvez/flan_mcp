import 'package:logging/logging.dart' as logging;
import 'package:marionette_mcp/src/vm_service/vm_service_connector.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Context for managing VM service connection and registering MCP tools.
final class VmServiceContext {
  VmServiceContext()
    : connector = VmServiceConnector(),
      _logger = logging.Logger('VmServiceContext');

  final VmServiceConnector connector;
  final logging.Logger _logger;

  /// Registers all VM service related tools with the MCP server.
  void registerTools(McpServer server) {
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
            return CallToolResult(
              content: [
                TextContent(text: 'Successfully connected to app at $uri'),
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
            var elements =
                (response['elements'] as List<dynamic>)
                    .cast<Map<String, dynamic>>();

            // Apply filters
            final typesFilter = args['types'] as String?;
            final withKeysOnly = args['with_keys_only'] as bool? ?? false;
            final textContains = args['text_contains'] as String?;

            if (typesFilter != null && typesFilter.isNotEmpty) {
              final allowed =
                  typesFilter.split(',').map((t) => t.trim()).toSet();
              elements =
                  elements
                      .where(
                        (e) =>
                            e['type'] != null &&
                            allowed.contains(e['type'] as String),
                      )
                      .toList();
            }

            if (withKeysOnly) {
              elements =
                  elements
                      .where(
                        (e) => e['key'] != null && (e['key'] as String) != '',
                      )
                      .toList();
            }

            if (textContains != null && textContains.isNotEmpty) {
              final needle = textContains.toLowerCase();
              elements =
                  elements.where((e) {
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
            final reloaded = await connector.hotReload();

            if (reloaded) {
              return CallToolResult(
                content: [
                  const TextContent(text: 'Hot reload completed successfully'),
                ],
              );
            } else {
              return CallToolResult(
                isError: true,
                content: [
                  TextContent(
                    text: 'Hot reload failed. The app may need a full restart.',
                  ),
                ],
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
                  const TextContent(
                    text: 'Hot restart completed successfully',
                  ),
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
      );
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
