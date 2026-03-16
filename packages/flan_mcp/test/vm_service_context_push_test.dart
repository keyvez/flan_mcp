import 'dart:async';

import 'package:flan_mcp/src/vm_service/vm_service_connector.dart';
import 'package:flan_mcp/src/vm_service/vm_service_context.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

void main() {
  group('VmServiceContext push message flow', () {
    test(
      'buffers queued messages and emits resources/updated notification',
      () async {
        final connector = _FakeVmServiceConnector();
        final context = VmServiceContext(connector: connector);
        final server = _buildServer();
        context.registerTools(server);

        final transport = _RecordingTransport();
        await server.connect(transport);

        connector.enqueueUserMessage({'text': 'first message'});
        connector.emitUserMessageQueuedEvent();

        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(context.debugBufferedMessageCount, 0);
        expect(connector.pendingMessageCount, 1);
        final hasResourceUpdated = transport.sentMessages.any(
          (message) =>
              message is JsonRpcNotification &&
              message.method == Method.notificationsResourcesUpdated &&
              message.params?['uri'] == 'flan://messages/pending',
        );
        expect(hasResourceUpdated, isTrue);

        await server.close();
        await transport.close();
      },
    );

    test(
      'emits sampling/createMessage request when client supports sampling',
      () async {
        final connector = _FakeVmServiceConnector();
        final context = VmServiceContext(connector: connector);
        final server = _buildServer();
        context.registerTools(server);

        final transport = _RecordingTransport();
        await server.connect(transport);

        transport.injectIncoming(
          JsonRpcInitializeRequest(
            id: 1,
            initParams: InitializeRequest(
              protocolVersion: latestProtocolVersion,
              capabilities: const ClientCapabilities(
                sampling: ClientCapabilitiesSampling(),
              ),
              clientInfo: const Implementation(
                name: 'test-client',
                version: '1.0.0',
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        connector.enqueueUserMessage({'text': 'sampling message'});
        connector.emitUserMessageQueuedEvent();
        await Future<void>.delayed(const Duration(milliseconds: 80));

        final samplingRequest = transport.sentMessages
            .whereType<JsonRpcRequest>()
            .where((message) => message.method == Method.samplingCreateMessage)
            .cast<JsonRpcRequest?>()
            .firstWhere((_) => true, orElse: () => null);

        expect(samplingRequest, isNotNull);

        transport.injectIncoming(
          JsonRpcResponse(
            id: samplingRequest!.id,
            result: {
              'model': 'test-model',
              'stopReason': 'endTurn',
              'role': 'assistant',
              'content': {'type': 'text', 'text': 'ack'},
            },
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));

        await server.close();
        await transport.close();
      },
    );
  });
}

McpServer _buildServer() {
  return McpServer(
    const Implementation(name: 'flan-mcp-test', version: '0.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: const ServerCapabilitiesTools(),
        resources: const ServerCapabilitiesResources(
          subscribe: true,
          listChanged: true,
        ),
        logging: const <String, dynamic>{},
      ),
    ),
  );
}

final class _FakeVmServiceConnector extends VmServiceConnector {
  bool _connected = true;
  final List<Map<String, dynamic>> _pendingMessages = [];

  int get pendingMessageCount => _pendingMessages.length;

  void enqueueUserMessage(Map<String, dynamic> message) {
    _pendingMessages.add(message);
  }

  void emitUserMessageQueuedEvent() {
    onUserMessageQueued?.call();
  }

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect(String uri) async {
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<Map<String, dynamic>> consumeUserMessages() async {
    final messages = List<Map<String, dynamic>>.from(_pendingMessages);
    _pendingMessages.clear();
    return {
      'status': 'Success',
      'messages': messages,
      'count': messages.length,
    };
  }

  @override
  Future<Map<String, dynamic>> peekUserMessages() async {
    return {'status': 'Success', 'count': _pendingMessages.length};
  }

  @override
  Future<Map<String, dynamic>> setAgentListening(bool listening) async {
    return {'status': 'Success', 'listening': listening};
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
