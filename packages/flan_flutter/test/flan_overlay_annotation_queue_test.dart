import 'package:flan_flutter/src/overlay/flan_overlay_widget.dart';
import 'package:flan_flutter/src/services/annotation_service.dart';
import 'package:flan_flutter/src/services/inspector_service.dart';
import 'package:flan_flutter/src/services/screenshot_service.dart';
import 'package:flan_flutter/src/services/user_message_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('programmatic annotation is mirrored into queued draft message',
      (tester) async {
    final inspectorService = InspectorService();
    final annotationService = AnnotationService();
    final userMessageService = UserMessageService();
    final screenshotService =
        ScreenshotService(maxScreenshotSize: const Size(1024, 1024));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.expand(
          child: FlanOverlayWidget(
            inspectorService: inspectorService,
            annotationService: annotationService,
            userMessageService: userMessageService,
            screenshotService: screenshotService,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(userMessageService.pendingMessageCount, 0);

    annotationService.addAnnotationProgrammatically(
      x: 10,
      y: 10,
      width: 60,
      height: 40,
      text: 'mark here',
    );
    await tester.pump();

    expect(userMessageService.pendingMessageCount, 1);
    final message = userMessageService.peekMessages().single;
    final data = message['data'] as Map<String, dynamic>;
    expect(data['annotationDraft'], isTrue);
    final annotations = data['annotations'] as List<dynamic>;
    expect(annotations, hasLength(1));
  });

  testWidgets(
      'draft message is recreated after consume while annotation remains',
      (tester) async {
    final inspectorService = InspectorService();
    final annotationService = AnnotationService();
    final userMessageService = UserMessageService();
    final screenshotService =
        ScreenshotService(maxScreenshotSize: const Size(1024, 1024));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.expand(
          child: FlanOverlayWidget(
            inspectorService: inspectorService,
            annotationService: annotationService,
            userMessageService: userMessageService,
            screenshotService: screenshotService,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
    await tester.pump();

    annotationService.addAnnotationProgrammatically(
      x: 20,
      y: 20,
      width: 80,
      height: 50,
      text: 'persist draft',
    );
    await tester.pump();
    expect(userMessageService.pendingMessageCount, 1);

    userMessageService.consumeMessages();
    await tester.pump();

    expect(userMessageService.pendingMessageCount, 1);
    final data = userMessageService.peekMessages().single['data']
        as Map<String, dynamic>;
    expect(data['annotationDraft'], isTrue);
  });
}
