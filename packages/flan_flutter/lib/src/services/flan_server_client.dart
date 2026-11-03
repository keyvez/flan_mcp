import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Port the Flan relay listens on when nothing says otherwise.
const int kDefaultFlanRelayPort = 4050;

/// Work out where the relay actually is, from the build-time setting and the
/// page the app is being served from.
///
/// The relay runs beside the agent, on the machine hosting the app — but the
/// browser may be somewhere else entirely, reaching it over a tailnet. A
/// loopback URL then points at the *viewer's* machine, where nothing is
/// listening, and every flush fails. The page's own origin is the one host
/// known to be reachable from where the app is running, so derive from it.
///
/// [configured] wins whenever it names a real host: an explicit
/// `FLAN_SERVER_URL` is a deliberate choice and may well point somewhere else.
String resolveRelayUrl({
  required String configured,
  required Uri pageOrigin,
  required bool isWeb,
  int defaultPort = kDefaultFlanRelayPort,
}) {
  final explicit = configured.trim();
  final configuredUri = explicit.isEmpty ? null : Uri.tryParse(explicit);
  final configuredIsLoopback =
      configuredUri == null || _isLoopback(configuredUri.host);

  if (explicit.isNotEmpty && !configuredIsLoopback) {
    return explicit;
  }

  // Native apps run on the same machine as the relay, so loopback is right.
  if (isWeb && !_isLoopback(pageOrigin.host) && pageOrigin.host.isNotEmpty) {
    final port =
        configuredUri?.hasPort == true ? configuredUri!.port : defaultPort;
    // Deliberately http: the relay serves plain HTTP. A page served over https
    // will have this blocked as mixed content — set FLAN_SERVER_URL explicitly
    // to a TLS endpoint in that case.
    return 'http://${pageOrigin.host}:$port';
  }

  return explicit.isNotEmpty ? explicit : 'http://127.0.0.1:$defaultPort';
}

bool _isLoopback(String host) =>
    host.isEmpty ||
    host == 'localhost' ||
    host == '127.0.0.1' ||
    host == '::1' ||
    host == '[::1]' ||
    host == '0.0.0.0';

/// Result of handing a message batch to the local Flan relay.
class FlanFlushResult {
  const FlanFlushResult({
    required this.accepted,
    required this.delivered,
    this.error,
    this.agentTurn,
  });

  const FlanFlushResult.failure(String message)
      : accepted = false,
        delivered = false,
        error = message,
        agentTurn = null;

  /// Whether the relay took ownership of the messages.
  final bool accepted;

  /// Whether the connected agent received the messages immediately.
  final bool delivered;

  /// A user-facing diagnostic when [accepted] is false.
  final String? error;

  /// The agent that took the batch and when, for asking later whether it has
  /// finished. Null when the relay could not say (an older relay, an agent
  /// with no session registry and no Codex rollout).
  final FlanAgentTurn? agentTurn;
}

/// The turn a flush started in an agent: who took it, when, and on which host.
class FlanAgentTurn {
  const FlanAgentTurn({
    required this.agentPid,
    required this.deliveredAtMs,
    this.host,
    this.thread,
  });

  /// Parses the relay's `agent_turn` object, or returns null.
  static FlanAgentTurn? fromJson(Object? json) {
    if (json is! Map) return null;
    final pid = json['agent_pid'];
    final at = json['delivered_at_ms'];
    if (pid is! int || at is! int) return null;
    final host = json['host'];
    final thread = json['thread'];
    return FlanAgentTurn(
      agentPid: pid,
      deliveredAtMs: at,
      host: host is String && host.isNotEmpty ? host : null,
      thread: thread is String && thread.isNotEmpty ? thread : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'agent_pid': agentPid,
        'delivered_at_ms': deliveredAtMs,
        'host': host,
        if (thread != null) 'thread': thread,
      };

  /// Two turns are the same when they name the same delivery.
  bool sameAs(FlanAgentTurn other) =>
      agentPid == other.agentPid &&
      deliveredAtMs == other.deliveredAtMs &&
      host == other.host &&
      thread == other.thread;

  final int agentPid;

  /// The agent host's clock, never this app's — compared only against that
  /// host's own session registry.
  final int deliveredAtMs;

  /// The peer relay the agent runs behind, when it is not the app's own.
  final String? host;

  /// The Codex thread the batch was queued into. Codex keeps no session
  /// registry, so the relay reads the thread's rollout instead.
  final String? thread;
}

/// Something the agent said while working on a turn — its plain-English
/// narration between tool calls.
class FlanAgentMessage {
  const FlanAgentMessage({required this.atMs, required this.text});

