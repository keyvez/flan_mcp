import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

/// Connects to trm's Text Tap Unix socket and sends input to the pane
/// running Claude Code.
///
/// This is a standalone connector — it does not modify trm or flan_mcp core.
/// Usage:
/// ```dart
/// final bridge = TrmPaneBridge();
/// await bridge.connect();
/// await bridge.sendProcessQueue();
/// ```
class TrmPaneBridge {
  TrmPaneBridge({String? socketPath})
      : _socketPath = socketPath ??
            Platform.environment['TRM_SOCKET_PATH'] ??
            _detectSocketPath(),
        _logger = logging.Logger('TrmPaneBridge');

  final String _socketPath;
  final logging.Logger _logger;

  /// Prefer release socket over debug — stale debug socket files are common.
  static String _detectSocketPath() {
    const candidates = ['/tmp/trm.sock', '/tmp/trm-debug.sock'];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return '/tmp/trm.sock';
  }

  Socket? _socket;
  StreamSubscription<List<int>>? _subscription;
  int? _cachedClaudePane;
  DateTime? _lastDetectionTime;

  /// How long to cache the detected pane index before re-detecting.
  static const _detectionCacheDuration = Duration(minutes: 5);

  /// Debounce window: ignore rapid-fire sends within this duration.
  static const _debounceDuration = Duration(milliseconds: 500);

  DateTime? _lastSendTime;

  // Buffer for incoming data (newline-delimited JSON).
  final _incomingBuffer = StringBuffer();

  // Queue of received complete JSON lines, consumed by _recvMsg.
  final _receivedLines = <String>[];

  // Completer waiting for the next line (set by _recvMsg when queue is empty).
  Completer<String?>? _lineWaiter;

  /// Connect to the trm Text Tap socket.
  ///
  /// Tries the detected socket path first. If that fails, tries the other
  /// candidate socket before giving up. This handles stale socket files left
  /// over from previous debug builds.
  Future<void> connect() async {
    if (_socket != null) return;

    // Try primary socket path.
    try {
      await _connectToSocket(_socketPath);
      return;
    } catch (e) {
      _logger.fine('Primary socket $_socketPath failed: $e');
    }

    // Try fallback candidates.
    const candidates = ['/tmp/trm.sock', '/tmp/trm-debug.sock'];
    for (final candidate in candidates) {
      if (candidate == _socketPath) continue;
      if (!await File(candidate).exists()) continue;
      try {
        await _connectToSocket(candidate);
        _logger.info('Connected to fallback socket $candidate');
        return;
      } catch (e) {
        _logger.fine('Fallback socket $candidate failed: $e');
      }
    }

    throw SocketException('No working trm socket found');
  }

  /// Low-level connection to a specific socket path.
  Future<void> _connectToSocket(String path) async {
    if (!await File(path).exists()) {
      throw SocketException('trm socket not found at $path');
    }

    _logger.info('Connecting to trm socket at $path');
    _socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );

