import 'dart:developer' as developer;
import 'dart:async';
import 'dart:convert';
import 'dart:io' show pid;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flan_flutter/src/services/flan_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service that queues messages from the user in the Flutter app
/// to be sent to the LLM agent via the MCP server.
class UserMessageService extends ChangeNotifier {
  UserMessageService({
    http.Client? httpClient,
    FlanServerClient? serverClient,
    String serverUrl = const String.fromEnvironment('FLAN_SERVER_URL'),
    String appId = const String.fromEnvironment('FLAN_APP_ID'),
    bool pollServer = false,
  }) : _serverClient = serverClient ??
            FlanServerClient(
              serverUrl: serverUrl,
              appId: appId,
              httpClient: httpClient,
            ) {
    if (pollServer) {
      _startServerPolling();
    }
  }

  static const String userMessageQueuedEventKind = 'flan.userMessageQueued';
  static const String _pendingMessagesStorageKey =
      'flan.pending_user_messages.v1';
  static const String _nextQueueIdStorageKey = 'flan.pending_queue_next_id.v1';
  static const String _agentStatusStorageKey = 'flan.agent_status.v1';
  static const String _autoDrainStorageKey = 'flan.auto_drain.v1';
  static const String _sentMessagesStorageKey = 'flan.sent_user_messages.v1';

  /// Status of a sent message ([sentMessages]) while the agent is on it.
  static const String sentWorking = 'working';

  /// The agent finished the turn the message started.
  static const String sentDone = 'done';

  /// Handed over, but nothing can say when the agent finishes — an agent
  /// with no session registry, or a relay too old to ask.
  static const String sentUntracked = 'sent';

  /// The agent exited before finishing.
  static const String sentStopped = 'stopped';

  /// Finished messages kept for the queue's history, newest kept.
  static const int _sentHistoryLimit = 50;
  static const _progressPollInterval = Duration(seconds: 2);

  static const _serverPollInterval = Duration(seconds: 10);

  final FlanServerClient _serverClient;
  final List<Map<String, dynamic>> _pendingMessages = [];

  /// Messages handed to the agent, oldest first. They stay in the queue —
  /// as work in progress, then as history — carrying `status`, `sentAt`,
  /// the `agentTurn` they started and the `agentMessages` the agent has said
  /// while on it.
  final List<Map<String, dynamic>> _sentMessages = [];
  Timer? _progressTimer;
  bool _progressPollInFlight = false;
  int _nextQueueId = 1;

  /// When true, VM service extension events (`postEvent`) are suppressed.
  /// Set this when a flan-channel is handling message delivery so the
  /// flan MCP server doesn't trigger redundant `process_queue` calls.
  bool suppressVmEvents = false;
  Future<void>? _hydrationFuture;
  bool _isPersisting = false;
  bool _persistRequested = false;

  bool _isAgentListening = false;
  bool? _isHostConnected = false;
  bool? _isPushCapableHostConnected = false;
  int _agentConsumeGeneration = 0;
  bool _waitingForActivity = false;
  String? _sentMessageText;
  Timer? _heartbeatTimer;

  bool _isAgentWorking = false;
  String? _agentStatusMessage;
  Timer? _workingTimeoutTimer;
  Timer? _completionClearTimer;

  bool _autoDrain = false;

  bool _hasServerAssociation = false;
  String? _linkedLabel;
  Timer? _serverPollTimer;

  /// Safety timeout: auto-clear working state if the agent never calls
  /// `agent_status` with `done: true`.
  static const _workingTimeout = Duration(minutes: 5);

  /// How long the completion message is shown before auto-clearing.
  static const _completionDisplayDuration = Duration(seconds: 4);

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

  /// Whether the agent is actively working on consumed messages.
  bool get isAgentWorking => _isAgentWorking;

  /// Agent status text — either a streaming status while working, or a brief
  /// completion summary shown temporarily after the agent finishes.
  String? get agentStatusMessage => _agentStatusMessage;

