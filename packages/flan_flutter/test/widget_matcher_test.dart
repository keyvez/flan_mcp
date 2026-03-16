import 'package:flan_flutter/src/binding/flan_configuration.dart';
import 'package:flan_flutter/src/services/widget_matcher.dart' as wm;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const config = FlanConfiguration();

  group('WidgetMatcher.fromJson', () {
    test('coordinates take highest precedence', () {
      final matcher = wm.WidgetMatcher.fromJson({
        'x': '10.0',
        'y': '20.0',
        'key': 'some_key',
        'text': 'some text',
      });
      expect(matcher, isA<wm.CoordinatesMatcher>());
    });

    test('key takes precedence over text and type', () {
      final matcher = wm.WidgetMatcher.fromJson({
        'key': 'my_key',
        'text': 'some text',
        'type': 'SomeType',
      });
      expect(matcher, isA<wm.KeyMatcher>());
    });

    test('text takes precedence over type', () {
      final matcher = wm.WidgetMatcher.fromJson({
        'text': 'some text',
        'type': 'SomeType',
      });
      expect(matcher, isA<wm.TextMatcher>());
    });

    test('type is used when no other fields present', () {
      final matcher = wm.WidgetMatcher.fromJson({
        'type': 'ElevatedButton',
      });
      expect(matcher, isA<wm.TypeStringMatcher>());
    });

    test('throws ArgumentError when no valid fields', () {
      expect(
        () => wm.WidgetMatcher.fromJson({'invalid': 'field'}),
        throwsArgumentError,
      );
    });

    test('empty map throws ArgumentError', () {
      expect(
        () => wm.WidgetMatcher.fromJson({}),
        throwsArgumentError,
      );
    });
  });

  group('CoordinatesMatcher', () {
    test('fromJson parses x and y', () {
      final matcher = wm.CoordinatesMatcher.fromJson({'x': '10.5', 'y': '20.3'});
      expect(matcher.x, 10.5);
      expect(matcher.y, 20.3);
    });

    test('offset getter returns correct Offset', () {
      const matcher = wm.CoordinatesMatcher(15.0, 25.0);
      expect(matcher.offset, const Offset(15.0, 25.0));
    });

    test('matches always returns false', () {
      const matcher = wm.CoordinatesMatcher(10.0, 20.0);
      expect(matcher.matches(const Text('hi'), config), isFalse);
    });

    test('toJson returns x and y', () {
      const matcher = wm.CoordinatesMatcher(10.0, 20.0);
      expect(matcher.toJson(), {'x': 10.0, 'y': 20.0});
    });
  });

  group('KeyMatcher', () {
    test('matches widget with matching ValueKey<String>', () {
      const matcher = wm.KeyMatcher('test_key');
      const widget = SizedBox(key: ValueKey<String>('test_key'));
      expect(matcher.matches(widget, config), isTrue);
    });

    test('does not match widget with different key', () {
      const matcher = wm.KeyMatcher('test_key');
      const widget = SizedBox(key: ValueKey<String>('other_key'));
      expect(matcher.matches(widget, config), isFalse);
    });

    test('does not match widget with non-string ValueKey', () {
      const matcher = wm.KeyMatcher('42');
      const widget = SizedBox(key: ValueKey<int>(42));
      expect(matcher.matches(widget, config), isFalse);
    });

    test('does not match widget without key', () {
      const matcher = wm.KeyMatcher('test_key');
      const widget = SizedBox();
      expect(matcher.matches(widget, config), isFalse);
    });

    test('fromJson parses key', () {
      final matcher = wm.KeyMatcher.fromJson({'key': 'my_key'});
      expect(matcher.keyValue, 'my_key');
    });

    test('toJson returns key', () {
      const matcher = wm.KeyMatcher('my_key');
      expect(matcher.toJson(), {'key': 'my_key'});
    });
  });

  group('TextMatcher', () {
    test('matches Text widget with matching text', () {
      const matcher = wm.TextMatcher('Hello');
      const widget = Text('Hello');
      expect(matcher.matches(widget, config), isTrue);
    });

    test('does not match Text widget with different text', () {
      const matcher = wm.TextMatcher('Hello');
      const widget = Text('World');
      expect(matcher.matches(widget, config), isFalse);
    });

    test('fromJson parses text', () {
      final matcher = wm.TextMatcher.fromJson({'text': 'test'});
      expect(matcher.text, 'test');
    });

    test('toJson returns text', () {
      const matcher = wm.TextMatcher('test');
      expect(matcher.toJson(), {'text': 'test'});
    });
  });

  group('TypeMatcher', () {
    test('matches widget with matching runtime type', () {
      const matcher = wm.TypeMatcher(Text);
      const widget = Text('hi');
      expect(matcher.matches(widget, config), isTrue);
    });

    test('does not match widget with different type', () {
      const matcher = wm.TypeMatcher(Text);
      const widget = SizedBox();
      expect(matcher.matches(widget, config), isFalse);
    });

    test('toJson throws UnsupportedError', () {
      const matcher = wm.TypeMatcher(Text);
      expect(() => matcher.toJson(), throwsUnsupportedError);
    });
  });

  group('TypeStringMatcher', () {
    test('matches widget by type name string', () {
      const matcher = wm.TypeStringMatcher('SizedBox');
      const widget = SizedBox();
      expect(matcher.matches(widget, config), isTrue);
    });

    test('does not match widget with different type name', () {
      const matcher = wm.TypeStringMatcher('Text');
      const widget = SizedBox();
      expect(matcher.matches(widget, config), isFalse);
    });

    test('fromJson parses type', () {
      final matcher = wm.TypeStringMatcher.fromJson({'type': 'Button'});
      expect(matcher.typeName, 'Button');
    });

    test('toJson returns type', () {
      const matcher = wm.TypeStringMatcher('Button');
      expect(matcher.toJson(), {'type': 'Button'});
    });
  });
}
