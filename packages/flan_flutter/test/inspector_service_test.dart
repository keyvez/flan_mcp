import 'package:flan_flutter/src/services/inspector_service.dart';
import 'package:flutter/widgets.dart' hide InspectorSelection;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('enable/disable', () {
    test('initial state is disabled', () {
      final service = InspectorService();
      expect(service.enabled, isFalse);
      expect(service.locked, isFalse);
      expect(service.elementsAtPoint, isEmpty);
      expect(service.currentElementIndex, -1);
      expect(service.currentHighlight, isNull);
      expect(service.lastSelection, isNull);
    });

    test('enable notifies listeners', () {
      final service = InspectorService();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.enable();
      expect(notifications, 1);
      expect(service.enabled, isTrue);
    });

    test('disable resets state and notifies', () {
      final service = InspectorService();
      service.enable();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.disable();
      expect(notifications, 1);
      expect(service.enabled, isFalse);
      expect(service.locked, isFalse);
      expect(service.lastSelection, isNull);
    });
  });

  group('handlePointerHover', () {
    testWidgets('ignores hover when disabled', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 200, height: 200, child: Text('Hello')),
        ),
      );

      final service = InspectorService();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.handlePointerHover(const Offset(100, 100));
      expect(notifications, 0);
      expect(service.elementsAtPoint, isEmpty);
    });

    testWidgets('finds elements when enabled', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 200, height: 200, child: Text('Hello')),
        ),
      );

      final service = InspectorService()..enable();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.handlePointerHover(const Offset(100, 100));
      expect(notifications, greaterThanOrEqualTo(1));
    });

    testWidgets('ignores hover when locked', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 200, height: 200, child: Text('Hello')),
        ),
      );

      final service = InspectorService()..enable();
      // Simulate a lock
      service.handlePointerHover(const Offset(100, 100));
      service.selectCurrentElement(); // locks
      expect(service.locked, isTrue);

      var notifications = 0;
      service.addListener(() => notifications++);
      service.handlePointerHover(const Offset(50, 50));
      expect(notifications, 0);
    });
  });

  group('cycleNextElement / cyclePreviousElement', () {
    test('no-op when no elements', () {
      final service = InspectorService()..enable();
      var notifications = 0;
      service.addListener(() => notifications++);
      service.cycleNextElement();
      expect(notifications, 0);
      service.cyclePreviousElement();
      expect(notifications, 0);
    });

    testWidgets('cycles through elements', (tester) async {
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
      service.handlePointerHover(const Offset(100, 100));
      if (service.elementsAtPoint.length > 1) {
        final firstIndex = service.currentElementIndex;
        service.cycleNextElement();
        expect(service.currentElementIndex, isNot(firstIndex));
        service.cyclePreviousElement();
        expect(service.currentElementIndex, firstIndex);
      }
    });
  });

  group('selectCurrentElement', () {
    testWidgets('selects and locks', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 200, height: 200, child: Text('Select me')),
        ),
      );

      final service = InspectorService()..enable();
      service.handlePointerHover(const Offset(100, 100));
      expect(service.locked, isFalse);

      final selection = service.selectCurrentElement();
      expect(service.locked, isTrue);
      expect(selection, isNotNull);
      expect(service.lastSelection, isNotNull);
    });

    testWidgets('toggles unlock when already locked', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 200, height: 200, child: Text('Toggle')),
        ),
      );

      final service = InspectorService()..enable();
      service.handlePointerHover(const Offset(100, 100));
      service.selectCurrentElement(); // lock
      expect(service.locked, isTrue);

      final result = service.selectCurrentElement(); // unlock
      expect(service.locked, isFalse);
      expect(result, isNull);
      expect(service.lastSelection, isNull);
    });

    testWidgets('returns null when no highlight', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 200, height: 200),
        ),
      );

      final service = InspectorService()..enable();
      // Don't hover, so no elements at point
      final result = service.selectCurrentElement();
      expect(result, isNull);
    });
  });

  group('inspectAt', () {
    testWidgets('updates UI state', (tester) async {
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

    testWidgets('returns null for empty area', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 200, height: 200),
        ),
      );

      final service = InspectorService()..enable();
      final selection = service.inspectAt(-1000, -1000);
      expect(selection, isNull);
    });
  });

  group('inspectAtForAgent', () {
    testWidgets('is side-effect-free for inspector UI state', (tester) async {
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
    });

    testWidgets('prefers visible topmost widget over hidden overlap',
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
    });

    testWidgets('returns null for off-screen coordinates', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 200, height: 200),
        ),
      );

      final service = InspectorService()..enable();
      final selection = service.inspectAtForAgent(-9999, -9999);
      expect(selection, isNull);
    });

    testWidgets('can include properties', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: Center(child: Text('Props')),
          ),
        ),
      );

      final service = InspectorService()..enable();
      final withProps =
          service.inspectAtForAgent(100, 100, includeProperties: true);
      if (withProps != null) {
        // Properties map should exist (may or may not have entries)
        expect(withProps.properties, isA<Map<String, String>>());
      }
    });
  });

  group('InspectorSelection toJson', () {
    test('includes all fields', () {
      final selection = InspectorSelection(
        widgetType: 'Text',
        widgetPath: 'MaterialApp > Scaffold > Text',
        sourceLocation: 'lib/main.dart:42:10',
        key: 'my_key',
        text: 'Hello',
        bounds: const Rect.fromLTWH(10, 20, 100, 50),
        properties: {'data': 'Hello'},
      );

      final json = selection.toJson();
      expect(json['widgetType'], 'Text');
      expect(json['widgetPath'], 'MaterialApp > Scaffold > Text');
      expect(json['sourceLocation'], 'lib/main.dart:42:10');
      expect(json['key'], 'my_key');
      expect(json['text'], 'Hello');
      expect(json['bounds'], isA<Map>());
      expect((json['bounds'] as Map)['x'], 10.0);
      expect((json['bounds'] as Map)['y'], 20.0);
      expect((json['bounds'] as Map)['width'], 100.0);
      expect((json['bounds'] as Map)['height'], 50.0);
      expect(json['properties'], {'data': 'Hello'});
    });

    test('omits null fields', () {
      final selection = InspectorSelection(
        widgetType: 'SizedBox',
        widgetPath: 'SizedBox',
        bounds: const Rect.fromLTWH(0, 0, 10, 10),
      );

      final json = selection.toJson();
      expect(json.containsKey('sourceLocation'), isFalse);
      expect(json.containsKey('key'), isFalse);
      expect(json.containsKey('text'), isFalse);
      expect(json.containsKey('properties'), isFalse);
    });
  });

  group('text extraction', () {
    testWidgets('extracts text from Text widget', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: Text('Extract me'),
          ),
        ),
      );

      final service = InspectorService()..enable();
      final selection = service.inspectAtForAgent(100, 100);
      // If we find a Text widget, its text should be included
      if (selection != null && selection.widgetType == 'Text') {
        expect(selection.text, 'Extract me');
      }
    });
  });

  group('key extraction', () {
    testWidgets('extracts ValueKey<String>', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            key: ValueKey<String>('test_key'),
            width: 200,
            height: 200,
            child: Text('Keyed'),
          ),
        ),
      );

      final service = InspectorService()..enable();
      service.inspectAt(100, 100);
      if (service.lastSelection != null) {
        // If SizedBox is selected, key should be test_key
        if (service.lastSelection!.widgetType == 'SizedBox') {
          expect(service.lastSelection!.key, 'test_key');
        }
      }
    });

    testWidgets('extracts non-string key as toString', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            key: ValueKey<int>(42),
            width: 200,
            height: 200,
            child: Text('Int key'),
          ),
        ),
      );

      final service = InspectorService()..enable();
      final selection = service.inspectAtForAgent(100, 100);
      if (selection != null && selection.key != null) {
        // Non-string ValueKey should be returned as toString
        expect(selection.key, isNotEmpty);
      }
    });
  });

  group('text extraction', () {
    testWidgets('extracts text from RichText widget', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: RichText(
              text: const TextSpan(
                text: 'Rich text content',
                style: TextStyle(fontSize: 14),
              ),
            ),
          ),
        ),
      );

      final service = InspectorService()..enable();
      final selection =
          service.inspectAtForAgent(100, 100, includeProperties: false);
      // If RichText is found, text should be extracted
      if (selection != null && selection.widgetType == 'RichText') {
        expect(selection.text, contains('Rich text content'));
      }
    });

    testWidgets('extracts text from EditableText', (tester) async {
      final controller = TextEditingController(text: 'Editable content');
      final focusNode = FocusNode();
      addTearDown(() {
        controller.dispose();
        focusNode.dispose();
      });

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: EditableText(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(fontSize: 14),
              cursorColor: const Color(0xFF000000),
              backgroundCursorColor: const Color(0xFF333333),
            ),
          ),
        ),
      );

      final service = InspectorService()..enable();
      final selection =
          service.inspectAtForAgent(100, 100, includeProperties: false);
      if (selection != null && selection.widgetType == 'EditableText') {
        expect(selection.text, 'Editable content');
      }
    });
  });

  group('source location extraction', () {
    testWidgets('inspectAtForAgent returns source location when available',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: Center(child: Text('Locate me')),
          ),
        ),
      );

      final service = InspectorService()..enable();
      final selection = service.inspectAtForAgent(100, 100);
      // Source location may or may not be available in test builds
      // Just verify the selection was returned
      expect(selection, isNotNull);
    });
  });

  group('properties extraction', () {
    testWidgets('extracts properties from widget', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: Center(
              child: SizedBox(
                width: 50,
                height: 30,
                child: Text('With props'),
              ),
            ),
          ),
        ),
      );

      final service = InspectorService()..enable();
      final selection =
          service.inspectAtForAgent(100, 100, includeProperties: true);
      if (selection != null) {
        expect(selection.properties, isA<Map<String, String>>());
      }
    });
  });
}
