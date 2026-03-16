import 'package:flan_flutter/src/binding/flan_configuration.dart';
import 'package:flan_flutter/src/services/text_input_simulator.dart';
import 'package:flan_flutter/src/services/widget_finder.dart';
import 'package:flan_flutter/src/services/widget_matcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = FlanConfiguration();
  final finder = WidgetFinder();
  final simulator = TextInputSimulator(finder);

  testWidgets('enterText updates text field controller', (tester) async {
    final controller = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            key: const ValueKey<String>('input'),
            controller: controller,
          ),
        ),
      ),
    );

    await tester.runAsync(() async {
      await simulator.enterText(
        const KeyMatcher('input'),
        'Hello World',
        config,
      );
    });
    await tester.pumpAndSettle();

    expect(controller.text, 'Hello World');
    expect(controller.selection.baseOffset, 'Hello World'.length);
  });

  testWidgets('enterText throws when element not found', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox()),
      ),
    );

    await tester.runAsync(() async {
      expect(
        () => simulator.enterText(
          const KeyMatcher('nonexistent'),
          'text',
          config,
        ),
        throwsException,
      );
    });
  });
}
