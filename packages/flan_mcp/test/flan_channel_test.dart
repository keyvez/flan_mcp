import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import '../bin/flan_channel.dart';

void main() {
  for (final clientName in <String?>[
    null,
    'codex',
    'codex_cli_rs',
    'claude-code',
  ]) {
    test('flush handles client $clientName without false delivery', () async {
      final server = McpServer(
        const Implementation(name: 'test', version: '1'),
      );
      final transport = _RecordingTransport();
      await server.connect(transport);
      addTearDown(server.close);
      if (clientName != null) {
        transport.injectIncoming(
          JsonRpcInitializeRequest(
            id: 1,
            initParams: InitializeRequest(
              protocolVersion: latestProtocolVersion,
              capabilities: const ClientCapabilities(),
              clientInfo: Implementation(name: clientName, version: '1'),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
      }
      final channel = FlanChannel(
        mcpServer: server,
        listenPort: 0,
        serverUrl: null,
      );
      await channel.start();
      addTearDown(channel.close);
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:${channel.boundPort}/flush'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'messages': [
            {'text': 'fix this button'},
          ],
        }),
      );
      final response = await request.close();
      final body =
          jsonDecode(await response.transform(utf8.decoder).join()) as Map;
      final notifications = transport.sentMessages
          .whereType<JsonRpcNotification>()
          .where((message) => message.method == 'notifications/claude/channel');
      if (clientName == 'claude-code') {
        expect(response.statusCode, HttpStatus.ok);
        expect(body['accepted'], isTrue);
        expect(body['delivered'], isTrue);
        expect(notifications, hasLength(1));
      } else {
        expect(response.statusCode, HttpStatus.conflict);
        expect(body['accepted'], isFalse);
        expect(body['delivered'], isFalse);
        expect(
          body['error'],
          contains(clientName == null ? 'initialization' : 'process_queue'),
        );
        expect(notifications, isEmpty);
      }
    });
  }
}

final class _RecordingTransport implements Transport {
  @override
  void Function()? onclose;

  @override
  void Function(Error error)? onerror;

  @override
  void Function(JsonRpcMessage message)? onmessage;

  @override
  String? get sessionId => 'test-session';

  final List<JsonRpcMessage> sentMessages = [];

  @override
  Future<void> start() async {}

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    sentMessages.add(message);
  }

  void injectIncoming(JsonRpcMessage message) {
    onmessage?.call(message);
  }

  @override
  Future<void> close() async {
    onclose?.call();
  }
}
