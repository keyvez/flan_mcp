import 'dart:developer' as developer;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Event kind sent when annotations change.
const String kAnnotationChangedEventKind = 'flan.annotationChanged';

/// Shapes available in annotation mode.
enum AnnotationShape { box, arrow, circle }

/// A single annotation with bounds, text, and metadata.
class Annotation {
  Annotation({
    required this.id,
    required this.bounds,
    required this.text,
    this.shape = AnnotationShape.box,
    this.start,
    this.end,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final AnnotationShape shape;

  /// Ordered endpoints for arrows; bounds alone cannot preserve direction.
  final Offset? start;
  final Offset? end;

  final String id;
  final Rect bounds;
  final String text;
  final DateTime timestamp;

  Annotation copyWith({Rect? bounds, String? text}) => Annotation(
        id: id,
        bounds: bounds ?? this.bounds,
        text: text ?? this.text,
        timestamp: timestamp,
        shape: shape,
        start: start,
        end: end,
      );

  Offset get arrowStart => start ?? bounds.topLeft;
  Offset get arrowEnd => end ?? bounds.bottomRight;

  bool contains(Offset position) {
    switch (shape) {
      case AnnotationShape.box:
        return bounds.contains(position);
      case AnnotationShape.circle:
        if (bounds.isEmpty) return false;
        final dx = (position.dx - bounds.center.dx) / (bounds.width / 2);
        final dy = (position.dy - bounds.center.dy) / (bounds.height / 2);
        return dx * dx + dy * dy <= 1;
      case AnnotationShape.arrow:
        final delta = arrowEnd - arrowStart;
        final lengthSquared = delta.distanceSquared;
        if (lengthSquared == 0) return (position - arrowStart).distance <= 10;
        final relative = position - arrowStart;
        final t =
            ((relative.dx * delta.dx + relative.dy * delta.dy) / lengthSquared)
                .clamp(0.0, 1.0);
        return (position - (arrowStart + delta * t)).distance <= 10;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'shape': shape.name,
        if (shape == AnnotationShape.arrow) ...{
          'start': {'x': arrowStart.dx, 'y': arrowStart.dy},
          'end': {'x': arrowEnd.dx, 'y': arrowEnd.dy},
        },
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

  /// User is dragging to draw a shape.
  drawing,

  /// Shape is drawn, text field is visible for labeling.
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
  AnnotationShape _shape = AnnotationShape.box;

  AnnotationShape get shape => _shape;

  void selectShape(AnnotationShape shape) {
    if (_shape == shape) return;
    _shape = shape;
    cancelEditing();
  }

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
    _editingIndex = null;
    notifyListeners();
  }

  void disable() {
    _enabled = false;
    _drawState = AnnotationDrawState.normal;
    _dragStart = null;
    _dragCurrent = null;
    _pendingRect = null;
    _editingIndex = null;
    notifyListeners();
  }

  /// Called when the user starts dragging to draw a shape.
  /// Returns true if an existing annotation was tapped for editing.
  bool startDrawing(Offset position) {
    if (!_enabled) return false;
    if (_drawState == AnnotationDrawState.editing ||
        _drawState == AnnotationDrawState.editingExisting) return false;

    // Check if the tap is on an existing annotation (last drawn = top)
    for (var i = _annotations.length - 1; i >= 0; i--) {
      if (_annotations[i].contains(position)) {
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

  /// Called as the user drags to update the shape.
  void updateDrawing(Offset position) {
    if (_drawState != AnnotationDrawState.drawing) return;
    _dragCurrent = position;
    notifyListeners();
  }

  /// Called when the user finishes dragging. If the shape is large
  /// enough, transitions to the editing state for text input.
  void finishDrawing() {
    // Don't interfere with text editing (new or existing annotation).
    if (_drawState == AnnotationDrawState.editing ||
        _drawState == AnnotationDrawState.editingExisting) return;

    if (_drawState != AnnotationDrawState.drawing ||
        _dragStart == null ||
        _dragCurrent == null) {
      _resetDrawing();
      return;
    }

    final rect = Rect.fromPoints(_dragStart!, _dragCurrent!);
    if (_shape == AnnotationShape.arrow
        ? (_dragCurrent! - _dragStart!).distance < _kMinAnnotationSize
        : rect.width < _kMinAnnotationSize ||
            rect.height < _kMinAnnotationSize) {
      _resetDrawing();
      return;
    }

    _pendingRect = rect;
    _drawState = AnnotationDrawState.editing;
    notifyListeners();
  }

  /// Submits the annotation text for the pending shape.
  void submitAnnotationText(String text) {
    if (_drawState != AnnotationDrawState.editing || _pendingRect == null) {
      return;
    }

    final annotation = Annotation(
      id: '${_nextId++}',
      bounds: _pendingRect!,
      shape: _shape,
      start: _shape == AnnotationShape.arrow ? _dragStart : null,
      end: _shape == AnnotationShape.arrow ? _dragCurrent : null,
      text: text.isEmpty ? '(no label)' : text,
    );
    _annotations.add(annotation);
    _postAnnotationChangedEvent();
    _resetDrawing();
  }

  /// Submits updated text for the annotation being edited.
  void submitEditedAnnotationText(String text) {
    if (_drawState != AnnotationDrawState.editingExisting ||
        _editingIndex == null) {
      return;
    }
    if (_editingIndex! < 0 || _editingIndex! >= _annotations.length) {
      _editingIndex = null;
      _drawState = AnnotationDrawState.normal;
      notifyListeners();
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
    _postAnnotationChangedEvent();
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
    if (_editingIndex != null) {
      if (_editingIndex == index) {
        _editingIndex = null;
        _drawState = AnnotationDrawState.normal;
      } else if (_editingIndex! > index) {
        _editingIndex = _editingIndex! - 1;
      }
    }
    _postAnnotationChangedEvent();
    notifyListeners();
    return true;
  }

  /// Updates an annotation's text by id. Empty text deletes the annotation.
  /// Returns true if an annotation was found and changed.
  bool updateAnnotationTextById(String id, String text) {
    final index = _annotations.indexWhere((a) => a.id == id);
    if (index == -1) return false;

    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      _annotations.removeAt(index);
      if (_editingIndex != null) {
        if (_editingIndex == index) {
          _editingIndex = null;
          _drawState = AnnotationDrawState.normal;
        } else if (_editingIndex! > index) {
          _editingIndex = _editingIndex! - 1;
        }
      }
    } else {
      _annotations[index] = _annotations[index].copyWith(text: trimmed);
    }
    _postAnnotationChangedEvent();
    notifyListeners();
    return true;
  }

  /// Clears all annotations.
  void clearAnnotations() {
    _annotations.clear();
    _drawState = AnnotationDrawState.normal;
    _dragStart = null;
    _dragCurrent = null;
    _pendingRect = null;
    _editingIndex = null;
    _postAnnotationChangedEvent();
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
    _postAnnotationChangedEvent();
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

  void _postAnnotationChangedEvent() {
    developer.postEvent(kAnnotationChangedEventKind, {
      'count': _annotations.length,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
}
