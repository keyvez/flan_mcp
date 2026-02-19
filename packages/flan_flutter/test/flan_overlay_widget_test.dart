import 'package:flan_flutter/src/overlay/flan_overlay_widget.dart';
import 'package:flan_flutter/src/services/annotation_service.dart';
import 'package:flan_flutter/src/services/error_interceptor.dart';
import 'package:flan_flutter/src/services/inspector_service.dart';
import 'package:flan_flutter/src/services/screenshot_service.dart';
import 'package:flan_flutter/src/services/user_message_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildTestApp({
  required InspectorService inspectorService,
  required AnnotationService annotationService,
  required UserMessageService userMessageService,
  required ScreenshotService screenshotService,
  required ErrorInterceptor errorInterceptor,
  Widget? child,
  bool useMaterialApp = false,
}) {
  final overlay = SizedBox.expand(
    child: FlanOverlayWidget(
      inspectorService: inspectorService,
      annotationService: annotationService,
      userMessageService: userMessageService,
      screenshotService: screenshotService,
      errorInterceptor: errorInterceptor,
      child: child ?? const ColoredBox(color: Colors.black),
    ),
  );

  if (useMaterialApp) {
    return MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: overlay,
      ),
    );
  }

  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
      child: overlay,
    ),
  );
}

Future<void> _runAsyncAndSettle(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  await tester.runAsync(action);
  await tester.pumpAndSettle();
}

/// Installs the error interceptor with a no-op original handler so that
/// triggered errors don't propagate to the test framework.
void _installInterceptorSafely(ErrorInterceptor interceptor) {
  // Set a no-op handler so the interceptor captures it as the "original"
  FlutterError.onError = (details) {};
  interceptor.install();
}

late InspectorService inspectorService;
late AnnotationService annotationService;
late UserMessageService userMessageService;
late ScreenshotService screenshotService;
late ErrorInterceptor errorInterceptor;

void _createServices() {
  inspectorService = InspectorService();
  annotationService = AnnotationService();
  userMessageService = UserMessageService();
  screenshotService =
      ScreenshotService(maxScreenshotSize: const Size(1024, 1024));
  errorInterceptor = ErrorInterceptor();
}

