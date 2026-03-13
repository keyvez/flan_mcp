import 'dart:async';
import 'dart:convert';

import 'package:flan_flutter/src/services/user_message_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('basic queue operations', () {
    test('starts empty', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      expect(service.hasPendingMessages, isFalse);
      expect(service.pendingMessageCount, 0);
      expect(service.peekMessages(), isEmpty);
    });

    test('sendMessage adds to queue', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      service.sendMessage({'type': 'test', 'text': 'hello'});
      expect(service.hasPendingMessages, isTrue);
      expect(service.pendingMessageCount, 1);
      final messages = service.peekMessages();
      expect(messages.first['text'], 'hello');
      expect(messages.first['queueId'], isA<int>());
      expect(messages.first['timestamp'], isA<String>());
    });

    test('sendMessage notifies listeners', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.sendMessage({'type': 'test', 'text': 'notify'});
      expect(notifications, 1);
    });

    test('consumeMessages returns and clears', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      service.sendMessage({'type': 'test', 'text': 'consume'});
      final consumed = service.consumeMessages();
      expect(consumed, hasLength(1));
      expect(service.pendingMessageCount, 0);
    });

    test('consumeMessages returns empty list when nothing pending', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      final consumed = service.consumeMessages();
      expect(consumed, isEmpty);
    });

    test('clearMessages clears all', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      service.sendMessage({'type': 'test', 'text': 'one'});
      service.sendMessage({'type': 'test', 'text': 'two'});
      expect(service.pendingMessageCount, 2);
      service.clearMessages();
      expect(service.pendingMessageCount, 0);
    });

    test('clearMessages on empty queue is no-op', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.clearMessages();
      expect(notifications, 0);
    });
  });

  group('removeMessageByQueueId', () {
    test('removes existing message', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      service.sendMessage({'type': 'test', 'text': 'remove me'});
      final queueId = service.peekMessages().first['queueId'] as int;
      expect(service.removeMessageByQueueId(queueId), isTrue);
      expect(service.pendingMessageCount, 0);
    });

    test('returns false for non-existent id', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      expect(service.removeMessageByQueueId(99999), isFalse);
    });
  });

  group('updateMessageByQueueId', () {
    test('updates existing message', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      service.sendMessage({'type': 'test', 'text': 'original'});
      final queueId = service.peekMessages().first['queueId'] as int;
      expect(
        service.updateMessageByQueueId(queueId, {'text': 'updated'}),
        isTrue,
      );
      expect(service.peekMessages().first['text'], 'updated');
      // queueId should be preserved
      expect(service.peekMessages().first['queueId'], queueId);
    });

    test('returns false for non-existent id', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      expect(
        service.updateMessageByQueueId(99999, {'text': 'nope'}),
        isFalse,
      );
    });
  });

  group('persistence', () {
    test('restores queued messages after service recreation', () async {
      final first = UserMessageService();
      await first.ensureHydrated();
      first.sendMessage({
        'type': 'user_feedback',
        'text': 'persist me',
        'data': {'k': 'v'},
      });

      await Future<void>.delayed(const Duration(milliseconds: 30));
      first.dispose();

      final second = UserMessageService();
      await second.ensureHydrated();
      final restored = second.peekMessages();

      expect(restored, hasLength(1));
      expect(restored.first['text'], 'persist me');
      expect(restored.first['queueId'], isA<int>());
    });

    test('consumed queue stays empty after service recreation', () async {
      final first = UserMessageService();
      await first.ensureHydrated();
      first.sendMessage({'type': 'user_feedback', 'text': 'to consume'});

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(first.peekMessages(), hasLength(1));

      final consumed = first.consumeMessages();
      expect(consumed, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      first.dispose();

      final second = UserMessageService();
      await second.ensureHydrated();
      expect(second.peekMessages(), isEmpty);
    });
  });

  group('waiting state', () {
    test('markWaiting sets waiting state', () async {
      final service = UserMessageService();
      await service.ensureHydrated();

      expect(service.waitingForActivity, isFalse);
      expect(service.sentMessageText, isNull);

      service.markWaiting('my message');
      expect(service.waitingForActivity, isTrue);
      expect(service.sentMessageText, 'my message');
    });

    test('clearWaiting resets waiting state', () async {
      final service = UserMessageService();
      await service.ensureHydrated();

      service.markWaiting('waiting');
      service.clearWaiting();
      expect(service.waitingForActivity, isFalse);
      expect(service.sentMessageText, isNull);
    });

    test('clearWaiting is no-op when not waiting', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.clearWaiting();
      expect(notifications, 0);
    });

    test('markWaiting only when explicitly requested', () async {
      final service = UserMessageService();
      await service.ensureHydrated();

      expect(service.isAgentListening, isFalse);
      expect(service.waitingForActivity, isFalse);

      service.sendMessage({'type': 'user_feedback', 'text': 'offline queue'});
      expect(service.peekMessages(), hasLength(1));
      expect(service.waitingForActivity, isFalse);
    });
  });

  group('agent listening', () {
    test('isAgentListening defaults to false', () {
      final service = UserMessageService();
      expect(service.isAgentListening, isFalse);
    });

    test('setting isAgentListening notifies', () async {
      final service = UserMessageService();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.isAgentListening = true;
      expect(notifications, 1);
      expect(service.isAgentListening, isTrue);
    });

    test('setting same value does not notify', () async {
      final service = UserMessageService();
      service.isAgentListening = false; // already false
      var notifications = 0;
      service.addListener(() => notifications++);
      service.isAgentListening = false;
      expect(notifications, 0);
    });

    test('heartbeat timeout auto-clears agent listening', () async {
      final service = UserMessageService();
      service.isAgentListening = true;
      expect(service.isAgentListening, isTrue);

      // Wait for heartbeat timeout (5 seconds + buffer)
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(service.isAgentListening, isFalse);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('setting isAgentListening to false cancels timer', () async {
      final service = UserMessageService();
      service.isAgentListening = true;
      service.isAgentListening = false;
      expect(service.isAgentListening, isFalse);
      // No crash from timer firing later
      service.dispose();
    });
  });

  group('host connection state', () {
    test('tracks push-capable host', () async {
      final service = UserMessageService();
      await service.ensureHydrated();

      expect(service.isHostConnected, isFalse);
      expect(service.isPushCapableHostConnected, isFalse);

      service.setHostConnectionState(connected: true, pushCapable: true);
      expect(service.isHostConnected, isTrue);
      expect(service.isPushCapableHostConnected, isTrue);

      service.setHostConnectionState(connected: true, pushCapable: false);
      expect(service.isHostConnected, isTrue);
      expect(service.isPushCapableHostConnected, isFalse);

      service.setHostConnectionState(connected: false, pushCapable: true);
      expect(service.isHostConnected, isFalse);
      // push is normalized: connected=false means pushCapable=false
      expect(service.isPushCapableHostConnected, isFalse);
    });

    test('does not notify when state unchanged', () async {
      final service = UserMessageService();
      service.setHostConnectionState(connected: true, pushCapable: true);
      var notifications = 0;
      service.addListener(() => notifications++);
      service.setHostConnectionState(connected: true, pushCapable: true);
      expect(notifications, 0);
    });
  });

  group('consumeMessages generation', () {
    test('bumps agent consume generation', () async {
      final service = UserMessageService();
      await service.ensureHydrated();

      expect(service.agentConsumeGeneration, 0);
      service.sendMessage({'type': 'user_feedback', 'text': 'one'});
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final consumed = service.consumeMessages();
      expect(consumed, hasLength(1));
      expect(service.agentConsumeGeneration, 1);
    });
  });

  group('warmUp', () {
    test('is idempotent', () async {
      final service = UserMessageService();
      service.warmUp();
      service.warmUp();
      service.warmUp();
      await service.ensureHydrated();
      expect(service.pendingMessageCount, 0);
    });
  });

  group('dispose', () {
    test('cancels heartbeat timer', () {
      final service = UserMessageService();
      service.isAgentListening = true;
      service.dispose();
      // No crash or leak
    });
  });

  group('queue id incrementing', () {
    test('assigns incrementing queue ids', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      service.sendMessage({'type': 'test', 'text': 'a'});
      service.sendMessage({'type': 'test', 'text': 'b'});
      final messages = service.peekMessages();
      final id1 = messages[0]['queueId'] as int;
      final id2 = messages[1]['queueId'] as int;
      expect(id2, greaterThan(id1));
    });
  });

  group('hydration merge', () {
    test('persisted messages are restored after recreation', () async {
      final first = UserMessageService();
      await first.ensureHydrated();
      first.sendMessage({
        'type': 'user_feedback',
        'text': 'persisted msg',
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      first.dispose();

      final second = UserMessageService();
      await second.ensureHydrated();

      final messages = second.peekMessages();
      expect(messages.length, 1);
      expect(messages.first['text'], 'persisted msg');
    });

    test('next queue id is correctly inferred from persisted messages',
        () async {
      final first = UserMessageService();
      await first.ensureHydrated();
      first.sendMessage({'type': 'test', 'text': 'a'});
      first.sendMessage({'type': 'test', 'text': 'b'});
      final maxQueueId = first.peekMessages().last['queueId'] as int;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      first.dispose();

      final second = UserMessageService();
      await second.ensureHydrated();
      // Add a new message - its queueId should be greater than the max persisted
      second.sendMessage({'type': 'test', 'text': 'c'});
      final newMessages = second.peekMessages();
      final newQueueId = newMessages.last['queueId'] as int;
      expect(newQueueId, greaterThan(maxQueueId));
    });
  });

  group('message identity', () {
    test('messages without queueId use timestamp+type+text identity',
        () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      // Send two messages with different text
      service.sendMessage({'type': 'a', 'text': 'first'});
      service.sendMessage({'type': 'a', 'text': 'second'});
      expect(service.pendingMessageCount, 2);
    });
  });

  group('host connection notification', () {
    test('setHostConnectionState with connected=false normalizes pushCapable',
        () {
      final service = UserMessageService();
      service.setHostConnectionState(connected: false, pushCapable: true);
      // When not connected, push should be false
      expect(service.isPushCapableHostConnected, isFalse);
      expect(service.isHostConnected, isFalse);
    });
  });

  group('agent working state', () {
    test('isAgentWorking defaults to false', () {
      final service = UserMessageService();
      expect(service.isAgentWorking, isFalse);
      expect(service.agentStatusMessage, isNull);
    });

    test('setting isAgentWorking notifies', () {
      final service = UserMessageService();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.isAgentWorking = true;
      expect(notifications, 1);
      expect(service.isAgentWorking, isTrue);
    });

    test('setting same value does not notify', () {
      final service = UserMessageService();
      service.isAgentWorking = false; // already false
      var notifications = 0;
      service.addListener(() => notifications++);
      service.isAgentWorking = false;
      expect(notifications, 0);
    });

    test('consumeMessages auto-sets isAgentWorking', () async {
      final service = UserMessageService();
      await service.ensureHydrated();
      service.sendMessage({'type': 'test', 'text': 'work'});
      expect(service.isAgentWorking, isFalse);
      service.consumeMessages();
      expect(service.isAgentWorking, isTrue);
    });

    test('markDone clears working state and status', () {
      final service = UserMessageService();
      service.isAgentWorking = true;
      expect(service.isAgentWorking, isTrue);
      service.markDone();
      expect(service.isAgentWorking, isFalse);
    });

    test('markDone with message sets agentStatusMessage temporarily', () {
      final service = UserMessageService();
      service.isAgentWorking = true;
      service.markDone(message: 'Done!');
      expect(service.isAgentWorking, isFalse);
      expect(service.agentStatusMessage, 'Done!');
    });

    test('agentStatusMessage auto-clears after timer', () async {
      final service = UserMessageService();
      service.isAgentWorking = true;
      service.markDone(message: 'Finished');
      expect(service.agentStatusMessage, 'Finished');

      // Wait for the completion display duration (4 seconds + buffer)
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(service.agentStatusMessage, isNull);
      service.dispose();
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('heartbeat timeout clears working state', () async {
      final service = UserMessageService();
      service.isAgentListening = true;
      service.isAgentWorking = true;
      expect(service.isAgentWorking, isTrue);

      // Wait for heartbeat timeout (5 seconds + buffer)
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(service.isAgentListening, isFalse);
      expect(service.isAgentWorking, isFalse);
      service.dispose();
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('entering working state does not clear agent status message', () {
      final service = UserMessageService();
      service.markDone(message: 'Old message');
      expect(service.agentStatusMessage, 'Old message');
      // The setter no longer clears the status — the agent sets it via
      // updateAgentStatus instead.
      service.isAgentWorking = true;
      expect(service.agentStatusMessage, 'Old message');
    });

    test('dispose cancels working timers', () {
      final service = UserMessageService();
      service.isAgentWorking = true;
      service.markDone(message: 'test');
      service.dispose();
      // No crash or leak
    });

    test('updateAgentStatus sets message and working state', () {
      final service = UserMessageService();
      expect(service.isAgentWorking, isFalse);
      expect(service.agentStatusMessage, isNull);
      service.updateAgentStatus('Analyzing...');
      expect(service.isAgentWorking, isTrue);
      expect(service.agentStatusMessage, 'Analyzing...');
    });

    test('updateAgentStatus updates message text', () {
      final service = UserMessageService();
      service.updateAgentStatus('Analyzing...');
      service.updateAgentStatus('Running tests...');
      expect(service.isAgentWorking, isTrue);
      expect(service.agentStatusMessage, 'Running tests...');
    });

    test('updateAgentStatus notifies listeners', () {
      final service = UserMessageService();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.updateAgentStatus('Working');
      expect(notifications, 1);
    });

    test('heartbeat timeout clears agent status message', () async {
      final service = UserMessageService();
      service.isAgentListening = true;
      service.updateAgentStatus('Busy...');
      expect(service.agentStatusMessage, 'Busy...');

      // Wait for heartbeat timeout (5 seconds + buffer)
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(service.isAgentListening, isFalse);
      expect(service.isAgentWorking, isFalse);
      expect(service.agentStatusMessage, isNull);
      service.dispose();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('agent status persistence', () {
    test('updateAgentStatus persists to SharedPreferences', () async {
      final first = UserMessageService();
      await first.ensureHydrated();
      first.updateAgentStatus('Analyzing...');

      // Allow async persistence to complete
      await Future<void>.delayed(const Duration(milliseconds: 30));
      first.dispose();

      final second = UserMessageService();
      await second.ensureHydrated();
      // Status message is restored but working state is NOT (connection lost)
      expect(second.agentStatusMessage, 'Analyzing...');
      expect(second.isAgentWorking, isFalse);
    });

    test('markDone persists status then auto-clears', () async {
      final first = UserMessageService();
      await first.ensureHydrated();
      first.updateAgentStatus('Working...');
      first.markDone(message: 'All done!');

      // Allow async persistence to complete
      await Future<void>.delayed(const Duration(milliseconds: 30));
      first.dispose();

      final second = UserMessageService();
      await second.ensureHydrated();
      expect(second.agentStatusMessage, 'All done!');
    });

    test('clearing status removes from SharedPreferences', () async {
      final first = UserMessageService();
      await first.ensureHydrated();
      first.updateAgentStatus('Busy');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      first.markDone();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      first.dispose();

      final second = UserMessageService();
      await second.ensureHydrated();
      expect(second.agentStatusMessage, isNull);
    });
  });

  group('server association polling', () {
    test('hasServerAssociation defaults to false', () {
      final service = UserMessageService();
      expect(service.hasServerAssociation, isFalse);
    });

    test('hasServerAssociation updates on successful poll', () async {
      final client = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({'has_association': true, 'association_count': 1}),
          200,
        );
      });
      final service = UserMessageService(httpClient: client);
      await service.pollServerStatus();
      expect(service.hasServerAssociation, isTrue);
    });

    test('hasServerAssociation false when server returns no association',
        () async {
      final client = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({'has_association': false, 'association_count': 0}),
          200,
        );
      });
      final service = UserMessageService(httpClient: client);
      await service.pollServerStatus();
      expect(service.hasServerAssociation, isFalse);
    });

    test('hasServerAssociation false when server unreachable', () async {
      final client = http_testing.MockClient((request) async {
        throw Exception('Connection refused');
      });
      final service = UserMessageService(httpClient: client);
      await service.pollServerStatus();
      expect(service.hasServerAssociation, isFalse);
    });

    test('notifies listeners when server association changes', () async {
      var hasAssociation = false;
      final client = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({
            'has_association': hasAssociation,
            'association_count': hasAssociation ? 1 : 0,
          }),
          200,
        );
      });
      final service = UserMessageService(httpClient: client);
      var notifications = 0;
      service.addListener(() => notifications++);

      // Initial poll — no association, no change from default false
      await service.pollServerStatus();
      expect(notifications, 0);

      // Simulate association appearing
      hasAssociation = true;
      await service.pollServerStatus();
      expect(notifications, 1);
      expect(service.hasServerAssociation, isTrue);
    });
  });
}
