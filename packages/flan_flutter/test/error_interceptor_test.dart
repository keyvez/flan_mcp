import 'dart:ui';

import 'package:flan_flutter/src/services/error_interceptor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Installs the interceptor with a no-op original handler to prevent
/// errors from propagating to the test framework.
void _installSafely(ErrorInterceptor interceptor) {
  FlutterError.onError = (details) {};
  interceptor.install();
}

void main() {
  late ErrorInterceptor interceptor;

  setUp(() {
    interceptor = ErrorInterceptor();
  });

  test('starts with no errors', () {
    expect(interceptor.errors, isEmpty);
    expect(interceptor.latest, isNull);
  });

  test('install replaces FlutterError.onError', () {
    final beforeInstall = FlutterError.onError;
    _installSafely(interceptor);
    expect(FlutterError.onError, isNot(beforeInstall));
  });

  test('captures FlutterError after install', () {
    _installSafely(interceptor);

    var notifications = 0;
    interceptor.addListener(() => notifications++);

    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('test error'),
      library: 'test',
    ));

    expect(interceptor.errors, hasLength(1));
    expect(interceptor.latest, isNotNull);
    expect(interceptor.latest!.summary, contains('test error'));
    expect(interceptor.latest!.details, contains('test error'));
    expect(notifications, 1);
  });

  test('dismiss removes a specific error by id', () {
    _installSafely(interceptor);

    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('error 1'),
    ));
    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('error 2'),
    ));

    expect(interceptor.errors, hasLength(2));

    final firstId = interceptor.errors.first.id;
    interceptor.dismiss(firstId);

    expect(interceptor.errors, hasLength(1));
    expect(interceptor.errors.first.summary, contains('error 2'));
  });

  test('dismiss with non-existent id does nothing', () {
    _installSafely(interceptor);

    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('error'),
    ));

    var notifications = 0;
    interceptor.addListener(() => notifications++);

    interceptor.dismiss(99999);
    expect(interceptor.errors, hasLength(1));
    expect(notifications, 0);
  });

  test('clear removes all errors', () {
    _installSafely(interceptor);

    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('error 1'),
    ));
    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('error 2'),
    ));

    expect(interceptor.errors, hasLength(2));

    interceptor.clear();
    expect(interceptor.errors, isEmpty);
    expect(interceptor.latest, isNull);
  });

  test('clear on empty does not notify', () {
    var notifications = 0;
    interceptor.addListener(() => notifications++);

    interceptor.clear();
    expect(notifications, 0);
  });

  test('caps at 50 errors', () {
    _installSafely(interceptor);

    for (var i = 0; i < 60; i++) {
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('error $i'),
      ));
    }

    expect(interceptor.errors.length, 50);
    // The earliest errors should have been evicted.
    expect(interceptor.errors.first.summary, contains('error 10'));
    expect(interceptor.latest!.summary, contains('error 59'));
  });

  test('InterceptedError has incrementing ids', () {
    _installSafely(interceptor);

    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('a'),
    ));
    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('b'),
    ));

    expect(interceptor.errors[1].id, greaterThan(interceptor.errors[0].id));
  });

  test('captures platform errors after install', () {
    _installSafely(interceptor);

    var notifications = 0;
    interceptor.addListener(() => notifications++);

    // Trigger platform error handler directly
    final platformHandler = PlatformDispatcher.instance.onError;
    expect(platformHandler, isNotNull);

    final result = platformHandler!(
      Exception('platform error'),
      StackTrace.current,
    );

    expect(result, isFalse); // no original handler returns false
    expect(interceptor.errors, hasLength(1));
    expect(interceptor.latest!.summary, contains('platform error'));
    expect(notifications, 1);
  });

  test('platform error forwards to original handler', () {
    var originalCalled = false;
    PlatformDispatcher.instance.onError = (error, stack) {
      originalCalled = true;
      return true;
    };
    interceptor.install();

    final platformHandler = PlatformDispatcher.instance.onError;
    final result = platformHandler!(
      Exception('forwarded error'),
      StackTrace.current,
    );

    expect(result, isTrue); // original returns true
    expect(originalCalled, isTrue);
    expect(interceptor.errors, hasLength(1));
  });

  test('InterceptedError has timestamp', () {
    _installSafely(interceptor);

    final before = DateTime.now();
    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('timed'),
    ));
    final after = DateTime.now();

    final error = interceptor.latest!;
    expect(
      error.timestamp.isAfter(before) || error.timestamp == before,
      isTrue,
    );
    expect(
      error.timestamp.isBefore(after) || error.timestamp == after,
      isTrue,
    );
  });
}
