import 'package:flan_flutter/src/binding/flan_configuration.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FlanConfiguration defaults', () {
    test('default maxScreenshotSize is 2000x2000', () {
      const config = FlanConfiguration();
      expect(config.maxScreenshotSize, const Size(2000, 2000));
    });

    test('default callbacks are null', () {
      const config = FlanConfiguration();
      expect(config.isInteractiveWidget, isNull);
      expect(config.shouldStopTraversal, isNull);
      expect(config.extractText, isNull);
    });
  });

  group('isInteractiveWidgetType', () {
    test('recognizes built-in interactive widgets', () {
      const config = FlanConfiguration();

      expect(config.isInteractiveWidgetType(ElevatedButton), isTrue);
      expect(config.isInteractiveWidgetType(TextButton), isTrue);
      expect(config.isInteractiveWidgetType(IconButton), isTrue);
      expect(config.isInteractiveWidgetType(FloatingActionButton), isTrue);
      expect(config.isInteractiveWidgetType(OutlinedButton), isTrue);
      expect(config.isInteractiveWidgetType(FilledButton), isTrue);
      expect(config.isInteractiveWidgetType(TextField), isTrue);
      expect(config.isInteractiveWidgetType(TextFormField), isTrue);
      expect(config.isInteractiveWidgetType(Checkbox), isTrue);
      expect(config.isInteractiveWidgetType(Switch), isTrue);
      expect(config.isInteractiveWidgetType(Slider), isTrue);
      expect(config.isInteractiveWidgetType(Radio), isTrue);
      expect(config.isInteractiveWidgetType(GestureDetector), isTrue);
      expect(config.isInteractiveWidgetType(InkWell), isTrue);
      expect(config.isInteractiveWidgetType(DropdownButton), isTrue);
      expect(config.isInteractiveWidgetType(PopupMenuButton), isTrue);
      expect(config.isInteractiveWidgetType(CheckboxListTile), isTrue);
      expect(config.isInteractiveWidgetType(RadioListTile), isTrue);
      expect(config.isInteractiveWidgetType(SwitchListTile), isTrue);
    });

    test('does not recognize non-interactive widgets', () {
      const config = FlanConfiguration();

      expect(config.isInteractiveWidgetType(Container), isFalse);
      expect(config.isInteractiveWidgetType(SizedBox), isFalse);
      expect(config.isInteractiveWidgetType(Text), isFalse);
      expect(config.isInteractiveWidgetType(Padding), isFalse);
    });

    test('custom callback extends interactive widget types', () {
      final config = FlanConfiguration(
        isInteractiveWidget: (type) => type == Container,
      );

      expect(config.isInteractiveWidgetType(Container), isTrue);
      // Built-in still works
      expect(config.isInteractiveWidgetType(ElevatedButton), isTrue);
    });
  });

  group('shouldStopAtType', () {
    test('stops at built-in interactive widgets except GestureDetector/InkWell',
        () {
      const config = FlanConfiguration();

      // Should stop at interactive widgets
      expect(config.shouldStopAtType(ElevatedButton), isTrue);
      expect(config.shouldStopAtType(TextField), isTrue);
      expect(config.shouldStopAtType(Checkbox), isTrue);

      // Should NOT stop at GestureDetector and InkWell
      expect(config.shouldStopAtType(GestureDetector), isFalse);
      expect(config.shouldStopAtType(InkWell), isFalse);
    });

    test('stops at Text widget', () {
      const config = FlanConfiguration();
      expect(config.shouldStopAtType(Text), isTrue);
    });

    test('does not stop at non-interactive widgets without custom callback', () {
      const config = FlanConfiguration();
      expect(config.shouldStopAtType(Container), isFalse);
      expect(config.shouldStopAtType(SizedBox), isFalse);
    });

    test('custom shouldStopTraversal extends stop types', () {
      final config = FlanConfiguration(
        shouldStopTraversal: (type) => type == Container,
      );

      expect(config.shouldStopAtType(Container), isTrue);
      // Built-in still works
      expect(config.shouldStopAtType(ElevatedButton), isTrue);
    });
  });

  group('extractTextFromWidget', () {
    test('extracts text from Text widget', () {
      const config = FlanConfiguration();
      expect(
        config.extractTextFromWidget(const Text('hello')),
        'hello',
      );
    });

    test('extracts text from RichText widget', () {
      const config = FlanConfiguration();
      final widget = RichText(
        text: const TextSpan(text: 'rich text'),
      );
      expect(config.extractTextFromWidget(widget), 'rich text');
    });

    test('extracts text from EditableText widget', () {
      const config = FlanConfiguration();
      final controller = TextEditingController(text: 'editable');
      final widget = EditableText(
        controller: controller,
        focusNode: FocusNode(),
        style: const TextStyle(),
        cursorColor: const Color(0xFF000000),
        backgroundCursorColor: const Color(0xFF000000),
      );
      expect(config.extractTextFromWidget(widget), 'editable');
    });

    test('extracts text from TextField with controller', () {
      const config = FlanConfiguration();
      final controller = TextEditingController(text: 'field text');
      final widget = TextField(controller: controller);
      expect(config.extractTextFromWidget(widget), 'field text');
    });

    test('extracts text from TextFormField with controller', () {
      const config = FlanConfiguration();
      final controller = TextEditingController(text: 'form text');
      final widget = TextFormField(controller: controller);
      expect(config.extractTextFromWidget(widget), 'form text');
    });

    test('returns null for non-text widget without custom callback', () {
      const config = FlanConfiguration();
      expect(config.extractTextFromWidget(const SizedBox()), isNull);
    });

    test('custom extractText extends extraction', () {
      final config = FlanConfiguration(
        extractText: (widget) {
          if (widget is SizedBox) return 'custom text';
          return null;
        },
      );

      expect(config.extractTextFromWidget(const SizedBox()), 'custom text');
      // Built-in still works
      expect(config.extractTextFromWidget(const Text('hi')), 'hi');
    });
  });
}
