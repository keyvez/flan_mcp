import 'dart:ui';

import 'package:flutter/foundation.dart';

/// A single annotation with bounds, text, and metadata.
class Annotation {
  Annotation({
    required this.id,
    required this.bounds,
    required this.text,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final String id;
  final Rect bounds;
  final String text;
  final DateTime timestamp;

  Annotation copyWith({Rect? bounds, String? text}) => Annotation(
        id: id,
        bounds: bounds ?? this.bounds,
        text: text ?? this.text,
        timestamp: timestamp,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'bounds': {
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        },
        'text': text,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// The current drawing state of the annotation overlay.
enum AnnotationDrawState {
  /// No drawing in progress, user can start a new annotation.
  normal,

  /// User is dragging to draw a rectangle.
  drawing,

  /// Rectangle is drawn, text field is visible for labeling.
  editing,
}

/// Minimum annotation box dimension in pixels.
const double _kMinAnnotationSize = 20.0;

/// Service that manages annotation state: drawing, CRUD, and
/// programmatic annotation creation.
class AnnotationService extends ChangeNotifier {
  bool _enabled = false;
  AnnotationDrawState _drawState = AnnotationDrawState.normal;
  final List<Annotation> _annotations = [];
  int _nextId = 1;

  // Drawing state
  Offset? _dragStart;
  Offset? _dragCurrent;
  Rect? _pendingRect;

  bool get enabled => _enabled;
  AnnotationDrawState get drawState => _drawState;
  List<Annotation> get annotations => List.unmodifiable(_annotations);
  Rect? get pendingRect => _pendingRect;
  Offset? get dragStart => _dragStart;
  Offset? get dragCurrent => _dragCurrent;

  void enable() {
    _enabled = true;
    _drawState = AnnotationDrawState.normal;
    _dragStart = null;
    _dragCurrent = null;
    _pendingRect = null;
    notifyListeners();
  }

  void disable() {
    _enabled = false;
    _drawState = AnnotationDrawState.normal;
    _dragStart = null;
    _dragCurrent = null;
    _pendingRect = null;
    notifyListeners();
  }

  /// Called when the user starts dragging to draw a rectangle.
  void startDrawing(Offset position) {
    if (!_enabled || _drawState == AnnotationDrawState.editing) return;
    _drawState = AnnotationDrawState.drawing;
    _dragStart = position;
    _dragCurrent = position;
    notifyListeners();
  }

  /// Called as the user drags to update the rectangle.
  void updateDrawing(Offset position) {
    if (_drawState != AnnotationDrawState.drawing) return;
    _dragCurrent = position;
    notifyListeners();
  }

  /// Called when the user finishes dragging. If the rectangle is large
  /// enough, transitions to the editing state for text input.
  void finishDrawing() {
    if (_drawState != AnnotationDrawState.drawing ||
        _dragStart == null ||
        _dragCurrent == null) {
      _resetDrawing();
      return;
    }

    final rect = Rect.fromPoints(_dragStart!, _dragCurrent!);
    if (rect.width < _kMinAnnotationSize ||
        rect.height < _kMinAnnotationSize) {
      _resetDrawing();
      return;
    }

    _pendingRect = rect;
    _drawState = AnnotationDrawState.editing;
    notifyListeners();
  }

  /// Submits the annotation text for the pending rectangle.
  void submitAnnotationText(String text) {
    if (_drawState != AnnotationDrawState.editing || _pendingRect == null) {
      return;
    }

    final annotation = Annotation(
      id: '${_nextId++}',
      bounds: _pendingRect!,
      text: text.isEmpty ? '(no label)' : text,
    );
    _annotations.add(annotation);
    _resetDrawing();
  }

  /// Cancels the current editing state without creating an annotation.
  void cancelEditing() {
    _resetDrawing();
  }

  /// Removes an annotation by its id. Returns true if found and removed.
  bool removeAnnotationById(String id) {
    final index = _annotations.indexWhere((a) => a.id == id);
    if (index == -1) return false;
    _annotations.removeAt(index);
    notifyListeners();
    return true;
  }

  /// Clears all annotations.
  void clearAnnotations() {
    _annotations.clear();
    notifyListeners();
  }

  /// Programmatically adds an annotation with the given bounds and text.
  Annotation addAnnotationProgrammatically({
    required double x,
    required double y,
    required double width,
    required double height,
    required String text,
  }) {
    final annotation = Annotation(
      id: '${_nextId++}',
      bounds: Rect.fromLTWH(x, y, width, height),
      text: text,
    );
    _annotations.add(annotation);
    notifyListeners();
    return annotation;
  }

  /// Returns annotation data for MCP consumption.
  List<Map<String, dynamic>> getAnnotationsData() {
    return _annotations.map((a) => a.toJson()).toList();
  }

  void _resetDrawing() {
    _drawState = AnnotationDrawState.normal;
    _dragStart = null;
    _dragCurrent = null;
    _pendingRect = null;
    notifyListeners();
  }
}
