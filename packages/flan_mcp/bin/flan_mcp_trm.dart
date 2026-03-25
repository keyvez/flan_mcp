/// Entry point for flan_mcp with trm Text Tap integration.
///
/// Wraps the standard flan_mcp server but additionally creates a
/// [TrmPaneBridge] that auto-sends `process_queue` to the Claude Code
/// pane in trm whenever a user message is queued from the Flutter app.
///
/// Usage:
///   dart run packages/flan_mcp/bin/flan_mcp_trm.dart [options]
///
/// Accepts the same CLI options as flan_mcp.dart (--help, --version,
/// --log-level, --log-file, --sse-port).
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:logging/logging.dart' as logging;
import 'package:flan_mcp/src/cmux_pane_bridge.dart';
import 'package:flan_mcp/src/compat/copilot_stdio_server_transport.dart';
import 'package:flan_mcp/src/trm_pane_bridge.dart';
import 'package:flan_mcp/src/version.g.dart';
import 'package:flan_mcp/src/vm_service/vm_service_context.dart';
import 'package:flan_mcp/src/vm_service/vm_service_discovery.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

ArgParser buildParser() {
  return ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addFlag('version', negatable: false, help: 'Print the tool version.')
    ..addOption(
      'log-level',
      abbr: 'l',
      defaultsTo: 'INFO',
      help: 'Log level (FINEST, FINER, FINE, CONFIG, INFO, WARNING, SEVERE).',
    )
    ..addOption(
      'log-file',
      help: 'Path to log file. If not set, logs to stderr.',
    )
    ..addOption(
      'sse-port',
      help: 'Port for SSE server. If not set, uses stdio transport.',
    )
    ..addOption(
      'trm-socket',
      help: 'Path to trm Text Tap socket. Defaults to \$TRM_SOCKET_PATH or /tmp/trm.sock.',
    );
}

void printUsage(ArgParser argParser) {
  stderr
    ..writeln('Flan MCP Server (trm integration) - Flutter app interaction for AI agents')
    ..writeln()
    ..writeln('Usage: flan_mcp_trm [options]')
    ..writeln()
    ..writeln('Options:')
    ..writeln(argParser.usage);
}

Future<int> main(List<String> arguments) async {
  final argParser = buildParser();
  try {
    final results = argParser.parse(arguments);

    if (results.flag('help')) {
      printUsage(argParser);
      return 0;
    }
    if (results.flag('version')) {
      stderr.writeln('flan_mcp (trm) version: $version');
      return 0;
    }

    final logLevelName = (results.option('log-level') ?? 'INFO').toUpperCase();
    final logFile = results.option('log-file');
    final ssePortStr = results.option('sse-port');
    final ssePort = ssePortStr != null ? int.tryParse(ssePortStr) : null;
    final trmSocket = results.option('trm-socket');

    setupLogging(logLevelName, logFile);

    final logger = logging.Logger('main');

    // --- Set up TrmPaneBridge ---
    final bridge = TrmPaneBridge(socketPath: trmSocket);
    try {
      await bridge.connect();
      logger.info('Connected to trm Text Tap socket');
    } catch (err) {
      logger.warning(
        'Could not connect to trm socket (will retry on first send): $err',
      );
    }

    // --- Best-effort cmux bridge ---
    // Always create the bridge — it uses the flan server HTTP endpoint first
    // regardless of whether the cmux socket is reachable. Only discard it if
    // even the flan server is unreachable (handled inside sendProcessQueue).
    final cmuxBridge = CmuxPaneBridge();
    try {
      await cmuxBridge.connect();
      logger.info('Connected to cmux socket');
    } catch (err) {
      logger.warning('cmux socket not available (will use flan server only): $err');
    }

    // --- Set up VmServiceContext (same as flan_mcp.dart) ---
    final vmService = VmServiceContext();

    // Mark the pane as connected when the Flutter app actually connects.
    vmService.connector.onConnect = () {
      unawaited(() async {
        try {
          await bridge.markConnected();
          logger.info('Marked pane as connected in trm');
        } catch (err) {
          logger.fine('TrmPaneBridge markConnected failed: $err');
        }
      }());
    };

    final server = McpServer(
      const Implementation(name: 'flan-mcp', version: version),
      options: McpServerOptions(
        capabilities: ServerCapabilities(
          tools: const ServerCapabilitiesTools(),
          resources: const ServerCapabilitiesResources(
            subscribe: true,
            listChanged: true,
          ),
          logging: const <String, dynamic>{},
        ),
        instructions: '''
Flan MCP enables AI agents to interact with Flutter apps running in debug mode. It provides tools to inspect UI elements, tap buttons, enter text, scroll, take screenshots, retrieve logs, and perform hot reloads.

Usage:
1. Start the Flutter app in debug mode and note the VM service URI (e.g., ws://127.0.0.1:8181/ws).
2. Use the "connect" tool with the VM service URI to establish a connection.
3. Use "get_interactive_elements" to discover available UI elements.
4. Interact with elements using "tap", "enter_text", or "scroll_to" tools.
5. Use "take_screenshots" to see the current app state and "get_logs" to debug issues.
6. Use "hot_reload" after making code changes to reload the app without losing state.

Important: Elements are matched by their key (ValueKey<String>) or text content. Keys are more reliable. If you cannot locate a widget, you may need to add a ValueKey to it in the Flutter source code. For example: `ElevatedButton(key: ValueKey('submit_button'), ...)`.
''',
      ),
    );

    vmService.registerTools(server);

    // --- Auto-discover Flutter app and listen for flush events ---
    // This is a lightweight event-only connection, independent of the
    // flan tool connection. It listens for userMessageQueued events
    // and triggers the cmux bridge to send the process queue command.
    unawaited(() async {
      try {
        final uris = await discoverVmServiceUris();
        if (uris.isEmpty) {
          logger.info('No Flutter apps discovered for event listener');
          return;
        }
        final uri = uris.first;
        logger.info('Connecting event listener to $uri');
        final eventService = await vmServiceConnectUri(uri);
        eventService.onExtensionEvent.listen((e) {
          if (e.kind == EventKind.kExtension &&
              e.extensionKind == 'flan.userMessageQueued') {
            logger.info('Flush event received, triggering cmux bridge');
            unawaited(() async {
              try {
                await cmuxBridge.sendProcessQueue(uri);
              } catch (err) {
                logger.warning('CmuxPaneBridge send failed: $err');
              }
            }());
          }
        });
        await eventService.streamListen(EventStreams.kExtension);
        logger.info('Event listener active on $uri');

        // Reconnect if connection drops.
        eventService.onDone.then((_) {
          logger.info('Event listener connection lost');
        });
      } catch (err) {
        logger.fine('Event listener setup failed: $err');
      }
    }());

    if (ssePort != null) {
      return await runSseServer(server, ssePort, bridge, cmuxBridge);
    } else {
      return await runStdioServer(server, bridge, cmuxBridge);
    }
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln();
    printUsage(argParser);
    return 1;
  } on Exception catch (e) {
    stderr.writeln(e.toString());
    return 1;
  }
}

