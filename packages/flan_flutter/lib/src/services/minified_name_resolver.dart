/// Turn `minified:Hb` back into `CorpConsoleScreen`.
///
/// A dart2js release build minifies type names, so `runtimeType.toString()`
/// returns `minified:Hb` rather than the class a person would recognise. The
/// usual answer is to ship the host app unminified, which is what this one did
/// — and an unminified bundle costs roughly 3.2x, which is how its
/// `main.dart.js` reached 25.13 MiB against Cloudflare's 25 MiB per-asset
/// ceiling and stopped deploying at all.
///
/// The names were never actually lost. dart2js writes the mapping into the
/// source map, under the `x_org_dartlang_dart2js.minified_names` extension:
/// two tables, `global` and `instance`, each a comma-separated run of
/// `minified, index` pairs where the index points into the map's own `names`
/// array. So a minified build plus its map carries strictly more information
/// than an unminified build did, in a file that does not count against the
/// bundle's size limit.
///
/// ## When this runs
///
/// Only when a report is being filed. That is deliberate: resolving is a
/// several-megabyte fetch and parse, and a widget name is read by a human
/// exactly once, in the issue. Doing it in the inspector — on selection, on
/// hover, on every tree walk — would pay that cost continuously to produce a
/// string nobody looks at. [resolveIn] is therefore called while composing
/// issue text, and nowhere else.
///
/// ## When it does nothing
///
/// On an unminified build there is nothing to resolve and no `minified:`
/// prefix to find, so every method here is a pass-through. A host that never
/// configures [mapUrl] behaves the same way. Failure to fetch or parse the map
/// is not an error either: the report is still worth filing with `minified:Hb`
/// in it, and a debugging aid that could block a bug report would be worse
/// than the problem it solves.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class MinifiedNameResolver {
  MinifiedNameResolver._();

  /// Where the source map lives. Set by the host app; null disables
  /// resolution entirely.
  static String? mapUrl;

  /// Minified name to real name, once the map has been read.
  static Map<String, String>? _table;

  /// Whether a load has been attempted. Distinct from `_table == null` so a
  /// failed fetch is not retried on every subsequent report in the session.
  static bool _attempted = false;

  /// What a minified type name looks like coming out of `Type.toString()`.
  static final RegExp _minified = RegExp(r'minified:([A-Za-z0-9_$]+)');

  /// Drop everything learned so far. For tests, and for a host that swaps
  /// builds underneath a running session.
  @visibleForTesting
  static void reset() {
    _table = null;
    _attempted = false;
  }

  @visibleForTesting
  static void seed(Map<String, String> table) {
    _table = table;
    _attempted = true;
  }

  /// How many names are known. Zero before the first resolve.
  static int get knownNames => _table?.length ?? 0;

  /// Replace every `minified:*` in [text] with the real name where one is
  /// known, leaving the rest of the string alone.
  ///
  /// Returns [text] unchanged when there is nothing minified in it, which is
  /// the common case on a debug or profile build — so the map is never fetched
  /// unless a minified name is actually present.
  static Future<String> resolveIn(String text) async {
    if (!_minified.hasMatch(text)) return text;
    await _ensureLoaded();
    final table = _table;
    if (table == null || table.isEmpty) return text;

    return text.replaceAllMapped(_minified, (match) {
      final short = match.group(1)!;
      // An unknown minified name is left exactly as it was. Guessing, or
      // blanking it, would both make the report harder to act on than the
      // opaque-but-honest original.
      return table[short] ?? match.group(0)!;
    });
  }

  static Future<void> _ensureLoaded() async {
    if (_attempted) return;
    _attempted = true;

    final url = mapUrl;
    if (url == null || url.isEmpty) return;

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return;
      _table = parseMap(response.body);
    } catch (_) {
      // Deliberately swallowed. See the class comment: a report that cannot
      // be filed because a debugging aid failed is a worse outcome than a
      // report carrying `minified:Hb`.
    }
  }

  /// Build the lookup table from a dart2js source map.
  ///
  /// Separated from the fetch so it can be tested against a real map without
  /// a network, and because this is the half with the format knowledge in it.
  @visibleForTesting
  static Map<String, String> parseMap(String source) {
    // Total by construction. A caller reaches this while somebody is trying to
    // file a bug report, so every malformed input has to come back as "no
    // names known" rather than as an exception — including the one that is not
    // JSON at all, which is what a proxy error page or a 404 body looks like
    // when it arrives with a 200.
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return const {};
    }
    if (decoded is! Map) return const {};

    final names = decoded['names'];
    final extension = decoded['x_org_dartlang_dart2js'];
    if (names is! List || extension is! Map) return const {};

    final minifiedNames = extension['minified_names'];
    if (minifiedNames is! Map) return const {};

    final table = <String, String>{};
    // `global` holds classes and top-level members, `instance` holds instance
    // members. Both are read: a report can name either, and a collision
    // between the two tables is not worth a second lookup path.
    for (final key in const ['global', 'instance']) {
      final raw = minifiedNames[key];
      if (raw is! String || raw.isEmpty) continue;

      // "A,33177,A0,34329,..." — alternating minified name and index into
      // `names`. Walked in pairs; a trailing odd element is malformed input
      // and is dropped rather than throwing.
      final parts = raw.split(',');
      for (var i = 0; i + 1 < parts.length; i += 2) {
        final short = parts[i];
        final index = int.tryParse(parts[i + 1]);
        if (index == null || index < 0 || index >= names.length) continue;

        final real = names[index];
        if (real is! String || real.isEmpty) continue;

        // dart2js records members as `Class.member`. The leading segment is
        // what a widget name resolves to, and it is what a report wants.
        table.putIfAbsent(short, () => real);
      }
    }
    return table;
  }
}
