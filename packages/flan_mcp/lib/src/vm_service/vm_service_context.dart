import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart' as logging;
import 'package:flan_mcp/src/utils/num_parser.dart';
import 'package:flan_mcp/src/vm_service/vm_service_connector.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Context for managing VM service connection and registering MCP tools.
final class VmServiceContext {
  VmServiceContext({VmServiceConnector? connector})
    : connector = connector ?? VmServiceConnector(),
      _logger = logging.Logger('VmServiceContext');

  static const String _pendingMessagesResourceUri = 'flan://messages/pending';
  static const String _pendingMessagesResourceMime = 'application/json';
  static const String _annotationsResourceUri = 'flan://annotations';
  static const String _annotationsResourceMime = 'application/json';

  final VmServiceConnector connector;
  final logging.Logger _logger;
  McpServer? _server;

  /// Buffered messages consumed from the Flutter app queue, available for
  /// retrieval via `get_user_message`.
  final List<Map<String, dynamic>> _bufferedMessages = [];

  /// Whether `process_queue` is actively running.
  bool _isProcessingQueue = false;
  Timer? _agentListeningHeartbeat;

  /// Completer that `process_queue` waits on. Completed when new messages arrive.
  Completer<void>? _messageArrived;

  bool _isDrainingMessages = false;
  bool _drainRequested = false;
  DateTime? _lastMessageReceivedAt;
  int _lastKnownAppPendingCount = 0;
  int _drainGeneration = 0;
  bool _enableSamplingPush = false;
  DateTime? _lastSamplingPushAt;

  void _onUserMessageQueued() {
    unawaited(_refreshPendingQueueAndNotify(origin: 'extension-event'));
  }

  void _onAnnotationChanged() {
    unawaited(_notifyAnnotationsResourceUpdated());
  }

  Future<void> _notifyAnnotationsResourceUpdated() async {
    final server = _server;
    if (server == null || !server.isConnected) return;

    try {
      await server.server.sendResourceUpdated(
        const ResourceUpdatedNotification(uri: _annotationsResourceUri),
      );
    } catch (err) {
      _logger.fine('Skipping annotation resource update notification: $err');
    }
  }

  Future<void> _refreshPendingQueueAndNotify({required String origin}) async {
    if (!connector.isConnected || _server == null) return;

    try {
      final generationBefore = _drainGeneration;
      final response = await connector.peekUserMessages();
      final pendingCount = (response['count'] as num?)?.toInt() ?? 0;
      // Only update the cached count when no drain happened while the peek
      // was in flight.  A concurrent drain already set the authoritative
      // count to 0, and overwriting it with a stale peek value would make
      // the resource report phantom pending messages.
      if (_drainGeneration == generationBefore) {
        _lastKnownAppPendingCount = pendingCount;
      }
      if (pendingCount > 0) {
        _lastMessageReceivedAt = DateTime.now().toUtc();
      }

      if (_messageArrived != null && !_messageArrived!.isCompleted) {
        _messageArrived!.complete();
      }

      // Only send logging/resource notifications when the peek is still
      // fresh (no drain consumed the messages while the peek was in flight)
      // and process_queue is NOT active.
      if (_drainGeneration == generationBefore) {
        if (!_isProcessingQueue && pendingCount > 0) {
          await _server!.sendLoggingMessage(
            LoggingMessageNotification(
              level: LoggingLevel.info,
              logger: 'flan-user',
              data:
                  '$pendingCount pending message(s) from the Flutter app user. '
                  'Call process_queue, get_user_message, or read flan://messages/pending.',
            ),
          );
        }

        await _notifyPendingMessagesResourceUpdated();
        _maybeTriggerSamplingPushForPendingCount(pendingCount);
      }
    } catch (err, st) {
      _logger.warning('Failed to refresh pending queue ($origin)', err, st);
    }
  }

  Future<void> _drainMessagesAndNotify({required String origin}) async {
    if (!connector.isConnected || _server == null) return;

    if (_isDrainingMessages) {
      _drainRequested = true;
      return;
    }

    _isDrainingMessages = true;
    var totalAdded = 0;
    final allAddedMessages = <Map<String, dynamic>>[];

    try {
      while (true) {
        _drainRequested = false;
        final response = await connector.consumeUserMessages();
        final messages =
            (response['messages'] as List<dynamic>?)
                ?.cast<Map<String, dynamic>>() ??
            const <Map<String, dynamic>>[];

        if (messages.isNotEmpty) {
          _bufferedMessages.addAll(messages);
          allAddedMessages.addAll(messages);
          _lastMessageReceivedAt = DateTime.now().toUtc();
          _lastKnownAppPendingCount = 0;
          _drainGeneration++;
          totalAdded += messages.length;
        }

        if (!_drainRequested) {
          break;
        }
      }

      if (totalAdded == 0) return;

      if (_messageArrived != null && !_messageArrived!.isCompleted) {
        _messageArrived!.complete();
      }

      await _notifyPendingMessagesResourceUpdated();
      _maybeTriggerSamplingPush(allAddedMessages);
    } catch (err, st) {
      _logger.warning('Failed to drain user messages ($origin)', err, st);
    } finally {
      _isDrainingMessages = false;
    }
  }

