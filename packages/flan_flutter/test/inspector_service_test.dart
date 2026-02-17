import 'package:flan_flutter/src/services/inspector_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'inspectAtForAgent is side-effect-free for inspector UI state',
    (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: Center(child: Text('Hello')),
          ),
        ),
      );

      final service = InspectorService()..enable();
      var notifications = 0;
      service.addListener(() => notifications++);

      service.inspectAtForAgent(20, 20);

      expect(notifications, 0);
      expect(service.lastSelection, isNull);
      expect(service.elementsAtPoint, isEmpty);
      expect(service.currentElementIndex, -1);
    },
  );

  testWidgets('inspectAt updates inspector UI state', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 200,
          height: 200,
          child: Center(child: Text('Hello')),
        ),
      ),
    );

    final service = InspectorService()..enable();
    var notifications = 0;
    service.addListener(() => notifications++);

    service.inspectAt(20, 20);

    expect(notifications, 1);
  });

  testWidgets(
    'inspectAtForAgent prefers visible topmost widget over hidden overlap',
    (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: Stack(
              children: [
                Center(
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: ColoredBox(
                      key: ValueKey<String>('hidden-under'),
                      color: Color(0xFF00AA55),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: ColoredBox(
                    key: ValueKey<String>('visible-top'),
                    color: Color(0xAA3366FF),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final service = InspectorService()..enable();
      final selection = service.inspectAtForAgent(100, 100);

      expect(selection, isNotNull);
      expect(selection!.key, isNot('hidden-under'));
    },
  );
}
