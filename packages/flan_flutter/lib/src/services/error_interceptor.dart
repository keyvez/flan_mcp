import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Intercepts Flutter framework errors and unhandled exceptions,
/// making them available for forwarding to the connected agent.
class ErrorInterceptor extends ChangeNotifier {
  final _errors = Queue<InterceptedError>();
  static const _maxErrors = 50;

  FlutterExceptionHandler? _originalFlutterErrorHandler;
  ErrorCallback? _originalPlatformErrorHandler;

  /// Installs error interception hooks.
  void install() {
    _originalFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = _handleFlutterError;

    _originalPlatformErrorHandler =
        PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = _handlePlatformError;
  }

  /// All intercepted errors, newest last.
  List<InterceptedError> get errors =>
      UnmodifiableListView(_errors);

  /// The most recent error, or `null` if none.
  InterceptedError? get latest => _errors.isEmpty ? null : _errors.last;

  /// Dismiss (remove) a specific error by its id.
  void dismiss(int id) {
    final removed = _errors.length;
    _errors.removeWhere((e) => e.id == id);
    if (_errors.length != removed) {
      notifyListeners();
    }
  }

  /// Clear all intercepted errors.
  void clear() {
    if (_errors.isEmpty) return;
    _errors.clear();
    notifyListeners();
  }

  void _handleFlutterError(FlutterErrorDetails details) {
    _addError(
      summary: details.exceptionAsString(),
      details: details.toString(),
    );

    // Forward to the original handler (which renders the red error screen).
    final original = _originalFlutterErrorHandler;
    if (original != null) {
      original(details);
    }
  }

  bool _handlePlatformError(Object error, StackTrace stack) {
    _addError(
      summary: error.toString(),
      details: '$error\n$stack',
    );

    // Forward to the original handler if one existed.
    final original = _originalPlatformErrorHandler;
    if (original != null) {
      return original(error, stack);
    }
    return false;
  }

  void _addError({required String summary, required String details}) {
    _errors.add(InterceptedError(
      id: InterceptedError._nextId++,
      summary: summary,
      details: details,
      timestamp: DateTime.now(),
    ));
    if (_errors.length > _maxErrors) {
      _errors.removeFirst();
    }
    notifyListeners();
  }
}

/// A single intercepted error.
class InterceptedError {
  InterceptedError({
    required this.id,
    required this.summary,
    required this.details,
    required this.timestamp,
  });

  static int _nextId = 0;

  final int id;
  final String summary;
  final String details;
  final DateTime timestamp;
}
