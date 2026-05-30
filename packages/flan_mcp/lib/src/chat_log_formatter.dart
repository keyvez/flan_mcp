import 'dart:convert';

/// Renders a structured chat-log message for the agent: a
/// readable, role-prefixed transcript followed by the raw turns +
/// context as a JSON block (so the agent can both skim and parse).
///
/// This is the renderer for Flan's `chat_log` modality — a sibling
/// of the screenshot and direct-message modalities. It lives in
/// `lib/` (not `bin/`) so it's importable + unit-testable.
///
/// [turns] is the `data['turns']` list (each `{role, text}`).
/// [data] is the message's full `data` bag, used for the context
/// header (route / screen / last_error / selected_entity).
String formatChatLog(List<dynamic> turns, Map<String, dynamic>? data) {
  final buf = StringBuffer();

  // Context header.
  final header = <String>[];
  final screen = data?['screen'] as String?;
  final route = data?['route'] as String?;
  final lastError = data?['last_error'] as String?;
  if (screen != null && screen.isNotEmpty) header.add('screen: $screen');
  if (route != null && route.isNotEmpty) header.add('route: $route');
  header.add('${turns.length} turn(s)');
  if (lastError != null && lastError.isNotEmpty) header.add('has error');
  buf.writeln('Chat log (${header.join(', ')}):');

  // Readable transcript. Error turns are flagged so the agent
  // spots failures at a glance.
  for (final turn in turns) {
    if (turn is! Map) continue;
    final role = (turn['role'] ?? '?').toString();
    final turnText = (turn['text'] ?? '').toString();
    final marker = role.toLowerCase() == 'error' ? ' ⚠' : '';
    buf.writeln('  [${role.toUpperCase()}$marker] $turnText');
  }

  // Structured echo for precise parsing.
  final structured = <String, dynamic>{
    'turns': turns,
    if (route != null) 'route': route,
    if (screen != null) 'screen': screen,
    if (data?['selected_entity'] != null)
      'selected_entity': data!['selected_entity'],
    if (lastError != null) 'last_error': lastError,
  };
  buf
    ..writeln('Chat log (structured):')
    ..writeln(jsonEncode(structured));

  return buf.toString();
}
