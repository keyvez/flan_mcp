import 'dart:convert';

/// A single step in a recorded macro.
sealed class MacroStep {
  const MacroStep();

  Map<String, dynamic> toJson();

  /// Returns a human-readable description of this step.
  String toDescription();

  /// Returns Flutter integration test code for this step.
  String toFlutterTestCode();

  static MacroStep fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'tap' => TapStep.fromJson(json),
      'enter_text' => EnterTextStep.fromJson(json),
      'scroll_to' => ScrollToStep.fromJson(json),
      'navigate' => NavigateStep.fromJson(json),
      'wait' => WaitStep.fromJson(json),
      _ => throw ArgumentError('Unknown macro step type: $type'),
    };
  }
}

/// Tap a widget identified by key, text, or type (in priority order).
final class TapStep extends MacroStep {
  const TapStep({this.key, this.text, this.type});

  factory TapStep.fromJson(Map<String, dynamic> json) => TapStep(
    key: json['key'] as String?,
    text: json['text'] as String?,
    type: json['widgetType'] as String?,
  );

  final String? key;
  final String? text;
  final String? type;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'tap',
    if (key != null) 'key': key,
    if (text != null) 'text': text,
    if (type != null) 'widgetType': type,
  };

  @override
  String toDescription() {
    if (key != null) return 'Tap widget with key "$key"';
    if (text != null) return 'Tap widget with text "$text"';
    if (type != null) return 'Tap first $type widget';
    return 'Tap (unknown target)';
  }

  @override
  String toFlutterTestCode() {
    if (key != null) {
      return "    await tester.tap(find.byKey(const ValueKey('$key')));\n"
          '    await tester.pumpAndSettle();';
    }
    if (text != null) {
      return "    await tester.tap(find.text('${_escapeSingleQuote(text!)}'));\n"
          '    await tester.pumpAndSettle();';
    }
    if (type != null) {
      return '    await tester.tap(find.byType($type));\n'
          '    await tester.pumpAndSettle();';
    }
    return '    // TODO: tap (target unknown)';
  }
}

/// Enter text into a field identified by key or text.
final class EnterTextStep extends MacroStep {
  const EnterTextStep({required this.input, this.key, this.text, this.type});

  factory EnterTextStep.fromJson(Map<String, dynamic> json) => EnterTextStep(
    input: json['input'] as String,
    key: json['key'] as String?,
    text: json['text'] as String?,
    type: json['widgetType'] as String?,
  );

  final String input;
  final String? key;
  final String? text;
  final String? type;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'enter_text',
    'input': input,
    if (key != null) 'key': key,
    if (text != null) 'text': text,
    if (type != null) 'widgetType': type,
  };

  @override
  String toDescription() {
    final target =
        key != null
            ? 'field with key "$key"'
            : text != null
            ? 'field with text "$text"'
            : type ?? 'text field';
    return 'Enter "${_truncate(input, 40)}" into $target';
  }

  @override
  String toFlutterTestCode() {
    final finder =
        key != null
            ? "find.byKey(const ValueKey('$key'))"
            : text != null
            ? "find.widgetWithText(TextField, '${_escapeSingleQuote(text!)}')"
            : 'find.byType(TextField)';
    return "    await tester.enterText($finder, '${_escapeSingleQuote(input)}');\n"
        '    await tester.pumpAndSettle();';
  }
}

/// Scroll until a widget identified by key or text is visible.
final class ScrollToStep extends MacroStep {
  const ScrollToStep({this.key, this.text, this.type});

  factory ScrollToStep.fromJson(Map<String, dynamic> json) => ScrollToStep(
    key: json['key'] as String?,
    text: json['text'] as String?,
    type: json['widgetType'] as String?,
  );

  final String? key;
  final String? text;
  final String? type;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'scroll_to',
    if (key != null) 'key': key,
    if (text != null) 'text': text,
    if (type != null) 'widgetType': type,
  };

  @override
  String toDescription() {
    if (key != null) return 'Scroll to widget with key "$key"';
    if (text != null) return 'Scroll to widget with text "$text"';
    if (type != null) return 'Scroll to first $type widget';
    return 'Scroll (unknown target)';
  }

  @override
  String toFlutterTestCode() {
    final finder =
        key != null
            ? "find.byKey(const ValueKey('$key'))"
            : text != null
            ? "find.text('${_escapeSingleQuote(text!)}')"
            : 'find.byType($type)';
    return '    await tester.scrollUntilVisible(\n'
        '      $finder,\n'
        '      500,\n'
        '    );\n'
        '    await tester.pumpAndSettle();';
  }
}

/// Navigate to a named route.
final class NavigateStep extends MacroStep {
  const NavigateStep({required this.route});

  factory NavigateStep.fromJson(Map<String, dynamic> json) =>
      NavigateStep(route: json['route'] as String);

  final String route;

  @override
  Map<String, dynamic> toJson() => {'type': 'navigate', 'route': route};

  @override
  String toDescription() => 'Navigate to route "$route"';

  @override
  String toFlutterTestCode() =>
      "    // Navigate to '$route' — adapt to your routing strategy\n"
      "    await tester.tap(find.byTooltip('Back'));\n"
      '    await tester.pumpAndSettle();';
}

/// Wait for a specified duration.
final class WaitStep extends MacroStep {
  const WaitStep({required this.milliseconds});

  factory WaitStep.fromJson(Map<String, dynamic> json) =>
      WaitStep(milliseconds: json['milliseconds'] as int);

  final int milliseconds;

  @override
  Map<String, dynamic> toJson() =>
      {'type': 'wait', 'milliseconds': milliseconds};

  @override
  String toDescription() => 'Wait ${milliseconds}ms';