  static FlanAgentMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at_ms'];
    final text = json['text'];
    if (at is! int || text is! String || text.isEmpty) return null;
    return FlanAgentMessage(atMs: at, text: text);
  }

  /// The agent host's clock, like [FlanAgentTurn.deliveredAtMs].
  final int atMs;
  final String text;

  Map<String, dynamic> toJson() => {'at_ms': atMs, 'text': text};
}

/// Whether a Claude Code session-registry status means no turn is running.
bool isRestingAgentStatus(Object? status) =>
    status == 'idle' || status == 'shell';

/// Where an agent stands on a [FlanAgentTurn].
class FlanAgentTurnState {
  const FlanAgentTurnState({
    required this.alive,
    required this.finished,
    this.idle = false,
    this.messages = const [],
  });

  final bool alive;
  final bool finished;

  /// What the agent has said since the turn was delivered, oldest first.
  /// Empty from a relay too old to read transcripts.
  final List<FlanAgentMessage> messages;

  /// The agent is at rest right now (`idle` or `shell`), whatever turn it was
  /// asked about —
  /// what auto-drain needs to start a queue that no flush of ours began.
  final bool idle;
}

/// Result of asking the relay to hot reload this app.
class FlanHotReloadResult {
  const FlanHotReloadResult({
    required this.ok,
    required this.detail,
    this.via,
    this.needsPageRefresh = false,
  });

  const FlanHotReloadResult.failure(String message)
      : ok = false,
        detail = message,
        via = null,
        needsPageRefresh = false;

  /// Whether the reload was carried out (or, for a signalled one, requested —
  /// see [via]).
  final bool ok;

  /// What the relay did, in its own words. Shown to the developer as-is.
  final String detail;

  /// How the relay asked: `signal`, `reloadSources`, or `host:via` when a peer
  /// did it. A signalled reload is fire-and-forget, so `ok` means the signal
  /// was delivered, not that the code compiled — compile errors land in the
  /// `flutter run` terminal.
  final String? via;

  bool get wasSignalled => via == 'signal';

  /// The code compiled and reached nobody — a web page with no debug client
  /// attached, which is every `flutter run -d web-server` without the Dart
  /// Debug Extension. Refreshing the page is what finishes the job.
  final bool needsPageRefresh;
}

/// Association state reported by the local Flan relay.
class FlanServerStatus {
  const FlanServerStatus({
    required this.hasAssociation,
    this.linkedLabel,
  });

  final bool hasAssociation;
  final String? linkedLabel;
}

/// Talks to the stable Flan relay endpoint supplied by the host application.
///
/// The browser never receives the loopback-only port of an MCP channel. The
/// relay owns that implementation detail and forwards messages server-side.
class FlanServerClient {
  FlanServerClient({
    required String serverUrl,
    required this.appId,
    http.Client? httpClient,
  })  : _serverUrl = serverUrl.trim(),
        _httpClient = httpClient ?? http.Client();

  static const _requestTimeout = Duration(seconds: 5);

  /// A hot reload is a compile, not a round trip. The relay stops waiting for
  /// flutter_tools after 20s, so this has to outlast that.
  static const _reloadTimeout = Duration(seconds: 25);

  final String _serverUrl;
  final String appId;
  final http.Client _httpClient;

  bool get isConfigured => _serverUrl.isNotEmpty;

