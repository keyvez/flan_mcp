import 'dart:async';

import 'package:flutter/foundation.dart';

/// Service that queues messages from the user in the Flutter app
/// to be sent to the LLM agent via the MCP server.
class UserMessageService extends ChangeNotifier {
  final List<Map<String, dynamic>> _pendingMessages = [];

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

  /// Enqueues a message to be sent to the agent.
  void sendMessage(Map<String, dynamic> message) {
    _pendingMessages.add({
      ...message,
      'timestamp': DateTime.now().toIso8601String(),
    });
    notifyListeners();
  }

  /// Returns all pending messages and clears the queue.
  List<Map<String, dynamic>> consumeMessages() {
    if (_pendingMessages.isEmpty) return [];
    final messages = List<Map<String, dynamic>>.from(_pendingMessages);
    _pendingMessages.clear();
    return messages;
  }

  /// Returns pending messages without clearing.
  List<Map<String, dynamic>> peekMessages() {
    return List.unmodifiable(
      _pendingMessages.map((m) => Map<String, dynamic>.from(m)),
    );
  }
}
