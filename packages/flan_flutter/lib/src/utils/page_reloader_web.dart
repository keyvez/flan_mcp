import 'dart:js_interop';

/// `window.location.reload()`, via `dart:js_interop` so that nothing new is
/// added to the package's dependencies for one call.
@JS('location')
external _Location get _location;

extension type _Location._(JSObject _) implements JSObject {
  external void reload();
}

const bool canReloadPage = true;

void reloadPage() => _location.reload();
