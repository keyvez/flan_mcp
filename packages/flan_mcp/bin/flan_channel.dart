/// Flan Channel — a Claude Code channel MCP server.
///
/// Receives flush events from the flan TUI (or directly from the Flutter app)
/// and pushes queued user messages directly into the running Claude Code session
/// via the MCP `notifications/claude/channel` mechanism, eliminating the
/// "connect then process_queue" round-trip.
///
/// Usage:
///   dart run packages/flan_mcp/bin/flan_channel.dart [options]
///
/// Register in .mcp.json as an MCP server, then start Claude Code with:
///   claude --dangerously-load-development-channels server:flan-channel
///
/// The channel listens for POST /flush requests on --listen-port (default 4051).
/// The flan TUI should be configured to POST to this port in addition to (or
/// instead of) injecting text into the Claude terminal.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:logging/logging.dart' as logging;
import 'package:flan_mcp/src/chat_log_formatter.dart';
import 'package:flan_mcp/src/compat/copilot_stdio_server_transport.dart';
import 'package:flan_mcp/src/version.g.dart';
import 'package:mcp_dart/mcp_dart.dart';

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

ArgParser _buildParser() {
  return ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Print usage.')
    ..addFlag('version', negatable: false, help: 'Print the tool version.')
    ..addOption(
      'log-level',
      abbr: 'l',
      defaultsTo: 'INFO',
      help: 'Log level (FINEST, FINER, FINE, CONFIG, INFO, WARNING, SEVERE).',
    )
    ..addOption('log-file', help: 'Path to log file. Defaults to stderr.')
    ..addOption(
      'listen-port',
      defaultsTo: '4051',
      help: 'Local HTTP port to listen on for flush POSTs from the TUI.',
    )
;
}

