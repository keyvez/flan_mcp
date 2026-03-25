import 'dart:developer' as developer;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:flan_flutter/src/services/inspector_service.dart';

// ---------------------------------------------------------------------------
// Step model
// ---------------------------------------------------------------------------

/// A single recorded interaction step.
sealed class RecordedStep {
  const RecordedStep();

  /// Short human-readable label (used in the overlay counter and log).
  String get label;

  /// Dart source line(s) for use inside a `testWidgets` body.
  String toTestCode();
}

/// Tap on a widget identified semantically (key > text > type).
final class RecordedTap extends RecordedStep {
  const RecordedTap({this.key, this.text, this.widgetType});

  final String? key;
  final String? text;
  final String? widgetType;

  @override
  String get label {
    if (key != null) return 'tap key="$key"';
    if (text != null) return 'tap "$text"';
    return 'tap ${widgetType ?? "?"}';
  }

  @override
  String toTestCode() {
    if (key != null) {
      return "    await tester.tap(find.byKey(const ValueKey('${_esc(key!)}'))); await tester.pumpAndSettle();";
    }
    if (text != null) {
      return "    await tester.tap(find.text('${_esc(text!)}')); await tester.pumpAndSettle();";
    }
    return '    await tester.tap(find.byType($widgetType)); await tester.pumpAndSettle();';
  }
}

/// Text entered into a field.
final class RecordedTextEntry extends RecordedStep {
  const RecordedTextEntry({required this.text, this.key, this.fieldText, this.widgetType});

  final String text;
  final String? key;
  final String? fieldText;
  final String? widgetType;

  @override
  String get label {
    final target = key != null
        ? 'key="$key"'
        : fieldText != null
            ? '"$fieldText"'
            : widgetType ?? 'field';
    return 'enter "$text" → $target';
  }

  @override
  String toTestCode() {
    final finder = key != null
        ? "find.byKey(const ValueKey('${_esc(key!)}'))"
        : fieldText != null
            ? "find.widgetWithText(TextField, '${_esc(fieldText!)}')"
            : 'find.byType(TextField)';
    return "    await tester.enterText($finder, '${_esc(text)}'); await tester.pumpAndSettle();";
  }
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Records user interactions in the running app and generates a barebones
/// Flutter integration test.
///
/// Activated by the in-app recording mode (toggled via Ctrl+Shift+R).
/// Taps are captured by the overlay's gesture detector, which inspects the
/// widget under the tap using [InspectorService] to get a semantic identifier
/// (key > text > type) instead of raw coordinates.
class MacroRecorderService extends ChangeNotifier {
  bool _recording = false;
  final List<RecordedStep> _steps = [];

  bool get isRecording => _recording;

  /// Number of steps captured so far.
  int get stepCount => _steps.length;

  List<RecordedStep> get steps => List.unmodifiable(_steps);

  // ---------------------------------------------------------------------------
  // Recording lifecycle
  // ---------------------------------------------------------------------------

  void startRecording() {
    _recording = true;
    _steps.clear();
    notifyListeners();
  }

  /// Stops recording and returns the generated test source.
  /// Does NOT clear steps so the caller can still read them.
  String stopRecording() {
    _recording = false;
    final source = _buildTestSource();
    notifyListeners();
    return source;
  }

  void cancelRecording() {
    _recording = false;
    _steps.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Step capture
  // ---------------------------------------------------------------------------

  /// Called by the overlay when the user taps at [position].
  /// Uses [inspector] to resolve the widget under the tap semantically.
  void recordTap(InspectorService inspector, Offset position) {
    if (!_recording) return;

    final selection = inspector.inspectAtForAgent(
      position.dx,
      position.dy,
      includeProperties: false,
    );

    // Prefer key → text (if it's a label/button) → type as last resort.
    final String? key =
        selection?.key?.isNotEmpty == true ? selection!.key : null;
    final String? text = selection?.text?.isNotEmpty == true
        ? selection!.text
        : null;
    final String? widgetType = selection?.widgetType;

    _steps.add(RecordedTap(key: key, text: text, widgetType: widgetType));
    notifyListeners();

    developer.log(
      'Recorded tap: key=$key text=$text type=$widgetType',
      name: 'FlanRecorder',
    );
  }

  /// Called by the overlay when the user submits text into a field.
  void recordTextEntry({
    required String text,
    InspectorSelection? fieldSelection,
  }) {
    if (!_recording) return;

    final key = fieldSelection?.key?.isNotEmpty == true
        ? fieldSelection!.key
        : null;
    final fieldText = fieldSelection?.text?.isNotEmpty == true
        ? fieldSelection!.text
        : null;
    final widgetType = fieldSelection?.widgetType;

    _steps.add(
      RecordedTextEntry(
        text: text,
        key: key,
        fieldText: fieldText,
        widgetType: widgetType,
      ),
    );
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Code generation
  // ---------------------------------------------------------------------------

  String _buildTestSource() {
    final buf = StringBuffer();
    buf.writeln("import 'package:flutter_test/flutter_test.dart';");
    buf.writeln("import 'package:integration_test/integration_test.dart';");
    buf.writeln();
    buf.writeln('// Generated by Flan — ${DateTime.now().toUtc().toIso8601String()}');
    buf.writeln('// ${_steps.length} step(s) recorded.');
    buf.writeln();
    buf.writeln('void main() {');
    buf.writeln('  IntegrationTestWidgetsFlutterBinding.ensureInitialized();');
    buf.writeln();
    buf.writeln("  testWidgets('recorded_flow', (WidgetTester tester) async {");
    buf.writeln('    // TODO: replace with your app entry point');
    buf.writeln('    // await tester.pumpWidget(const MyApp());');
    buf.writeln('    await tester.pumpAndSettle();');
    buf.writeln();
    for (var i = 0; i < _steps.length; i++) {
      buf.writeln('    // Step ${i + 1}: ${_steps[i].label}');
      buf.writeln(_steps[i].toTestCode());
      if (i < _steps.length - 1) buf.writeln();
    }
    buf.writeln('  });');
    buf.writeln('}');
    return buf.toString();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _esc(String s) => s.replaceAll("'", r"\'");
