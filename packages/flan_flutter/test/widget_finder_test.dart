import 'package:flan_flutter/src/binding/flan_configuration.dart';
import 'package:flan_flutter/src/services/widget_finder.dart';
import 'package:flan_flutter/src/services/widget_matcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = FlanConfiguration();
  final finder = WidgetFinder();

  testWidgets('findElement finds widget by key', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          key: ValueKey<String>('target'),
          width: 100,
          height: 100,
        ),
      ),
    );

    final element = finder.findElement(
      const KeyMatcher('target'),
      config,
    );
    expect(element, isNotNull);
    expect(element!.widget.key, const ValueKey<String>('target'));
  });

  testWidgets('findElement returns null for missing widget', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(),
      ),
    );

    final element = finder.findElement(
      const KeyMatcher('nonexistent'),
      config,
    );
    expect(element, isNull);
  });

  testWidgets('findElement finds widget by text', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('Find Me'),
      ),
    );

    final element = finder.findElement(
      const TextMatcher('Find Me'),
      config,
    );
    expect(element, isNotNull);
    expect((element!.widget as Text).data, 'Find Me');
  });

  testWidgets('findElementFrom searches subtree only', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            SizedBox(
              key: ValueKey<String>('container'),
              child: Text('Inside'),
            ),
            Text('Outside'),
          ],
        ),
      ),
    );

    // Find the container first
    final container = finder.findElement(
      const KeyMatcher('container'),
      config,
    );
    expect(container, isNotNull);

    // Find text inside the container
    final inside = finder.findElementFrom(
      const TextMatcher('Inside'),
      container,
      config,
    );
    expect(inside, isNotNull);

    // Should NOT find text outside the container
    final outside = finder.findElementFrom(
      const TextMatcher('Outside'),
      container,
      config,
    );
    expect(outside, isNull);
  });

  testWidgets('findElementFrom with null startElement returns null',
      (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(),
      ),
    );

    final element = finder.findElementFrom(
      const KeyMatcher('anything'),
      null,
      config,
    );
    expect(element, isNull);
  });
}
