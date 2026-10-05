import 'dart:convert';

import 'package:flan_flutter/src/services/flan_server_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  _relayResolutionTests();

  test('flush sends app identity and messages to the stable relay', () async {
    late http.Request captured;
    final client = http_testing.MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({'accepted': true, 'delivered': true}),
        200,
      );
    });
    final relay = FlanServerClient(
      serverUrl: 'http://relay.test/flan',
      appId: 'worktree-003',
      httpClient: client,
    );

    final result = await relay.flush(
      messages: [
        {'type': 'user_message', 'text': 'hello'},
      ],
      vmServiceUri: 'ws://vm.test/ws',
      origin: 'http://frontend.test:5205',
    );

    expect(captured.url, Uri.parse('http://relay.test/flan/api/flush'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['app_id'], 'worktree-003');
    expect(body['vm_service_uri'], 'ws://vm.test/ws');
    expect(body['origin'], 'http://frontend.test:5205');
    expect(body['messages'], hasLength(1));
    expect(result.accepted, isTrue);
    expect(result.delivered, isTrue);
  });

  test('accepted queued batch is not reported as delivered', () async {
    final relay = FlanServerClient(
      serverUrl: 'http://relay.test',
      appId: 'app-a',
      httpClient: http_testing.MockClient(
        (_) async => http.Response(
          jsonEncode({'accepted': true, 'delivered': false}),
          200,
        ),
      ),
    );

    final result = await relay.flush(messages: [
      {'text': 'queued'},
    ]);

    expect(result.accepted, isTrue);
    expect(result.delivered, isFalse);
  });

  test('legacy discovery-only response does not consume messages', () async {
    final relay = FlanServerClient(
      serverUrl: 'http://relay.test',
      appId: 'app-a',
      httpClient: http_testing.MockClient(
        (_) async => http.Response(
          jsonEncode({'ok': true, 'channel_port': 9999}),
          200,
        ),
      ),
    );

    final result = await relay.flush(messages: [
      {'text': 'keep me'},
    ]);

    expect(result.accepted, isFalse);
    expect(result.delivered, isFalse);
  });

  test('hot reload names the app and asks for a reload, not a restart',
      () async {
    late http.Request captured;
    final relay = FlanServerClient(
      serverUrl: 'http://relay.test/flan',
      appId: 'worktree-003',
      httpClient: http_testing.MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          // The relay answers `application/json` with no charset, and its
          // detail is prose with an em dash and an arrow in it. Bytes, so the
          // test can't quietly agree with the client about the codec.
          utf8.encode(jsonEncode({
            'ok': true,
            'via': 'signal',
            'detail': 'Hot reload requested — SIGUSR1 → pid 4242',
          })),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );

    final result = await relay.hotReload(vmServiceUri: 'ws://vm.test/ws');

    expect(captured.url, Uri.parse('http://relay.test/flan/api/hot-reload'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['app_id'], 'worktree-003');
    expect(body['vm_service_uri'], 'ws://vm.test/ws');
    expect(body['full_restart'], isFalse);
    expect(result.ok, isTrue);
    // The distinction the UI leans on: a signalled reload was *requested*, and
    // a compile error after that point never comes back here.
    expect(result.wasSignalled, isTrue);
    // Verbatim, em dash and arrow intact: latin1 would make them mojibake.
    expect(result.detail, 'Hot reload requested — SIGUSR1 → pid 4242');
  });

  /// A web page has no pid and no VM service; without its origin the relay has
  /// nothing to resolve it by, and answers about "pid 0".
  test('a web app identifies itself by origin', () async {
    late http.Request captured;
    final relay = FlanServerClient(
      serverUrl: 'http://relay.test',
      appId: '',
      httpClient: http_testing.MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'ok': true, 'via': 'signal', 'detail': 'done'}),
          200,
        );
      }),
    );

    final result = await relay.hotReload(origin: 'http://localhost:8087');

    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['origin'], 'http://localhost:8087');
    expect(body.containsKey('app_id'), isFalse);
    expect(result.ok, isTrue);
  });

  test('a relay that cannot reload is reported with its own reason', () async {
    final relay = FlanServerClient(
      serverUrl: 'http://relay.test',
      appId: 'app-a',
      httpClient: http_testing.MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': false,
            'via': 'reloadSources',
            'detail': "lib/main.dart:7:3: Error: Expected ';'",
          }),
          500,
        ),
      ),
    );

    final result = await relay.hotReload();

    expect(result.ok, isFalse);
    expect(result.detail, contains("Expected ';'"));
  });

  /// A web app has no VM service and may have no FLAN_APP_ID either. Asking
  /// the relay then can only reload *something*, so don't ask.
  test('an app with no identity at all is refused before the request',
      () async {
    var requested = false;
    final relay = FlanServerClient(
      serverUrl: 'http://relay.test',
      appId: '',
      httpClient: http_testing.MockClient((_) async {
        requested = true;
        return http.Response('{}', 200);
      }),
    );

    final result = await relay.hotReload();

    expect(requested, isFalse);
    expect(result.ok, isFalse);
    expect(result.detail, contains('FLAN_APP_ID'));
  });

  test('status uses app identity instead of a browser process id', () async {
    late http.Request captured;
    final relay = FlanServerClient(
      serverUrl: 'http://relay.test',
      appId: 'app-a',
      httpClient: http_testing.MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'has_association': true,
            'linked_label': 'agent-a',
          }),
          200,
        );
      }),
    );

    final status = await relay.getStatus(processId: 42);

    expect(captured.url.queryParameters, {'app_id': 'app-a'});
    expect(status?.hasAssociation, isTrue);
    expect(status?.linkedLabel, 'agent-a');
  });
}

void _relayResolutionTests() {
  group('resolveRelayUrl', () {
    test('derives the relay host from the page when served over a tailnet', () {
      // The browser is on another machine; a loopback relay would point at it.
      final url = resolveRelayUrl(
        configured: '',
        pageOrigin: Uri.parse('http://mini.tail1234.ts.net:5305/#/candidates'),
        isWeb: true,
      );

      expect(url, 'http://mini.tail1234.ts.net:4050');
    });

    test('rewrites a loopback setting to the page host, keeping its port', () {
      final url = resolveRelayUrl(
        configured: 'http://localhost:4099',
        pageOrigin: Uri.parse('http://mini.tail1234.ts.net:5305/'),
        isWeb: true,
      );

      expect(url, 'http://mini.tail1234.ts.net:4099');
    });

    test('leaves an explicit remote relay alone', () {
      // Naming a host is a deliberate choice — it may not be the app's host.
      final url = resolveRelayUrl(
        configured: 'https://relay.example.com/flan',
        pageOrigin: Uri.parse('http://mini.tail1234.ts.net:5305/'),
        isWeb: true,
      );

      expect(url, 'https://relay.example.com/flan');
    });

    test('keeps loopback when the page itself is local', () {
      final url = resolveRelayUrl(
        configured: '',
        pageOrigin: Uri.parse('http://localhost:5305/'),
        isWeb: true,
      );

      expect(url, 'http://127.0.0.1:4050');
    });

    test('keeps loopback off the web, where app and relay share a machine', () {
      final url = resolveRelayUrl(
        configured: '',
        pageOrigin: Uri.parse('file:///Users/g/app'),
        isWeb: false,
      );

      expect(url, 'http://127.0.0.1:4050');
    });
  });
}
