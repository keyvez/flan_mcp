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

  final _logger = logging.Logger('FlanChannel');
  HttpServer? _httpServer;

  /// Images (screenshots, drawings) buffered from the last flush, available
  /// for retrieval via the `get_flushed_images` tool.
  final List<Map<String, dynamic>> _pendingImages = [];

  Future<void> start() async {
    _httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, listenPort);
    _logger.info('Listening for flush events on http://127.0.0.1:$listenPort');
    unawaited(_serveRequests());
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
      await _pushToClaudeSession(content: content, vmUri: vmUri);

      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true}));
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
        // Current route / URL
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

  Future<void> _pushToClaudeSession({
    required String content,
    String? vmUri,
  }) async {
    if (!mcpServer.isConnected) {
      _logger.warning('MCP server not connected, cannot push channel event');
      return;
    }

    final meta = <String, String>{
      if (vmUri != null) 'vm_uri': vmUri,
    };

    await mcpServer.server.notification(
      JsonRpcNotification(
        method: 'notifications/claude/channel',
        params: {
          'content': content,
          if (meta.isNotEmpty) 'meta': meta,
        },
      ),
    );

    _logger.info('Channel event pushed to Claude (${content.length} chars)');
  }
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
            'the message content directly. If a vm_uri attribute is present '
            'and you are not already connected, use the flan connect tool '
            'first. If the message mentions attached images, call '
            'get_flushed_images to retrieve them.',
      ),
    );

    final channel = FlanChannel(
      mcpServer: server,
      listenPort: listenPort,
    );

    // Register tools before connecting (capabilities cannot be added after).
    channel.registerTools();

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