  set isAgentWorking(bool value) {
    _workingTimeoutTimer?.cancel();
    _workingTimeoutTimer = null;

    if (value) {
      // Cancel any lingering done-display timer, but do NOT clear
      // _agentStatusMessage — the agent may have already set it via
      // updateAgentStatus before this setter fires.
      _completionClearTimer?.cancel();
      _completionClearTimer = null;

      _workingTimeoutTimer = Timer(_workingTimeout, () {
        if (_isAgentWorking) {
          _isAgentWorking = false;
          _agentStatusMessage = null;
          _finishUntrackedSent(sentUntracked);
          _persistAgentStatus();
          notifyListeners();
        }
      });
    }

    if (_isAgentWorking != value) {
      _isAgentWorking = value;
      notifyListeners();
    }
  }

  /// Updates the agent status message while the agent is working.
  ///
  /// Sets the working state to true, resets the safety timeout, persists the
  /// status to SharedPreferences, and notifies listeners.
  void updateAgentStatus(String message) {
    _workingTimeoutTimer?.cancel();
    _workingTimeoutTimer = null;
    _completionClearTimer?.cancel();
    _completionClearTimer = null;

    _isAgentWorking = true;
    _agentStatusMessage = message;
    _appendUntrackedProgress(message);

    _workingTimeoutTimer = Timer(_workingTimeout, () {
      if (_isAgentWorking) {
        _isAgentWorking = false;
        _agentStatusMessage = null;
        _finishUntrackedSent(sentUntracked);
        _persistAgentStatus();
        notifyListeners();
      }
    });

    _persistAgentStatus();
    notifyListeners();
  }

  /// Clears the working state and optionally shows a brief completion message.
  void markDone({String? message}) {
    _workingTimeoutTimer?.cancel();
    _workingTimeoutTimer = null;
    _completionClearTimer?.cancel();
    _completionClearTimer = null;

    _isAgentWorking = false;
    if (message != null && message.isNotEmpty) {
      _appendUntrackedProgress(message);
    }
    _finishUntrackedSent(sentDone);

    if (message != null && message.isNotEmpty) {
      _agentStatusMessage = message;
      _completionClearTimer = Timer(_completionDisplayDuration, () {
        _agentStatusMessage = null;
        _persistAgentStatus();
        notifyListeners();
      });
    } else {
      _agentStatusMessage = null;
    }

    _persistAgentStatus();
    notifyListeners();
  }

  /// Whether the queue drains itself one task at a time: send hands the agent
  /// only the oldest message, and each later one goes out when the agent
  /// finishes the one before. Off, send hands over the whole queue as a batch.
  bool get autoDrain => _autoDrain;

  set autoDrain(bool value) {
    warmUp();
    if (_autoDrain == value) return;
    _autoDrain = value;
    unawaited(_persistAutoDrain());
    notifyListeners();
  }

  /// Whether an MCP host is currently connected to Flan.
  bool get isHostConnected => (_isHostConnected ?? false) == true;

  /// Whether the connected host supports Flan push nudges
  /// (notifications and/or sampling).
  bool get isPushCapableHostConnected =>
      (_isPushCapableHostConnected ?? false) == true;

  /// Whether the flan server has an association linking this app to a
  /// Claude Code surface. Associations are created after a flush triggers
  /// Claude Code to connect; this reflects post-connection state, not a
  /// prerequisite for flushing.
  bool get hasServerAssociation => _hasServerAssociation;

  /// Short label identifying the linked Claude surface (e.g. "dev/flan_mcp").
  /// Null when not linked.
  String? get linkedLabel => _linkedLabel;