  Future<FlanFlushResult> flush({
    required List<Map<String, dynamic>> messages,
    String? vmServiceUri,
    String? origin,
  }) async {
    if (!isConfigured) {
      return const FlanFlushResult.failure(
        'Flan relay is not configured for this app.',
      );
    }

    try {
      final response = await _httpClient
          .post(
            _endpoint('api/flush'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              if (appId.isNotEmpty) 'app_id': appId,
              if (vmServiceUri != null) 'vm_service_uri': vmServiceUri,
              if (origin != null) 'origin': origin,
              'messages': messages,
            }),
          )
          .timeout(_requestTimeout);
      final body = _decodeBody(response);
      final accepted = body['accepted'] == true;
      final delivered = body['delivered'] == true;
      if (response.statusCode >= 200 && response.statusCode < 300 && accepted) {
        return FlanFlushResult(
          accepted: true,
          delivered: delivered,
          agentTurn: FlanAgentTurn.fromJson(body['agent_turn']),
        );
      }

      final detail = body['error'] ?? body['reason'];
      return FlanFlushResult.failure(
        detail is String && detail.isNotEmpty
            ? detail
            : 'Flan relay rejected the message batch '
                '(HTTP ${response.statusCode}).',
      );
    } on TimeoutException {
      return const FlanFlushResult.failure('Flan relay timed out.');
    } catch (error) {
      return FlanFlushResult.failure('Flan relay is unavailable: $error');
    }
  }

  /// Asks the relay to hot reload (or [fullRestart]) the `flutter run` behind
  /// this app.
  ///
  /// The app cannot reload itself: nothing in the process has a compiler. The
  /// relay runs beside the `flutter run` that does, so it is asked to signal it
  /// — which is also why this goes to the app's OWN relay and is never relayed
  /// to a peer, unlike a flush looking for an agent.
  ///
  /// Identity is whatever the app knows: `FLAN_APP_ID` if it was defined, the
  /// VM service URI a native app already sends on every flush, and the page's
  /// own origin — which on web is the only one of the three that exists.
  Future<FlanHotReloadResult> hotReload({
    bool fullRestart = false,
    String? vmServiceUri,
    String? origin,
  }) async {
    if (!isConfigured) {
      return const FlanHotReloadResult.failure(
        'Flan relay is not configured for this app.',
      );
    }
    final hasIdentity = appId.isNotEmpty ||
        (vmServiceUri != null && vmServiceUri.isNotEmpty) ||
        (origin != null && origin.isNotEmpty);
    if (!hasIdentity) {
      return const FlanHotReloadResult.failure(
        'Nothing identifies this app to the relay — run it with '
        '--dart-define=FLAN_APP_ID=<name>.',
      );
    }

    final body = jsonEncode(<String, dynamic>{
      if (appId.isNotEmpty) 'app_id': appId,
      if (vmServiceUri != null && vmServiceUri.isNotEmpty)
        'vm_service_uri': vmServiceUri,
      if (origin != null && origin.isNotEmpty) 'origin': origin,
      'full_restart': fullRestart,
    });

    final primary = await _postHotReload(_endpoint('api/hot-reload'), body);
    if (!primary.relayTooOld) return primary.result;

    // This app's relay predates hot reload. Several flan-servers run at once —
    // one per worktree, one per host — and they go stale independently, so the
    // host's standing relay on the default port is very often current when the
    // worktree's is not. Ask it: it is the same machine, so it can see the same
    // `flutter run`.
    final stable = _stableRelayEndpoint();
    if (stable != null) {
      final second = await _postHotReload(stable, body);
      if (!second.relayTooOld) return second.result;
    }

    return FlanHotReloadResult.failure(
      'This app\'s flan relay ($_serverUrl) is too old for hot reload. '
      'Restart it (`./wt restart flan`) after updating the installed binary.',
    );
  }

  /// POST one hot-reload request, separating "this relay cannot do it" from
  /// "this relay says no".
  Future<({FlanHotReloadResult result, bool relayTooOld})> _postHotReload(
    Uri endpoint,
    String body,
  ) async {
    try {
      final response = await _httpClient
          .post(
            endpoint,
            headers: const {'Content-Type': 'application/json'},
            body: body,
          )
          // A reload compiles: the relay's own ceiling for one is 20s, and a
          // client that gave up sooner would report a failure for a reload that
          // then succeeded.
          .timeout(_reloadTimeout);
      // 404 is the one answer that means the ENDPOINT is missing rather than
      // the reload failing, and it is what every relay built before this
      // feature says.
      if (response.statusCode == 404) {
        return (
          result:
              const FlanHotReloadResult.failure('No hot reload on this relay.'),
          relayTooOld: true,
        );
      }
      final decoded = _decodeBody(response);
      final detail = decoded['detail'];
      final via = decoded['via'];
      final ok = decoded['ok'] == true &&
          response.statusCode >= 200 &&
          response.statusCode < 300;
      return (
        result: FlanHotReloadResult(
          needsPageRefresh: decoded['needs_page_refresh'] == true,
          ok: ok,
          detail: detail is String && detail.isNotEmpty
              ? detail
              : ok
                  ? 'Hot reload requested.'
                  : 'Flan relay could not hot reload this app '
                      '(HTTP ${response.statusCode}).',
          via: via is String && via.isNotEmpty ? via : null,
        ),
        relayTooOld: false,
      );
    } on TimeoutException {
      return (
        result: const FlanHotReloadResult.failure('Flan relay timed out.'),
        relayTooOld: false,
      );
    } catch (error) {
      return (
        result:
            FlanHotReloadResult.failure('Flan relay is unavailable: $error'),
        relayTooOld: false,
      );
    }
  }

  /// The same host's relay on the standard port, or null when that is already
  /// where we just asked.
  Uri? _stableRelayEndpoint() {
    final configured = Uri.tryParse(_serverUrl);
    if (configured == null || configured.host.isEmpty) return null;
    final port = configured.hasPort ? configured.port : kDefaultFlanRelayPort;
    if (port == kDefaultFlanRelayPort) return null;
    return configured.replace(
        port: kDefaultFlanRelayPort, path: '/api/hot-reload');
  }

  Future<FlanServerStatus?> getStatus({int? processId}) async {
    if (!isConfigured) return null;

    final query = <String, String>{
      if (appId.isNotEmpty) 'app_id': appId,
      if (appId.isEmpty && processId != null) 'pid': '$processId',
    };
    try {
      final response = await _httpClient
          .get(_endpoint('api/status').replace(queryParameters: query))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return null;
      final body = _decodeBody(response);
      final hasAssociation = body['has_association'] == true;
      return FlanServerStatus(
        hasAssociation: hasAssociation,
        linkedLabel: hasAssociation ? body['linked_label'] as String? : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Asks the relay whether the agent has finished the turn [turn] started.
  /// Null when the relay could not be asked — not the same as "still working".
  Future<FlanAgentTurnState?> getAgentTurn(FlanAgentTurn turn) async {
    if (!isConfigured) return null;
    final query = <String, String>{
      'pid': '${turn.agentPid}',
      'since': '${turn.deliveredAtMs}',
      if (turn.host != null) 'host': turn.host!,
      if (turn.thread != null) 'thread': turn.thread!,
    };
    try {
      final response = await _httpClient
          .get(_endpoint('api/agent-turn').replace(queryParameters: query))
          .timeout(_requestTimeout);
      if (response.statusCode != 200) return null;
      final body = _decodeBody(response);
      final alive = body['alive'] == true;
      final updatedAt = body['status_updated_at_ms'];
      // "shell" is a turn that ended with a background shell still running —
      // not working on anything. A session with a dev server in the
      // background rests there and never says "idle", so counting only "idle"
      // held the queue behind it forever. Decided here too, not just taken
      // from the relay, so an agent host on an older relay still moves.
      final resting = isRestingAgentStatus(body['status']);
      final finishedHere = alive &&
          resting &&
          updatedAt is int &&
          updatedAt > turn.deliveredAtMs;
      final messages = body['messages'];
      return FlanAgentTurnState(
        alive: alive,
        finished: body['finished'] == true || finishedHere,
        idle: resting,
        messages: [
          if (messages is List)
            for (final m in messages)
              if (FlanAgentMessage.fromJson(m) case final message?) message,
        ],
      );
    } catch (_) {
      return null;
    }
  }

  Uri _endpoint(String path) {
    final normalized = _serverUrl.endsWith('/') ? _serverUrl : '$_serverUrl/';
    return Uri.parse(normalized).resolve(path);
  }

  static Map<String, dynamic> _decodeObject(String value) {
    if (value.isEmpty) return const <String, dynamic>{};
    final decoded = jsonDecode(value);
    return decoded is Map<String, dynamic>
        ? decoded
        : const <String, dynamic>{};
  }

  /// Decode a relay response as UTF-8, whatever its headers say.
  ///
  /// `response.body` picks its codec from the Content-Type charset and falls
  /// back to **latin1** when there is none — and the relay sends a bare
  /// `application/json`. Its messages are prose ("Hot reload requested —
  /// SIGUSR1 → pid 4242") shown to the developer verbatim, and latin1-decoding
  /// those UTF-8 bytes turns every dash and arrow into mojibake.
  static Map<String, dynamic> _decodeBody(http.Response response) {
    if (response.bodyBytes.isEmpty) return const <String, dynamic>{};
    return _decodeObject(utf8.decode(response.bodyBytes, allowMalformed: true));
  }
}
