import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

/// Connects to cmux's JSON-RPC Unix socket and identifies our own surface
/// via `system.identify` at startup.
///
/// Message delivery to Claude Code now flows through the flan-channel push
/// path, so this bridge no longer injects text into panes — it remains only
/// for surface identification / connection bookkeeping.
class CmuxPaneBridge {
  CmuxPaneBridge({String? socketPath})
      : _socketPath = socketPath ??
            Platform.environment['CMUX_SOCKET_PATH'] ??
            _detectSocketPath(),
        _logger = logging.Logger('CmuxPaneBridge');

  final String _socketPath;
  final logging.Logger _logger;

  static String _detectSocketPath() {
    const candidates = ['/tmp/cmux.sock', '/tmp/cmux-debug.sock'];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return '/tmp/cmux.sock';
  }

  bool _connected = false;
  String? _ownSurfaceId;

  Future<void> connect() async {
    if (_connected) return;

    if (!await File(_socketPath).exists()) {
      throw SocketException('cmux socket not found at $_socketPath');
    }

    final resp = await _sendRpc('system.ping', {});
    if (resp == null) {
      throw SocketException('cmux socket at $_socketPath not responding');
    }

    final identResp = await _sendRpc('system.identify', {});
    _ownSurfaceId =
        identResp?['result']?['focused']?['surface_id'] as String?;
    _logger.info('Own surface: $_ownSurfaceId');

    _connected = true;
  }

  bool get isConnected => _connected;

  Future<void> close() async {
    _connected = false;
    _ownSurfaceId = null;
  }

  Future<Map<String, dynamic>?> _sendRpc(
      String method, Map<String, dynamic> params) async {
    try {
      final socket = await Socket.connect(
        InternetAddress(_socketPath, type: InternetAddressType.unix),
        0,
      );

      final completer = Completer<String?>();
      final buffer = StringBuffer();

      socket.listen(
        (data) {
          buffer.write(utf8.decode(data));
          final content = buffer.toString();
          if (content.contains('\n')) {
            if (!completer.isCompleted) {
              completer.complete(content.split('\n').first.trim());
            }
          }
        },
        onError: (Object err) {
          if (!completer.isCompleted) completer.complete(null);
        },
        onDone: () {
          if (!completer.isCompleted) {
            final content = buffer.toString().trim();
            completer.complete(content.isNotEmpty ? content : null);
          }
        },
      );

      final request = jsonEncode({
        'id': '${method.hashCode}',
        'method': method,
        'params': params,
      });
      socket.add(utf8.encode('$request\n'));
      await socket.flush();

      final line = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );

      socket.destroy();

      if (line == null || line.isEmpty) return null;
      return jsonDecode(line) as Map<String, dynamic>;
    } catch (err) {
      _logger.fine('cmux RPC $method failed: $err');
      return null;
    }
  }
}
