import 'page_reloader_stub.dart'
    if (dart.library.js_interop) 'page_reloader_web.dart' as impl;

import 'package:flutter/foundation.dart';

/// Reloads the page the app is served from.
///
/// This exists because of `flutter run -d web-server`: flutter owns no browser
/// there, so a hot reload recompiles on the host and reaches nobody — the log
/// says "Recompile complete. No client connected." and the page keeps running
/// the old build until someone refreshes it. Refreshing is the last step the
/// relay cannot take, and the app can.
///
/// A no-op off the web, where the question doesn't arise.
class PageReloader {
  const PageReloader._();

  /// Whether a reload is possible here at all — true on the web, and wherever
  /// a test has installed [debugOverride] to stand in for the page.
  static bool get isSupported => debugOverride != null || impl.canReloadPage;

  /// Swapped in tests; a real page reload would tear the test down with it.
  @visibleForTesting
  static void Function()? debugOverride;

  static void reload() {
    final override = debugOverride;
    if (override != null) {
      override();
      return;
    }
    impl.reloadPage();
  }
}
