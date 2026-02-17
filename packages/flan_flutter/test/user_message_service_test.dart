import 'package:flan_flutter/src/services/user_message_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

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

  test('markWaiting only when explicitly requested', () async {
    final service = UserMessageService();
    await service.ensureHydrated();

    // No listener heartbeat by default, but queueing should still work.
    expect(service.isAgentListening, isFalse);
    expect(service.waitingForActivity, isFalse);

    service.sendMessage({'type': 'user_feedback', 'text': 'offline queue'});
    expect(service.peekMessages(), hasLength(1));
    expect(service.waitingForActivity, isFalse);
  });

  test('can remove queued message by queue id and clear queue', () async {
    final service = UserMessageService();
    await service.ensureHydrated();

    service.sendMessage({'type': 'user_feedback', 'text': 'first'});
    service.sendMessage({'type': 'user_feedback', 'text': 'second'});
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final messages = service.peekMessages();
    expect(messages, hasLength(2));
    final firstQueueId = messages.first['queueId'] as int;

    expect(service.removeMessageByQueueId(firstQueueId), isTrue);
    expect(service.peekMessages(), hasLength(1));

    service.clearMessages();
    expect(service.peekMessages(), isEmpty);
  });
}
