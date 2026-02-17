import 'package:flan_mcp/src/utils/num_parser.dart';
import 'package:test/test.dart';

void main() {
  group('parseRequiredDoubleArg', () {
    test('parses int values', () {
      final value = parseRequiredDoubleArg(<String, dynamic>{'x': 12}, 'x');

      expect(value, 12.0);
    });

    test('parses double values', () {
      final value = parseRequiredDoubleArg(<String, dynamic>{'x': 12.5}, 'x');

      expect(value, 12.5);
    });

    test('parses numeric strings', () {
      final value = parseRequiredDoubleArg(<String, dynamic>{'x': '12.5'}, 'x');

      expect(value, 12.5);
    });

    test('throws for non-numeric strings', () {
      expect(
        () => parseRequiredDoubleArg(<String, dynamic>{'x': 'abc'}, 'x'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when key is missing', () {
      expect(
        () => parseRequiredDoubleArg(<String, dynamic>{}, 'x'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
