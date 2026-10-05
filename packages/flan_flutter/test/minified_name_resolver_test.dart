import 'dart:convert';
import 'dart:io';

import 'package:flan_flutter/src/services/minified_name_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real dart2js map, if the person running the tests has one.
///
/// The parser's whole job is to understand a format nobody in this repository
/// controls, so the test that actually matters is the one run against output
/// dart2js produced. It cannot be a committed fixture — a representative map
/// is several megabytes — and it must not be a path on one machine, so it is
/// opt-in:
///
///     flutter test --dart-define=FLAN_DART2JS_MAP=/path/to/main.dart.js.map
///
/// Without it the case is skipped rather than silently passing, so a run that
/// did not exercise the real format says so.
const _realMap = String.fromEnvironment('FLAN_DART2JS_MAP');

void main() {
  setUp(MinifiedNameResolver.reset);

  group('parseMap', () {
    test('reads the dart2js minified_names extension', () {
      final source = jsonEncode({
        'version': 3,
        'names': ['CorpConsoleScreen', 'AuthProvider', 'Widget.build'],
        'x_org_dartlang_dart2js': {
          'minified_names': {
            'global': 'Hb,0,d7,1',
            'instance': 'aB,2',
          },
        },
      });

      final table = MinifiedNameResolver.parseMap(source);

      expect(table['Hb'], 'CorpConsoleScreen');
      expect(table['d7'], 'AuthProvider');
      expect(table['aB'], 'Widget.build');
    });

    /// Every one of these has a plausible route into a real map, and none of
    /// them may throw: the resolver runs while somebody is trying to file a
    /// bug report, and failing there would lose the report.
    test('survives malformed and missing input', () {
      for (final source in <String>[
        '{}',
        '[]',
        'not json at all',
        jsonEncode({'names': 'not a list'}),
        jsonEncode({'names': <String>[], 'x_org_dartlang_dart2js': 'nope'}),
        // Index past the end of `names`.
        jsonEncode({
          'names': ['A'],
          'x_org_dartlang_dart2js': {
            'minified_names': {'global': 'Hb,99'},
          },
        }),
        // Odd trailing element — a name with no index.
        jsonEncode({
          'names': ['A'],
          'x_org_dartlang_dart2js': {
            'minified_names': {'global': 'Hb,0,orphan'},
          },
        }),
        // Index that is not a number.
        jsonEncode({
          'names': ['A'],
          'x_org_dartlang_dart2js': {
            'minified_names': {'global': 'Hb,x'},
          },
        }),
      ]) {
        expect(
          () => MinifiedNameResolver.parseMap(source),
          returnsNormally,
          reason:
              'threw on: ${source.substring(0, source.length.clamp(0, 40))}',
        );
      }
    });
  });

  group('resolveIn', () {
    test('rewrites only the minified parts', () async {
      MinifiedNameResolver.seed({'Hb': 'CorpConsoleScreen'});

      expect(
        await MinifiedNameResolver.resolveIn(
          'Selected widget: minified:Hb at /s/corp',
        ),
        'Selected widget: CorpConsoleScreen at /s/corp',
      );
    });

    test('leaves an unknown minified name exactly as it was', () async {
      MinifiedNameResolver.seed({'Hb': 'CorpConsoleScreen'});

      // Honest and opaque beats guessed. A wrong name sends somebody to the
      // wrong file.
      expect(
        await MinifiedNameResolver.resolveIn('Widget: minified:zz9'),
        'Widget: minified:zz9',
      );
    });

    test('is a pass-through when nothing is minified', () async {
      MinifiedNameResolver.mapUrl = null;

      const text = 'Selected widget: SettingsScreen at /s/settings';
      expect(await MinifiedNameResolver.resolveIn(text), text);
      // Never touched the map: an unminified build must not pay for this.
      expect(MinifiedNameResolver.knownNames, 0);
    });
  });

  group('against a real dart2js map', () {
    test('resolves app classes end to end', () async {
      if (_realMap.isEmpty) {
        markTestSkipped(
          'set --dart-define=FLAN_DART2JS_MAP=<main.dart.js.map> to run this',
        );
        return;
      }
      final file = File(_realMap);
      if (!file.existsSync()) {
        markTestSkipped('no dart2js map at $_realMap');
        return;
      }

      final table = MinifiedNameResolver.parseMap(file.readAsStringSync());
      expect(table, isNotEmpty);

      // Reverse the table and check the round trip on classes this app
      // actually has, rather than asserting a minified name that changes with
      // every build.
      final reverse = {for (final e in table.entries) e.value: e.key};
      for (final className in const [
        'CorpConsoleScreen',
        'AuthProvider',
        'SettingsScreen',
      ]) {
        final short = reverse[className];
        expect(short, isNotNull, reason: '$className missing from the map');
        expect(table[short], className);
      }

      MinifiedNameResolver.seed(table);
      final short = reverse['CorpConsoleScreen']!;
      expect(
        await MinifiedNameResolver.resolveIn('Widget: minified:$short'),
        'Widget: CorpConsoleScreen',
      );
    });
  });

  // An annotation reaches an agent as prose AND as a JSON `data` map, and the
  // widget names live at several depths inside the second. The overlay
  // resolves that map by running the resolver over the ENCODED json, which is
  // only safe because a minified token can never contain a quote or a brace.
  group('resolving over encoded json', () {
    setUp(MinifiedNameResolver.reset);
    tearDown(MinifiedNameResolver.reset);

    test('nested widget names resolve and the structure survives', () async {
      MinifiedNameResolver.seed({'Q0': 'SimpleShortlistView', 'alL': 'AppShell'});
      final payload = {
        'annotations': [
          {
            'text': 'simplify this view',
            'widget': {
              'widgetType': 'minified:Q0',
              'widgetPath': 'minified:alL > minified:Q0',
            },
          },
        ],
      };

      final resolved = jsonDecode(
        await MinifiedNameResolver.resolveIn(jsonEncode(payload)),
      ) as Map<String, dynamic>;

      final widget =
          (resolved['annotations'] as List).first['widget'] as Map;
      expect(widget['widgetType'], 'SimpleShortlistView');
      expect(widget['widgetPath'], 'AppShell > SimpleShortlistView');
      // Untouched text stays exactly as the user typed it.
      expect(
        (resolved['annotations'] as List).first['text'],
        'simplify this view',
      );
    });

    test('an unknown name is left alone rather than guessed at', () async {
      MinifiedNameResolver.seed({'Q0': 'SimpleShortlistView'});
      final resolved = jsonDecode(
        await MinifiedNameResolver.resolveIn(
          jsonEncode({'widgetType': 'minified:zZ9'}),
        ),
      ) as Map<String, dynamic>;
      expect(resolved['widgetType'], 'minified:zZ9');
    });

    test('a payload with nothing minified comes back identical', () async {
      MinifiedNameResolver.seed({'Q0': 'SimpleShortlistView'});
      const encoded = '{"widgetType":"SimpleShortlistView"}';
      expect(await MinifiedNameResolver.resolveIn(encoded), same(encoded));
    });
  });
}
