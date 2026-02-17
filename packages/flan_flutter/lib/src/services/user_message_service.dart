import 'dart:developer' as developer;
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service that queues messages from the user in the Flutter app
/// to be sent to the LLM agent via the MCP server.
class UserMessageService extends ChangeNotifier {
  static const String userMessageQueuedEventKind = 'flan.userMessageQueued';
  static const String _pendingMessagesStorageKey =
      'flan.pending_user_messages.v1';
  static const String _nextQueueIdStorageKey = 'flan.pending_queue_next_id.v1';

  final List<Map<String, dynamic>> _pendingMessages = [];
  int _nextQueueId = 1;
  Future<void>? _hydrationFuture;
  bool _isPersisting = false;
  bool _persistRequested = false;

  bool _isAgentListening = false;
  bool _waitingForActivity = false;
  String? _sentMessageText;
  Timer? _heartbeatTimer;

  /// How long to wait without a heartbeat before considering the agent
  /// disconnected.
  static const _heartbeatTimeout = Duration(seconds: 5);

  /// Whether there are pending messages to deliver.
  bool get hasPendingMessages => _pendingMessages.isNotEmpty;

  /// Number of pending messages in the queue.
  int get pendingMessageCount => _pendingMessages.length;

  /// Whether the agent is actively waiting for user messages.
  /// Automatically expires if no heartbeat is received within
  /// [_heartbeatTimeout].
  bool get isAgentListening => _isAgentListening;

  set isAgentListening(bool value) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    if (value) {
      // Start a heartbeat timeout — if the agent doesn't re-signal within
      // the timeout, assume it disconnected (e.g. tool call was cancelled).
      _heartbeatTimer = Timer(_heartbeatTimeout, () {
        if (_isAgentListening) {
          _isAgentListening = false;
          // Also clear waiting state — agent is gone, no activity coming
          _waitingForActivity = false;
          _sentMessageText = null;
          notifyListeners();
        }
      });
    }

