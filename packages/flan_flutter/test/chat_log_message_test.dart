import 'package:flutter_test/flutter_test.dart';
import 'package:flan_flutter/src/services/user_message_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Verifies the `chat_log` modality payload — the exact shape
/// [FlanBinding.sendChatLog] builds — round-trips through the
/// message queue intact. (sendChatLog delegates to trySendToAgent
/// -> UserMessageService.sendMessage, which is the testable seam;
/// the static binding singleton isn't unit-test friendly.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Mirrors the payload assembled by FlanBinding.sendChatLog.
  Map<String, dynamic> chatLogPayload({
    required List<Map<String, dynamic>> turns,
    String? summary,
    String? route,
    String? screen,
    Map<String, dynamic>? entity,
    String? lastError,
  }) =>
      {
        'text': summary ??
            'Chat log sent from the app (${turns.length} turns).',
        'type': 'chat_log',
        'data': <String, dynamic>{
          'turns': turns,
          if (route != null) 'route': route,
          if (screen != null) 'screen': screen,
          if (entity != null) 'selected_entity': entity,
          if (lastError != null) 'last_error': lastError,
        },
      };

  group('chat_log message', () {
    test('queues with type chat_log and preserved turns + context',
        () async {
      final service = UserMessageService();
      await service.ensureHydrated();

      service.sendMessage(chatLogPayload(
        turns: [
          {'role': 'user', 'text': 'add a Telugu criteria'},
          {'role': 'assistant', 'text': 'creating...'},
          {'role': 'error', 'text': '500'},
        ],
        route: '/criteria',
        screen: 'stockCriteria',
        lastError: '500',
      ));

      final queued = service.peekMessages();
      expect(queued, hasLength(1));
      final msg = queued.first;
      expect(msg['type'], 'chat_log');

      final data = msg['data'] as Map<String, dynamic>;
      final turns = data['turns'] as List;
      expect(turns, hasLength(3));
      expect((turns.first as Map)['role'], 'user');
      expect((turns.last as Map)['text'], '500');
      expect(data['route'], '/criteria');
      expect(data['screen'], 'stockCriteria');
      expect(data['last_error'], '500');
    });

    test('default summary mentions the turn count', () {
      final payload = chatLogPayload(turns: [
        {'role': 'user', 'text': 'a'},
        {'role': 'assistant', 'text': 'b'},
      ]);
      expect(payload['text'], contains('2 turns'));
      expect(payload['type'], 'chat_log');
    });

    test('omits optional context keys when not provided', () {
      final payload = chatLogPayload(turns: [
        {'role': 'user', 'text': 'hi'},
      ]);
      final data = payload['data'] as Map<String, dynamic>;
      expect(data.containsKey('route'), isFalse);
      expect(data.containsKey('screen'), isFalse);
      expect(data.containsKey('selected_entity'), isFalse);
      expect(data.containsKey('last_error'), isFalse);
      expect(data['turns'], hasLength(1));
    });
  });
}
