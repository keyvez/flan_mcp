import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

/// Connects to cmux's JSON-RPC Unix socket and sends
/// `flan connect to <uri> and process queue once connected`
/// to a Claude Code surface in the same project.
///
/// At startup, captures our own surface via `system.identify`.
/// At send time, finds Claude Code surfaces whose claude process has a
/// matching cwd (same directory or ancestor/descendant).
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

  static const _debounceDuration = Duration(seconds: 2);
  DateTime? _lastSendTime;
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

  Future<void> sendProcessQueue(String? vmServiceUri) async {
    final now = DateTime.now();
    if (_lastSendTime != null &&
        now.difference(_lastSendTime!) < _debounceDuration) {
      _logger.fine('Debouncing send (too soon after last send)');
      return;
    }

    try {
      if (!_connected) await connect();

      final targetId = await _findTargetSurface();
      if (targetId == null) {
        _logger.warning('No target surface found');
        return;
      }

      _lastSendTime = now;

      final text = vmServiceUri != null
          ? 'flan connect to $vmServiceUri and process queue once connected'
          : 'process queue';

      final textResp = await _sendRpc('surface.send_text', {
        'surface_id': targetId,
        'text': text,
      });

      if (textResp?['ok'] == true) {
        final nlResp = await _sendRpc('surface.send_text', {
          'surface_id': targetId,
          'text': '\n',
        });
        if (nlResp?['ok'] == true) {
          _logger.info('Sent to surface $targetId');
        }
      } else {
        _logger.warning('Failed to send to surface $targetId');
      }
    } catch (err) {
      _logger.warning('Error sending to cmux: $err');
      _connected = false;
    }
  }

  /// Find target surface: a Claude Code surface (not ours) that has a
  /// sibling claude process with a matching cwd.
  Future<String?> _findTargetSurface() async {
    final ownCwd = Directory.current.path;

    // Get all Claude Code surfaces.
    final resp = await _sendRpc('surface.list', {});
    final surfaces = resp?['result']?['surfaces'] as List<dynamic>? ?? [];

    final ccSurfaces = <String>[];
    for (final s in surfaces) {
      final title = s['title'] as String? ?? '';
      final id = s['id'] as String?;
      if (id != null && title.contains('Claude Code') && id != _ownSurfaceId) {
        ccSurfaces.add(id);
      }
    }

    if (ccSurfaces.isEmpty) {
      _logger.fine('No other Claude Code surfaces found');
      return null;
    }

    // Find claude processes with matching cwds (excluding our ancestor).
    final ownClaudePid = await _findAncestorClaudePid(pid);
    final matchingClaudePids = <int>[];

    final psResult = await Process.run('ps', ['-eo', 'pid=,tty=,comm=']);
    for (final line in psResult.stdout.toString().trim().split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 3) continue;
      final p = int.tryParse(parts[0]);
      final comm = parts.sublist(2).join(' ');
      if (p == null || !comm.contains('claude') || p == ownClaudePid) continue;

      final cwd = await _getCwd(p);
      if (cwd == null) continue;
      if (cwd == ownCwd ||
          ownCwd.startsWith('$cwd/') ||
          cwd.startsWith('$ownCwd/')) {
        matchingClaudePids.add(p);
      }
    }

    if (matchingClaudePids.isEmpty) {
      _logger.fine('No claude processes with matching cwd');
      return null;
    }

    _logger.info(
      'Found ${matchingClaudePids.length} matching claude(s), '
      '${ccSurfaces.length} candidate surface(s). '
      'Sending to ${ccSurfaces.first}',
    );

    // We know there are matching claude processes and available surfaces.
    // Send to the first non-own Claude Code surface.
    return ccSurfaces.first;
  }

  Future<int?> _findAncestorClaudePid(int startPid) async {
    var current = startPid;
    for (var i = 0; i < 15; i++) {
      final result =
          await Process.run('ps', ['-o', 'ppid=', '-p', '$current']);
      final ppid = int.tryParse(result.stdout.toString().trim());
      if (ppid == null || ppid <= 1) break;

      final info = await Process.run('ps', ['-o', 'comm=', '-p', '$ppid']);
      if (info.stdout.toString().trim().contains('claude')) return ppid;
      current = ppid;
    }
    return null;
  }

  Future<String?> _getCwd(int processPid) async {
    try {
      final result = await Process.run(
        'lsof', ['-d', 'cwd', '-Fn', '-p', '$processPid'],
      );
      for (final line in result.stdout.toString().trim().split('\n')) {
        if (line.startsWith('n/')) return line.substring(1);
      }
    } catch (_) {}
    return null;
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
