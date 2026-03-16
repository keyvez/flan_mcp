import 'package:flan_flutter/src/binding/flan_configuration.dart';
import 'package:flan_flutter/src/services/element_tree_finder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = FlanConfiguration();

  testWidgets('finds interactive button elements', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ElevatedButton(
                key: ValueKey<String>('test_btn'),
                onPressed: null,
                child: Text('Click Me'),
              ),
            ],
          ),
        ),
      ),
    );

    final finder = ElementTreeFinder(config);
    final elements = finder.findInteractiveElements();

    // Should find at least the ElevatedButton
    final button = elements.where(
      (e) => e['type'] == 'ElevatedButton',
    );
    expect(button, isNotEmpty);
    expect(button.first['key'], 'test_btn');
  });

  testWidgets('finds text widgets', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('Hello World'),
          ),
        ),
      ),
    );

    final finder = ElementTreeFinder(config);
    final elements = finder.findInteractiveElements();

    // Should find the Text widget
    final textElements = elements.where(
      (e) => e['text'] == 'Hello World',
    );
    expect(textElements, isNotEmpty);
  });

  testWidgets('includes bounds for elements', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 50,
              child: ElevatedButton(
                onPressed: null,
                child: Text('Test'),
              ),
            ),
          ),
        ),
      ),
    );

    final finder = ElementTreeFinder(config);
    final elements = finder.findInteractiveElements();

    final button = elements.firstWhere(
      (e) => e['type'] == 'ElevatedButton',
    );
    expect(button['bounds'], isA<Map>());
    final bounds = button['bounds'] as Map;
    expect(bounds['x'], isA<double>());
    expect(bounds['y'], isA<double>());
    expect(bounds['width'], isA<double>());
    expect(bounds['height'], isA<double>());
  });

  testWidgets('includes visibility information', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: null,
              child: Text('Visible'),
            ),
          ),
        ),
      ),
    );

    final finder = ElementTreeFinder(config);
    final elements = finder.findInteractiveElements();

    final button = elements.firstWhere(
      (e) => e['type'] == 'ElevatedButton',
    );
    expect(button['visible'], isA<bool>());
  });

  testWidgets('extracts key from ValueKey<String>', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TextField(
            key: ValueKey<String>('my_input'),
          ),
        ),
      ),
    );

    final finder = ElementTreeFinder(config);
    final elements = finder.findInteractiveElements();

    final textField = elements.firstWhere(
      (e) => e['type'] == 'TextField',
    );
    expect(textField['key'], 'my_input');
  });

  testWidgets('custom isInteractiveWidget extends detection', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GestureDetector(
              key: const ValueKey<String>('custom_widget'),
              onTap: () {},
              child: const ColoredBox(
                color: Color(0xFF0000FF),
                child: SizedBox(width: 100, height: 100),
              ),
            ),
          ),
        ),
      ),
    );

    final customConfig = FlanConfiguration(
      isInteractiveWidget: (type) => type == GestureDetector,
    );

    final finder = ElementTreeFinder(customConfig);
    final elements = finder.findInteractiveElements();

    final widget = elements.where(
      (e) => e['key'] == 'custom_widget',
    );
    expect(widget, isNotEmpty);
  });

  testWidgets('finds multiple interactive elements', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ElevatedButton(
                onPressed: () {},
                child: const Text('Button 1'),
              ),
              ElevatedButton(
                onPressed: () {},
                child: const Text('Button 2'),
              ),
              const TextField(),
            ],
          ),
        ),
      ),
    );

    final finder = ElementTreeFinder(config);
    final elements = finder.findInteractiveElements();

    // Should find at least the two buttons and the text field
    final buttons = elements.where(
      (e) => e['type'] == 'ElevatedButton',
    );
    expect(buttons.length, greaterThanOrEqualTo(2));
  });
}