void setupLogging(String logLevelName, String? logFile) {
  final logLevel = logging.Level.LEVELS.firstWhere(
    (e) => e.name == logLevelName,
    orElse: () => logging.Level.INFO,
  );

  logging.Logger.root.level = logLevel;

  if (logFile != null) {
    final file = File(logFile)..createSync(recursive: true);
    logging.Logger.root.onRecord.listen((record) {
      file.writeAsStringSync(
        '[${record.level.name}][${record.loggerName}][${_formatTime(record.time)}] ${record.message}\n',
        mode: FileMode.append,
      );
    });
  } else {
    logging.Logger.root.onRecord.listen((record) {
      stderr.writeln(
        '[${record.level.name}][${record.loggerName}][${_formatTime(record.time)}] ${record.message}',
      );
    });
  }
}

String _formatTime(DateTime time) {
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}

Future<int> runStdioServer(
    McpServer server, TrmPaneBridge bridge, CmuxPaneBridge cmuxBridge) async {
  final logger = logging.Logger('main');

  final transport = CopilotCompatStdioServerTransport();

  try {
    logger.fine('Running MCP server on stdio');
    await server.connect(transport);
    logger.info('Server started (trm integration active)');
  } catch (e, st) {
    logger.severe('Error when starting the Stdio transport', e, st);
    return 1;
  }

  // Wait for either a signal (SIGTERM/SIGINT) or stdin EOF (client disconnect).
  final stdinClosed = Completer<void>();
  final originalOnClose = transport.onclose;
  transport.onclose = () {
    originalOnClose?.call();
    if (!stdinClosed.isCompleted) stdinClosed.complete();
  };

  final exitSignal = _ExitSignal();
  await Future.any([
    exitSignal.wait.then((signal) {
      logger.info('Received ${signal.name}, stopping');
    }),
    stdinClosed.future.then((_) {
      logger.info('MCP client disconnected (stdin closed), stopping');
    }),
  ]);

  await bridge.close();
  await cmuxBridge.close();
  await server.close();
  await transport.close();
  logger.info('Stopped');
  return 0;
}

Future<int> runSseServer(
  McpServer server,
  int ssePort,
  TrmPaneBridge bridge,
  CmuxPaneBridge cmuxBridge,
) async {
  final logger = logging.Logger('main');
  final sseServerManager = SseServerManager(server);
  try {
    final httpServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      ssePort,
    );
    logger.fine('Running MCP server on SSE port $ssePort');
    unawaited(
      _ExitSignal().wait.then((signal) {
        logger.info('Received ${signal.name}, stopping');
        unawaited(httpServer.close());
      }),
    );

    await for (final request in httpServer) {
      unawaited(sseServerManager.handleRequest(request));
    }

    logger.info('Stopping');
    await bridge.close();
    await cmuxBridge.close();
    await server.close();
  } catch (e, st) {
    logger.severe('Error when waiting for MCP client connection', e, st);
    return 1;
  }

  logger.info('Stopped');
  return 0;
}

class _ExitSignal {
  _ExitSignal() {
    if (!Platform.isWindows) {
      _sigtermSubscription = ProcessSignal.sigterm.watch().listen(
        _handleSignal,
      );
    }
    _sigintSubscription = ProcessSignal.sigint.watch().listen(_handleSignal);
  }

  final _completer = Completer<ProcessSignal>();
  StreamSubscription<ProcessSignal>? _sigtermSubscription;
  late final StreamSubscription<ProcessSignal> _sigintSubscription;

  Future<ProcessSignal> get wait => _completer.future;

  void _handleSignal(ProcessSignal signal) {
    if (!_completer.isCompleted) {
      _completer.complete(signal);
      _cleanup();
    }
  }

  void _cleanup() {
    _sigtermSubscription?.cancel();
    _sigintSubscription.cancel();
  }
}
