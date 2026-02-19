import 'package:flan_flutter/src/overlay/flan_overlay_widget.dart';
import 'package:flan_flutter/src/services/annotation_service.dart';
import 'package:flan_flutter/src/services/error_interceptor.dart';
import 'package:flan_flutter/src/services/inspector_service.dart';
import 'package:flan_flutter/src/services/screenshot_service.dart';
import 'package:flan_flutter/src/services/user_message_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildTestApp({
  required InspectorService inspectorService,
  required AnnotationService annotationService,
  required UserMessageService userMessageService,
  required ScreenshotService screenshotService,
  required ErrorInterceptor errorInterceptor,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
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
}

/// Runs [action] in a real async zone so that screenshot capture and other
/// async work inside the overlay can complete, then pumps frames.
Future<void> _runAsyncAndSettle(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  await tester.runAsync(action);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('programmatic annotation creates exactly one queued draft',
      (tester) async {
    final inspectorService = InspectorService();
    final annotationService = AnnotationService();
    final userMessageService = UserMessageService();
    final screenshotService =
        ScreenshotService(maxScreenshotSize: const Size(1024, 1024));
    final errorInterceptor = ErrorInterceptor();

    await tester.pumpWidget(_buildTestApp(
      inspectorService: inspectorService,
      annotationService: annotationService,
      userMessageService: userMessageService,
      screenshotService: screenshotService,
      errorInterceptor: errorInterceptor,
    ));
    await tester.pumpAndSettle();

    expect(userMessageService.pendingMessageCount, 0);

    await _runAsyncAndSettle(tester, () async {
      annotationService.addAnnotationProgrammatically(
        x: 10,
        y: 10,
        width: 60,
        height: 40,
        text: 'mark here',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    expect(userMessageService.pendingMessageCount, 1);
    final message = userMessageService.peekMessages().single;
    final data = message['data'] as Map<String, dynamic>;
    expect(data['annotationDraft'], isTrue);
    final annotations = data['annotations'] as List<dynamic>;
    expect(annotations, hasLength(1));
  });

  testWidgets('adding two annotations creates exactly one queued draft',
      (tester) async {
    final inspectorService = InspectorService();
    final annotationService = AnnotationService();
    final userMessageService = UserMessageService();
    final screenshotService =
        ScreenshotService(maxScreenshotSize: const Size(1024, 1024));
    final errorInterceptor = ErrorInterceptor();

    await tester.pumpWidget(_buildTestApp(
      inspectorService: inspectorService,
      annotationService: annotationService,
      userMessageService: userMessageService,
      screenshotService: screenshotService,
      errorInterceptor: errorInterceptor,
    ));
    await tester.pumpAndSettle();

    await _runAsyncAndSettle(tester, () async {
      annotationService.addAnnotationProgrammatically(
        x: 10,
        y: 10,
        width: 60,
        height: 40,
        text: 'first',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    expect(userMessageService.pendingMessageCount, 1);

    await _runAsyncAndSettle(tester, () async {
      annotationService.addAnnotationProgrammatically(
        x: 100,
        y: 100,
        width: 60,
        height: 40,
        text: 'second',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    // Still exactly one draft message, now containing both annotations.
    expect(userMessageService.pendingMessageCount, 1);
    final data = userMessageService.peekMessages().single['data']
        as Map<String, dynamic>;
    expect(data['annotationDraft'], isTrue);
    final annotations = data['annotations'] as List<dynamic>;
    expect(annotations, hasLength(2));
  });

  testWidgets(
      'interactive annotation via draw+submit creates exactly one queue entry',
      (tester) async {
    final inspectorService = InspectorService();
    final annotationService = AnnotationService();
    final userMessageService = UserMessageService();
    final screenshotService =
        ScreenshotService(maxScreenshotSize: const Size(1024, 1024));
    final errorInterceptor = ErrorInterceptor();

    await tester.pumpWidget(_buildTestApp(
      inspectorService: inspectorService,
      annotationService: annotationService,
      userMessageService: userMessageService,
      screenshotService: screenshotService,
      errorInterceptor: errorInterceptor,
    ));
    await tester.pumpAndSettle();

    // Enable annotation mode so the overlay is active.
    annotationService.enable();
    await tester.pumpAndSettle();

    // Simulate the drawing flow via the annotation service.
    annotationService.startDrawing(const Offset(50, 50));
    annotationService.updateDrawing(const Offset(150, 120));
    annotationService.finishDrawing();
    await tester.pumpAndSettle();

    // Submit text — this triggers _onAnnotationServiceChanged (which calls
    // _upsertQueuedAnnotationDraft) AND the overlay's onAnnotationSubmitted
    // callback (which calls _sendToAgent). Both are async and race.
    await _runAsyncAndSettle(tester, () async {
      annotationService.submitAnnotationText('test label');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    // Exactly one message should exist — not two.
    expect(userMessageService.pendingMessageCount, 1);
  });

  testWidgets('consume clears annotations and does not recreate draft',
      (tester) async {
    final inspectorService = InspectorService();
    final annotationService = AnnotationService();
    final userMessageService = UserMessageService();
    final screenshotService =
        ScreenshotService(maxScreenshotSize: const Size(1024, 1024));
    final errorInterceptor = ErrorInterceptor();

    await tester.pumpWidget(_buildTestApp(
      inspectorService: inspectorService,
      annotationService: annotationService,
      userMessageService: userMessageService,
      screenshotService: screenshotService,
      errorInterceptor: errorInterceptor,
    ));
    await tester.pumpAndSettle();

    await _runAsyncAndSettle(tester, () async {
      annotationService.addAnnotationProgrammatically(
        x: 20,
        y: 20,
        width: 80,
        height: 50,
        text: 'persist draft',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(userMessageService.pendingMessageCount, 1);

    await _runAsyncAndSettle(tester, () async {
      userMessageService.consumeMessages();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    // After consume, annotations are cleared so no draft is recreated.
    expect(userMessageService.pendingMessageCount, 0);
    expect(annotationService.annotations, isEmpty);
  });
}