    // Single subscription that feeds all incoming data into a line buffer.
    _subscription = _socket!.listen(
      (data) {
        _incomingBuffer.write(utf8.decode(data));
        _drainLines();
      },
      onError: (Object err) {
        _logger.warning('trm socket error: $err');
        _completeWaiter(null);
        _disconnect();
      },
      onDone: () {
        _logger.info('trm socket closed');
        _completeWaiter(null);
        _disconnect();
      },
    );
  }

  /// Explicitly mark our pane as connected. Call this when the MCP client
  /// (e.g. Claude Code) has actually connected to the server.
  Future<void> markConnected() async {
    try {
      await _ensureConnected();
      await _detectClaudePane();
    } catch (err) {
      _logger.fine('markConnected failed: $err');
    }
  }

  /// Extract complete newline-delimited lines from the buffer and either
  /// deliver them to a waiting _recvMsg or queue them.
  void _drainLines() {
    final content = _incomingBuffer.toString();
    if (!content.contains('\n')) return;

    final parts = content.split('\n');
    // The last element is the incomplete tail (possibly empty).
    _incomingBuffer.clear();
    _incomingBuffer.write(parts.last);

    for (var i = 0; i < parts.length - 1; i++) {
      final line = parts[i].trim();
      if (line.isEmpty) continue;

      if (_lineWaiter != null && !_lineWaiter!.isCompleted) {
        _lineWaiter!.complete(line);
        _lineWaiter = null;
      } else {
        _receivedLines.add(line);
      }
    }
  }

  void _completeWaiter(String? value) {
    if (_lineWaiter != null && !_lineWaiter!.isCompleted) {
      _lineWaiter!.complete(value);
      _lineWaiter = null;
    }
  }

  void _disconnect() {
    // Notify trm that we're disconnecting from the pane (clears the
    // "connected" indicator pill). Best-effort — the socket may already
    // be dead.
    if (_socket != null && _cachedClaudePane != null) {
      try {
        final msg =
            '${jsonEncode({"type": "mark_disconnected", "pane": _cachedClaudePane})}\n';
        _socket!.add(utf8.encode(msg));
      } catch (_) {
        // Ignore — the server will auto-clear on socket close anyway.
      }
    }
    _subscription?.cancel();
    _subscription = null;
    _socket?.destroy();
    _socket = null;
    _cachedClaudePane = null;
    _lastDetectionTime = null;
    _incomingBuffer.clear();
    _receivedLines.clear();
  }

  /// Disconnect from the trm socket.
  Future<void> close() async {
    _disconnect();
  }

  bool get isConnected => _socket != null;

  /// Send `process_queue\r` to the detected Claude pane.
  ///
  /// Debounces rapid calls. Silently returns if not connected or no
  /// claude pane is found.
  Future<void> sendProcessQueue() async {
    await _sendInput('process_queue');
  }

  /// Send arbitrary text + CR to the Claude pane.
  Future<void> _sendInput(String text) async {
    // Debounce
    final now = DateTime.now();
    if (_lastSendTime != null &&
        now.difference(_lastSendTime!) < _debounceDuration) {
      _logger.fine('Debouncing send (too soon after last send)');
      return;
    }

    try {
      await _ensureConnected();

      final pane = await _detectClaudePane();
      if (pane == null) {
        _logger.warning('No Claude pane detected, cannot send input');
        return;
      }

      _lastSendTime = now;
      await _sendMsg({'type': 'send', 'pane': pane, 'text': '$text\r'});
      final resp = await _recvMsg();

      if (resp?['status'] == 'queued') {
        _logger.info('Sent "$text" to trm pane $pane');
      } else {
        _logger.warning('Failed to send to pane $pane: $resp');
        // Invalidate cache so we re-detect next time.
        _cachedClaudePane = null;
        _lastDetectionTime = null;
      }
    } catch (err) {
      _logger.warning('Error sending input to trm: $err');
      _disconnect();
    }
  }

  Future<void> _ensureConnected() async {
    if (_socket == null) {
      await connect();
    }
  }

  /// Detect which pane is running Claude Code.
  ///
  /// Walks up our own process tree to find the trm ancestor, then identifies
  /// which of trm's direct children (panes) is our ancestor. This is reliable
  /// because flan_mcp is always launched from within a trm pane.
  Future<int?> _detectClaudePane() async {
    // Return cached value if fresh
    if (_cachedClaudePane != null && _lastDetectionTime != null) {
      if (DateTime.now().difference(_lastDetectionTime!) <
          _detectionCacheDuration) {
        return _cachedClaudePane;
      }
    }

    _logger.fine('Detecting Claude pane...');

    // Get pane count from the socket
    await _sendMsg({'type': 'list_panes'});
    final listResp = await _recvMsg();
    final paneCount = listResp?['pane_count'] as int?;

    if (paneCount == null || paneCount == 0) {
      _logger.warning('No panes found in trm');
      return null;
    }

    // Unsubscribe to prevent content messages
    await _sendMsg({'type': 'unsubscribe'});
    await _recvMsg();

    // Walk up our process tree to find the trm ancestor and which of its
    // children is our ancestor (that child corresponds to our pane).
    int? paneIndex;
    if (paneCount == 1) {
      // Only one pane — no ambiguity, just use pane 0.
      paneIndex = 0;
    } else {
      paneIndex = await _detectOurPane();
    }

    if (paneIndex == null || paneIndex >= paneCount) {
      // Fallback: mark pane 0 (most common case is single-pane).
      _logger.info('Could not detect pane (detected=$paneIndex, count=$paneCount), defaulting to pane 0');
      _cachedClaudePane = 0;
    } else {
      _cachedClaudePane = paneIndex;
    }

    _lastDetectionTime = DateTime.now();
    _logger.info('Detected Claude pane: $_cachedClaudePane');

    // Notify trm that we're connected to this pane so it shows
    // the "connected" indicator pill with our app name.
    await _sendMsg({'type': 'mark_connected', 'pane': _cachedClaudePane, 'app': 'flan'});
    await _recvMsg(); // drain ack

    return _cachedClaudePane;
  }

  /// Walk up the process tree from our PID to find the trm process, then
  /// determine which of trm's children (pane slots) is our ancestor.
  /// Returns the pane index (0-based) or null if detection fails.
  Future<int?> _detectOurPane() async {
    // Collect our ancestor chain: our PID, parent, grandparent, ...
    final ancestors = <int>[];
    var currentPid = pid; // dart:io top-level pid getter
    for (var i = 0; i < 20; i++) {
      // Safety limit
      ancestors.add(currentPid);
      final ppidStr =
          await _runCommand('/bin/ps', ['-p', '$currentPid', '-o', 'ppid=']);
      if (ppidStr == null) break;
      final ppid = int.tryParse(ppidStr.trim());
      if (ppid == null || ppid <= 1) break;
      currentPid = ppid;
    }

    if (ancestors.length < 2) return null;

    // The last PID in the chain (before init) should be trm.
    // Find trm's direct children (one per pane), sorted by PID.
    final trmPid = ancestors.last;
    final childrenStr = await _runCommand('/usr/bin/pgrep', ['-P', '$trmPid']);
    if (childrenStr == null) return null;

    final children = childrenStr
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map((s) => int.tryParse(s))
        .whereType<int>()
        .toList()
      ..sort();

    // Find which child is in our ancestor chain — that's our pane.
    for (var i = 0; i < children.length; i++) {
      if (ancestors.contains(children[i])) {
        return i;
      }
    }

    return null;
  }

  /// Run a command and return stdout, or null on failure.
  Future<String?> _runCommand(String executable, List<String> args) async {
    try {
      final result = await Process.run(executable, args);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // --- Socket I/O ---

  Future<void> _sendMsg(Map<String, dynamic> msg) async {
    final data = '${jsonEncode(msg)}\n';
    _socket!.add(utf8.encode(data));
    await _socket!.flush();
  }

  /// Read one newline-delimited JSON message with a timeout.
  /// Uses the single stream subscription set up in connect().
  Future<Map<String, dynamic>?> _recvMsg() async {
    // Check if we already have a buffered line.
    if (_receivedLines.isNotEmpty) {
      final line = _receivedLines.removeAt(0);
      try {
        return jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }

    // Wait for the next line from the stream with a timeout.
    _lineWaiter = Completer<String?>();
    final timer = Timer(const Duration(seconds: 3), () {
      _completeWaiter(null);
    });

    try {
      final line = await _lineWaiter!.future;
      timer.cancel();
      if (line == null) return null;
      try {
        return jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    } catch (_) {
      timer.cancel();
      return null;
    }
  }
}
