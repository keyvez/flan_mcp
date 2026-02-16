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

  /// An existing annotation is selected for editing its text.
  editingExisting,
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

  // Editing existing annotation state
  int? _editingIndex;

  bool get enabled => _enabled;
  AnnotationDrawState get drawState => _drawState;
  List<Annotation> get annotations => List.unmodifiable(_annotations);
  Rect? get pendingRect => _pendingRect;
  Offset? get dragStart => _dragStart;
  Offset? get dragCurrent => _dragCurrent;
  int? get editingIndex => _editingIndex;

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
  /// Returns true if an existing annotation was tapped for editing.
  bool startDrawing(Offset position) {
    if (!_enabled) return false;
    if (_drawState == AnnotationDrawState.editing ||
        _drawState == AnnotationDrawState.editingExisting) return false;

    // Check if the tap is on an existing annotation (last drawn = top)
    for (var i = _annotations.length - 1; i >= 0; i--) {
      if (_annotations[i].bounds.contains(position)) {
        _editingIndex = i;
        _drawState = AnnotationDrawState.editingExisting;
        notifyListeners();
        return true;
      }
    }

    _drawState = AnnotationDrawState.drawing;
    _dragStart = position;
    _dragCurrent = position;
    notifyListeners();
    return false;
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
    // Don't interfere with editing an existing annotation
    if (_drawState == AnnotationDrawState.editingExisting) return;

    if (_drawState != AnnotationDrawState.drawing ||
        _dragStart == null ||
        _dragCurrent == null) {
      _resetDrawing();
      return;
    }

    final rect = Rect.fromPoints(_dragStart!, _dragCurrent!);
    if (rect.width < _kMinAnnotationSize || rect.height < _kMinAnnotationSize) {
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

  /// Submits updated text for the annotation being edited.
  void submitEditedAnnotationText(String text) {
    if (_drawState != AnnotationDrawState.editingExisting ||
        _editingIndex == null) {
      return;
    }
    if (text.isEmpty) {
      // Empty text deletes the annotation
      _annotations.removeAt(_editingIndex!);
    } else {
      _annotations[_editingIndex!] =
          _annotations[_editingIndex!].copyWith(text: text);
    }
    _editingIndex = null;
    _drawState = AnnotationDrawState.normal;
    notifyListeners();
  }

  /// Cancels the current editing state without creating an annotation.
  void cancelEditing() {
    _editingIndex = null;
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
