import 'dart:convert';

import 'package:test/test.dart';

import 'package:flan_mcp/src/chat_log_formatter.dart';

void main() {
  group('formatChatLog', () {
    final turns = [
      {'role': 'user', 'text': 'add a criteria that a candidate speaks Telugu'},
      {'role': 'assistant', 'text': 'I will create a new criterion...'},
      {'role': 'error', 'text': '500 Internal Server Error'},
    ];
    final data = {
      'turns': turns,
      'route': '/criteria-library',
      'screen': 'stockCriteria',
      'last_error': '500 Internal Server Error',
    };

    test('renders a context header with screen, route and count', () {
      final out = formatChatLog(turns, data);
      expect(out, contains('Chat log ('));
      expect(out, contains('screen: stockCriteria'));
      expect(out, contains('route: /criteria-library'));
      expect(out, contains('3 turn(s)'));
      expect(out, contains('has error'));
    });

    test('renders a readable role-prefixed transcript', () {
      final out = formatChatLog(turns, data);
      expect(out, contains('[USER] add a criteria that a candidate speaks Telugu'));
      expect(out, contains('[ASSISTANT] I will create a new criterion...'));
    });

    test('flags error turns with a marker', () {
      final out = formatChatLog(turns, data);
      expect(out, contains('[ERROR ⚠] 500 Internal Server Error'));
    });

    test('echoes a structured json block that round-trips', () {
      final out = formatChatLog(turns, data);
      expect(out, contains('Chat log (structured):'));

      // Pull the JSON line (the last non-empty line) and decode it.
      final jsonLine = out
          .split('\n')
          .lastWhere((l) => l.trim().startsWith('{'));
      final decoded = jsonDecode(jsonLine) as Map<String, dynamic>;
      expect(decoded['turns'], hasLength(3));
      expect(decoded['route'], '/criteria-library');
      expect(decoded['screen'], 'stockCriteria');
      expect(decoded['last_error'], '500 Internal Server Error');
    });

    test('includes selected_entity in structured output when present', () {
      final out = formatChatLog(turns, {
        ...data,
        'selected_entity': {'id': 'abc', 'type': 'job'},
      });
      expect(out, contains('"selected_entity"'));
      expect(out, contains('"abc"'));
    });

    test('handles missing context and malformed turns gracefully', () {
      final out = formatChatLog(
        [
          {'role': 'user', 'text': 'hi'},
          'not a map',
          {'role': 'assistant'},
        ],
        null,
      );
      expect(out, contains('3 turn(s)'));
      expect(out, contains('[USER] hi'));
      // The non-map entry is skipped; the role-less map renders empty text.
      expect(out, contains('[ASSISTANT]'));
      expect(out, isNot(contains('screen:')));
      expect(out, isNot(contains('route:')));
    });
  });
}
