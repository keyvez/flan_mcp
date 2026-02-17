import 'package:flutter_test/flutter_test.dart';
import 'package:flan_flutter/src/utils/num_parser.dart';

void main() {
  group('parseRequiredDoubleParam', () {
    test('parses int values', () {
      final value = parseRequiredDoubleParam(42, 'x');

      expect(value, 42.0);
    });

    test('parses double values', () {
      final value = parseRequiredDoubleParam(42.5, 'x');

      expect(value, 42.5);
    });

    test('parses numeric strings', () {
      final value = parseRequiredDoubleParam('42.5', 'x');

      expect(value, 42.5);
    });

    test('throws for non-numeric strings', () {
      expect(
        () => parseRequiredDoubleParam('abc', 'x'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws for null values', () {
      expect(
        () => parseRequiredDoubleParam(null, 'x'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