void _printUsage(ArgParser p) {
  stderr
    ..writeln('Flan Channel — Claude Code channel MCP server')
    ..writeln()
    ..writeln('Usage: flan_channel [options]')
    ..writeln()
    ..writeln(p.usage);
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

void _setupLogging(String levelName, String? logFile) {
  final level = logging.Level.LEVELS.firstWhere(
    (e) => e.name == levelName,
    orElse: () => logging.Level.INFO,
  );
  logging.Logger.root.level = level;
  if (logFile != null) {
    final file = File(logFile)..createSync(recursive: true);
    logging.Logger.root.onRecord.listen((r) {
      file.writeAsStringSync(
        '[${r.level.name}][${r.loggerName}][${_fmt(r.time)}] ${r.message}\n',
        mode: FileMode.append,
      );
    });
  } else {
    logging.Logger.root.onRecord.listen((r) {
      stderr.writeln('[${r.level.name}][${r.loggerName}][${_fmt(r.time)}] ${r.message}');
    });
  }
}

String _fmt(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

// ---------------------------------------------------------------------------
// Channel server
// ---------------------------------------------------------------------------

class FlanChannel {
  FlanChannel({
    required this.mcpServer,
    required this.listenPort,
  });

  final McpServer mcpServer;
  final int listenPort;

  /// The port the HTTP server actually bound to (may differ from [listenPort]
  /// if that port was already in use).
  int get boundPort => _boundPort;
  int _boundPort = 0;

  final _logger = logging.Logger('FlanChannel');
  HttpServer? _httpServer;
  Timer? _registrationTimer;

  /// Images (screenshots, drawings) buffered from the last flush, available
  /// for retrieval via the `get_flushed_images` tool.
  final List<Map<String, dynamic>> _pendingImages = [];

  /// Channel events that have been received from a flush but not yet
  /// confirmed delivered to the Claude session. We hold them here and replay
  /// them when the session connects/initializes, so a flush that arrives
  /// before the MCP client is ready (or during a transient disconnect) is
  /// never silently dropped — which previously forced the user to retype.
  final List<_PendingEvent> _pendingEvents = [];

  /// Guards [_drainPending] so two concurrent drains can't double-send.
  bool _draining = false;

  /// Maximum number of ports to try when the preferred port is taken.
  static const _maxPortAttempts = 10;

  Future<void> start() async {
    // Try the preferred port first, then increment up to _maxPortAttempts.
    for (var attempt = 0; attempt < _maxPortAttempts; attempt++) {
      final port = listenPort + attempt;
      try {
        _httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        _boundPort = port;
        _logger.info('Listening for flush events on http://127.0.0.1:$port');
        unawaited(_serveRequests());
        unawaited(_registerWithTui());
        // Re-register periodically so the TUI picks us up after restarts.
        _registrationTimer = Timer.periodic(
          const Duration(seconds: 30),
          (_) => unawaited(_registerWithTui()),
        );
        return;
      } on SocketException catch (e) {
        if (attempt == _maxPortAttempts - 1) rethrow;
        _logger.fine('Port $port in use ($e), trying ${port + 1}');
      }
    }
  }

  /// Register our bound port with the flan TUI server.  We send our PID and
  /// let the server resolve which trm pane we belong to (it uses trm's own
  /// `surface.list` RPC, so the index is guaranteed to match).
  Future<void> _registerWithTui() async {
    try {
      final resp = await HttpClient()
          .postUrl(Uri.parse('http://127.0.0.1:4050/api/register-channel'))
          .then((req) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({
          'pid': pid,
          'port': _boundPort,
          'cwd': Directory.current.path,
        }));
        return req.close();
      });
      final body = await resp.transform(utf8.decoder).join();
      _logger.info('Registered channel (pid=$pid) → port $_boundPort: ${resp.statusCode} $body');
    } catch (e) {
      _logger.warning('Could not register channel port with TUI: $e');
    }
  }

  void registerTools() {
    mcpServer.registerTool(
      'get_flushed_images',
      description:
          'Retrieves screenshots and drawings that were included with the '
          'most recent batch of flushed user messages. Call this when the '
          'channel event mentions attached images. Returns the images as '
          'base64-encoded PNGs. Each call consumes the buffered images.',
      annotations: const ToolAnnotations(
        title: 'Get Flushed Images',
        readOnlyHint: true,
      ),
      inputSchema: const ToolInputSchema(properties: {}),
      callback: (args, extra) async {
        if (_pendingImages.isEmpty) {
          return CallToolResult(
            content: [const TextContent(text: 'No pending images')],
          );
        }

        final images = List<Map<String, dynamic>>.from(_pendingImages);
        _pendingImages.clear();

        final contentList = <Content>[];
        for (final img in images) {
          final imgType = img['type'] as String? ?? 'image';
          contentList.add(TextContent(text: '[$imgType]'));
          contentList.add(
            ImageContent(
              data: img['data'] as String,
              mimeType: img['mimeType'] as String? ?? 'image/png',
            ),
          );
        }

        return CallToolResult(content: contentList);
      },
    );
  }

  Future<void> close() async {
    _registrationTimer?.cancel();
    await _httpServer?.close(force: true);
  }

  Future<void> _serveRequests() async {
    await for (final req in _httpServer!) {
      unawaited(_handle(req));
    }
  }

  void _addCorsHeaders(HttpResponse res) {
    res.headers
      ..add('Access-Control-Allow-Origin', '*')
      ..add('Access-Control-Allow-Methods', 'POST, OPTIONS')
      ..add('Access-Control-Allow-Headers', 'Content-Type');
  }

  Future<void> _handle(HttpRequest req) async {
    _addCorsHeaders(req.response);

    // Handle CORS preflight.
    if (req.method == 'OPTIONS') {
      req.response
        ..statusCode = HttpStatus.noContent
        ..close();
      return;
    }

    if (req.method != 'POST') {
      req.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..close();
      return;
    }

    try {
      final bodyBytes = await req.fold<List<int>>(
        [],
        (acc, chunk) => acc..addAll(chunk),
      );
      final body = bodyBytes.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;

      final vmUri = body['vm_service_uri'] as String?;
      final flutterPid = body['flutter_pid'];
      final messages =
          (body['messages'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
              [];

      _logger.info('Flush received: pid=$flutterPid vm_uri=$vmUri '
          'messages=${messages.length}');

      if (messages.isEmpty) {
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': false, 'reason': 'no messages'}));
        await req.response.close();
        return;
      }

      final content = _formatMessages(messages);
      final route = _extractRouteAttribute(messages);
      final delivered = await _pushToClaudeSession(
        content: content,
        vmUri: vmUri,
        route: route,
      );

      // Always 200/ok: the event is now durably queued and will be replayed
      // when the session connects, so the app should treat it as accepted and
      // NOT make the user retype. `delivered` distinguishes pushed-now from
      // queued-for-replay for diagnostics.
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true, 'delivered': delivered}));
    } catch (err, st) {
      _logger.warning('Error handling flush request', err, st);
      req.response
        ..statusCode = HttpStatus.internalServerError
        ..write(jsonEncode({'error': err.toString()}));
    } finally {
      await req.response.close();
    }
  }

  /// Format messages for the channel notification.
  ///
  /// Extracts contextual data (current route, inspector selection, annotations)
  /// from the `data` field of each message so the agent receives the full
  /// context — not just the summary text.  Images (screenshots, drawings) are
  /// buffered separately in [_pendingImages] for retrieval via the
  /// `get_flushed_images` tool.
  String _formatMessages(List<Map<String, dynamic>> messages) {
    _pendingImages.clear();

    final buf = StringBuffer();
    for (final msg in messages) {
      final text = msg['text'] as String? ?? '';
      final type = msg['type'] as String? ?? 'message';
      final ts = msg['timestamp'] as String? ?? '';
      final data = msg['data'] as Map<String, dynamic>?;

      if (ts.isNotEmpty) buf.writeln('[$ts]');
      if (type != 'user_feedback') buf.writeln('type: $type');
      buf.writeln(text);

      if (data != null) {
        // Navigation context — emit each signal on its own line so the
        // agent can latch onto whichever one the app populates. `url` is
        // the platform/deep-link URL (browser bar / go_router); `Route
        // stack` is the in-app breadcrumb of named routes from root to
        // top; `Current route` is the deepest route name (kept for
        // backward compat with older messages that only sent that one).
        final url = data['url'] as String?;
        if (url != null && url.isNotEmpty) {
          buf.writeln('URL: $url');
        }
        final routeStack = data['routeStack'] as String?;
        if (routeStack != null && routeStack.isNotEmpty) {
          buf.writeln('Route stack: $routeStack');
        }
        final currentRoute = data['currentRoute'] as String?;
        if (currentRoute != null && currentRoute.isNotEmpty) {
          buf.writeln('Current route: $currentRoute');
        }

        // Inspector selection details
        final selection = data['inspectorSelection'];
        if (selection is Map<String, dynamic>) {
          buf.writeln('Inspector selection:');
          if (selection['widgetType'] != null) {
            buf.writeln('  Widget type: ${selection['widgetType']}');
          }
          if (selection['widgetPath'] != null) {
            buf.writeln('  Widget path: ${selection['widgetPath']}');
          }
          if (selection['sourceLocation'] != null) {
            buf.writeln('  Source: ${selection['sourceLocation']}');
          }
          if (selection['bounds'] != null) {
            buf.writeln('  Bounds: ${selection['bounds']}');
          }
          if (selection['properties'] != null) {
            buf.writeln('  Properties: ${jsonEncode(selection['properties'])}');
          }
        }

        // Annotations
        final annotations = data['annotations'];
        if (annotations is List && annotations.isNotEmpty) {
          buf.writeln('Annotations: ${jsonEncode(annotations)}');
        }

        // Chat log — a structured conversation transcript (e.g. an
        // in-app AI chat). Rendered as a readable, role-prefixed
        // transcript AND echoed as structured JSON so the agent can
        // both skim it and parse it precisely.
        final chatLog = data['turns'] ?? data['chatLog'];
        if (chatLog is List && chatLog.isNotEmpty) {
          buf.write(formatChatLog(chatLog, data));
        }

        // Buffer images for retrieval via tool
        if (data.containsKey('screenshot')) {
          _pendingImages.add({
            'type': 'screenshot',
            'data': data['screenshot'],
            'mimeType': 'image/png',
          });
          buf.writeln('[screenshot attached — use get_flushed_images to view]');
        }
        if (data.containsKey('drawingImage')) {
          _pendingImages.add({
            'type': 'drawing',
            'data': data['drawingImage'],
            'mimeType': 'image/png',
          });
          buf.writeln('[drawing attached — use get_flushed_images to view]');
        }
      }

      buf.writeln();
    }
    return buf.toString().trim();
  }

  /// Picks the best `route` attribute value to surface on the `<channel>`
  /// element. The agent reads this from the element header so pronouns
  /// like "this screen" have a referent even when the user didn't use
  /// the inspector/annotation tools.
  ///
  /// Preference order: the first message's `data.url` (platform / deep
  /// link — go_router URI, browser address bar), then `data.currentRoute`
  /// (deepest [ModalRoute] name) for non-Router apps.
  String? _extractRouteAttribute(List<Map<String, dynamic>> messages) {
    for (final msg in messages) {
      final data = msg['data'];
      if (data is! Map<String, dynamic>) continue;
      final url = data['url'];
      if (url is String && url.isNotEmpty) return url;
      final currentRoute = data['currentRoute'];
      if (currentRoute is String && currentRoute.isNotEmpty) {
        return currentRoute;
      }
    }
    return null;
  }

  /// Queue a channel event for delivery and attempt to drain immediately.
  ///
  /// Returns `true` if the event was delivered to the MCP session now, or
  /// `false` if it was queued for replay (because the session isn't connected
  /// yet, or a send failed). Either way the event is retained until a send
  /// succeeds, so nothing is lost.
  Future<bool> _pushToClaudeSession({
    required String content,
    String? vmUri,
    String? route,
  }) async {
    _pendingEvents.add(_PendingEvent(content: content, vmUri: vmUri, route: route));
    await _drainPending();
    return _pendingEvents.isEmpty;
  }

  /// Replay any events that arrived while the session was unavailable. Wired
  /// to the MCP server's `oninitialized` so a freshly-connected client gets
  /// everything that queued up beforehand.
  Future<void> replayPending() async {
    if (_pendingEvents.isEmpty) return;
    _logger.info('Replaying ${_pendingEvents.length} pending channel event(s)');
    await _drainPending();
  }

  /// Send queued events in order, stopping at the first failure so ordering is
  /// preserved and the failed event stays at the head of the queue for retry.
  Future<void> _drainPending() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pendingEvents.isNotEmpty) {
        if (!mcpServer.isConnected) {
          _logger.warning(
            'MCP server not connected; ${_pendingEvents.length} channel '
            'event(s) held for replay',
          );
          return;
        }
        final event = _pendingEvents.first;
        final meta = <String, String>{
          if (event.vmUri != null) 'vm_uri': event.vmUri!,
          if (event.route != null) 'route': event.route!,
        };
        try {
          await mcpServer.server.notification(
            JsonRpcNotification(
              method: 'notifications/claude/channel',
              params: {
                'content': event.content,
                if (meta.isNotEmpty) 'meta': meta,
              },
            ),
          );
        } catch (e, st) {
          _logger.warning(
            'Failed to push channel event; keeping it queued for replay', e, st);
          return;
        }
        // Delivered — drop it from the queue.
        _pendingEvents.removeAt(0);
        _logger.info(
          'Channel event pushed to Claude (${event.content.length} chars, '
          'route=${event.route ?? "-"}, vm_uri=${event.vmUri != null ? "set" : "-"})',
        );
      }
    } finally {
      _draining = false;
    }
  }
}