  Future<void> _notifyPendingMessagesResourceUpdated() async {
    final server = _server;
    if (server == null || !server.isConnected) return;

    try {
      await server.server.sendResourceUpdated(
        const ResourceUpdatedNotification(uri: _pendingMessagesResourceUri),
      );
    } catch (err) {
      // Clients that do not support/subscribe to resources can ignore this.
      _logger.fine('Skipping resource update notification: $err');
    }
  }

  void _maybeTriggerSamplingPush(List<Map<String, dynamic>> newMessages) {
    if (!_enableSamplingPush || _isProcessingQueue) {
      return;
    }

    final server = _server;
    if (server == null || !server.isConnected) {
      return;
    }

    final capabilities = server.server.getClientCapabilities();
    if (capabilities?.sampling == null) {
      return;
    }

    final now = DateTime.now().toUtc();
    final lastPushAt = _lastSamplingPushAt;
    if (lastPushAt != null &&
        now.difference(lastPushAt) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastSamplingPushAt = now;

    final preview = newMessages
        .take(3)
        .map((m) => '- ${m['text'] as String? ?? '(no text)'}')
        .join('\n');

    unawaited(() async {
      try {
        final result = await server.server.createMessage(
          CreateMessageRequest(
            messages: [
              SamplingMessage(
                role: SamplingMessageRole.user,
                content: SamplingTextContent(
                  text:
                      'A Flutter app user sent new message(s) to Flan.\n'
                      'Call get_user_message (or read flan://messages/pending) '
                      'to consume them now.\n'
                      'Preview:\n$preview',
                ),
              ),
            ],
            maxTokens: 160,
          ),
          RequestOptions(timeout: const Duration(seconds: 3)),
        );
        _logger.fine(
          'Triggered sampling push for ${newMessages.length} message(s), model: ${result.model}',
        );
      } catch (err) {
        _logger.warning('Sampling push trigger failed', err);
      }
    }());
  }

  void _maybeTriggerSamplingPushForPendingCount(int pendingCount) {
    if (!_enableSamplingPush || _isProcessingQueue || pendingCount <= 0) {
      return;
    }

    final server = _server;
    if (server == null || !server.isConnected) {
      return;
    }

    final capabilities = server.server.getClientCapabilities();
    if (capabilities?.sampling == null) {
      return;
    }

    final now = DateTime.now().toUtc();
    final lastPushAt = _lastSamplingPushAt;
    if (lastPushAt != null &&
        now.difference(lastPushAt) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastSamplingPushAt = now;

    unawaited(() async {
      try {
        final result = await server.server.createMessage(
          CreateMessageRequest(
            messages: [
              SamplingMessage(
                role: SamplingMessageRole.user,
                content: SamplingTextContent(
                  text:
                      'A Flutter app user sent new message(s) to Flan.\n'
                      'There are currently $pendingCount pending message(s).\n'
                      'Call process_queue (or get_user_message) to consume them.',
                ),
              ),
            ],
            maxTokens: 120,
          ),
          RequestOptions(timeout: const Duration(seconds: 3)),
        );
        _logger.fine(
          'Triggered sampling push for pending queue ($pendingCount), model: ${result.model}',
        );
      } catch (err) {
        _logger.warning('Sampling push trigger failed', err);
      }
    }());
  }

  int get debugBufferedMessageCount => _bufferedMessages.length;

  void debugSetSamplingPushEnabled(bool enabled) {
    _enableSamplingPush = enabled;
  }

  void _startAgentListeningHeartbeat() {
    _agentListeningHeartbeat?.cancel();
    _agentListeningHeartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_isProcessingQueue || !connector.isConnected) return;
      unawaited(() async {
        try {
          await connector.setAgentListening(true);
        } catch (_) {
          // Ignore heartbeat errors (e.g. app disconnect in progress).
        }
      }());
    });
  }

  void _stopAgentListeningHeartbeat() {
    _agentListeningHeartbeat?.cancel();
    _agentListeningHeartbeat = null;
  }

  /// Handles unexpected connection loss by cleaning up state and notifying
  /// the agent via a logging message.
  void _onConnectionLost() {
    _stopAgentListeningHeartbeat();
    _isDrainingMessages = false;
    _drainRequested = false;
    _isProcessingQueue = false;
    _lastKnownAppPendingCount = 0;
    _enableSamplingPush = false;
    _lastSamplingPushAt = null;
    unawaited(() async {
      try {
        await connector.setHostConnectionState(
          connected: false,
          pushCapable: false,
        );
      } catch (_) {}
    }());
    unawaited(() async {
      try {
        await connector.setAgentListening(false);
      } catch (_) {}
    }());
    // Wake up process_queue if it's blocked so it can return an error.
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
    connector.onUserMessageQueued = _onUserMessageQueued;
    connector.onAnnotationChanged = _onAnnotationChanged;

    server.registerResource(
      'flan_pending_messages',
      _pendingMessagesResourceUri,
      (
        description:
            'Snapshot of queued user messages waiting for the agent '
            'in the connected Flutter app.',
        mimeType: _pendingMessagesResourceMime,
      ),
      (uri, extra) async => _buildPendingMessagesResource(uri),
    );

    server.registerResource(
      'flan_annotations',
      _annotationsResourceUri,
      (
        description: 'Current annotations drawn on the Flutter app screen.',
        mimeType: _annotationsResourceMime,
      ),
      (uri, extra) async => _buildAnnotationsResource(uri),
    );

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
            'sampling_push': JsonSchema.boolean(
              description:
                  'Enable server-initiated sampling/createMessage triggers when user messages arrive. '
                  'Only works if the MCP client advertises sampling capability.',
            ),
          },
          required: ['uri'],
        ),
        callback: (args, extra) async {
          final uri = args['uri'] as String;
          _enableSamplingPush = args['sampling_push'] as bool? ?? false;
          _logger.info('Connecting to app at $uri');

          try {
            await connector.connect(uri);
            await _refreshPendingQueueAndNotify(origin: 'connect');
            final clientCapabilities = _server?.server.getClientCapabilities();
            final samplingAvailable = clientCapabilities?.sampling != null;
            // Resource-updated notifications are server-initiated JSON-RPC
            // notifications and are available whenever a host is connected.
            final notificationPushAvailable = _server?.isConnected ?? false;
            final pushCapable = notificationPushAvailable || samplingAvailable;
            try {
              await connector.setHostConnectionState(
                connected: true,
                pushCapable: pushCapable,
              );
            } catch (err) {
              _logger.fine('Failed to set host connection state: $err');
            }
            final samplingState = !_enableSamplingPush
                ? 'disabled'
                : (samplingAvailable ? 'enabled' : 'requested (unsupported)');
            return CallToolResult(
              content: [
                TextContent(
                  text:
                      'Successfully connected to app at $uri.\n\n'
                      'Message delivery is event-driven now (no timer polling). '
                      'You can use process_queue to drain pending messages, '
                      'get_user_message for manual retrieval, '
                      'or read flan://messages/pending.\n'
                      'sampling_push: $samplingState',
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
            _stopAgentListeningHeartbeat();
            _isDrainingMessages = false;
            _drainRequested = false;
            _isProcessingQueue = false;
            _lastKnownAppPendingCount = 0;
            _enableSamplingPush = false;
            _lastSamplingPushAt = null;
            if (_messageArrived != null && !_messageArrived!.isCompleted) {
              _messageArrived!.complete();
            }
            try {
              await connector.setAgentListening(false);
            } catch (_) {}
            try {
              await connector.setHostConnectionState(
                connected: false,
                pushCapable: false,
              );
            } catch (_) {}
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
            'type, ancestor path, source location, key/text (when present), '
            'and bounds. '
            'Does not require inspector mode to be enabled. '
            'This call is side-effect-free and does not toggle inspector or '
            'annotation UI state. '
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
            await _drainMessagesAndNotify(origin: 'get_user_message');
            final allMessages = List<Map<String, dynamic>>.from(
              _bufferedMessages,
            );
            _bufferedMessages.clear();

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
      // --- Queue processing tool ---
      ..registerTool(
        'process_queue',
        description:
            'Consumes and returns queued user messages from the Flutter app '
            'until the queue is drained. Use this after the user sends a batch '
            'of instructions, then run it once to process all pending items. '
            'Messages include selected-widget metadata and optional images. '
            'After applying changes, verify with inspect_widget_at when '
            'possible instead of full screenshots.',
        annotations: const ToolAnnotations(
          title: 'Process Queue',
          readOnlyHint: true,
        ),
        inputSchema: ToolInputSchema(
          properties: {
            'idle_timeout_ms': JsonSchema.integer(
              description:
                  'How long to wait for more messages after processing begins. '
                  'Stops when no new messages arrive within this window. '
                  'Defaults to 500.',
            ),
            'max_wait_seconds': JsonSchema.integer(
              description:
                  'Safety cap for total processing time. Defaults to 30.',
            ),
          },
        ),
        callback: (args, extra) async {
          final idleTimeoutMs = (args['idle_timeout_ms'] as int?) ?? 500;
          final maxWaitSeconds = (args['max_wait_seconds'] as int?) ?? 30;
          _logger.info(
            'Processing message queue '
            '(idle_timeout_ms: $idleTimeoutMs, max_wait_seconds: $maxWaitSeconds)',
          );

          _isProcessingQueue = true;

          // Signal the Flutter app that the agent is listening.
          if (connector.isConnected) {
            try {
              await connector.setAgentListening(true);
            } catch (_) {}
          }
          _startAgentListeningHeartbeat();

          try {
            final deadline = DateTime.now().add(
              Duration(seconds: maxWaitSeconds),
            );
            final allMessages = <Map<String, dynamic>>[];

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

              await _drainMessagesAndNotify(origin: 'process_queue');

              if (_bufferedMessages.isNotEmpty) {
                allMessages.addAll(_bufferedMessages);
                _bufferedMessages.clear();
              } else if (allMessages.isEmpty) {
                return CallToolResult(
                  content: [
                    const TextContent(text: 'No pending user messages'),
                  ],
                );
              }

              final remaining = deadline.difference(DateTime.now());
              if (remaining <= Duration.zero) {
                break;
              }

              _messageArrived = Completer<void>();
              if (_bufferedMessages.isNotEmpty &&
                  !_messageArrived!.isCompleted) {
                _messageArrived!.complete();
              }

              final waitWindow = Duration(milliseconds: idleTimeoutMs);
              try {
                await _messageArrived!.future.timeout(
                  remaining < waitWindow ? remaining : waitWindow,
                );
              } on TimeoutException {
                // Queue stayed idle for the configured window: done.
                break;
              }
            }

            if (allMessages.isEmpty) {
              return CallToolResult(
                content: [const TextContent(text: 'No pending user messages')],
              );
            }

            return _formatUserMessages(allMessages);
          } catch (err) {
            _logger.warning('Error processing user message queue', err);
            return CallToolResult(
              isError: true,
              content: [TextContent(text: err.toString())],
            );
          } finally {
            _stopAgentListeningHeartbeat();
            _isProcessingQueue = false;
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

  ReadResourceResult _buildPendingMessagesResource(Uri uri) {
    const previewLimit = 10;
    final previewSource = _bufferedMessages.length <= previewLimit
        ? _bufferedMessages
        : _bufferedMessages.sublist(_bufferedMessages.length - previewLimit);

    final preview = previewSource.map((message) {
      final data = message['data'] as Map<String, dynamic>?;
      return <String, dynamic>{
        'timestamp': message['timestamp'],
        'text': message['text'],
        'hasScreenshot': data?.containsKey('screenshot') ?? false,
        'hasDrawing': data?.containsKey('drawingImage') ?? false,
      };
    }).toList();

    final bufferedCount = _bufferedMessages.length;
    final appPendingCount = _lastKnownAppPendingCount;
    final snapshot = jsonEncode({
      'count': bufferedCount + appPendingCount,
      'bufferedCount': bufferedCount,
      'appPendingCount': appPendingCount,
      'previewCount': preview.length,
      'preview': preview,
      'lastMessageReceivedAt': _lastMessageReceivedAt?.toIso8601String(),
    });

    return ReadResourceResult(
      contents: [
        TextResourceContents(
          uri: uri.toString(),
          mimeType: _pendingMessagesResourceMime,
          text: snapshot,
        ),
      ],
    );
  }

  Future<ReadResourceResult> _buildAnnotationsResource(Uri uri) async {
    if (!connector.isConnected) {
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: _annotationsResourceMime,
            text: jsonEncode({'error': 'Not connected'}),
          ),
        ],
      );
    }

    try {
      final response = await connector.getAnnotations();
      final annotations = response['annotations'] as List<dynamic>? ?? [];
      final snapshot = jsonEncode({
        'count': annotations.length,
        'annotations': annotations,
      });

      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: _annotationsResourceMime,
            text: snapshot,
          ),
        ],
      );
    } catch (err) {
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: _annotationsResourceMime,
            text: jsonEncode({'error': err.toString()}),
          ),
        ],
      );
    }
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
