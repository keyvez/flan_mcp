import 'package:flan_flutter/src/binding/flan_binding.dart';
import 'package:flan_flutter/src/overlay/flan_overlay_widget.dart';
import 'package:flan_flutter/src/services/annotation_service.dart';
import 'package:flan_flutter/src/services/error_interceptor.dart';
import 'package:flan_flutter/src/services/inspector_service.dart';
import 'package:flan_flutter/src/services/macro_recorder_service.dart';
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
          macroRecorderService: MacroRecorderService(),
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    ),
  );
}

/// The smallest thing that is a [Router], so the overlay has one to read a URL
/// from. A go_router app is this shape: the route IS the URL, and there are no
/// named routes for the binding's stack walk to find.
class _StaticRouterDelegate extends RouterDelegate<Uri> with ChangeNotifier {
  _StaticRouterDelegate(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => child;

  @override
  Future<bool> popRoute() async => false;

  @override
  Future<void> setNewRoutePath(Uri configuration) async {}
}

class _UriRouteParser extends RouteInformationParser<Uri> {
  @override
  Future<Uri> parseRouteInformation(RouteInformation routeInformation) async =>
      routeInformation.uri;
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

  /// The mechanism the fix rests on. In production the overlay is mounted ABOVE
  /// the app, so `Router.maybeOf(overlayContext)` looks up the wrong branch and
  /// finds nothing — which is why a go_router app, whose route is a URL and not
  /// a stack of named routes, sent messages with no route at all. Walking down
  /// from the root finds it.
  testWidgets('the router URL is found by walking down from the root',
      (tester) async {
    await tester.pumpWidget(MaterialApp.router(
      routerDelegate: _StaticRouterDelegate(const ColoredBox(color: Colors.black)),
      routeInformationParser: _UriRouteParser(),
      routeInformationProvider: PlatformRouteInformationProvider(
        initialRouteInformation:
            RouteInformation(uri: Uri.parse('/candidates/42?tab=notes')),
      ),
    ));

    expect(
      findRouterUrl(tester.binding.rootElement!),
      '/candidates/42?tab=notes',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    expect(findRouterUrl(tester.binding.rootElement!), isNull);
  });

  /// The report: an annotation reached the agent as a cropped screenshot with
  /// no way to tell which screen it was. Every other message type collected the
  /// navigation context; the annotation draft — the one you get by drawing —
  /// never did.
  testWidgets('a queued annotation carries the route it was drawn on',
      (tester) async {
    final annotations = AnnotationService();
    final messages = UserMessageService();
    final overlay = SizedBox.expand(
      child: FlanOverlayWidget(
        inspectorService: InspectorService(),
        annotationService: annotations,
        userMessageService: messages,
        screenshotService: ScreenshotService(),
        errorInterceptor: ErrorInterceptor(),
        macroRecorderService: MacroRecorderService(),
        child: const ColoredBox(color: Colors.black),
      ),
    );
    await tester.pumpWidget(MaterialApp.router(
      routerDelegate: _StaticRouterDelegate(overlay),
      routeInformationParser: _UriRouteParser(),
      routeInformationProvider: PlatformRouteInformationProvider(
        initialRouteInformation:
            RouteInformation(uri: Uri.parse('/candidates/42?tab=notes')),
      ),
    ));
    annotations.enable();
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(300, 200));
    await gesture.moveTo(const Offset(400, 300));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'this button');
    await _runAsyncAndSettle(tester, () async {
      tester
          .widget<EditableText>(find.byType(EditableText))
          .onSubmitted!('this button');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    final data = messages.peekMessages().single['data'] as Map;
    expect(data['url'], '/candidates/42?tab=notes');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  /// Draw a box and leave the overlay in its editing state, with the label's
  /// field focused — the state every bug below was reported from.
  Future<AnnotationService> editingLabel(WidgetTester tester) async {
    final annotations = AnnotationService();
    await tester.pumpWidget(_buildTestApp(
      inspectorService: InspectorService(),
      annotationService: annotations,
      userMessageService: UserMessageService(),
      screenshotService: ScreenshotService(),
      errorInterceptor: ErrorInterceptor(),
    ));
    annotations.enable();
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(300, 200));
    await gesture.moveTo(const Offset(400, 300));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(annotations.drawState, AnnotationDrawState.editing);
    return annotations;
  }

  TextEditingController labelController(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).controller;

  /// The report: "typing in an annotation box that already has text closes it".
  /// The submit-on-Enter formatter asked whether the text CONTAINED a newline,
  /// which every keystroke satisfies once the label holds one — so the
  /// keystroke was thrown away and the box submitted instead.
  testWidgets('typing into a label that already has a line break keeps typing',
      (tester) async {
    final annotations = await editingLabel(tester);

    await tester.enterText(find.byType(EditableText), 'first\nsecond');
    await tester.pump();
    // One more character, exactly as a keypress delivers it.
    await tester.enterText(find.byType(EditableText), 'first\nsecondX');
    await tester.pump();

    expect(labelController(tester).text, 'first\nsecondX');
    expect(
      annotations.drawState,
      AnnotationDrawState.editing,
      reason: 'the label should still be open for editing',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  /// The report: "Ctrl+C and Ctrl+V are broken". Both are two Ctrl presses
  /// inside 500ms, which is also the double-tap gesture that toggles annotation
  /// mode — so copying and pasting tore the editor down mid-edit.
  testWidgets('copy then paste in a label does not toggle annotation mode',
      (tester) async {
    final annotations = await editingLabel(tester);
    await tester.enterText(find.byType(EditableText), 'look here');
    await tester.pump();

    for (var i = 0; i < 2; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
    await tester.pump();

    expect(annotations.enabled, isTrue);
    expect(annotations.drawState, AnnotationDrawState.editing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  /// The report: "selecting and regular text editing are broken". The overlay
  /// is mounted above the app's WidgetsApp, which is what installs
  /// DefaultTextEditingShortcuts — without it the arrow keys reach no intent at
  /// all, so the caret could not even be moved.
  testWidgets('shift-arrow extends the selection inside a label',
      (tester) async {
    await editingLabel(tester);
    await tester.enterText(find.byType(EditableText), 'look here');
    await tester.pump();
    expect(labelController(tester).selection.isCollapsed, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    final selection = labelController(tester).selection;
    expect(selection.isCollapsed, isFalse);
    expect(selection.textInside('look here'), 'e');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final shape in AnnotationShape.values) {
    testWidgets('toolbar draws and queues ${shape.name} with geometry',
        (tester) async {
      final annotations = AnnotationService();
      final messages = UserMessageService();
      await tester.pumpWidget(_buildTestApp(
        inspectorService: InspectorService(),
        annotationService: annotations,
        userMessageService: messages,
        screenshotService: ScreenshotService(),
        errorInterceptor: ErrorInterceptor(),
      ));
      annotations.enable();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('annotation-tool-${shape.name}')));
      await tester.pumpAndSettle();
      expect(annotations.shape, shape);
      const start = Offset(300, 200);
      final end = shape == AnnotationShape.arrow
          ? const Offset(100, 200)
          : const Offset(400, 300);
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(annotations.drawState, AnnotationDrawState.editing);
      await tester.enterText(find.byType(EditableText), 'look here');
      await _runAsyncAndSettle(tester, () async {
        tester
            .widget<EditableText>(find.byType(EditableText))
            .onSubmitted!('look here');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      expect(annotations.annotations.single.shape, shape);
      final data = messages.peekMessages().single['data'] as Map;
      final queued = (data['annotations'] as List).single as Map;
      expect(queued['shape'], shape.name);
      expect(queued['text'], 'look here');
      if (shape == AnnotationShape.arrow) {
        expect(queued['start'], {'x': 300.0, 'y': 200.0});
        expect(queued['end'], {'x': 100.0, 'y': 200.0});
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

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
    expect(data['annotations'], isNotNull);
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
    expect(data['annotations'], isNotNull);
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

  testWidgets(
      'adding second annotation preserves first after async thumbnail completes',
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

    // Add first annotation and wait for async thumbnail to complete.
    await _runAsyncAndSettle(tester, () async {
      annotationService.addAnnotationProgrammatically(
        x: 10,
        y: 10,
        width: 60,
        height: 40,
        text: 'first',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    expect(userMessageService.pendingMessageCount, 1);
    var data = userMessageService.peekMessages().single['data']
        as Map<String, dynamic>;
    var annotations = data['annotations'] as List<dynamic>;
    expect(annotations, hasLength(1));
    expect((annotations[0] as Map)['text'], 'first');

    // Add second annotation — the async thumbnail for the first may still be
    // pending or complete. After this, both annotations must be present.
    await _runAsyncAndSettle(tester, () async {
      annotationService.addAnnotationProgrammatically(
        x: 100,
        y: 100,
        width: 60,
        height: 40,
        text: 'second',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    expect(userMessageService.pendingMessageCount, 1);
    data = userMessageService.peekMessages().single['data']
        as Map<String, dynamic>;
    annotations = data['annotations'] as List<dynamic>;
    // Both annotations must be present — the stale async thumbnail must not
    // have overwritten the data with only the first annotation.
    expect(annotations, hasLength(2));
    final texts = annotations
        .map((a) => (a as Map)['text']?.toString() ?? '')
        .toList();
    expect(texts, containsAll(['first', 'second']));
  });

  testWidgets(
      'rapidly adding three annotations preserves all in the draft',
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

    // Add three annotations rapidly without waiting for async completion.
    await _runAsyncAndSettle(tester, () async {
      annotationService.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 30, text: 'A',
      );
      annotationService.addAnnotationProgrammatically(
        x: 60, y: 10, width: 40, height: 30, text: 'B',
      );
      annotationService.addAnnotationProgrammatically(
        x: 110, y: 10, width: 40, height: 30, text: 'C',
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });

    expect(userMessageService.pendingMessageCount, 1);
    final data = userMessageService.peekMessages().single['data']
        as Map<String, dynamic>;
    final annotations = data['annotations'] as List<dynamic>;
    expect(annotations, hasLength(3));
    final texts = annotations
        .map((a) => (a as Map)['text']?.toString() ?? '')
        .toList();
    expect(texts, containsAll(['A', 'B', 'C']));
  });

  testWidgets(
      'thumbnail is preserved when updating draft with a new annotation',
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

    // Add first annotation and wait for the async thumbnail to attach.
    await _runAsyncAndSettle(tester, () async {
      annotationService.addAnnotationProgrammatically(
        x: 10,
        y: 10,
        width: 60,
        height: 40,
        text: 'first',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    expect(userMessageService.pendingMessageCount, 1);
    var data = userMessageService.peekMessages().single['data']
        as Map<String, dynamic>;
    // After the async thumbnail completes, queueThumbnail should be present.
    expect(data['queueThumbnail'], isNotNull,
        reason: 'thumbnail should be attached after first annotation');

    // Add a second annotation — this triggers _upsertQueuedAnnotationDraft
    // which updates the draft. The existing thumbnail must be preserved.
    annotationService.addAnnotationProgrammatically(
      x: 100,
      y: 100,
      width: 60,
      height: 40,
      text: 'second',
    );
    await tester.pumpAndSettle();

    // Check immediately — the thumbnail should still be present even before
    // the new async thumbnail capture completes.
    data = userMessageService.peekMessages().single['data']
        as Map<String, dynamic>;
    expect(data['queueThumbnail'], isNotNull,
        reason: 'thumbnail must not be lost when updating draft');
    expect(data['annotations'], hasLength(2));
  });
}