/// A channel event awaiting (or retrying) delivery to the Claude session.
class _PendingEvent {
  _PendingEvent({required this.content, this.vmUri, this.route});

  final String content;
  final String? vmUri;
  final String? route;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Future<int> main(List<String> arguments) async {
  final argParser = _buildParser();
  try {
    final results = argParser.parse(arguments);

    if (results.flag('help')) {
      _printUsage(argParser);
      return 0;
    }
    if (results.flag('version')) {
      stderr.writeln('flan_channel version: $version');
      return 0;
    }

    final levelName = (results.option('log-level') ?? 'INFO').toUpperCase();
    final logFile = results.option('log-file');
    final listenPort =
        int.tryParse(results.option('listen-port') ?? '4051') ?? 4051;
    _setupLogging(levelName, logFile);

    final logger = logging.Logger('main');

    // Build MCP server with the channel capability so Claude Code treats
    // this as a channel source.
    final server = McpServer(
      const Implementation(name: 'flan-channel', version: version),
      options: McpServerOptions(
        capabilities: ServerCapabilities(
          experimental: const {'claude/channel': <String, dynamic>{}},
        ),
        instructions:
            'Flan channel: delivers queued Flutter app user messages directly '
            'into this Claude Code session. When you receive a <channel> event '
            'from flan-channel, the content IS the user message(s) including '
            'context (current route, inspector selection, annotations). Act on '
            'the message content directly. The <channel> element may carry a '
            'route="..." attribute (the deep-link URL or current route name '
            'when no widget was picked) — treat that as the user\'s "this" '
            'referent unless the body specifies otherwise. If a vm_uri '
            'attribute is present and you are not already connected, use the '
            'flan connect tool first. If the message mentions attached '
            'images, call get_flushed_images to retrieve them.',
      ),
    );

    final channel = FlanChannel(
      mcpServer: server,
      listenPort: listenPort,
    );

    // Register tools before connecting (capabilities cannot be added after).
    channel.registerTools();

    // When the client finishes initializing, replay any flush events that
    // queued up before the session was ready — otherwise an early flush (or
    // one during a reconnect) would be silently dropped and the user would
    // have to retype it.
    final priorOnInitialized = server.server.oninitialized;
    server.server.oninitialized = () {
      priorOnInitialized?.call();
      unawaited(channel.replayPending());
    };

    // Connect the MCP server to stdio first (Claude Code reads from here).
    final transport = CopilotCompatStdioServerTransport();
    try {
      await server.connect(transport);
      logger.info('flan-channel MCP server connected (stdio)');
    } catch (e, st) {
      logger.severe('Failed to connect stdio transport', e, st);
      return 1;
    }

    // Start the local HTTP listener for TUI flush events.
    try {
      await channel.start();
    } catch (e, st) {
      logger.severe('Failed to start flush listener on port $listenPort: $e\n$st');
      return 1;
    }

    // Wait for shutdown.
    final stdinClosed = Completer<void>();
    final originalOnClose = transport.onclose;
    transport.onclose = () {
      originalOnClose?.call();
      if (!stdinClosed.isCompleted) stdinClosed.complete();
    };

    final exitSignal = _ExitSignal();
    await Future.any([
      exitSignal.wait.then((sig) => logger.info('Received ${sig.name}, stopping')),
      stdinClosed.future.then((_) => logger.info('MCP client disconnected, stopping')),
    ]);

    await channel.close();
    await server.close();
    await transport.close();
    logger.info('flan-channel stopped');
    return 0;
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln();
    _printUsage(argParser);
    return 1;
  } on Exception catch (e) {
    stderr.writeln(e.toString());
    return 1;
  }
}

class _ExitSignal {
  _ExitSignal() {
    if (!Platform.isWindows) {
      _sigterm = ProcessSignal.sigterm.watch().listen(_handle);
    }
    _sigint = ProcessSignal.sigint.watch().listen(_handle);
  }

  final _c = Completer<ProcessSignal>();
  StreamSubscription<ProcessSignal>? _sigterm;
  late final StreamSubscription<ProcessSignal> _sigint;

  Future<ProcessSignal> get wait => _c.future;

  void _handle(ProcessSignal sig) {
    if (!_c.isCompleted) {
      _c.complete(sig);
      _sigterm?.cancel();
      _sigint.cancel();
    }
  }
}