  @override
  String toFlutterTestCode() =>
      '    await tester.pump(const Duration(milliseconds: $milliseconds));';
}

/// A recorded macro consisting of an ordered list of steps.
class Macro {
  Macro({required this.name, required this.description, DateTime? createdAt})
    : createdAt = createdAt ?? DateTime.now().toUtc(),
      steps = [];

  Macro._fromJson(Map<String, dynamic> json)
    : name = json['name'] as String,
      description = json['description'] as String? ?? '',
      createdAt = DateTime.parse(json['createdAt'] as String),
      steps =
          (json['steps'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .map(MacroStep.fromJson)
              .toList();

  final String name;
  final String description;
  final DateTime createdAt;
  final List<MacroStep> steps;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'createdAt': createdAt.toIso8601String(),
    'stepCount': steps.length,
    'steps': steps.map((s) => s.toJson()).toList(),
  };

  static Macro fromJson(Map<String, dynamic> json) => Macro._fromJson(json);

  /// Returns a human-readable summary of the macro.
  String toSummary() {
    final buf = StringBuffer()
      ..writeln('Macro: $name')
      ..writeln('Description: ${description.isEmpty ? "(none)" : description}')
      ..writeln('Created: ${createdAt.toIso8601String()}')
      ..writeln('Steps (${steps.length}):');
    for (var i = 0; i < steps.length; i++) {
      buf.writeln('  ${i + 1}. ${steps[i].toDescription()}');
    }
    return buf.toString().trimRight();
  }

  /// Exports the macro as a self-contained Flutter integration test file.
  String toFlutterTestFile() {
    final buf = StringBuffer();
    buf.writeln("import 'package:flutter_test/flutter_test.dart';");
    buf.writeln("import 'package:integration_test/integration_test.dart';");
    buf.writeln();
    buf.writeln('// Generated by Flan — ${DateTime.now().toUtc().toIso8601String()}');
    buf.writeln('// Macro: $name');
    if (description.isNotEmpty) {
      buf.writeln('// $description');
    }
    buf.writeln();
    buf.writeln('void main() {');
    buf.writeln('  IntegrationTestWidgetsFlutterBinding.ensureInitialized();');
    buf.writeln();
    buf.writeln("  testWidgets('$name', (tester) async {");
    buf.writeln(
      '    // TODO: pump your app widget here, e.g.:',
    );
    buf.writeln(
      '    // await tester.pumpWidget(const MyApp());',
    );
    buf.writeln('    await tester.pumpAndSettle();');
    buf.writeln();
    for (var i = 0; i < steps.length; i++) {
      buf.writeln('    // Step ${i + 1}: ${steps[i].toDescription()}');
      buf.writeln(steps[i].toFlutterTestCode());
      buf.writeln();
    }
    buf.writeln('  });');
    buf.writeln('}');
    return buf.toString();
  }
}

/// Manages macro recording and storage.
class MacroRecorder {
  final Map<String, Macro> _macros = {};
  Macro? _recording;
  String? _recordingName;

  /// Whether a recording is currently in progress.
  bool get isRecording => _recording != null;

  /// The name of the macro currently being recorded, or null.
  String? get recordingName => _recordingName;

  /// Starts recording a new macro with the given [name] and [description].
  ///
  /// Throws if a recording is already in progress.
  void startRecording({required String name, String description = ''}) {
    if (_recording != null) {
      throw StateError(
        'A recording is already in progress ("$_recordingName"). '
        'Call stop_recording first.',
      );
    }
    _recording = Macro(name: name, description: description);
    _recordingName = name;
  }

  /// Stops the current recording and saves it as a named macro.
  ///
  /// Returns the completed macro. Throws if not recording.
  Macro stopRecording() {
    final macro = _recording;
    if (macro == null) {
      throw StateError('No recording in progress. Call start_recording first.');
    }
    _macros[macro.name] = macro;
    _recording = null;
    _recordingName = null;
    return macro;
  }

  /// Discards the current recording without saving.
  void cancelRecording() {
    _recording = null;
    _recordingName = null;
  }

  /// Records a tap step. No-op if not recording.
  void recordTap({String? key, String? text, String? type}) {
    _recording?.steps.add(TapStep(key: key, text: text, type: type));
  }

  /// Records an enter_text step. No-op if not recording.
  void recordEnterText({
    required String input,
    String? key,
    String? text,
    String? type,
  }) {
    _recording?.steps.add(
      EnterTextStep(input: input, key: key, text: text, type: type),
    );
  }

  /// Records a scroll_to step. No-op if not recording.
  void recordScrollTo({String? key, String? text, String? type}) {
    _recording?.steps.add(ScrollToStep(key: key, text: text, type: type));
  }

  /// Records a navigate step. No-op if not recording.
  void recordNavigate(String route) {
    _recording?.steps.add(NavigateStep(route: route));
  }

  /// Records a wait step. No-op if not recording.
  void recordWait(int milliseconds) {
    _recording?.steps.add(WaitStep(milliseconds: milliseconds));
  }

  /// Returns all saved macros.
  List<Macro> listMacros() => _macros.values.toList();

  /// Returns the macro with the given [name], or null if not found.
  Macro? getMacro(String name) => _macros[name];

  /// Deletes the macro with the given [name]. Returns true if it existed.
  bool deleteMacro(String name) => _macros.remove(name) != null;

  /// Returns the steps of the in-progress recording, or null if not recording.
  List<MacroStep>? get currentRecordingSteps => _recording?.steps;

  /// Returns a JSON representation of all macros.
  String exportAllAsJson() {
    final all = _macros.values.map((m) => m.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(all);
  }
}

// Helpers
String _escapeSingleQuote(String s) => s.replaceAll("'", "\\'");

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';