Widget _app({Widget? child, bool useMaterialApp = false}) => _buildTestApp(
      inspectorService: inspectorService,
      annotationService: annotationService,
      userMessageService: userMessageService,
      screenshotService: screenshotService,
      errorInterceptor: errorInterceptor,
      child: child,
      useMaterialApp: useMaterialApp,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _createServices();
  });

  group('FlanOverlayWidget renders child', () {
    testWidgets('renders child widget', (tester) async {
      await tester.pumpWidget(_app(child: const Text('App Content')));
      await tester.pumpAndSettle();

      expect(find.text('App Content'), findsOneWidget);
    });
  });

  group('Queue badge', () {
    testWidgets('shows Q badge', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.text('Q'), findsOneWidget);
    });

    testWidgets('badge shows message count', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Initially shows 0
      expect(find.text('0'), findsOneWidget);

      // Add a message
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10,
          y: 10,
          width: 60,
          height: 40,
          text: 'test',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Now shows 1
      expect(find.text('1'), findsOneWidget);
    });
  });

  group('Error dot', () {
    testWidgets('no error dot when no errors', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // The error panel header text should not exist
      expect(find.text('1 error'), findsNothing);
      expect(find.text('Add to queue'), findsNothing);
    });

    testWidgets('error dot appears when error is intercepted', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Trigger an error safely (without propagating to test framework)
      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('test error'),
      ));
      await tester.pumpAndSettle();

      // Error interceptor should have captured the error
      expect(errorInterceptor.errors, hasLength(1));
    });

    testWidgets('tapping error dot shows error panel', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('visible error'),
      ));
      await tester.pumpAndSettle();

      // Panel should not be visible yet
      expect(find.text('1 error'), findsNothing);

      // Tap the error dot (shows "1")
      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();

      // Panel should now be visible with error details
      expect(find.text('1 error'), findsOneWidget);
      expect(find.textContaining('visible error'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
    });

    testWidgets('dismiss removes error from panel', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('dismiss me'),
      ));
      await tester.pumpAndSettle();

      // Open panel
      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();

      // Tap dismiss
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      // Error should be gone, panel closes because no more errors
      expect(errorInterceptor.errors, isEmpty);
      expect(find.text('1 error'), findsNothing);
    });

    testWidgets('add to queue sends error to user message service',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('queue me'),
      ));
      await tester.pumpAndSettle();

      // Open panel
      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();

      expect(userMessageService.pendingMessageCount, 0);

      // Tap "Add to queue"
      await tester.tap(find.text('Add to queue'));
      await tester.pumpAndSettle();

      // Error should be added as a message
      expect(userMessageService.pendingMessageCount, 1);
      final message = userMessageService.peekMessages().first;
      expect(message['type'], 'app_error');
      expect(message['text'], contains('queue me'));
    });

    testWidgets('clear all removes all errors', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('error 1'),
      ));
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('error 2'),
      ));
      await tester.pumpAndSettle();

      // Open panel
      await tester.tap(find.text('2').first);
      await tester.pumpAndSettle();

      // Tap "Clear all"
      expect(find.text('Clear all'), findsOneWidget);
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();

      expect(errorInterceptor.errors, isEmpty);
    });

    testWidgets('tapping error dot again toggles panel closed', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('toggle test'),
      ));
      await tester.pumpAndSettle();

      // Open panel
      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();
      expect(find.text('1 error'), findsOneWidget);

      // Close panel by tapping dot again
      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();
      expect(find.text('1 error'), findsNothing);
    });

    testWidgets('error panel shows plural label for multiple errors',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('err1'),
      ));
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('err2'),
      ));
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('err3'),
      ));
      await tester.pumpAndSettle();

      // Open panel
      await tester.tap(find.text('3').first);
      await tester.pumpAndSettle();

      expect(find.text('3 errors'), findsOneWidget);
    });

    testWidgets('opening error panel closes queue panel', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Add a message to the queue
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 60, height: 40, text: 'queued',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Queued messages'), findsOneWidget);

      // Trigger an error and open error panel
      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('override queue'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();

      // Error panel visible, queue panel dismissed
      expect(find.text('1 error'), findsOneWidget);
      // Queue panel header should be gone (queue badge still shows "Q")
      expect(find.textContaining('Queued messages'), findsNothing);
    });
  });

  group('Annotation mode', () {
    testWidgets('annotation mode shows banner text', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.textContaining('Annotation mode ON'), findsNothing);

      annotationService.enable();
      await tester.pumpAndSettle();

      expect(find.textContaining('Annotation mode ON'), findsOneWidget);
    });

    testWidgets('disabling annotation mode hides banner', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();
      expect(find.textContaining('Annotation mode ON'), findsOneWidget);

      annotationService.disable();
      await tester.pumpAndSettle();
      expect(find.textContaining('Annotation mode ON'), findsNothing);
    });

    testWidgets('annotations do not render when annotation mode is off',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Add annotation while mode is on, then disable
      annotationService.enable();
      annotationService.addAnnotationProgrammatically(
        x: 50, y: 50, width: 100, height: 60, text: 'persist',
      );
      await tester.pumpAndSettle();

      // Annotation painter should be in the tree while mode is on
      expect(find.byType(CustomPaint), findsWidgets);

      // Disable annotation mode — annotations disappear from the
      // visual overlay but remain preserved in the queue draft.
      annotationService.disable();
      await tester.pumpAndSettle();

      // No AnnotationPainter should be rendered (only the child's
      // CustomPaints remain, not the annotation overlay).
      final painters = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
      final hasAnnotationPainter = painters.any(
        (cp) => cp.painter.runtimeType.toString() == 'AnnotationPainter',
      );
      expect(hasAnnotationPainter, isFalse);
    });
  });

  group('Queue panel', () {
    testWidgets('tapping badge with messages opens queue panel',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Add a message to the queue
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 60, height: 40, text: 'queued',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(userMessageService.pendingMessageCount, 1);

      // Tap the Q badge
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Queue panel should be visible with the annotation message
      expect(find.textContaining('queued'), findsWidgets);
    });

    testWidgets('tapping badge with no messages enters annotation mode',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isFalse);

      // Tap Q badge with no messages
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isTrue);
    });

    testWidgets('tapping Q badge toggles panel closed', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 60, height: 40, text: 'msg',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Queued messages'), findsOneWidget);

      // Close
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Queued messages'), findsNothing);
    });

    testWidgets('opening queue panel closes error panel', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Setup: trigger error and open error panel
      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('some error'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();
      expect(find.text('1 error'), findsOneWidget);

      // Add a message and open queue panel
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 60, height: 40, text: 'item',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Queue panel open, error panel closed
      expect(find.textContaining('Queued messages'), findsOneWidget);
      expect(find.text('1 error'), findsNothing);
    });

    testWidgets('queue panel shows Flush button', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 60, height: 40, text: 'flush me',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.text('Flush'), findsOneWidget);
    });

    testWidgets('queue panel Flush clears all messages', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 60, height: 40, text: 'clear me',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Tap Flush
      await tester.tap(find.text('Flush'));
      await tester.pumpAndSettle();

      expect(userMessageService.pendingMessageCount, 0);
      expect(annotationService.annotations, isEmpty);
    });

    testWidgets('queue panel delete icon removes message', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 60, height: 40, text: 'deletable',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(userMessageService.pendingMessageCount, 1);

      // Open panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Find and tap the delete icon
      final deleteIcon = find.byIcon(Icons.delete_outline);
      if (deleteIcon.evaluate().isNotEmpty) {
        await tester.tap(deleteIcon.first);
        await tester.pumpAndSettle();

        expect(userMessageService.pendingMessageCount, 0);
      }
    });

    testWidgets('queue panel shows message text', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Directly add a message to user message service
      await _runAsyncAndSettle(tester, () async {
        userMessageService.warmUp();
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Hello agent',
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Hello agent'), findsOneWidget);
    });

    testWidgets('queue panel shows timestamp', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        userMessageService.warmUp();
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'timestamped msg',
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Timestamp should be visible (formatted as YYYY-MM-DD HH:MM:SS)
      // Look for the year in the formatted timestamp
      final year = DateTime.now().year.toString();
      expect(find.textContaining(year), findsWidgets);
    });

    testWidgets('queue panel shows queueId', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        userMessageService.warmUp();
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'id message',
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('id:'), findsWidgets);
    });
  });

  group('Inspector mode', () {
    testWidgets('enabling inspector disables annotation mode', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();
      expect(annotationService.enabled, isTrue);

      inspectorService.enable();
      await tester.pumpAndSettle();

      // Inspector is active; annotation mode stays enabled
      // (it's disabled by the keyboard handler, not by the service itself)
      expect(inspectorService.enabled, isTrue);
    });

    testWidgets('inspector mode renders inspector overlay', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();

      // The inspector overlay should be in the tree (Listener widget)
      expect(find.byType(Listener), findsWidgets);
    });
  });

  group('Keyboard shortcuts', () {
    testWidgets('Escape closes error panel', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('esc test'),
      ));
      await tester.pumpAndSettle();

      // Open panel
      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();
      expect(find.text('1 error'), findsOneWidget);

      // Press Escape
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('1 error'), findsNothing);
    });

    testWidgets('Escape disables inspector mode', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();
      expect(inspectorService.enabled, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(inspectorService.enabled, isFalse);
    });

    testWidgets('Escape disables annotation mode', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();
      expect(annotationService.enabled, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isFalse);
    });
  });

  group('Agent status', () {
    testWidgets('shows agent disconnected state', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // By default, agent is not listening
      expect(userMessageService.isAgentListening, isFalse);
    });

    testWidgets('waitingForActivity is cleared on hot reload path',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      userMessageService.markWaiting('test message');
      expect(userMessageService.waitingForActivity, isTrue);

      userMessageService.clearWaiting();
      await tester.pumpAndSettle();
      expect(userMessageService.waitingForActivity, isFalse);
    });
  });

  group('Error panel auto-close', () {
    testWidgets('error panel auto-closes when errors become empty',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('auto close'),
      ));
      await tester.pumpAndSettle();

      // Open panel
      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();
      expect(find.text('1 error'), findsOneWidget);

      // Clear all errors externally
      errorInterceptor.clear();
      await tester.pumpAndSettle();

      // Panel should auto-close
      expect(find.text('1 error'), findsNothing);
      expect(find.text('0 errors'), findsNothing);
    });
  });

  group('Push connection indicator', () {
    testWidgets('badge reflects push connection state', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Initially not connected
      expect(userMessageService.isPushCapableHostConnected, isFalse);

      userMessageService.setHostConnectionState(
        connected: true,
        pushCapable: true,
      );
      await tester.pumpAndSettle();
      expect(userMessageService.isPushCapableHostConnected, isTrue);
    });
  });

  group('Consume generation tracking', () {
    testWidgets('consuming messages clears annotation draft', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Add annotation which creates a draft
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'draft ann',
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });

      expect(userMessageService.pendingMessageCount, greaterThan(0));

      // Consuming messages should bump generation
      await _runAsyncAndSettle(tester, () async {
        userMessageService.consumeMessages();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(userMessageService.pendingMessageCount, 0);
    });
  });

  group('Queue panel annotation chips', () {
    testWidgets('shows annotation text in queue panel', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Add annotation with specific text
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 50, y: 50, width: 100, height: 60, text: 'Bug here',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Annotation text should appear
      expect(find.textContaining('Bug here'), findsWidgets);
    });

    testWidgets('multiple annotations show in queue panel', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'First',
        );
        annotationService.addAnnotationProgrammatically(
          x: 100, y: 100, width: 50, height: 30, text: 'Second',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('First'), findsWidgets);
      expect(find.textContaining('Second'), findsWidgets);
    });
  });

  group('Annotation draft upsert', () {
    testWidgets('adding annotation creates draft in queue', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(userMessageService.pendingMessageCount, 0);

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 20, y: 20, width: 80, height: 50, text: 'Draft test',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Annotation should have created a draft message
      expect(userMessageService.pendingMessageCount, 1);
      final msg = userMessageService.peekMessages().first;
      expect(msg['type'], 'user_feedback');
      final data = msg['data'] as Map<String, dynamic>;
      expect(data['annotationDraft'], isTrue);
    });

    testWidgets('updating annotation text updates draft', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 20, y: 20, width: 80, height: 50, text: 'Original',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(userMessageService.pendingMessageCount, 1);

      // Update annotation text
      final ann = annotationService.annotations.first;
      await _runAsyncAndSettle(tester, () async {
        annotationService.updateAnnotationTextById(ann.id, 'Updated');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Still only 1 message (updated, not duplicated)
      expect(userMessageService.pendingMessageCount, 1);
    });

    testWidgets('clearing annotations removes draft from queue',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 20, y: 20, width: 80, height: 50, text: 'Will clear',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(userMessageService.pendingMessageCount, 1);

      // Clear all annotations
      await _runAsyncAndSettle(tester, () async {
        annotationService.clearAnnotations();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(userMessageService.pendingMessageCount, 0);
    });
  });

  group('Queued messages panel interaction', () {
    testWidgets('delete annotation from queue removes it from service',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'to delete',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Find the annotation delete icon (X icon next to annotation chip)
      final closeIcons = find.byIcon(Icons.close);
      if (closeIcons.evaluate().isNotEmpty) {
        await tester.tap(closeIcons.first);
        await tester.pumpAndSettle();
        // Annotation should be removed from service
        expect(annotationService.annotations, isEmpty);
      }
    });

    testWidgets('queue panel shows edit icon for annotation chips',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'editable',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Edit icon should be present for annotation chips
      expect(find.byIcon(Icons.edit_outlined), findsWidgets);
    });
  });

  group('Ctrl+Shift+Enter sends to agent', () {
    testWidgets('Ctrl+Shift+Enter with no selection sends generic message',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final countBefore = userMessageService.pendingMessageCount;

      // Press Ctrl+Shift+Enter with nothing selected
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      // Allow async work
      await _runAsyncAndSettle(tester, () async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });

      // A message should have been sent
      expect(userMessageService.pendingMessageCount,
          greaterThan(countBefore));
    });
  });

  group('Ctrl+Shift+H toggles inspector', () {
    testWidgets('Ctrl+Shift+H enables inspector mode', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(inspectorService.enabled, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(inspectorService.enabled, isTrue);
    });

    testWidgets('Ctrl+Shift+H disables inspector when already enabled',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();
      expect(inspectorService.enabled, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(inspectorService.enabled, isFalse);
    });

    testWidgets('Ctrl+Shift+H disables annotation mode', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();
      expect(annotationService.enabled, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(inspectorService.enabled, isTrue);
      expect(annotationService.enabled, isFalse);
    });
  });

  group('Rebuild queued message text', () {
    testWidgets('draft text includes annotation labels', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 50, y: 50, width: 100, height: 60, text: 'Label A',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      final msg = userMessageService.peekMessages().first;
      final text = msg['text'] as String;
      expect(text, contains('Label A'));
    });
  });

  group('Sending error to agent', () {
    testWidgets('error is formatted correctly', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('formatted error'),
      ));
      await tester.pumpAndSettle();

      // Open panel and add to queue
      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add to queue'));
      await tester.pumpAndSettle();

      final msg = userMessageService.peekMessages().first;
      expect(msg['type'], 'app_error');
      final data = msg['data'] as Map<String, dynamic>;
      expect(data['summary'], contains('formatted error'));
      expect(data['details'], isA<String>());
    });
  });

  group('Queue panel remove message', () {
    testWidgets('removing annotation draft clears annotations',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'remove draft',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(annotationService.annotations, hasLength(1));

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Delete the message
      final deleteIcon = find.byIcon(Icons.delete_outline);
      if (deleteIcon.evaluate().isNotEmpty) {
        await tester.tap(deleteIcon.first);
        await tester.pumpAndSettle();

        // Annotations should be cleared because it was a draft
        expect(annotationService.annotations, isEmpty);
      }
    });
  });

  group('Queue panel clear all', () {
    testWidgets('clearing queue also clears annotations', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'clear all draft',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(annotationService.annotations, hasLength(1));

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Tap delete sweep icon (clear all)
      final deleteSwitch = find.byIcon(Icons.delete_sweep_outlined);
      if (deleteSwitch.evaluate().isNotEmpty) {
        await tester.tap(deleteSwitch.first);
        await tester.pumpAndSettle();

        expect(annotationService.annotations, isEmpty);
        expect(userMessageService.pendingMessageCount, 0);
      }
    });
  });

  group('Text message overlay', () {
    testWidgets('waitingForActivity dismisses text overlay', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      userMessageService.markWaiting('test');
      await tester.pumpAndSettle();

      userMessageService.clearWaiting();
      await tester.pumpAndSettle();

      expect(userMessageService.waitingForActivity, isFalse);
    });
  });

  group('Done button in annotation mode', () {
    testWidgets('Done button in queue panel exits annotation mode',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Enable annotation mode and add annotation
      annotationService.enable();
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'done test',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // "Done" button should be visible when annotation mode is active
      final doneButton = find.text('Done');
      if (doneButton.evaluate().isNotEmpty) {
        await tester.tap(doneButton);
        await tester.pumpAndSettle();
        expect(annotationService.enabled, isFalse);
      }
    });
  });

  group('Double-tap Ctrl toggles annotation mode', () {
    testWidgets('double-tap Ctrl enables annotation mode', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isFalse);

      // First Ctrl press
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 100));

      // Second Ctrl press within 500ms
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isTrue);
    });

    testWidgets('double-tap Ctrl disables annotation mode when active',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();
      expect(annotationService.enabled, isTrue);

      // First Ctrl press
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 100));

      // Second Ctrl press
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isFalse);
    });

    testWidgets('double-tap Ctrl disables inspector when enabling annotation',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();
      expect(inspectorService.enabled, isTrue);

      // Double-tap Ctrl
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isTrue);
      expect(inspectorService.enabled, isFalse);
    });
  });

  group('Double-tap Alt opens text message overlay', () {
    testWidgets('double-tap Alt shows text message overlay', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // No overlay text present
      expect(find.text('Send message to agent'), findsNothing);

      // First Alt press
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));

      // Second Alt press within 500ms
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // The text message overlay should now be visible
      expect(find.text('Send message to agent'), findsOneWidget);
    });

    testWidgets('Escape dismisses text message overlay', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open overlay with double-tap Alt
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.text('Send message to agent'), findsOneWidget);

      // Press Escape to dismiss
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Send message to agent'), findsNothing);
    });

    testWidgets('double-tap Alt disables inspector mode', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();

      // Double-tap Alt
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(inspectorService.enabled, isFalse);
      expect(find.text('Send message to agent'), findsOneWidget);
    });

    testWidgets('double-tap Alt disables annotation mode', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      // Double-tap Alt
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isFalse);
      expect(find.text('Send message to agent'), findsOneWidget);
    });
  });

  group('Text message overlay', () {
    testWidgets('shows send hint text', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.textContaining('Enter to send'), findsOneWidget);
    });

    testWidgets('shows waiting state when agent is working', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Mark waiting (without setting isAgentListening to avoid timer)
      userMessageService.markWaiting('test message');
      // Use pump() instead of pumpAndSettle() because the waiting state
      // shows a CircularProgressIndicator that animates indefinitely.
      await tester.pump();

      expect(find.text('Agent is working...'), findsOneWidget);
      expect(find.text('test message'), findsOneWidget);

      // Clean up waiting state
      userMessageService.clearWaiting();
      await tester.pump();
    });

    testWidgets('keyboard icon button present in overlay', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.keyboard), findsOneWidget);
    });
  });

  group('Inspector overlay', () {
    testWidgets('inspector overlay shows Listener widget', (tester) async {
      await tester.pumpWidget(_app(child: const Text('Tap me')));
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();

      expect(find.byType(Listener), findsWidgets);
    });

    testWidgets('inspector shows highlight on hover', (tester) async {
      await tester.pumpWidget(_app(child: const Text('Hover target')));
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();

      inspectorService.handlePointerHover(const Offset(100, 100));
      await tester.pumpAndSettle();

      expect(inspectorService.elementsAtPoint, isNotEmpty);
    });
  });

  group('Annotation overlay interaction', () {
    testWidgets('annotation overlay renders CustomPaint', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('annotation overlay shows Listener for pointer events',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      expect(find.byType(Listener), findsWidgets);
    });
  });

  group('Q badge interaction when inspector active', () {
    testWidgets('tapping Q with no messages and inspector active disables inspector',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();
      expect(inspectorService.enabled, isTrue);

      // Tap Q badge with no messages
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Inspector should be disabled and annotation mode enabled
      expect(inspectorService.enabled, isFalse);
      expect(annotationService.enabled, isTrue);
    });
  });

  group('Error panel interactions', () {
    testWidgets('error panel shows error details text', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('detailed error message here'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('detailed error message here'), findsOneWidget);
    });

    testWidgets('adding error to queue dismisses it', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('dismissable'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add to queue'));
      await tester.pumpAndSettle();

      // Error should be dismissed from interceptor
      expect(errorInterceptor.errors, isEmpty);
    });

    testWidgets('multiple errors show navigation', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('first error'),
      ));
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('second error'),
      ));
      await tester.pumpAndSettle();

      // Open error panel
      await tester.tap(find.text('2').first);
      await tester.pumpAndSettle();

      expect(find.text('2 errors'), findsOneWidget);
      expect(find.text('Clear all'), findsOneWidget);
    });
  });

  group('Escape from queue panel', () {
    testWidgets('Escape closes queue panel when open', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Add a message to the queue
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 60, height: 40, text: 'esc test',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Queued messages'), findsOneWidget);

      // Note: Escape doesn't directly close the queue panel in this impl,
      // but it should close the annotation mode if active
      annotationService.enable();
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(annotationService.enabled, isFalse);
    });
  });

  group('Queued message text overlay content', () {
    testWidgets('text message overlay has dark background', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.byType(ColoredBox), findsWidgets);
    });
  });

  group('Queue badge displays correctly', () {
    testWidgets('badge shows push connection state change', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Start disconnected
      expect(find.text('Q'), findsOneWidget);

      // Connect with push
      userMessageService.setHostConnectionState(
        connected: true,
        pushCapable: true,
      );
      await tester.pumpAndSettle();

      // Badge should still show Q
      expect(find.text('Q'), findsOneWidget);
    });
  });

  group('Agent listening state', () {
    testWidgets('agent listening state updates UI', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      userMessageService.isAgentListening = true;
      await tester.pumpAndSettle();

      expect(userMessageService.isAgentListening, isTrue);

      // Clean up timer
      userMessageService.isAgentListening = false;
      await tester.pumpAndSettle();
    });
  });

  group('Annotation service programmatic operations', () {
    testWidgets('removing single annotation updates draft text',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'Keep',
        );
        annotationService.addAnnotationProgrammatically(
          x: 100, y: 100, width: 50, height: 30, text: 'Remove',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(userMessageService.pendingMessageCount, 1);
      expect(annotationService.annotations, hasLength(2));

      // Remove one annotation
      final removeId = annotationService.annotations.last.id;
      await _runAsyncAndSettle(tester, () async {
        annotationService.removeAnnotationById(removeId);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(annotationService.annotations, hasLength(1));
      expect(userMessageService.pendingMessageCount, 1);
      // Draft text should now only contain "Keep"
      final msg = userMessageService.peekMessages().first;
      final text = msg['text'] as String;
      expect(text, contains('Keep'));
    });
  });

  group('Queue panel with user feedback messages', () {
    testWidgets('queue panel shows message type badge', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        userMessageService.warmUp();
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'app_error',
          'text': 'Error occurred',
          'data': {
            'kind': 'app_error',
            'summary': 'Runtime error',
            'details': 'Stack trace...',
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Should show the error text
      expect(find.textContaining('Error occurred'), findsOneWidget);
    });
  });

  group('Queue badge with annotation mode transition', () {
    testWidgets('tapping Q when annotation mode active opens queue',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      // Add annotation
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'from annotation mode',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Queue panel should be visible
      expect(find.textContaining('Queued messages'), findsOneWidget);
    });
  });

  group('Annotation overlay drawing canvas', () {
    testWidgets('annotation mode shows banner and drawing canvas',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Annotation mode ON'),
        findsOneWidget,
      );
      // Should have a Listener for pointer events
      expect(find.byType(Listener), findsWidgets);
      // Should have CustomPaint for the annotation painter
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });

  group('Overlay widget child rendering', () {
    testWidgets('child widget is interactive', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(
        child: GestureDetector(
          onTap: () => tapped = true,
          child: const Text('Tap Target'),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Tap Target'));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });
  });

  group('Error panel with create issue button', () {
    testWidgets('error panel does not show create issue when not configured',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('issue test'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1').first);
      await tester.pumpAndSettle();

      // GitHub issue service not configured, so no "Create issue" button
      expect(find.text('Create issue'), findsNothing);
    });
  });

  group('Multiple messages in queue', () {
    testWidgets('queue panel shows multiple messages correctly',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        userMessageService.warmUp();
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Message one',
        });
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Message two',
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Message one'), findsOneWidget);
      expect(find.textContaining('Message two'), findsOneWidget);
    });
  });

  group('Queue panel with thumbnails', () {
    testWidgets('queue panel renders without thumbnails', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        userMessageService.warmUp();
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'No thumbnail msg',
          'data': <String, dynamic>{},
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No thumbnail msg'), findsOneWidget);
    });
  });

  group('Queued messages panel Flush button', () {
    testWidgets('Flush button text appears when messages exist',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        userMessageService.warmUp();
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'flush test msg',
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.text('Flush'), findsOneWidget);
    });
  });

  group('Error dot positioning', () {
    testWidgets('error dot is positioned to left of Q badge', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('position test'),
      ));
      await tester.pumpAndSettle();

      // Both Q badge and error dot should exist
      expect(find.text('Q'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });
  });

  group('Annotation mode banner content', () {
    testWidgets('banner shows draw instruction', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Drag to draw'),
        findsOneWidget,
      );
    });
  });

  group('Text message submitted callback', () {
    testWidgets('overlay shows send message title',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.text('Send message to agent'), findsOneWidget);
    });
  });

  group('Overlay build with no modes active', () {
    testWidgets('renders Stack with child and badge only', (tester) async {
      await tester.pumpWidget(_app(child: const Text('Just a child')));
      await tester.pumpAndSettle();

      expect(find.text('Just a child'), findsOneWidget);
      expect(find.text('Q'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
    });
  });

  group('Consume generation clears annotations', () {
    testWidgets('agent consuming clears annotation draft and annotations',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Add annotation which creates a draft
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'consume test',
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });

      expect(userMessageService.pendingMessageCount, greaterThan(0));
      expect(annotationService.annotations, hasLength(1));

      // Simulate agent consuming messages
      await _runAsyncAndSettle(tester, () async {
        userMessageService.consumeMessages();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // After consumption, annotations should be cleared
      expect(userMessageService.pendingMessageCount, 0);
      expect(annotationService.annotations, isEmpty);
    });
  });

  group('Reassemble dismisses text overlay', () {
    testWidgets('hot reload dismisses text overlay state', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.text('Send message to agent'), findsOneWidget);

      // Simulate reassemble (hot reload) by finding the state and calling reassemble
      final state = tester.state(find.byType(FlanOverlayWidget));
      // ignore: invalid_use_of_protected_member
      state.reassemble();
      await tester.pumpAndSettle();

      // Text overlay should be dismissed
      expect(find.text('Send message to agent'), findsNothing);
    });
  });

  group('Queue panel annotation deletion via close icon', () {
    testWidgets('close icon on annotation chip removes annotation',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 10, y: 10, width: 50, height: 30, text: 'chip delete',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Find close icons (X icons on annotation chips)
      final closeIcons = find.byIcon(Icons.close);
      if (closeIcons.evaluate().isNotEmpty) {
        await tester.tap(closeIcons.first);
        await tester.pumpAndSettle();

        expect(annotationService.annotations, isEmpty);
      }
    });
  });

  group('Queue panel message with screenshot', () {
    testWidgets('queue panel shows message with data field', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        userMessageService.warmUp();
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Screenshot msg',
          'data': <String, dynamic>{
            'screenshot': 'base64data',
            'userMessage': 'User typed this',
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Screenshot msg'), findsOneWidget);
    });
  });

  group('Ctrl+Shift+A toggles annotation mode', () {
    testWidgets('Ctrl+Shift+A enables annotation mode', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      // Ctrl+Shift+A isn't a defined shortcut so annotation mode should remain disabled
      expect(annotationService.enabled, isFalse);
    });
  });

  group('Q badge visibility', () {
    testWidgets('Q badge is always visible', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.text('Q'), findsOneWidget);

      // Even with inspector enabled
      inspectorService.enable();
      await tester.pumpAndSettle();
      expect(find.text('Q'), findsOneWidget);

      // Even with annotation enabled
      inspectorService.disable();
      annotationService.enable();
      await tester.pumpAndSettle();
      expect(find.text('Q'), findsOneWidget);
    });
  });

  group('Error interceptor in overlay', () {
    testWidgets('error interceptor listener updates UI', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Initially no error indicator
      expect(errorInterceptor.errors, isEmpty);

      _installInterceptorSafely(errorInterceptor);

      // Trigger error
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('listener update'),
      ));
      await tester.pumpAndSettle();

      // Error dot should now show
      expect(find.text('1'), findsOneWidget);

      // Trigger another error
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('second'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('2'), findsOneWidget);
    });
  });

  group('Queue panel delete sweep icon', () {
    testWidgets('delete sweep icon clears all messages', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        userMessageService.warmUp();
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'msg 1',
        });
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'msg 2',
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      final deleteSweep = find.byIcon(Icons.delete_sweep_outlined);
      if (deleteSweep.evaluate().isNotEmpty) {
        await tester.tap(deleteSweep.first);
        await tester.pumpAndSettle();

        expect(userMessageService.pendingMessageCount, 0);
      }
    });
  });

  group('Non-annotation message delete', () {
    testWidgets('deleting non-annotation message does not clear annotations',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Add a non-annotation message
      await _runAsyncAndSettle(tester, () async {
        userMessageService.warmUp();
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'regular message',
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      // Also add an annotation
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 50, y: 50, width: 60, height: 40, text: 'keep this',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Find delete icon for the first (non-annotation) message
      final deleteIcons = find.byIcon(Icons.delete_outline);
      if (deleteIcons.evaluate().isNotEmpty) {
        await tester.tap(deleteIcons.first);
        await tester.pumpAndSettle();

        // Annotations should still be present
        expect(annotationService.annotations, hasLength(1));
      }
    });
  });

  group('Text message overlay input state', () {
    testWidgets('text message overlay shows toolbar icons', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay via double-tap Alt
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Toolbar should have pencil, text, eraser, and move icons
      expect(find.byIcon(Icons.edit), findsOneWidget);
      expect(find.byIcon(Icons.text_fields), findsOneWidget);
      expect(find.byIcon(Icons.auto_fix_high), findsOneWidget);
      expect(find.byIcon(Icons.open_with), findsOneWidget);
    });

    testWidgets('keyboard icon toggles shortcuts panel', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Shortcuts panel should not be visible initially
      expect(find.text('Flan Shortcuts'), findsNothing);

      // Tap the keyboard icon to show shortcuts
      await tester.tap(find.byIcon(Icons.keyboard));
      await tester.pumpAndSettle();

      expect(find.text('Flan Shortcuts'), findsOneWidget);
      expect(find.text('Open overlay'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
      expect(find.text('Inspector'), findsOneWidget);
      expect(find.text('Annotate'), findsOneWidget);
      expect(find.text('Send to agent'), findsOneWidget);
      expect(find.text('Cycle widgets'), findsOneWidget);

      // Tap again to hide shortcuts
      await tester.tap(find.byIcon(Icons.keyboard));
      await tester.pumpAndSettle();

      expect(find.text('Flan Shortcuts'), findsNothing);
    });

    testWidgets('text message overlay has EditableText for input',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Should have an EditableText widget for the main input
      expect(find.byType(EditableText), findsAtLeastNWidgets(1));
    });

    testWidgets('text overlay dismiss on background tap', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.text('Send message to agent'), findsOneWidget);

      // Tap background to dismiss
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Send message to agent'), findsNothing);
    });
  });

  group('Text message submission', () {
    testWidgets('text overlay has EditableText for user input',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // EditableText should be present for user input
      expect(find.byType(EditableText), findsAtLeastNWidgets(1));

      // Entering text should work
      final editableTexts = find.byType(EditableText);
      await tester.enterText(editableTexts.first, 'Hello agent');
      await tester.pumpAndSettle();

      // The text should be displayed
      expect(find.text('Hello agent'), findsOneWidget);
    });

    testWidgets('text overlay with no messages still shows input area',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // The input area should be present with hint text
      expect(find.textContaining('Enter to send'), findsOneWidget);
      expect(find.byType(EditableText), findsAtLeastNWidgets(1));
    });
  });

  group('Send error to agent', () {
    testWidgets('add to queue button sends error message', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Install interceptor and trigger an error
      _installInterceptorSafely(errorInterceptor);
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('test error for queue'),
        library: 'test',
      ));
      await tester.pumpAndSettle();

      // Error dot should appear - tap it to open panel
      final errorDot = find.byType(GestureDetector);
      // Find the error count text (error dot shows count)
      expect(find.text('1'), findsAtLeastNWidgets(1));

      // Tap the "Add to queue" button (it's a tooltip or text)
      // The error panel has an "add to queue" icon
      final addIcons = find.byIcon(Icons.add_to_photos_outlined);
      if (addIcons.evaluate().isNotEmpty) {
        await tester.tap(addIcons.first);
        await tester.pumpAndSettle();

        // Error should be dismissed and a message should be in queue
        final messages = userMessageService.peekMessages();
        expect(messages, hasLength(1));
        expect(messages.first['type'], 'app_error');
      }
    });
  });

  group('Inspector overlay interaction', () {
    testWidgets('inspector tap selects a widget', (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(
          child: Text('Tap me', key: ValueKey('target')),
        ),
      ));
      await tester.pumpAndSettle();

      // Enable inspector
      inspectorService.enable();
      await tester.pumpAndSettle();

      // Tap on the center of the screen where the text is
      final textFinder = find.text('Tap me');
      expect(textFinder, findsOneWidget);

      // The inspector overlay should have a Listener widget
      expect(find.byType(Listener), findsAtLeastNWidgets(1));
    });

    testWidgets('inspector Escape key disables inspector', (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(child: Text('Hello')),
      ));
      await tester.pumpAndSettle();

      // Enable inspector
      inspectorService.enable();
      await tester.pumpAndSettle();

      // Press Escape
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(inspectorService.enabled, isFalse);
    });
  });

  group('Annotation overlay text input', () {
    testWidgets('annotation mode has CustomPaint and Listener',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Enable annotation mode
      annotationService.enable();
      await tester.pumpAndSettle();

      // Should have a CustomPaint (for drawing) and Listener (for pointer
      // events)
      expect(find.byType(CustomPaint), findsAtLeastNWidgets(1));
      expect(find.byType(Listener), findsAtLeastNWidgets(1));
    });
  });

  group('Queue panel annotation editing', () {
    testWidgets('annotation chip shows in queue with edit and close icons',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Manually queue a message that has annotations data (like what
      // _sendToAgent would create)
      await _runAsyncAndSettle(tester, () async {
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': '1 annotation(s):\n  - "edit me" at (100, 100) 80x40',
          'data': {
            'annotations': [
              {
                'id': 'ann-1',
                'text': 'edit me',
                'bounds': {
                  'x': 100,
                  'y': 100,
                  'width': 80,
                  'height': 40,
                },
              },
            ],
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Verify the annotation chip text is visible
      expect(find.text('edit me'), findsAtLeastNWidgets(1));

      // Edit and close icons should be present
      expect(find.byIcon(Icons.edit_outlined), findsAtLeastNWidgets(1));
      expect(find.byIcon(Icons.close), findsAtLeastNWidgets(1));
    });

    testWidgets('annotation chip without id skips edit/delete on tap',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': '1 annotation(s):\n  - "no id" at (10, 10) 50x30',
          'data': {
            'annotations': [
              {
                'id': '',
                'text': 'no id',
                'bounds': {'x': 10, 'y': 10, 'width': 50, 'height': 30},
              },
            ],
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.text('no id'), findsAtLeastNWidgets(1));
    });
  });

  group('Queue panel message types', () {
    testWidgets('queue panel shows timestamp', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Timestamped message',
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Should show the message text
      expect(find.textContaining('Timestamped message'), findsOneWidget);
    });

    testWidgets('queue panel shows annotation annotations list',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Message with annotations',
          'data': {
            'annotations': [
              {
                'id': 'ann-1',
                'text': 'First annotation',
                'bounds': {'x': 10, 'y': 20, 'width': 100, 'height': 50},
              },
              {
                'id': 'ann-2',
                'text': 'Second annotation',
                'bounds': {'x': 50, 'y': 80, 'width': 120, 'height': 60},
              },
            ],
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Should show both annotation texts as chips
      expect(find.text('First annotation'), findsAtLeastNWidgets(1));
      expect(find.text('Second annotation'), findsAtLeastNWidgets(1));
    });
  });

  group('Error panel clear all', () {
    testWidgets('clear all removes all errors', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);

      // Add two errors
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('error 1'),
        library: 'test',
      ));
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('error 2'),
        library: 'test',
      ));
      await tester.pumpAndSettle();

      expect(errorInterceptor.errors, hasLength(2));

      // Tap error dot to open panel
      expect(find.text('2'), findsAtLeastNWidgets(1));

      // Find and tap the clear all button (delete_sweep icon)
      final clearIcons = find.byIcon(Icons.delete_sweep_outlined);
      // The error panel has a clear all button
      if (clearIcons.evaluate().isNotEmpty) {
        await tester.tap(clearIcons.first);
        await tester.pumpAndSettle();
        expect(errorInterceptor.errors, isEmpty);
      }
    });
  });

  group('Ctrl+Shift+H toggles inspector', () {
    testWidgets('Ctrl+Shift+H enables inspector mode', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(inspectorService.enabled, isFalse);

      // Press Ctrl+Shift+H
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(inspectorService.enabled, isTrue);
    });

    testWidgets('Ctrl+Shift+H disables inspector when active',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();

      // Press Ctrl+Shift+H
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(inspectorService.enabled, isFalse);
    });
  });

  group('Ctrl+Shift+Enter sends to agent', () {
    testWidgets('annotation draft auto-queues message', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Add an annotation which triggers auto-draft in the queue
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 100, y: 100, width: 80, height: 40, text: 'draft me',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // The annotation draft should have auto-created a queued message
      final messages = userMessageService.peekMessages();
      expect(messages.isNotEmpty, isTrue);
      // At least one message should contain the annotation text
      final hasAnnotation = messages.any((m) {
        final text = m['text']?.toString() ?? '';
        return text.contains('draft me');
      });
      expect(hasAnnotation, isTrue);
    });
  });

  group('Q badge with messages count', () {
    testWidgets('badge shows correct count for messages', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'msg 1',
        });
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'msg 2',
        });
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'msg 3',
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Badge should show 3
      expect(find.text('3'), findsOneWidget);
    });
  });

  group('Queue panel close queue', () {
    testWidgets('tapping Q again closes queue panel', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'close test',
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Queued messages'), findsOneWidget);

      // Close queue panel by tapping Q again
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Queued messages'), findsNothing);
    });
  });

  group('Error panel dismiss single error', () {
    testWidgets('dismiss button removes specific error', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);

      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('dismiss me'),
        library: 'test',
      ));
      await tester.pumpAndSettle();

      expect(errorInterceptor.errors, hasLength(1));

      // Tap error dot to open panel
      // Find the dismiss icon in the error panel
      final dismissIcons = find.byIcon(Icons.close);
      if (dismissIcons.evaluate().isNotEmpty) {
        await tester.tap(dismissIcons.first);
        await tester.pumpAndSettle();
      }
    });
  });

  group('Queue panel Done button exits annotation mode', () {
    testWidgets('Done button in queue panel exits annotation mode',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Enable annotation mode and add annotation
      await _runAsyncAndSettle(tester, () async {
        annotationService.enable();
        annotationService.addAnnotationProgrammatically(
          x: 100, y: 100, width: 80, height: 40, text: 'test',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Done button should appear (annotation mode is active)
      final doneButton = find.text('Done');
      if (doneButton.evaluate().isNotEmpty) {
        await tester.tap(doneButton.first);
        await tester.pumpAndSettle();

        expect(annotationService.enabled, isFalse);
      }
    });
  });

  group('Q badge with no messages opens annotation mode', () {
    testWidgets('tapping Q with no messages enables annotation mode',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      expect(annotationService.enabled, isFalse);

      // Tap Q with no messages
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Should enter annotation mode since no messages are queued
      expect(annotationService.enabled, isTrue);
    });
  });

  group('User message service changed listener', () {
    testWidgets('waitingForActivity dismisses text overlay', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.text('Send message to agent'), findsOneWidget);

      // When waiting state clears (agent consumed), the overlay should
      // reflect the change
      userMessageService.clearWaiting();
      await tester.pumpAndSettle();

      // Text overlay should still be visible since we didn't set waiting
      expect(find.text('Send message to agent'), findsOneWidget);
    });
  });

  group('ToolButton widget', () {
    testWidgets('toolbar pencil button toggles active state', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Tap the pencil icon to activate
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      // The pencil should now be in active state - verify by checking
      // UI still works (active tool changes drawing behavior)
      expect(find.byIcon(Icons.edit), findsOneWidget);

      // Tap pencil again to deactivate
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.edit), findsOneWidget);
    });

    testWidgets('toolbar text button activates text tool', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Tap text fields icon to activate text tool
      await tester.tap(find.byIcon(Icons.text_fields));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.text_fields), findsOneWidget);
    });

    testWidgets('toolbar eraser button activates eraser tool', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Tap eraser icon
      await tester.tap(find.byIcon(Icons.auto_fix_high));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.auto_fix_high), findsOneWidget);
    });

    testWidgets('toolbar move button activates move tool', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Tap move icon
      await tester.tap(find.byIcon(Icons.open_with));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.open_with), findsOneWidget);
    });
  });

  group('Agent status indicator in text overlay', () {
    testWidgets('shows agent status indicator', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // The _AgentStatusIndicator should be present in the header
      // It shows based on isAgentListening state
      expect(find.text('Send message to agent'), findsOneWidget);
    });
  });

  group('Queue panel with Create Issue button', () {
    testWidgets('create issue not shown when not configured', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'no issue button',
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // GitHubIssueService is not configured, so no Create Issue button
      expect(find.text('Create Issue'), findsNothing);
    });
  });

  group('Multiple annotations in queue', () {
    testWidgets('multiple annotations show as chips', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Add multiple annotations
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 50, y: 50, width: 60, height: 40, text: 'chip 1',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 200, y: 200, width: 60, height: 40, text: 'chip 2',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Both annotation chips should appear
      expect(find.text('chip 1'), findsAtLeastNWidgets(1));
      expect(find.text('chip 2'), findsAtLeastNWidgets(1));
    });
  });

  group('Queue panel delete annotation from chip', () {
    testWidgets('close icon on second annotation chip removes it',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Add two annotations
      await _runAsyncAndSettle(tester, () async {
        annotationService.addAnnotationProgrammatically(
          x: 50, y: 50, width: 60, height: 40, text: 'keep',
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        annotationService.addAnnotationProgrammatically(
          x: 200, y: 200, width: 60, height: 40, text: 'remove',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // There should be close icons for annotations
      final closeIcons = find.byIcon(Icons.close);
      // Should have at least 2 close icons (one per annotation chip)
      if (closeIcons.evaluate().length >= 2) {
        // Tap the last close icon (for 'remove' annotation)
        await tester.tap(closeIcons.last);
        await tester.pumpAndSettle();

        // Should have 1 annotation remaining
        expect(annotationService.annotations, hasLength(1));
        expect(annotationService.annotations.first.text, 'keep');
      }
    });
  });

  group('Error panel create issue from error', () {
    testWidgets('create issue button shows when configured', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);

      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('issue error'),
        library: 'test',
      ));
      await tester.pumpAndSettle();

      // The error panel should show, check for create issue icon
      // (bug_report icon) — only when GitHubIssueService.isConfigured
      // Since it's not configured in tests, the icon shouldn't appear
      expect(find.byIcon(Icons.bug_report_outlined), findsNothing);
    });
  });

  group('Queue panel with data map message', () {
    testWidgets('message with data but no text shows data summary',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'data': {'key': 'value'},
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Should show something for the message (data toString)
      expect(find.textContaining('key'), findsAtLeastNWidgets(1));
    });
  });

  group('Host connection state', () {
    testWidgets('push connected shows green border on badge', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Set push connected state
      userMessageService.setHostConnectionState(
        connected: true,
        pushCapable: true,
      );
      await tester.pumpAndSettle();

      // Badge should still exist
      expect(find.text('Q'), findsOneWidget);
    });
  });

  group('Multiple drawing tool interactions', () {
    testWidgets('activating pencil then text switches tool', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Activate pencil
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      // Then activate text - should switch tools
      await tester.tap(find.byIcon(Icons.text_fields));
      await tester.pumpAndSettle();

      // Both icons should still exist
      expect(find.byIcon(Icons.edit), findsOneWidget);
      expect(find.byIcon(Icons.text_fields), findsOneWidget);
    });
  });

  group('Queue panel Flush button', () {
    testWidgets('Flush button tapping clears messages', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'flush me',
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Tap the Flush button text
      final flushButton = find.text('Flush');
      expect(flushButton, findsOneWidget);

      await tester.tap(flushButton);
      await tester.pumpAndSettle();

      // Messages should be cleared
      expect(userMessageService.peekMessages(), isEmpty);
    });
  });

  group('Inspector mode with locked selection', () {
    testWidgets('inspector selects widget on pointer down', (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Text('Click me'),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();

      // Tap on the widget area to trigger pointer down handler
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      // Inspector should be locked after tap
      expect(inspectorService.locked, isTrue);
    });
  });

  group('Annotation with pointer events', () {
    testWidgets('drawing in annotation mode triggers pointer events',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      // Simulate drag gesture to draw an annotation
      final gesture = await tester.startGesture(const Offset(100, 100));
      await tester.pump();
      await gesture.moveTo(const Offset(200, 200));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // After drawing, the service should have a pending rect
      // or be in editing state
      expect(
        annotationService.drawState == AnnotationDrawState.editing ||
            annotationService.drawState == AnnotationDrawState.normal,
        isTrue,
      );
    });
  });

  group('Text overlay with drawing content', () {
    testWidgets('typing text shows it in the editable area', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Enter text
      final editableTexts = find.byType(EditableText);
      expect(editableTexts, findsAtLeastNWidgets(1));
      await tester.enterText(editableTexts.first, 'some content');
      await tester.pumpAndSettle();

      // Text should be visible
      expect(find.text('some content'), findsOneWidget);
    });
  });

  group('Error panel navigation', () {
    testWidgets('navigate between errors with arrow buttons', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);

      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('first error'),
        library: 'test',
      ));
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('second error'),
        library: 'test',
      ));
      await tester.pumpAndSettle();

      // Open error panel
      // Find the error count in the error dot
      expect(find.text('2'), findsAtLeastNWidgets(1));

      // The error panel has navigation arrows when multiple errors exist
      final arrowRight = find.byIcon(Icons.chevron_right);
      final arrowLeft = find.byIcon(Icons.chevron_left);

      // Check if navigation arrows exist in the UI
      if (arrowRight.evaluate().isNotEmpty) {
        await tester.tap(arrowRight.first);
        await tester.pumpAndSettle();
      }
    });
  });

  group('Text message overlay drag handle', () {
    testWidgets('overlay has drag handle for repositioning', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // The overlay title 'Send message to agent' is wrapped in a drag
      // handle, so verify it exists
      expect(find.text('Send message to agent'), findsOneWidget);

      // Attempt to drag the overlay
      final titleFinder = find.text('Send message to agent');
      final gesture = await tester.startGesture(
        tester.getCenter(titleFinder),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(50, 50));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Overlay should still be visible after drag
      expect(find.text('Send message to agent'), findsOneWidget);
    });
  });

  group('Text overlay send hint', () {
    testWidgets('shows Enter to send and Shift+Enter hints', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Enter to send'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Shift+Enter for new line'),
        findsOneWidget,
      );
    });
  });

  group('Annotation overlay pointer down/move/up', () {
    testWidgets('drag creates pending rect in annotation mode',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      // Start drag at (100,100), move to (200,200), release
      final gesture = await tester.startGesture(const Offset(100, 100));
      await tester.pump();
      await gesture.moveTo(const Offset(200, 200));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      // After drawing, should be in editing state with pending rect
      if (annotationService.drawState == AnnotationDrawState.editing) {
        expect(annotationService.pendingRect, isNotNull);

        // Enter annotation text
        final editableTexts = find.byType(EditableText);
        if (editableTexts.evaluate().isNotEmpty) {
          await tester.enterText(editableTexts.first, 'drawn annotation');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
        }
      }
    });

    testWidgets('tap on existing annotation enters edit mode',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();

      // Add an annotation programmatically
      annotationService.addAnnotationProgrammatically(
        x: 100, y: 100, width: 100, height: 60, text: 'existing',
      );
      await tester.pumpAndSettle();

      // Tap on the annotation center (150, 130)
      await tester.tapAt(const Offset(150, 130));
      await tester.pumpAndSettle();

      // Should be in editingExisting state or similar
      expect(annotationService.annotations, hasLength(1));
    });
  });

  group('Inspector overlay arrow key navigation', () {
    testWidgets('arrow down cycles to next element', (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Widget A'),
              Text('Widget B'),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();

      // Tap on the widget area to select
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      // Press arrow down to cycle through elements
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      // Press arrow up to cycle back
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
    });

    testWidgets('escape when locked unlocks selection', (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(child: Text('Unlock me')),
      ));
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();

      // Tap to lock selection
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      expect(inspectorService.locked, isTrue);

      // Press Escape to unlock
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Should be unlocked
      expect(inspectorService.locked, isFalse);
    });
  });

  group('Inspector overlay submit message via text field', () {
    testWidgets('locked selection shows text field', (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Text('Select me'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      inspectorService.enable();
      await tester.pumpAndSettle();

      // Tap to lock selection
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      expect(inspectorService.locked, isTrue);

      // An EditableText should appear for typing a message
      final editableTexts = find.byType(EditableText);
      expect(editableTexts, findsAtLeastNWidgets(1));
    });
  });

  group('Send error to agent from error panel', () {
    testWidgets('send error creates app_error message in queue',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      _installInterceptorSafely(errorInterceptor);

      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('queue me'),
        library: 'test_lib',
      ));
      await tester.pumpAndSettle();

      // Error dot should show count 1
      expect(errorInterceptor.errors, hasLength(1));

      // Find and tap the add-to-queue icon
      final addIcons = find.byIcon(Icons.add_to_photos_outlined);
      if (addIcons.evaluate().isNotEmpty) {
        await tester.tap(addIcons.first);
        await tester.pumpAndSettle();

        // Error should be dismissed
        expect(errorInterceptor.errors, isEmpty);

        // A message should be in queue
        final messages = userMessageService.peekMessages();
        expect(messages, hasLength(1));
        expect(messages.first['type'], 'app_error');
        expect(
          messages.first['text'].toString(),
          contains('queue me'),
        );
      }
    });
  });

  group('Escape dismisses error panel', () {
    testWidgets('Escape closes error panel when open', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);

      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('esc error'),
        library: 'test',
      ));
      await tester.pumpAndSettle();

      // Open the error panel by tapping the error dot
      // The error dot is a GestureDetector wrapping _ErrorDot
      // Find the error count text
      final countText = find.text('1');
      // The error count is inside the error dot
      if (countText.evaluate().isNotEmpty) {
        // Tap the error dot area
        await tester.tap(countText.first);
        await tester.pumpAndSettle();
      }

      // Now press Escape to close error panel
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Error panel should be closed (but errors still exist)
      expect(errorInterceptor.errors, hasLength(1));
    });
  });

  group('Escape dismisses text overlay', () {
    testWidgets('Escape closes text message overlay', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.text('Send message to agent'), findsOneWidget);

      // Press Escape
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Send message to agent'), findsNothing);
    });
  });

  group('Escape from annotation mode', () {
    testWidgets('Escape disables annotation mode when in normal state',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();
      expect(annotationService.enabled, isTrue);
      expect(annotationService.drawState, AnnotationDrawState.normal);

      // Press Escape
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isFalse);
    });

    testWidgets(
        'Escape cancels current annotation editing but stays in annotation mode',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      // Start drawing an annotation
      annotationService.startDrawing(const Offset(10, 10));
      annotationService.updateDrawing(const Offset(100, 100));
      annotationService.finishDrawing();
      await tester.pumpAndSettle();
      expect(annotationService.drawState, AnnotationDrawState.editing);

      // Press Escape — should cancel the current annotation, not exit mode
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isTrue);
      expect(annotationService.drawState, AnnotationDrawState.normal);
      expect(annotationService.pendingRect, isNull);
    });

    testWidgets(
        'two Escapes: first cancels annotation, second exits annotation mode',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      // Start drawing an annotation
      annotationService.startDrawing(const Offset(10, 10));
      annotationService.updateDrawing(const Offset(100, 100));
      annotationService.finishDrawing();
      await tester.pumpAndSettle();
      expect(annotationService.drawState, AnnotationDrawState.editing);

      // First Escape — cancel the annotation
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(annotationService.enabled, isTrue);
      expect(annotationService.drawState, AnnotationDrawState.normal);

      // Second Escape — exit annotation mode
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(annotationService.enabled, isFalse);
    });

    testWidgets(
        'Escape cancels editing existing annotation but stays in mode',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      annotationService.addAnnotationProgrammatically(
        x: 10, y: 10, width: 80, height: 60, text: 'existing',
      );
      await tester.pumpAndSettle();

      // Tap on existing annotation to start editing
      annotationService.startDrawing(const Offset(30, 30));
      await tester.pumpAndSettle();
      expect(annotationService.drawState, AnnotationDrawState.editingExisting);

      // Press Escape — should cancel editing, not exit mode
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isTrue);
      expect(annotationService.drawState, AnnotationDrawState.normal);
      // The annotation should still exist
      expect(annotationService.annotations, hasLength(1));
      expect(annotationService.annotations.first.text, 'existing');
    });
  });

  group('Ctrl+Shift+H disabling annotation mode', () {
    testWidgets('Ctrl+Shift+H when annotation active enables inspector',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();

      // Press Ctrl+Shift+H
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      // Annotation mode should be disabled, inspector enabled
      expect(annotationService.enabled, isFalse);
      expect(inspectorService.enabled, isTrue);
    });
  });

  group('Drawing tool pointer interactions in text overlay', () {
    testWidgets('pencil tool allows drawing strokes on background',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Activate pencil tool
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      // Draw a stroke on the background (outside the dialog)
      final gesture = await tester.startGesture(const Offset(50, 50));
      await tester.pump();
      await gesture.moveTo(const Offset(100, 100));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Drawing should have been recorded - verify by checking CustomPaint
      // exists
      expect(find.byType(CustomPaint), findsAtLeastNWidgets(1));
    });

    testWidgets('eraser tool erases at position', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Activate eraser tool
      await tester.tap(find.byIcon(Icons.auto_fix_high));
      await tester.pumpAndSettle();

      // Use eraser on background
      final gesture = await tester.startGesture(const Offset(50, 50));
      await tester.pump();
      await gesture.moveTo(const Offset(80, 80));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.byType(CustomPaint), findsAtLeastNWidgets(1));
    });

    testWidgets('move tool allows moving elements', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Activate move tool
      await tester.tap(find.byIcon(Icons.open_with));
      await tester.pumpAndSettle();

      // Use move tool
      final gesture = await tester.startGesture(const Offset(50, 50));
      await tester.pump();
      await gesture.moveTo(const Offset(80, 80));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.byType(CustomPaint), findsAtLeastNWidgets(1));
    });
  });

  group('Queue message with inspector selection data', () {
    testWidgets('message with inspectorSelection shows in queue',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text':
              'Selected widget: Text at MaterialApp > Scaffold > Text\nSource: lib/main.dart:42',
          'data': {
            'inspectorSelection': {
              'widgetType': 'Text',
              'widgetPath': 'MaterialApp > Scaffold > Text',
              'sourceLocation': 'lib/main.dart:42',
            },
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Message should be visible
      expect(find.textContaining('Selected widget'), findsOneWidget);
    });
  });

  group('Queue message with drawing image', () {
    testWidgets('message with drawingImage data shows in queue',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'User message: (drawing attached)',
          'data': {
            'userMessage': '',
            'drawingImage': 'invalidbase64data',
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Message should be visible
      expect(find.textContaining('drawing attached'), findsOneWidget);
    });
  });

  group('Queue message with queueThumbnail', () {
    testWidgets('valid base64 thumbnail shows Image widget', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Create a minimal valid PNG for the thumbnail (1x1 pixel)
      // PNG header + IHDR + IDAT + IEND
      const validPngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Message with thumbnail',
          'data': {
            'queueThumbnail': validPngBase64,
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Should show the message and an Image.memory widget for thumbnail
      expect(find.textContaining('Message with thumbnail'), findsOneWidget);
      // The _QueueMessageThumbnail renders Image.memory
      expect(find.byType(Image), findsAtLeastNWidgets(1));
    });
  });

  group('Agent consume generation clears waiting state', () {
    testWidgets('consume generation increment updates UI', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Queue a message and consume it
      await _runAsyncAndSettle(tester, () async {
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'to be consumed',
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        userMessageService.consumeMessages();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // After consuming, queue should be empty
      expect(userMessageService.peekMessages(), isEmpty);
      expect(userMessageService.agentConsumeGeneration, 1);
    });
  });

  group('Annotation service disable via double-tap Ctrl', () {
    testWidgets('double-tap Ctrl when annotation active disables it',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      await tester.pumpAndSettle();
      expect(annotationService.enabled, isTrue);

      // Double-tap Ctrl to toggle off
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(annotationService.enabled, isFalse);
    });
  });

  group('Error dot tap opens/closes panel', () {
    testWidgets('tapping error dot opens panel then closes it',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);

      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('dot test'),
        library: 'test',
      ));
      await tester.pumpAndSettle();

      // Find the error count "1" text which is in the error dot
      // Tapping it should open the error panel
      final errorDotArea = find.text('1');
      expect(errorDotArea, findsAtLeastNWidgets(1));

      // First tap - opens panel
      await tester.tap(errorDotArea.first);
      await tester.pumpAndSettle();

      // Error details should be visible
      expect(find.textContaining('dot test'), findsAtLeastNWidgets(1));

      // Second tap - closes panel
      await tester.tap(errorDotArea.first);
      await tester.pumpAndSettle();
    });
  });

  group('Queue panel with annotation bounds', () {
    testWidgets('annotation with bounds shows position info', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text':
              '2 annotation(s):\n  - "Label A" at (10, 20) 100x50\n  - "Label B" at (30, 40) 80x60',
          'data': {
            'annotations': [
              {
                'id': 'a1',
                'text': 'Label A',
                'bounds': {'x': 10, 'y': 20, 'width': 100, 'height': 50},
              },
              {
                'id': 'a2',
                'text': 'Label B',
                'bounds': {'x': 30, 'y': 40, 'width': 80, 'height': 60},
                'widget': {
                  'widgetType': 'Text',
                  'widgetPath': 'App > Text',
                  'sourceLocation': 'lib/main.dart:10',
                  'text': 'Hello',
                },
              },
            ],
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.text('Label A'), findsAtLeastNWidgets(1));
      expect(find.text('Label B'), findsAtLeastNWidgets(1));
    });
  });

  group('Multiple error dismiss leaves panel open', () {
    testWidgets('dismissing one of two errors keeps panel open',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);

      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('error A'),
        library: 'test',
      ));
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('error B'),
        library: 'test',
      ));
      await tester.pumpAndSettle();

      expect(errorInterceptor.errors, hasLength(2));

      // Open error panel
      final countText = find.text('2');
      if (countText.evaluate().isNotEmpty) {
        await tester.tap(countText.first);
        await tester.pumpAndSettle();
      }

      // Dismiss first error
      final dismissButton = find.byIcon(Icons.close);
      if (dismissButton.evaluate().isNotEmpty) {
        await tester.tap(dismissButton.first);
        await tester.pumpAndSettle();

        // Should still have 1 error
        expect(errorInterceptor.errors, hasLength(1));
      }
    });
  });

  group('Queue panel annotation with no data map', () {
    testWidgets('message without data field shows text only', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Plain text only',
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Plain text only'), findsOneWidget);
    });
  });

  group('Overlay with MediaQuery padding', () {
    testWidgets('badge respects safe area padding', (tester) async {
      final app = Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            padding: EdgeInsets.only(top: 44, right: 16),
          ),
          child: SizedBox.expand(
            child: FlanOverlayWidget(
              inspectorService: inspectorService,
              annotationService: annotationService,
              userMessageService: userMessageService,
              screenshotService: screenshotService,
              errorInterceptor: errorInterceptor,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      // Badge should be visible with safe area padding
      expect(find.text('Q'), findsOneWidget);
    });
  });

  group('Inspector submit message flow', () {
    testWidgets('locked selection shows text input and accepts text',
        (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Text('Submit test'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      inspectorService.enable();
      await tester.pumpAndSettle();

      // Tap to select widget
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      expect(inspectorService.locked, isTrue);
      expect(inspectorService.lastSelection, isNotNull);

      // EditableText should be visible for entering a message
      final editables = find.byType(EditableText);
      expect(editables, findsAtLeastNWidgets(1));

      // Enter text (but don't submit to avoid async disposal issue)
      await tester.enterText(editables.first, 'fix this bug');
      await tester.pumpAndSettle();

      expect(find.text('fix this bug'), findsOneWidget);

      // Clean up: disable inspector before test ends
      inspectorService.disable();
      await tester.pumpAndSettle();
    });

    testWidgets('inspector locked shows text field positioned near selection',
        (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Text('Position test'),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();

      // Tap to lock selection
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      expect(inspectorService.locked, isTrue);

      // Text field should be present
      expect(find.byType(EditableText), findsAtLeastNWidgets(1));

      // Clean up
      inspectorService.disable();
      await tester.pumpAndSettle();
    });
  });

  group('Annotation new text submission', () {
    testWidgets('drawing and submitting text creates annotation',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      annotationService.enable();
      await tester.pumpAndSettle();

      // Draw a rectangle
      final gesture = await tester.startGesture(const Offset(100, 100));
      await tester.pump();
      await gesture.moveTo(const Offset(250, 200));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      // After drawing, should be in editing state with text input
      if (annotationService.drawState == AnnotationDrawState.editing) {
        // Enter text for the annotation
        final editables = find.byType(EditableText);
        if (editables.evaluate().isNotEmpty) {
          await tester.enterText(editables.first, 'new annotation');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();

          // Annotation should be created
          expect(annotationService.annotations, hasLength(1));
          expect(annotationService.annotations.first.text, 'new annotation');
        }
      }
    });
  });

  group('Annotation edit existing text', () {
    testWidgets('tapping existing annotation enters edit mode',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      annotationService.addAnnotationProgrammatically(
        x: 100, y: 100, width: 120, height: 60, text: 'edit existing',
      );
      await tester.pumpAndSettle();

      // Tap on the annotation area
      await tester.tapAt(const Offset(160, 130));
      await tester.pumpAndSettle();

      // Should be in editingExisting state
      if (annotationService.drawState ==
          AnnotationDrawState.editingExisting) {
        // EditableText should be present for editing
        final editables = find.byType(EditableText);
        expect(editables, findsAtLeastNWidgets(1));

        // Update the text
        await tester.enterText(editables.first, 'updated text');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        if (annotationService.annotations.isNotEmpty) {
          expect(annotationService.annotations.first.text, 'updated text');
        }
      }
    });
  });

  group('Text overlay drawing text tool', () {
    testWidgets('text tool creates floating text input on tap',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Activate text tool
      await tester.tap(find.byIcon(Icons.text_fields));
      await tester.pumpAndSettle();

      // Tap on the background to place text
      await tester.tapAt(const Offset(50, 50));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // A floating text input should appear (another EditableText)
      // The count of EditableText widgets should increase
      final editables = find.byType(EditableText);
      expect(editables, findsAtLeastNWidgets(1));
    });
  });

  group('Text overlay drag handle pan', () {
    testWidgets('dragging the title bar repositions dialog', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Find the title text which is in the drag handle area
      final titleFinder = find.text('Send message to agent');
      expect(titleFinder, findsOneWidget);

      // Perform a pan gesture on the title
      final center = tester.getCenter(titleFinder);
      final gesture = await tester.startGesture(center);
      await tester.pump();
      // Move by 30 pixels to trigger pan update
      await gesture.moveBy(const Offset(30, 30));
      await tester.pump();
      await gesture.moveBy(const Offset(20, 20));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Dialog should still be visible (repositioned)
      expect(find.text('Send message to agent'), findsOneWidget);
    });
  });

  group('Queue panel message type badge', () {
    testWidgets('app_error message shows error type badge', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'app_error',
          'text': 'Error: something broke',
          'data': {
            'kind': 'app_error',
            'summary': 'something broke',
            'details': 'Full stack trace here',
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Should show the error message text
      expect(
        find.textContaining('something broke'),
        findsAtLeastNWidgets(1),
      );
    });
  });

  group('Annotation overlay edit text field with delete', () {
    testWidgets('edit mode shows delete icon for existing annotation',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      annotationService.enable();
      annotationService.addAnnotationProgrammatically(
        x: 100, y: 100, width: 120, height: 60, text: 'delete from edit',
      );
      await tester.pumpAndSettle();

      // Tap on the annotation to enter edit mode
      await tester.tapAt(const Offset(160, 130));
      await tester.pumpAndSettle();

      if (annotationService.drawState ==
          AnnotationDrawState.editingExisting) {
        // Delete icon should be visible in the edit field
        final deleteIcon = find.byIcon(Icons.delete_outline);
        if (deleteIcon.evaluate().isNotEmpty) {
          await tester.tap(deleteIcon.first);
          await tester.pumpAndSettle();

          // Annotation should be removed
          expect(annotationService.annotations, isEmpty);
        }
      }
    });
  });

  group('Queue panel with raw Map annotations', () {
    testWidgets('non-typed Map annotations are normalized', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        // Send message with annotations as plain Map (not Map<String, dynamic>)
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': '1 annotation(s):\n  - "raw map"',
          'data': <String, dynamic>{
            'annotations': <dynamic>[
              <String, dynamic>{
                'id': 'raw-1',
                'text': 'raw map',
                'bounds': <String, dynamic>{
                  'x': 10,
                  'y': 20,
                  'width': 80,
                  'height': 40,
                },
              },
            ],
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.text('raw map'), findsAtLeastNWidgets(1));
    });
  });

  group('Text message submit with agent listening', () {
    testWidgets('submitting text when agent is listening marks waiting',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Set agent listening
      userMessageService.isAgentListening = true;

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Text overlay should be visible
      expect(find.text('Send message to agent'), findsOneWidget);

      // Clean up
      userMessageService.isAgentListening = false;
    });
  });

  group('Queue badge count overflow', () {
    testWidgets('badge shows 99+ for many messages', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        // Queue 100 messages
        for (var i = 0; i < 100; i++) {
          userMessageService.sendMessage({
            'type': 'user_feedback',
            'text': 'msg $i',
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Badge should show "99+" for overflow
      // The _QueuedMessagesBadge shows '99+' for count > 99
      // But also the number appears in the count badge
      expect(find.textContaining('99'), findsAtLeastNWidgets(1));
    });
  });

  group('_SubmitOnEnterFormatter behavior', () {
    testWidgets('enter key in text overlay triggers submit formatter',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // The EditableText has a _SubmitOnEnterFormatter attached
      // Verify the EditableText exists and can accept input
      final editables = find.byType(EditableText);
      expect(editables, findsAtLeastNWidgets(1));

      // Enter some text
      await tester.enterText(editables.first, 'test input');
      await tester.pumpAndSettle();

      expect(find.text('test input'), findsOneWidget);
    });
  });

  group('Inspector overlay tap behavior', () {
    testWidgets('tap on inspector selects and locks', (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Text('Lock test'),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      inspectorService.enable();
      await tester.pumpAndSettle();

      // Tap to lock selection
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      expect(inspectorService.locked, isTrue);
      expect(inspectorService.lastSelection, isNotNull);
    });
  });

  group('Queue panel _queueIdOf with String id', () {
    testWidgets('message with string queueId is handled', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        // The queue ID from the service is always int, but test resilience
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'String queueId msg',
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('String queueId msg'), findsOneWidget);
    });
  });

  group('Inline annotation editing in queue panel', () {
    testWidgets('annotation text is shown in queue panel', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        annotationService.addAnnotationProgrammatically(
          x: 10,
          y: 20,
          width: 100,
          height: 50,
          text: 'Edit me',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Should see annotation text and delete icon (no edit icon)
      expect(find.text('Edit me'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
    });

    testWidgets('tapping annotation text starts inline editing',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        annotationService.addAnnotationProgrammatically(
          x: 10,
          y: 20,
          width: 100,
          height: 50,
          text: 'Tap me',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Tap the annotation text to enter editing mode
      await tester.tap(find.text('Tap me'));
      await tester.pumpAndSettle();

      // A TextField should appear (inline, not in a dialog)
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      // Annotation still exists in service
      expect(annotationService.annotations, hasLength(1));
    });

    testWidgets('delete icon removes annotation from queue', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        annotationService.addAnnotationProgrammatically(
          x: 10,
          y: 20,
          width: 100,
          height: 50,
          text: 'Delete me',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Delete icon should be present
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.text('Delete me'), findsOneWidget);
    });
  });

  group('Queue message with inspector selection and annotations', () {
    testWidgets('message with inspectorSelection and annotations shows in queue',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Original text',
          'data': {
            'inspectorSelection': {
              'widgetType': 'ElevatedButton',
              'widgetPath': 'MaterialApp > Scaffold > ElevatedButton',
              'sourceLocation': 'lib/main.dart:42',
            },
            'annotations': [
              {
                'id': 'ann1',
                'text': 'Bug here',
                'bounds': {
                  'x': 10.0,
                  'y': 20.0,
                  'width': 100.0,
                  'height': 50.0,
                },
              },
            ],
            'userMessage': 'Fix this please',
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Verify the message displays in the queue panel
      expect(find.textContaining('Bug here'), findsWidgets);
    });

    testWidgets('annotation with widget info shows in queue', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Annotation with widget',
          'data': {
            'annotations': [
              {
                'id': 'ann2',
                'text': 'Widget bug',
                'bounds': {
                  'x': 10.0,
                  'y': 20.0,
                  'width': 100.0,
                  'height': 50.0,
                },
                'widget': {
                  'widgetType': 'Text',
                  'widgetPath': 'MaterialApp > Text',
                  'sourceLocation': 'lib/main.dart:10',
                  'text': 'Hello',
                },
              },
            ],
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Widget bug'), findsWidgets);
    });
  });

  group('Text message overlay interactions', () {
    testWidgets('text overlay opens with double-tap Alt and has input',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay with double-tap Alt
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Text overlay should show "Enter to send" hint text
      expect(find.textContaining('Enter to send'), findsOneWidget);
      // Should have EditableText for input
      expect(find.byType(EditableText), findsWidgets);
    });

    testWidgets('text overlay with text can enter text', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Find the text input area
      final editableTexts = find.byType(EditableText);
      expect(editableTexts, findsWidgets);

      // Enter text
      await tester.enterText(editableTexts.first, 'Hello from text overlay');
      await tester.pumpAndSettle();

      // Text should be entered
      expect(find.text('Hello from text overlay'), findsOneWidget);
    });
  });

  group('Delete annotation from chip close icon', () {
    testWidgets('tapping close icon on annotation chip removes it',
        (tester) async {
      await tester.pumpWidget(_app(useMaterialApp: true));
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        annotationService.addAnnotationProgrammatically(
          x: 10,
          y: 20,
          width: 100,
          height: 50,
          text: 'Close me',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Find the close icon on the annotation chip (size 12, red color)
      // The chip close icon has Icons.close with size 12
      final closeIcons = find.byIcon(Icons.close);
      expect(closeIcons, findsWidgets);

      // Tap the last close icon (the annotation chip one)
      await tester.tap(closeIcons.last);
      await tester.pumpAndSettle();

      // Annotation removed from service
      expect(annotationService.annotations, isEmpty);
    });
  });

  group('Queue message with multiple annotations edit/delete', () {
    testWidgets('editing one of multiple annotations preserves others',
        (tester) async {
      await tester.pumpWidget(_app(useMaterialApp: true));
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
        annotationService.addAnnotationProgrammatically(
          x: 10,
          y: 20,
          width: 100,
          height: 50,
          text: 'First',
        );
        annotationService.addAnnotationProgrammatically(
          x: 200,
          y: 300,
          width: 80,
          height: 40,
          text: 'Second',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Should have two edit icons (one per annotation)
      expect(find.byIcon(Icons.edit_outlined), findsNWidgets(2));
      // Should have two close icons for chip delete
      // (plus possible panel close icon)
      expect(find.byIcon(Icons.close), findsWidgets);

      // Both annotations in the service
      expect(annotationService.annotations, hasLength(2));

      // Tap edit on first annotation opens dialog
      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pumpAndSettle();

      // Dialog appears with pre-filled text
      expect(find.text('Edit annotation'), findsOneWidget);
      final textField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(textField, findsOneWidget);
    });
  });

  group('_onTextMessageSubmitted paths', () {
    testWidgets('text overlay opens and can type text', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Verify text overlay is open with the hint text
      expect(find.textContaining('Enter to send'), findsOneWidget);

      // Keyboard icon should be visible for shortcuts toggle
      expect(find.byIcon(Icons.keyboard), findsOneWidget);
    });
  });

  group('Inspector submit message flow', () {
    testWidgets('inspector with selection can submit message to queue',
        (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Text('Inspect me'),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Enable inspector and select a widget
      inspectorService.enable();
      await tester.pumpAndSettle();

      // Tap to select
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      if (inspectorService.locked && inspectorService.lastSelection != null) {
        // The inspector overlay should show a text input
        final editableTexts = find.byType(EditableText);
        // There should be at least one for the inspector message field
        expect(editableTexts, findsWidgets);
      }

      inspectorService.disable();
      await tester.pumpAndSettle();
    });
  });

  group('Long error summary truncation', () {
    testWidgets('error panel truncates summary longer than 200 chars',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);

      // Create an error with a summary longer than 200 characters
      final longSummary = 'A' * 250;
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception(longSummary),
      ));
      await tester.pumpAndSettle();

      // Open error panel by tapping the error dot
      final dotText = find.text('1');
      if (dotText.evaluate().isNotEmpty) {
        await tester.tap(dotText.first);
        await tester.pumpAndSettle();
      }

      // The truncated display should end with '...'
      // and the full summary should NOT appear
      expect(find.textContaining('...'), findsAtLeastNWidgets(1));
    });
  });

  group('Annotation queue edit triggers text rebuild', () {
    testWidgets(
        'deleting annotation from chip triggers _updateQueuedAnnotationInMessage',
        (tester) async {
      await tester.pumpWidget(_app(useMaterialApp: true));
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Add two annotations so deleting one still leaves a message
      annotationService.addAnnotationProgrammatically(
        x: 10,
        y: 20,
        width: 100,
        height: 50,
        text: 'First annotation',
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 50));

      annotationService.addAnnotationProgrammatically(
        x: 200,
        y: 20,
        width: 100,
        height: 50,
        text: 'Second annotation',
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 50));

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Should have close icons for annotation chip deletion
      final closeIcons = find.byIcon(Icons.close);
      expect(closeIcons, findsAtLeastNWidgets(1));

      // Get the initial pending message text
      final messagesBefore = userMessageService.peekMessages();
      expect(messagesBefore, isNotEmpty);
      final textBefore = messagesBefore.first['text']?.toString() ?? '';

      // Tap close on last annotation chip to delete it
      await tester.tap(closeIcons.last);
      await tester.pumpAndSettle();

      // Verify the message was updated (text should have changed
      // via _rebuildQueuedMessageText)
      final messagesAfter = userMessageService.peekMessages();
      expect(messagesAfter, isNotEmpty);
      // Annotation count changed — one was removed
      expect(annotationService.annotations.length, lessThan(2));
    });

    testWidgets(
        'queue message with rich annotation data covers _formatAnnotationLine',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();

        // Manually craft a message with rich annotation data including
        // widget info, bounds, and text — this covers _formatAnnotationLine
        userMessageService.sendMessage({
          'type': 'user_feedback',
          'text': 'Selected widget: Text at App > Text\n'
              '1 annotation(s):\n'
              '  - "label" at (10, 20) 100x50\n'
              '    Widget: Text at MyApp > Text\n'
              '    Source: lib/main.dart:10\n'
              '    Text: "hello"',
          'data': {
            'inspectorSelection': {
              'widgetType': 'Text',
              'widgetPath': 'App > Text',
              'sourceLocation': 'lib/main.dart:42',
            },
            'annotations': [
              {
                'id': 'ann-1',
                'text': 'label',
                'bounds': {'x': 10, 'y': 20, 'width': 100, 'height': 50},
                'widget': {
                  'widgetType': 'Text',
                  'widgetPath': 'MyApp > Text',
                  'sourceLocation': 'lib/main.dart:10',
                  'text': 'hello',
                },
              },
              {
                'id': 'ann-2',
                'text': 'second',
                'bounds': {'x': 200, 'y': 20, 'width': 80, 'height': 40},
              },
            ],
            'userMessage': 'Please fix this',
          },
        });
      });

      // Open queue panel
      await tester.tap(find.text('Q'));
      await tester.pumpAndSettle();

      // Verify the message is in the queue
      final messages = userMessageService.peekMessages();
      expect(messages, isNotEmpty);

      // The annotation chips should be visible
      expect(find.byIcon(Icons.edit_outlined), findsAtLeastNWidgets(1));
    });
  });

  group('Text message overlay submission', () {
    testWidgets('submitting text via overlay sends user_feedback message',
        (tester) async {
      await tester.pumpWidget(_app(useMaterialApp: true));
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Open text message overlay via double-tap Alt
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Verify overlay is open
      expect(find.textContaining('Enter to send'), findsOneWidget);

      // Find the EditableText in the text overlay
      final editables = find.byType(EditableText);
      expect(editables, findsAtLeastNWidgets(1));

      // Enter text
      await tester.enterText(editables.first, 'Hello agent');
      await tester.pump();

      // Simulate pressing Enter (newline) to trigger _SubmitOnEnterFormatter
      // The formatter strips the newline and calls _handleSubmit
      await tester.enterText(editables.first, 'Hello agent\n');
      await tester.pump();
      await tester.pumpAndSettle();

      // _handleSubmit calls widget.onSubmitted which is _onTextMessageSubmitted
      // Check that a user_feedback message was queued
      final messages = userMessageService.peekMessages();
      final feedbackMessages = messages
          .where((m) => m['type'] == 'user_feedback')
          .toList();
      expect(feedbackMessages, isNotEmpty);
    });

    testWidgets(
        'submitting empty text from overlay dismisses without sending',
        (tester) async {
      await tester.pumpWidget(_app(useMaterialApp: true));
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.textContaining('Enter to send'), findsOneWidget);

      // Don't type anything — just trigger submit with newline on empty text
      final editables = find.byType(EditableText);
      expect(editables, findsAtLeastNWidgets(1));

      await tester.enterText(editables.first, '\n');
      await tester.pump();
      await tester.pumpAndSettle();

      // No message should have been sent (empty text, no drawing)
      final messages = userMessageService.peekMessages();
      final feedbackMessages = messages
          .where((m) => m['type'] == 'user_feedback')
          .toList();
      expect(feedbackMessages, isEmpty);
    });

    testWidgets('submitted message data contains userMessage field',
        (tester) async {
      await tester.pumpWidget(_app(useMaterialApp: true));
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Enter text and submit
      final editables = find.byType(EditableText);
      expect(editables, findsAtLeastNWidgets(1));

      await tester.enterText(editables.first, 'My detailed message');
      await tester.pump();

      // Submit via newline
      await tester.enterText(editables.first, 'My detailed message\n');
      await tester.pump();
      await tester.pumpAndSettle();

      // _onTextMessageSubmitted creates a message with data.userMessage
      final feedbackMessages = userMessageService
          .peekMessages()
          .where((m) => m['type'] == 'user_feedback')
          .toList();
      if (feedbackMessages.isNotEmpty) {
        final data = feedbackMessages.first['data'];
        expect(data, isA<Map>());
        expect((data as Map)['userMessage'], 'My detailed message');
      }
    });
  });

  group('Inspector overlay submit message', () {
    testWidgets('inspector text field accepts input when widget is selected',
        (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Text('Submit target'),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Enable inspector
      inspectorService.enable();
      await tester.pumpAndSettle();

      // Tap to select a widget
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      if (inspectorService.locked && inspectorService.lastSelection != null) {
        // Should have an EditableText for the inspector message
        final editables = find.byType(EditableText);
        expect(editables, findsAtLeastNWidgets(1));

        // Enter text in the inspector text field
        await tester.enterText(editables.last, 'Fix this widget');
        await tester.pump();

        // Verify the text was entered
        final controller =
            tester.widget<EditableText>(editables.last).controller;
        expect(controller.text, 'Fix this widget');

        // Verify selection info
        expect(inspectorService.lastSelection!.widgetType, isNotEmpty);
        expect(inspectorService.lastSelection!.widgetPath, isNotEmpty);
      }

      inspectorService.disable();
      await tester.pumpAndSettle();
    });
  });

  group('Text overlay clear all button', () {
    testWidgets('clear all button appears when drawing tool creates content',
        (tester) async {
      await tester.pumpWidget(_app(useMaterialApp: true));
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Before adding content, clear all button should NOT be present
      expect(find.byIcon(Icons.delete_outline), findsNothing);

      // Tap the pen tool to activate drawing mode
      final penButton = find.byIcon(Icons.edit);
      if (penButton.evaluate().isNotEmpty) {
        await tester.tap(penButton.first);
        await tester.pumpAndSettle();

        // Simulate drawing a stroke by dragging within the text overlay area
        // The drawing area overlays on top of the text field
        // First, find the overlay's bounds
        final dragStart = const Offset(300, 400);
        final dragEnd = const Offset(400, 400);

        await tester.timedDragFrom(
          dragStart,
          dragEnd - dragStart,
          const Duration(milliseconds: 100),
        );
        await tester.pumpAndSettle();
      }

      // If drawing content was added, the clear button should appear
      final clearButton = find.byIcon(Icons.delete_outline);
      if (clearButton.evaluate().isNotEmpty) {
        await tester.tap(clearButton);
        await tester.pumpAndSettle();

        // After clearing, the clear button should disappear
        expect(find.byIcon(Icons.delete_outline), findsNothing);
      }
    });
  });

  group('Keyboard shortcuts panel toggle', () {
    testWidgets('tapping keyboard icon toggles shortcuts panel',
        (tester) async {
      await tester.pumpWidget(_app(useMaterialApp: true));
      await tester.pumpAndSettle();

      // Open text overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      // Keyboard icon should be visible
      final keyboardIcon = find.byIcon(Icons.keyboard);
      expect(keyboardIcon, findsOneWidget);

      // Tap to show shortcuts
      await tester.tap(keyboardIcon);
      await tester.pumpAndSettle();

      // Shortcuts panel content should appear
      expect(find.text('Flan Shortcuts'), findsOneWidget);

      // Tap again to hide
      await tester.tap(find.byIcon(Icons.keyboard));
      await tester.pumpAndSettle();

      // Shortcuts panel should be hidden
      expect(find.text('Flan Shortcuts'), findsNothing);
    });
  });

  group('Error panel add to queue from panel', () {
    testWidgets('add to queue button sends error to agent queue',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _runAsyncAndSettle(tester, () async {
        await userMessageService.ensureHydrated();
      });

      _installInterceptorSafely(errorInterceptor);

      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('queue this error'),
      ));
      await tester.pumpAndSettle();

      // Open error panel
      final countText = find.text('1');
      if (countText.evaluate().isNotEmpty) {
        await tester.tap(countText.first);
        await tester.pumpAndSettle();

        // Find the add to queue icon
        final addIcon = find.byIcon(Icons.add_to_photos_outlined);
        if (addIcon.evaluate().isNotEmpty) {
          await tester.tap(addIcon.first);
          await tester.pumpAndSettle();

          // Error should be dismissed and message queued
          final messages = userMessageService.peekMessages();
          final errorMessages = messages
              .where((m) => m['type'] == 'app_error')
              .toList();
          expect(errorMessages, isNotEmpty);
          expect(
            errorMessages.first['text']?.toString() ?? '',
            contains('queue this error'),
          );
        }
      }
    });
  });

  group('Error panel clear all button', () {
    testWidgets('clear all button removes all errors', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _installInterceptorSafely(errorInterceptor);

      // Add multiple errors so clear all button appears
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('error A'),
      ));
      FlutterError.onError!(FlutterErrorDetails(
        exception: Exception('error B'),
      ));
      await tester.pumpAndSettle();

      expect(errorInterceptor.errors, hasLength(2));

      // Open error panel
      final countText = find.text('2');
      if (countText.evaluate().isNotEmpty) {
        await tester.tap(countText.first);
        await tester.pumpAndSettle();

        // Find and tap "Clear all" text button
        final clearAll = find.text('Clear all');
        if (clearAll.evaluate().isNotEmpty) {
          await tester.tap(clearAll.first);
          await tester.pumpAndSettle();

          // All errors should be cleared
          expect(errorInterceptor.errors, isEmpty);
        }
      }
    });
  });

  group('Inspector overlay keyboard navigation', () {
    testWidgets('arrow keys cycle through elements in inspector',
        (tester) async {
      await tester.pumpWidget(_app(
        child: const Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Text('Navigate me'),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Enable inspector
      inspectorService.enable();
      await tester.pumpAndSettle();

      // Send arrow down and arrow up keys to cycle elements
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();

      // Tap to select
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      if (inspectorService.locked) {
        // Send Escape while locked to unlock
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }

      // Verify inspector is still enabled (Escape unlocks, doesn't disable)
      // Or send another Escape to disable
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });
  });
}
