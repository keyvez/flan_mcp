import 'package:flan_flutter/src/binding/flan_configuration.dart';
import 'package:flan_flutter/src/services/gesture_dispatcher.dart';
import 'package:flan_flutter/src/services/scroll_simulator.dart';
import 'package:flan_flutter/src/services/widget_finder.dart';
import 'package:flan_flutter/src/services/widget_matcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = FlanConfiguration();

  testWidgets('scrollUntilVisible finds already-visible widget',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: const [
              SizedBox(
                key: ValueKey<String>('target'),
                height: 50,
                child: Text('Visible'),
              ),
              SizedBox(height: 500),
            ],
          ),
        ),
      ),
    );

    final dispatcher = GestureDispatcher();
    final finder = WidgetFinder();
    final simulator = ScrollSimulator(dispatcher, finder);

    await tester.runAsync(() async {
      await simulator.scrollUntilVisible(
        const KeyMatcher('target'),
        config,
      );
    });
    // No exception means success — widget was already visible
  });

  testWidgets('scrollUntilVisible throws when no Scrollable found',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('No scroll')),
        ),
      ),
    );

    final dispatcher = GestureDispatcher();
    final finder = WidgetFinder();
    final simulator = ScrollSimulator(dispatcher, finder);

    await tester.runAsync(() async {
      expect(
        () => simulator.scrollUntilVisible(
          const KeyMatcher('nonexistent'),
          config,
        ),
        throwsException,
      );
    });
  });

  testWidgets('scrollUntilVisible with horizontal ListView',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 100,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: const [
                SizedBox(
                  key: ValueKey<String>('h_target'),
                  width: 100,
                  child: Text('Horizontal'),
                ),
                SizedBox(width: 2000),
              ],
            ),
          ),
        ),
      ),
    );

    final dispatcher = GestureDispatcher();
    final finder = WidgetFinder();
    final simulator = ScrollSimulator(dispatcher, finder);

    await tester.runAsync(() async {
      await simulator.scrollUntilVisible(
        const KeyMatcher('h_target'),
        config,
      );
    });
    // Already visible, no scroll needed
  });
}
