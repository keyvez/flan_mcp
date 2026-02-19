import 'dart:async';

import 'package:logging/logging.dart' as logging;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Exception thrown when an operation is attempted without an active connection.
class NotConnectedException implements Exception {
  const NotConnectedException();

  @override
  String toString() =>
      'Not connected to any app. Use app.connect tool first with the VM service URI.';
}

/// Exception thrown when a VM service extension call fails.
class VmServiceExtensionException implements Exception {
  VmServiceExtensionException(this.message, this.error, this.stackTrace);

  final String message;
  final String? error;
  final String? stackTrace;

  @override
  String toString() {
    final buffer = StringBuffer(message);
    if (error != null) {
      buffer.write('\nError: $error');
    }
    if (stackTrace != null) {
      buffer.write('\nStack trace: $stackTrace');
    }
    return buffer.toString();
  }
}

/// Result of a hot reload operation.
class HotReloadResult {
  const HotReloadResult({required this.success, this.details});

  final bool success;
  final String? details;
}

/// Manages connection to a Flutter app's VM service and provides
/// wrapper methods for custom flan.* extensions.
class VmServiceConnector {
  VmServiceConnector() : _logger = logging.Logger('VmServiceConnector');
  static const String _userMessageQueuedEventKind = 'flan.userMessageQueued';
  static const String _annotationChangedEventKind = 'flan.annotationChanged';

  final logging.Logger _logger;
  VmService? _service;
  String? _isolateId;
  StreamSubscription<Event>? _serviceEventSubscription;
  StreamSubscription<Event>? _extensionEventSubscription;

  final Map<String, String?> _registeredServices = {};
  final Map<String, List<Completer<String?>>> _pendingServiceRequests = {};
  bool _hotRestarting = false;

  /// Called when the connection is lost unexpectedly (e.g. app crash,
  /// WebSocket close). Set by [VmServiceContext] to clean up state.
  void Function()? onDisconnect;

  /// Called when the Flutter app emits a user-message-queued extension event.
  void Function()? onUserMessageQueued;

  /// Called when the Flutter app emits an annotation-changed extension event.
  void Function()? onAnnotationChanged;

  /// Returns true if currently connected to a VM service.
  bool get isConnected => _service != null && _isolateId != null;

  /// Connects to a VM service at the given URI.
  ///
  /// Throws an exception if connection fails.
  Future<void> connect(String uri) async {
    if (isConnected) {
      _logger.warning('Already connected, disconnecting first');
      await disconnect();
    }

    _logger.info('Connecting to VM service at $uri');

    try {
      _service = await vmServiceConnectUri(uri);

      // Detect unexpected connection loss (app crash, WebSocket close).
      // Skipped during hot restart since the connection loss is expected
      // and the restart method handles reconnection itself.
      unawaited(
        _service!.onDone.then((_) {
          if (_service != null && !_hotRestarting) {
            _logger.warning('VM service connection lost unexpectedly');
            unawaited(_serviceEventSubscription?.cancel());
            unawaited(_extensionEventSubscription?.cancel());
            _serviceEventSubscription = null;
            _extensionEventSubscription = null;
            _service = null;
            _isolateId = null;
            _registeredServices.clear();
            _pendingServiceRequests.clear();
            onDisconnect?.call();
          }
        }),
      );

      _serviceEventSubscription = _service!.onServiceEvent.listen((e) {
        switch (e.kind) {
          case EventKind.kServiceRegistered:
            final serviceName = e.service!;
            _registeredServices[serviceName] = e.method;
            _logger.info('Service registered: $serviceName -> ${e.method}');
            if (_pendingServiceRequests.containsKey(serviceName)) {
              for (final completer in _pendingServiceRequests[serviceName]!) {
                completer.complete(e.method);
              }
              _pendingServiceRequests.remove(serviceName);
            }
          case EventKind.kServiceUnregistered:
            _registeredServices.remove(e.service!);
            _logger.info('Service unregistered: ${e.service}');
          default:
            _logger.info('Service event: $e');
        }
      });
      await _service!.streamListen(EventStreams.kService);

      _extensionEventSubscription = _service!.onExtensionEvent.listen((e) {
        if (e.kind == EventKind.kExtension) {
          if (e.extensionKind == _userMessageQueuedEventKind) {
            _logger.fine(
              'Received $_userMessageQueuedEventKind extension event',
            );
            onUserMessageQueued?.call();
          } else if (e.extensionKind == _annotationChangedEventKind) {
            _logger.fine(
              'Received $_annotationChangedEventKind extension event',
            );
            onAnnotationChanged?.call();
          }
        }
      });
      await _service!.streamListen(EventStreams.kExtension);

      _isolateId = await _findIsolateWithFlanExtensions();
      _logger.info('Connected to isolate: $_isolateId');
    } catch (err) {
      await _serviceEventSubscription?.cancel();
      await _extensionEventSubscription?.cancel();
      _serviceEventSubscription = null;
      _extensionEventSubscription = null;
      _service = null;
      _isolateId = null;
      _logger.severe('Failed to connect to VM service', err);
      rethrow;
    }
  }