  /// Monotonic counter incremented whenever queued messages are consumed
  /// through the MCP consume path.
  int get agentConsumeGeneration => _agentConsumeGeneration;

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
          // Clear working state and status — agent heartbeat expired
          _isAgentWorking = false;
          _agentStatusMessage = null;
          _workingTimeoutTimer?.cancel();
          _workingTimeoutTimer = null;
          _completionClearTimer?.cancel();
          _completionClearTimer = null;
          _persistAgentStatus();
          notifyListeners();
        }
      });
    }

    if (_isAgentListening != value) {
      _isAgentListening = value;
      notifyListeners();
    }
  }

  /// Updates connected host state for UI signaling.
  void setHostConnectionState({
    required bool connected,
    required bool pushCapable,
  }) {
    final normalizedPush = connected && pushCapable;
    if (_isHostConnected == connected &&
        _isPushCapableHostConnected == normalizedPush) {
      return;
    }
    _isHostConnected = connected;
    _isPushCapableHostConnected = normalizedPush;
    notifyListeners();
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

  /// The queue id assigned to the most recently enqueued message.
  int get lastQueueId => _nextQueueId - 1;

  /// Enqueues a message to be sent to the agent.
  void sendMessage(Map<String, dynamic> message) {
    warmUp();
    final timestamp = DateTime.now().toIso8601String();
    _pendingMessages.add({
      'queueId': _nextQueueId++,
      ...message,
      'timestamp': timestamp,
    });

    if (!suppressVmEvents) {
      developer.postEvent(userMessageQueuedEventKind, {
        'pendingCount': _pendingMessages.length,
        'timestamp': timestamp,
      });
    }

    unawaited(_persistQueueState());
    notifyListeners();
  }

  /// Returns all pending messages and removes them from the queue.
  List<Map<String, dynamic>> consumeMessages({
    bool markAgentWorking = true,
  }) {
    warmUp();
    if (_pendingMessages.isEmpty) return [];
    final consumed =
        _pendingMessages.map((m) => Map<String, dynamic>.from(m)).toList();
    _pendingMessages.clear();
    // The agent pulled these over MCP and reports progress through
    // agent_status, which [updateAgentStatus] and [markDone] route here.
    _recordSent(consumed, status: sentWorking);
    _agentConsumeGeneration++;
    if (markAgentWorking) {
      isAgentWorking = true;
    }
    unawaited(_persistQueueState());
    notifyListeners();
    return consumed;
  }

  /// Removes and returns the queued messages whose ids are in [queueIds] —
  /// the ones a flush actually handed over, which in auto-drain mode is not
  /// the whole queue.
  ///
  /// They move to [sentMessages]. With the [agentTurn] the flush started they
  /// are followed until the agent finishes it, collecting what it says on
  /// the way; without one nothing can say when it finishes, and they are
  /// kept as merely sent.
  List<Map<String, dynamic>> consumeMessagesById(
    Set<int> queueIds, {
    bool markAgentWorking = true,
    FlanAgentTurn? agentTurn,
  }) {
    warmUp();
    final consumed = _pendingMessages
        .where((m) => queueIds.contains(m['queueId']))
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    if (consumed.isEmpty) return const [];
    _pendingMessages.removeWhere((m) => queueIds.contains(m['queueId']));
    _recordSent(
      consumed,
      status: agentTurn == null ? sentUntracked : sentWorking,
      agentTurn: agentTurn,
    );
    _agentConsumeGeneration++;
    if (markAgentWorking) {
      isAgentWorking = true;
    }
    unawaited(_persistQueueState());
    notifyListeners();
    return consumed;
  }

  /// Returns pending messages without clearing.
  List<Map<String, dynamic>> peekMessages() {
    warmUp();
    return List.unmodifiable(
      _pendingMessages.map((m) => Map<String, dynamic>.from(m)),
    );
  }

  /// Returns pending messages without clearing.
  /// Use this to get an accurate count of what [consumeMessages] would return.
  List<Map<String, dynamic>> peekConsumableMessages() {
    warmUp();
    return peekMessages();
  }

  /// No-op. Retained for API compatibility.
  void promoteDrafts() {}

  /// Messages already handed to the agent, oldest first: the work in
  /// progress (`status` [sentWorking]) and the history after it.
  List<Map<String, dynamic>> get sentMessages {
    warmUp();
    return List.unmodifiable(
      _sentMessages.map((m) => Map<String, dynamic>.from(m)),
    );
  }

  /// Whether the queue holds anything already sent, finished or not.
  bool get hasSentMessages => _sentMessages.isNotEmpty;

  /// Whether any sent message is still being worked on.
  bool get hasWorkingMessages =>
      _sentMessages.any((m) => m['status'] == sentWorking);

  void _recordSent(
    List<Map<String, dynamic>> messages, {
    required String status,
    FlanAgentTurn? agentTurn,
  }) {
    final sentAt = DateTime.now().toIso8601String();
    for (final m in messages) {
      _sentMessages.add({
        ..._withoutFullImages(m),
        'status': status,
        'sentAt': sentAt,
        if (agentTurn != null) 'agentTurn': agentTurn.toJson(),
        'agentMessages': const <Map<String, dynamic>>[],
      });
    }
    _trimSentHistory();
    _syncProgressPolling();
  }

  /// A history entry keeps the cropped thumbnail and drops the full-size
  /// images: the agent already has them, and fifty screenshots in
  /// SharedPreferences is megabytes rewritten on every change.
  static Map<String, dynamic> _withoutFullImages(Map<String, dynamic> m) {
    final data = m['data'];
    if (data is! Map) return m;
    return {
      ...m,
      'data': Map<String, dynamic>.from(data)
        ..remove('screenshot')
        ..remove('drawingImage'),
    };
  }

  /// Drops the oldest finished messages beyond [_sentHistoryLimit]. Work in
  /// progress is never dropped.
  void _trimSentHistory() {
    var excess = _sentMessages.length - _sentHistoryLimit;
    _sentMessages.removeWhere((m) {
      if (excess <= 0 || m['status'] == sentWorking) return false;
      excess--;
      return true;
    });
  }

  static FlanAgentTurn? _turnOf(Map<String, dynamic> message) =>
      FlanAgentTurn.fromJson(message['agentTurn']);

  /// The distinct agent turns sent messages are still waiting on.
  List<FlanAgentTurn> get workingTurns {
    final out = <FlanAgentTurn>[];
    for (final m in _sentMessages) {
      if (m['status'] != sentWorking) continue;
      final turn = _turnOf(m);
      if (turn != null && !out.any(turn.sameAs)) out.add(turn);
    }
    return out;
  }

  /// Folds what the relay said about [turn] into the messages it carries:
  /// what the agent has said so far, and whether it has finished.
  ///
  /// A later send to the same agent starts the next turn, so whatever the
  /// agent said after that is the next message's, not this one's — the
  /// relay answers "everything since", and the cut is made here.
  void recordAgentProgress(FlanAgentTurn turn, FlanAgentTurnState state) {
    int? nextDelivery;
    for (final m in _sentMessages) {
      final other = _turnOf(m);
      if (other == null ||
          other.agentPid != turn.agentPid ||
          other.host != turn.host ||
          other.thread != turn.thread ||
          other.deliveredAtMs <= turn.deliveredAtMs) {
        continue;
      }
      if (nextDelivery == null || other.deliveredAtMs < nextDelivery) {
        nextDelivery = other.deliveredAtMs;
      }
    }
    final said = [
      for (final message in state.messages)
        if (nextDelivery == null || message.atMs < nextDelivery)
          message.toJson(),
    ];
    final status = !state.alive
        ? sentStopped
        : state.finished
            ? sentDone
            : sentWorking;

    var changed = false;
    for (var i = 0; i < _sentMessages.length; i++) {
      final m = _sentMessages[i];
      if (m['status'] != sentWorking) continue;
      final mine = _turnOf(m);
      if (mine == null || !mine.sameAs(turn)) continue;
      final before = m['agentMessages'];
      // A relay too old to read transcripts answers no messages; keep what
      // was already collected rather than wiping it.
      final keep = said.isEmpty && before is List && before.isNotEmpty;
      final sameMessages = keep || jsonEncode(before) == jsonEncode(said);
      if (sameMessages && status == sentWorking) continue;
      _sentMessages[i] = {
        ...m,
        if (!keep) 'agentMessages': said,
        'status': status,
        if (status != sentWorking)
          'completedAt': DateTime.now().toIso8601String(),
      };
      changed = true;
    }
    if (!changed) return;
    _syncProgressPolling();
    unawaited(_persistQueueState());
    notifyListeners();
  }

  /// Progress reported through `agent_status` belongs to the messages the
  /// agent pulled over MCP — the ones no agent turn follows.
  void _appendUntrackedProgress(String text) {
    final at = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (var i = 0; i < _sentMessages.length; i++) {
      final m = _sentMessages[i];
      if (m['status'] != sentWorking || m['agentTurn'] != null) continue;
      final said = [
        for (final e in (m['agentMessages'] as List? ?? const []))
          Map<String, dynamic>.from(e as Map),
      ];
      if (said.isNotEmpty && said.last['text'] == text) continue;
      said.add({'at_ms': at, 'text': text});
      _sentMessages[i] = {...m, 'agentMessages': said};
      changed = true;
    }
    if (changed) unawaited(_persistQueueState());
  }

  void _finishUntrackedSent(String status) {
    var changed = false;
    for (var i = 0; i < _sentMessages.length; i++) {
      final m = _sentMessages[i];
      if (m['status'] != sentWorking || m['agentTurn'] != null) continue;
      _sentMessages[i] = {
        ...m,
        'status': status,
        'completedAt': DateTime.now().toIso8601String(),
      };
      changed = true;
    }
    if (changed) unawaited(_persistQueueState());
  }

  /// Removes one sent message from the queue's history.
  bool removeSentMessageByQueueId(int queueId) {
    warmUp();
    final before = _sentMessages.length;
    _sentMessages.removeWhere((m) => m['queueId'] == queueId);
    if (_sentMessages.length == before) return false;
    _syncProgressPolling();
    unawaited(_persistQueueState());
    notifyListeners();
    return true;
  }

  /// Clears every sent message the agent is no longer working on.
  void clearCompletedMessages() {
    warmUp();
    final before = _sentMessages.length;
    _sentMessages.removeWhere((m) => m['status'] != sentWorking);
    if (_sentMessages.length == before) return;
    unawaited(_persistQueueState());
    notifyListeners();
  }

  /// Follows the agent turns sent messages are waiting on, exactly while
  /// there are any.
  void _syncProgressPolling() {
    if (workingTurns.isEmpty || !_serverClient.isConfigured) {
      _progressTimer?.cancel();
      _progressTimer = null;
      return;
    }
    _progressTimer ??= Timer.periodic(
      _progressPollInterval,
      (_) => unawaited(pollAgentProgress()),
    );
  }

  /// Asks the relay once about every turn still being worked on.
  @visibleForTesting
  Future<void> pollAgentProgress() async {
    if (_progressPollInFlight) return;
    _progressPollInFlight = true;
    try {
      for (final turn in workingTurns) {
        final state = await _serverClient.getAgentTurn(turn);
        // Unreachable relay is not an answer — ask again next tick.
        if (state != null) recordAgentProgress(turn, state);
      }
    } finally {
      _progressPollInFlight = false;
    }
  }

  /// Merges [patch] into an existing queued message by queue id.
  /// Returns true if the message was found and updated.
  bool patchMessage(int queueId, Map<String, dynamic> patch) {
    warmUp();
    final index = _pendingMessages.indexWhere((m) => m['queueId'] == queueId);
    if (index == -1) return false;
    _pendingMessages[index] = {..._pendingMessages[index], ...patch};
    unawaited(_persistQueueState());
    notifyListeners();
    return true;
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

  /// Replaces a queued message by queue id.
  /// Returns true if a message was found and updated.
  bool updateMessageByQueueId(
      int queueId, Map<String, dynamic> updatedMessage) {
    warmUp();
    final index = _pendingMessages.indexWhere((m) => m['queueId'] == queueId);
    if (index == -1) return false;

    final existing = _pendingMessages[index];
    final merged = <String, dynamic>{
      ...existing,
      ...updatedMessage,
      'queueId': queueId,
    };
    _pendingMessages[index] = merged;
    unawaited(_persistQueueState());
    notifyListeners();
    return true;
  }

  /// Re-fires the VM event to notify the agent that there are pending messages.
  /// Call this to nudge the agent to consume queued messages.
  void notifyPending() {
    warmUp();
    if (_pendingMessages.isEmpty || suppressVmEvents) return;
    developer.postEvent(userMessageQueuedEventKind, {
      'pendingCount': _pendingMessages.length,
      'timestamp': DateTime.now().toIso8601String(),
    });
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

      // Restore agent status message (but NOT working state — after restart
      // the VM service connection is gone).
      final persistedStatus = prefs.getString(_agentStatusStorageKey);
      if (persistedStatus != null && persistedStatus.isNotEmpty) {
        _agentStatusMessage = persistedStatus;
      }

      final persistedAutoDrain = prefs.getBool(_autoDrainStorageKey) ?? false;
      if (persistedAutoDrain != _autoDrain) {
        _autoDrain = persistedAutoDrain;
        notifyListeners();
      }

      final persistedSent =
          _decodePersistedMessages(prefs.getString(_sentMessagesStorageKey));
      if (persistedSent.isNotEmpty) {
        final known = {for (final m in _sentMessages) _messageIdentity(m)};
        _sentMessages.insertAll(0, [
          for (final m in persistedSent)
            if (!known.contains(_messageIdentity(m))) m,
        ]);
        // Something sent before the restart and pulled over MCP has lost the
        // connection that would have reported its end.
        _finishUntrackedSent(sentUntracked);
        _syncProgressPolling();
        notifyListeners();
      }

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

      final inferredNextId =
          _inferNextQueueId([..._pendingMessages, ..._sentMessages]);
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
        final sentSnapshot = _sentMessages
            .map((m) => Map<String, dynamic>.from(m))
            .toList(growable: false);
        final nextQueueId = _nextQueueId;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _pendingMessagesStorageKey,
          jsonEncode(queueSnapshot),
        );
        await prefs.setString(
          _sentMessagesStorageKey,
          jsonEncode(sentSnapshot),
        );
        await prefs.setInt(_nextQueueIdStorageKey, nextQueueId);
      } while (_persistRequested);
    } catch (_) {
      // Best-effort persistence: keep in-memory queue if persistence fails.
    } finally {
      _isPersisting = false;
    }
  }

  Future<void> _persistAutoDrain() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoDrainStorageKey, _autoDrain);
    } catch (_) {
      // Best-effort persistence.
    }
  }

  void _persistAgentStatus() {
    unawaited(_persistAgentStatusAsync());
  }

  Future<void> _persistAgentStatusAsync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final msg = _agentStatusMessage;
      if (msg != null) {
        await prefs.setString(_agentStatusStorageKey, msg);
      } else {
        await prefs.remove(_agentStatusStorageKey);
      }
    } catch (_) {
      // Best-effort persistence.
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

  void _startServerPolling() {
    if (_serverPollTimer != null) return;
    unawaited(pollServerStatus());
    _serverPollTimer = Timer.periodic(_serverPollInterval, (_) {
      unawaited(pollServerStatus());
    });
  }

  @visibleForTesting
  Future<void> pollServerStatus() async {
    final status = await _serverClient.getStatus(processId: pid);
    if (status == null) {
      _setServerAssociation(false);
      return;
    }
    final has = status.hasAssociation;
    final label = status.linkedLabel;
    if (_hasServerAssociation != has || _linkedLabel != label) {
      _hasServerAssociation = has;
      _linkedLabel = label;
      notifyListeners();
    }
  }

  void _setServerAssociation(bool value) {
    if (_hasServerAssociation != value ||
        (value == false && _linkedLabel != null)) {
      _hasServerAssociation = value;
      if (!value) _linkedLabel = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _workingTimeoutTimer?.cancel();
    _completionClearTimer?.cancel();
    _serverPollTimer?.cancel();
    _progressTimer?.cancel();
    super.dispose();
  }
}