    if (_isAgentListening != value) {
      _isAgentListening = value;
      notifyListeners();
    }
  }

  /// Whether the overlay should show a "waiting for agent" state
  /// after sending a message.
  bool get waitingForActivity => _waitingForActivity;

  /// The text of the message that was sent, shown while waiting.
  String? get sentMessageText => _sentMessageText;

  /// Marks the overlay as waiting for agent activity (e.g. hot reload).
  void markWaiting(String messageText) {
    _sentMessageText = messageText;
    _waitingForActivity = true;
    notifyListeners();
  }

  /// Clears the waiting state (called on hot reload).
  void clearWaiting() {
    if (_waitingForActivity) {
      _waitingForActivity = false;
      _sentMessageText = null;
      notifyListeners();
    }
  }

  /// Starts asynchronous hydration of persisted queue state.
  /// Safe to call multiple times.
  void warmUp() {
    unawaited(ensureHydrated());
  }

  /// Ensures pending queue state is restored from persistent storage.
  Future<void> ensureHydrated() {
    return _hydrationFuture ??= _hydrateFromStorage();
  }

  /// Enqueues a message to be sent to the agent.
  void sendMessage(Map<String, dynamic> message) {
    warmUp();
    final timestamp = DateTime.now().toIso8601String();
    _pendingMessages.add({
      'queueId': _nextQueueId++,
      ...message,
      'timestamp': timestamp,
    });

    // Signal MCP bridge listeners over the VM extension stream.
    developer.postEvent(userMessageQueuedEventKind, {
      'pendingCount': _pendingMessages.length,
      'timestamp': timestamp,
    });

    unawaited(_persistQueueState());
    notifyListeners();
  }

  /// Returns all pending messages and clears the queue.
  List<Map<String, dynamic>> consumeMessages() {
    warmUp();
    if (_pendingMessages.isEmpty) return [];
    final messages = List<Map<String, dynamic>>.from(_pendingMessages);
    _pendingMessages.clear();
    unawaited(_persistQueueState());
    notifyListeners();
    return messages;
  }

  /// Returns pending messages without clearing.
  List<Map<String, dynamic>> peekMessages() {
    warmUp();
    return List.unmodifiable(
      _pendingMessages.map((m) => Map<String, dynamic>.from(m)),
    );
  }

  /// Removes a single queued message by queue id.
  /// Returns true if a message was found and removed.
  bool removeMessageByQueueId(int queueId) {
    warmUp();
    final index = _pendingMessages.indexWhere((m) => m['queueId'] == queueId);
    if (index == -1) return false;
    _pendingMessages.removeAt(index);
    unawaited(_persistQueueState());
    notifyListeners();
    return true;
  }

  /// Clears all queued pending messages.
  void clearMessages() {
    warmUp();
    if (_pendingMessages.isEmpty) return;
    _pendingMessages.clear();
    unawaited(_persistQueueState());
    notifyListeners();
  }

  Future<void> _hydrateFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawMessages = prefs.getString(_pendingMessagesStorageKey);
      final persistedQueue = _decodePersistedMessages(rawMessages);
      final persistedNextId = prefs.getInt(_nextQueueIdStorageKey) ??
          _inferNextQueueId(persistedQueue);

      if (persistedQueue.isEmpty) {
        if (_nextQueueId < persistedNextId) {
          _nextQueueId = persistedNextId;
        }
        return;
      }

      final merged = <Map<String, dynamic>>[];
      final seen = <String>{};

      for (final msg in persistedQueue) {
        final id = _messageIdentity(msg);
        if (seen.add(id)) merged.add(msg);
      }
      for (final msg in _pendingMessages) {
        final id = _messageIdentity(msg);
        if (seen.add(id)) merged.add(Map<String, dynamic>.from(msg));
      }

      _pendingMessages
        ..clear()
        ..addAll(merged);

      final inferredNextId = _inferNextQueueId(_pendingMessages);
      _nextQueueId = _max3(_nextQueueId, persistedNextId, inferredNextId);
      notifyListeners();
      unawaited(_persistQueueState());
    } catch (_) {
      // Best-effort hydration: keep in-memory queue if persistence fails.
    }
  }

  List<Map<String, dynamic>> _decodePersistedMessages(String? rawMessages) {
    if (rawMessages == null || rawMessages.isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(rawMessages);
      if (decoded is! List) return const [];

      final out = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is Map) {
          final normalized = Map<String, dynamic>.from(item);
          final queueId = normalized['queueId'];
          if (queueId is String) {
            final parsed = int.tryParse(queueId);
            if (parsed != null) {
              normalized['queueId'] = parsed;
            }
          }
          out.add(normalized);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistQueueState() async {
    if (_isPersisting) {
      _persistRequested = true;
      return;
    }

    _isPersisting = true;
    try {
      do {
        _persistRequested = false;
        final queueSnapshot = _pendingMessages
            .map((m) => Map<String, dynamic>.from(m))
            .toList(growable: false);
        final nextQueueId = _nextQueueId;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _pendingMessagesStorageKey,
          jsonEncode(queueSnapshot),
        );
        await prefs.setInt(_nextQueueIdStorageKey, nextQueueId);
      } while (_persistRequested);
    } catch (_) {
      // Best-effort persistence: keep in-memory queue if persistence fails.
    } finally {
      _isPersisting = false;
    }
  }

  int _inferNextQueueId(List<Map<String, dynamic>> messages) {
    var maxQueueId = 0;
    for (final message in messages) {
      final queueId = message['queueId'];
      if (queueId is int && queueId > maxQueueId) {
        maxQueueId = queueId;
      } else if (queueId is String) {
        final parsed = int.tryParse(queueId);
        if (parsed != null && parsed > maxQueueId) {
          maxQueueId = parsed;
        }
      }
    }
    return maxQueueId + 1;
  }

  int _max3(int a, int b, int c) {
    if (a >= b && a >= c) return a;
    if (b >= a && b >= c) return b;
    return c;
  }

  String _messageIdentity(Map<String, dynamic> message) {
    final queueId = message['queueId']?.toString();
    if (queueId != null && queueId.isNotEmpty) {
      return 'id:$queueId';
    }
    final timestamp = message['timestamp']?.toString() ?? '';
    final type = message['type']?.toString() ?? '';
    final text = message['text']?.toString() ?? '';
    return '$timestamp|$type|$text';
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }
}
