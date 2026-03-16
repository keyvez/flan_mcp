import 'package:flan_flutter/src/binding/flan_configuration.dart';
import 'package:flan_flutter/src/services/gesture_dispatcher.dart';
import 'package:flan_flutter/src/services/widget_finder.dart';
import 'package:flan_flutter/src/services/widget_matcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = FlanConfiguration();

  testWidgets('tap by key dispatches to matching widget', (tester) async {
    var tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey<String>('my_btn'),
              onPressed: () => tapped = true,
              child: const Text('Tap Me'),
            ),
          ),
        ),
      ),
    );

    final dispatcher = GestureDispatcher();
    final finder = WidgetFinder();

    await tester.runAsync(() async {
      await dispatcher.tap(
        const KeyMatcher('my_btn'),
        finder,
        config,
      );
    });
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
  });

  testWidgets('tap throws when element not found', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox()),
      ),
    );

    final dispatcher = GestureDispatcher();
    final finder = WidgetFinder();

    await tester.runAsync(() async {
      expect(
        () => dispatcher.tap(
          const KeyMatcher('nonexistent'),
          finder,
          config,
        ),
        throwsException,
      );
    });
  });

  testWidgets('tap at coordinates creates pointer events', (tester) async {
    var tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey<String>('coord_btn'),
              onPressed: () => tapped = true,
              child: const Text('Coord Tap'),
            ),
          ),
        ),
      ),
    );

    final dispatcher = GestureDispatcher();
    final finder = WidgetFinder();

    // Get the center coordinates of the button
    final element = finder.findElement(const KeyMatcher('coord_btn'), config);
    expect(element, isNotNull);
    final box = element!.renderObject as RenderBox;
    final center = box.localToGlobal(box.size.center(Offset.zero));

    await tester.runAsync(() async {
      await dispatcher.tap(
        CoordinatesMatcher(center.dx, center.dy),
        finder,
        config,
      );
    });
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
  });

  testWidgets('drag dispatches pointer move events from start to end',
      (tester) async {
    var dragOffset = Offset.zero;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            onPanUpdate: (details) {
              dragOffset += details.delta;
            },
            child: const SizedBox.expand(
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );

    final dispatcher = GestureDispatcher();

    await tester.runAsync(() async {
      await dispatcher.drag(
        const Offset(200, 300),
        const Offset(300, 400),
      );
    });
    await tester.pumpAndSettle();

    // The drag should have moved roughly 100 in x and 100 in y
    expect(dragOffset.dx, closeTo(100, 20));
    expect(dragOffset.dy, closeTo(100, 20));
  });

  testWidgets('drag with short distance completes without error',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            onPanUpdate: (_) {},
            child: const SizedBox.expand(
              child: ColoredBox(color: Colors.green),
            ),
          ),
        ),
      ),
    );

    final dispatcher = GestureDispatcher();

    await tester.runAsync(() async {
      // Drag a very small distance (less than kMaxDelta)
      await dispatcher.drag(
        const Offset(200, 200),
        const Offset(205, 205),
      );
    });
    // Should complete without error
  });
}