  /// Disconnects from the current VM service.
  Future<void> disconnect() async {
    if (_service != null) {
      _logger.info('Disconnecting from VM service');
      await _serviceEventSubscription?.cancel();
      await _extensionEventSubscription?.cancel();
      _serviceEventSubscription = null;
      _extensionEventSubscription = null;
      await _service!.dispose();
      _service = null;
      _isolateId = null;
      _registeredServices.clear();
      _pendingServiceRequests.clear();
      _logger.fine('Disconnected');
    }
  }

  /// Returns a future that completes with the registered method name for the
  /// given [serviceName].
  ///
  /// If the service is already registered, returns immediately.
  /// Otherwise, waits up to [timeout] for the service to be registered.
  /// Returns `null` if the service is not registered within the timeout.
  Future<String?> waitForServiceRegistration(
    String serviceName, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (_registeredServices.containsKey(serviceName)) {
      return _registeredServices[serviceName];
    }

    final completer = Completer<String?>();
    _pendingServiceRequests.putIfAbsent(serviceName, () => []).add(completer);

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingServiceRequests[serviceName]?.remove(completer);
        if (_pendingServiceRequests[serviceName]?.isEmpty ?? false) {
          _pendingServiceRequests.remove(serviceName);
        }
        return null;
      },
    );
  }

  /// Ensures that there is an active connection.
  ///
  /// Throws [NotConnectedException] if not connected.
  void _ensureConnected() {
    if (!isConnected) {
      throw const NotConnectedException();
    }
  }

  /// Calls a VM service extension and handles the response.
  Future<Map<String, dynamic>> _callExtension(
    String extensionName,
    Map<String, dynamic> args,
  ) async {
    _ensureConnected();

    _logger.fine('Calling extension: $extensionName with args: $args');

    try {
      final response = await _service!.callServiceExtension(
        'ext.flutter.$extensionName',
        isolateId: _isolateId,
        args: args,
      );

      final responseJson = response.json;
      if (responseJson == null) {
        throw VmServiceExtensionException(
          'Extension $extensionName returned null response',
          null,
          null,
        );
      }

      _logger.finest('Extension response: $responseJson');

      // Check if the response indicates an error
      if (responseJson['status'] == 'Error') {
        throw VmServiceExtensionException(
          'Extension $extensionName failed',
          responseJson['error'] as String?,
          responseJson['stackTrace'] as String?,
        );
      }

      return responseJson;
    } catch (err) {
      _logger.severe('Error calling extension $extensionName', err);
      rethrow;
    }
  }

  /// Gets the list of interactive elements in the widget tree.
  ///
  /// Throws [NotConnectedException] if not connected.
  Future<Map<String, dynamic>> getInteractiveElements() {
    return _callExtension('flan.interactiveElements', {});
  }

  /// Taps an element matching the given criteria.
  ///
  /// [matcher] should contain one of:
  /// - 'key': matches by `ValueKey<String>`
  /// - 'text': matches by visible text content
  /// - 'type': matches by widget type name
  /// - 'x' and 'y': screen coordinates for tapping at a specific position
  ///
  /// Throws [NotConnectedException] if not connected.
  Future<Map<String, dynamic>> tap(Map<String, dynamic> matcher) {
    return _callExtension('flan.tap', matcher);
  }

  /// Enters text into a text field matching the given criteria.
  ///
  /// [matcher] should contain either 'key' or 'text' field.
  /// [input] is the text to enter.
  /// Throws [NotConnectedException] if not connected.
  Future<Map<String, dynamic>> enterText(
    Map<String, dynamic> matcher,
    String input,
  ) {
    final args = Map<String, dynamic>.from(matcher)..['input'] = input;
    return _callExtension('flan.enterText', args);
  }

  /// Scrolls until an element matching the given criteria is visible.
  ///
  /// [matcher] should contain either 'key' or 'text' field.
  /// Throws [NotConnectedException] if not connected.
  Future<Map<String, dynamic>> scrollToElement(Map<String, dynamic> matcher) {
    return _callExtension('flan.scrollTo', matcher);
  }

  /// Gets the collected application logs.
  ///
  /// Throws [NotConnectedException] if not connected.
  Future<Map<String, dynamic>> getLogs() {
    return _callExtension('flan.getLogs', {});
  }

  /// Takes screenshots of all views in the app.
  ///
  /// Returns a list of base64-encoded PNG images.
  /// Throws [NotConnectedException] if not connected.
  Future<Map<String, dynamic>> takeScreenshots() {
    return _callExtension('flan.takeScreenshots', {});
  }

  // --- User message methods ---

  /// Consumes pending user messages from the Flutter app.
  Future<Map<String, dynamic>> consumeUserMessages() {
    return _callExtension('flan.consumeUserMessages', {});
  }

  /// Peeks at pending user messages without consuming them.
  /// Returns the count of pending messages.
  Future<Map<String, dynamic>> peekUserMessages() {
    return _callExtension('flan.peekUserMessages', {});
  }

  /// Sends a message to the agent queue in the Flutter app.
  Future<Map<String, dynamic>> sendToAgent(Map<String, dynamic> message) {
    return _callExtension('flan.sendToAgent', message);
  }

  /// Tells the Flutter app whether the agent is actively listening.
  Future<Map<String, dynamic>> setAgentListening(bool listening) {
    return _callExtension('flan.setAgentListening', {
      'listening': listening.toString(),
    });
  }

  /// Tells the Flutter app whether an MCP host is connected and push-capable.
  Future<Map<String, dynamic>> setHostConnectionState({
    required bool connected,
    required bool pushCapable,
  }) {
    return _callExtension('flan.setHostConnectionState', {
      'connected': connected.toString(),
      'pushCapable': pushCapable.toString(),
    });
  }

  /// Performs a hot reload of the Flutter app.
  ///
  /// Returns a [HotReloadResult] with success status and details.
  /// Throws [NotConnectedException] if not connected.
  Future<HotReloadResult> hotReload() async {
    _ensureConnected();

    _logger.info('Performing hot reload');

    try {
      final method = await waitForServiceRegistration('reloadSources');
      if (method == null) {
        final report = await _service!.reloadSources(_isolateId!);
        _logger.fine('Hot reload completed: success=${report.success}');
        return HotReloadResult(
          success: report.success ?? false,
          details: report.json.toString(),
        );
      } else {
        final result = await _service!.callMethod(
          method,
          isolateId: _isolateId!,
        );
        _logger.fine('Hot reload completed: result=${result.json}');
        final json = result.json ?? {};
        final success = json['type'] == 'Success';
        final reason =
            json['message'] as String? ??
            json['reason'] as String? ??
            (success ? null : json.toString());
        return HotReloadResult(success: success, details: reason);
      }
    } catch (err) {
      _logger.severe('Hot reload failed', err);
      rethrow;
    }
  }

  // --- Inspector methods ---

  /// Enables the widget inspector mode.
  Future<Map<String, dynamic>> enableInspector() {
    return _callExtension('flan.inspectorEnable', {});
  }

  /// Disables the widget inspector mode.
  Future<Map<String, dynamic>> disableInspector() {
    return _callExtension('flan.inspectorDisable', {});
  }

  /// Gets the current inspector selection data.
  Future<Map<String, dynamic>> getInspectorSelection() {
    return _callExtension('flan.inspectorGetSelection', {});
  }

  /// Cycles to the next element at the current inspector point.
  Future<Map<String, dynamic>> inspectorCycleElement() {
    return _callExtension('flan.inspectorCycleElement', {});
  }

  /// Programmatically inspects the widget at the given coordinates.
  Future<Map<String, dynamic>> inspectorSelectAt(double x, double y) {
    return _callExtension('flan.inspectorSelectAt', {'x': x, 'y': y});
  }

  // --- Annotation methods ---

  /// Enables annotation/markup drawing mode.
  Future<Map<String, dynamic>> enableAnnotationMode() {
    return _callExtension('flan.annotationEnable', {});
  }

  /// Disables annotation/markup drawing mode.
  Future<Map<String, dynamic>> disableAnnotationMode() {
    return _callExtension('flan.annotationDisable', {});
  }

  /// Gets all annotations with their bounds and text.
  Future<Map<String, dynamic>> getAnnotations() {
    return _callExtension('flan.annotationGetAll', {});
  }

  /// Clears all annotations.
  Future<Map<String, dynamic>> clearAnnotations() {
    return _callExtension('flan.annotationClear', {});
  }

  /// Removes an annotation by its id.
  Future<Map<String, dynamic>> removeAnnotation(String id) {
    return _callExtension('flan.annotationRemove', {'id': id});
  }

  /// Programmatically adds an annotation with the given bounds and text.
  Future<Map<String, dynamic>> addAnnotation({
    required double x,
    required double y,
    required double width,
    required double height,
    required String text,
  }) {
    return _callExtension('flan.annotationAdd', {
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'text': text,
    });
  }

  /// Performs a hot restart of the Flutter app (full state reset).
  ///
  /// Returns true if the restart was successful.
  /// Throws [NotConnectedException] if not connected.
  Future<bool> hotRestart() async {
    _ensureConnected();

    _logger.info('Performing hot restart');
    _hotRestarting = true;

    try {
      // Hot restart uses reloadSources with pause=false, but the actual
      // restart is done via the Flutter daemon's 'hotRestart' registered
      // service method, or by calling reloadSources with force=true.
      final method = await waitForServiceRegistration('hotRestart');
      if (method != null) {
        final result = await _service!.callMethod(
          method,
          isolateId: _isolateId!,
        );
        _logger.fine('Hot restart completed: result=${result.json}');
        // After restart, the old isolate is destroyed and a new one is
        // created. The new isolate needs time to register its extensions
        // before we can find it.
        _isolateId = await _findIsolateWithFlanExtensionsWithRetry();
        return result.json?['type'] == 'Success';
      } else {
        // Fallback: call reloadSources with force compile
        final report = await _service!.reloadSources(_isolateId!, force: true);
        _logger.fine('Hot restart (forced reload): success=${report.success}');
        return report.success ?? false;
      }
    } catch (err) {
      _logger.severe('Hot restart failed', err);
      // After restart, isolate ID may have changed, try to re-find
      try {
        _isolateId = await _findIsolateWithFlanExtensionsWithRetry();
      } catch (_) {
        // Ignore if re-find fails
      }
      rethrow;
    } finally {
      _hotRestarting = false;
    }
  }

  /// Finds the first isolate with flan extensions, retrying with a delay
  /// to allow a newly restarted isolate time to register its extensions.
  Future<String> _findIsolateWithFlanExtensionsWithRetry({
    int maxAttempts = 10,
    Duration delay = const Duration(milliseconds: 500),
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await _findIsolateWithFlanExtensions();
      } catch (err) {
        if (attempt == maxAttempts) rethrow;
        _logger.fine(
          'Isolate not ready yet (attempt $attempt/$maxAttempts), '
          'retrying in ${delay.inMilliseconds}ms',
        );
        await Future<void>.delayed(delay);
      }
    }
    // Unreachable, but satisfies the type system.
    throw StateError('Retry loop exited unexpectedly');
  }

  /// Finds the first isolate that has the flan extensions.
  ///
  /// Throws an exception if no suitable isolate is found.
  Future<String> _findIsolateWithFlanExtensions() async {
    final vm = await _service!.getVM();
    if (vm.isolates == null || vm.isolates!.isEmpty) {
      throw Exception('No isolates found in the VM');
    }

    // Find the first isolate that has the flan.getLogs extension
    for (final isolateRef in vm.isolates!) {
      if (isolateRef.id == null) {
        continue;
      }

      try {
        final isolate = await _service!.getIsolate(isolateRef.id!);
        final hasExtension =
            isolate.extensionRPCs?.any(
              (ext) => ext == 'ext.flutter.flan.getLogs',
            ) ??
            false;

        if (hasExtension) {
          return isolateRef.id!;
        }
      } catch (err) {
        _logger.warning(
          'Failed to check extensions for isolate ${isolateRef.id}',
          err,
        );
        continue;
      }
    }

    throw Exception(
      'No isolate found with ext.flutter.flan.getLogs extension. '
      'Make sure the Flutter app has flan_flutter initialized.',
    );
  }
}
