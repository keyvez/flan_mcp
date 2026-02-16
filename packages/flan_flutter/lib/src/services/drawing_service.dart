import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Available drawing tools.
enum DrawingTool { none, pencil, text, eraser, move }

/// A single freehand stroke.
class DrawingStroke {
  DrawingStroke({
    required this.id,
    required this.rawPoints,
    required this.color,
    required this.strokeWidth,
    List<Offset>? smoothedPoints,
  }) : smoothedPoints = smoothedPoints ?? rawPoints;

  final int id;
  final List<Offset> rawPoints;
  final List<Offset> smoothedPoints;
  final Color color;
  final double strokeWidth;

  /// Returns a copy with all points shifted by [delta].
  DrawingStroke copyWithOffset(Offset delta) {
    return DrawingStroke(
      id: id,
      rawPoints: rawPoints.map((p) => p + delta).toList(),
      color: color,
      strokeWidth: strokeWidth,
      smoothedPoints: smoothedPoints.map((p) => p + delta).toList(),
    );
  }

  /// Returns the bounding rect of the smoothed points.
  Rect get bounds {
    if (smoothedPoints.isEmpty) return Rect.zero;
    var minX = smoothedPoints[0].dx;
    var maxX = minX;
    var minY = smoothedPoints[0].dy;
    var maxY = minY;
    for (final p in smoothedPoints) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

/// A text label placed on the canvas.
class DrawingTextLabel {
  const DrawingTextLabel({
    required this.id,
    required this.position,
    required this.text,
    required this.color,
    required this.fontSize,
  });

  final int id;
  final Offset position;
  final String text;
  final Color color;
  final double fontSize;

  /// Returns a copy with position shifted by [delta].
  DrawingTextLabel copyWithOffset(Offset delta) {
    return DrawingTextLabel(
      id: id,
      position: position + delta,
      text: text,
      color: color,
      fontSize: fontSize,
    );
  }
}

/// Service managing drawing state for the text message overlay.
class DrawingService extends ChangeNotifier {
  DrawingTool _activeTool = DrawingTool.none;
  final List<DrawingStroke> _strokes = [];
  final List<DrawingTextLabel> _textLabels = [];
  List<Offset> _currentPoints = [];
  double _smoothingFactor = 0.2;
  int _nextId = 0;
  Offset? _pendingTextPosition;

  // Move tool state
  int? _movingStrokeId;
  int? _movingLabelId;
  Offset? _moveStartPosition;

  // Public getters
  DrawingTool get activeTool => _activeTool;
  List<DrawingStroke> get strokes => List.unmodifiable(_strokes);
  List<DrawingTextLabel> get textLabels => List.unmodifiable(_textLabels);
  List<Offset> get currentPoints => List.unmodifiable(_currentPoints);
  double get smoothingFactor => _smoothingFactor;
  Offset? get pendingTextPosition => _pendingTextPosition;
  int? get movingStrokeId => _movingStrokeId;
  int? get movingLabelId => _movingLabelId;

  bool get hasContent => _strokes.isNotEmpty || _textLabels.isNotEmpty;

  // Tool management
  void setTool(DrawingTool tool) {
    if (_activeTool == tool) return;
    // Cancel any pending text placement or move when switching tools
    _pendingTextPosition = null;
    _movingStrokeId = null;
    _movingLabelId = null;
    _moveStartPosition = null;
    _activeTool = tool;
    notifyListeners();
  }

  void setSmoothingFactor(double factor) {
    _smoothingFactor = factor.clamp(0.0, 1.0);
  }

  // --- Pencil ---

  void startStroke(Offset point) {
    _currentPoints = [point];
    notifyListeners();
  }

  void addPoint(Offset point) {
    _currentPoints.add(point);
    notifyListeners();
  }

  void finishStroke() {
    if (_currentPoints.length < 2) {
      _currentPoints = [];
      notifyListeners();
      return;
    }

    final smoothed = _smoothPoints(_currentPoints);
    _strokes.add(DrawingStroke(
      id: _nextId++,
      rawPoints: List.of(_currentPoints),
      smoothedPoints: smoothed,
      color: const Color(0xFFFFFFFF),
      strokeWidth: 2.5,
    ));
    _currentPoints = [];
    notifyListeners();
  }

  // --- Text ---

  void startTextPlacement(Offset position) {
    _pendingTextPosition = position;
    notifyListeners();
  }

  void submitText(String text) {
    if (_pendingTextPosition == null || text.trim().isEmpty) {
      _pendingTextPosition = null;
      notifyListeners();
      return;
    }
    _textLabels.add(DrawingTextLabel(
      id: _nextId++,
      position: _pendingTextPosition!,
      text: text.trim(),
      color: const Color(0xFFFFFFFF),
      fontSize: 16,
    ));
    _pendingTextPosition = null;
    notifyListeners();
  }

  void cancelTextPlacement() {
    _pendingTextPosition = null;
    notifyListeners();
  }

  // --- Eraser ---

  void eraseAt(Offset position, double radius) {
    bool changed = false;

    // Remove strokes whose any smoothed point falls within radius
    _strokes.removeWhere((stroke) {
      for (final pt in stroke.smoothedPoints) {
        if ((pt - position).distance <= radius) {
          changed = true;
          return true;
        }
      }
      return false;
    });

    // Remove text labels whose position falls within radius
    _textLabels.removeWhere((label) {
      if ((label.position - position).distance <= radius) {
        changed = true;
        return true;
      }
      return false;
    });

    if (changed) notifyListeners();
  }

  // --- Move ---

  /// Hit-test radius for selecting objects to move.
  static const _moveHitRadius = 20.0;

  /// Begins a move operation by finding the nearest stroke or label to [position].
  void startMove(Offset position) {
    _movingStrokeId = null;
    _movingLabelId = null;
    _moveStartPosition = position;

    // Check text labels first (they're on top visually)
    double bestDist = _moveHitRadius;
    for (final label in _textLabels) {
      final dist = (label.position - position).distance;
      if (dist < bestDist) {
        bestDist = dist;
        _movingLabelId = label.id;
        _movingStrokeId = null;
      }
    }

    // Then check strokes
    for (final stroke in _strokes) {
      for (final pt in stroke.smoothedPoints) {
        final dist = (pt - position).distance;
        if (dist < bestDist) {
          bestDist = dist;
          _movingStrokeId = stroke.id;
          _movingLabelId = null;
          break; // found a close-enough point on this stroke
        }
      }
    }

    notifyListeners();
  }

  /// Updates the position of the object being moved.
  void updateMove(Offset position) {
    if (_moveStartPosition == null) return;
    final delta = position - _moveStartPosition!;
    _moveStartPosition = position;

    if (_movingStrokeId != null) {
      final idx = _strokes.indexWhere((s) => s.id == _movingStrokeId);
      if (idx >= 0) {
        _strokes[idx] = _strokes[idx].copyWithOffset(delta);
        notifyListeners();
      }
    } else if (_movingLabelId != null) {
      final idx = _textLabels.indexWhere((l) => l.id == _movingLabelId);
      if (idx >= 0) {
        _textLabels[idx] = _textLabels[idx].copyWithOffset(delta);
        notifyListeners();
      }
    }
  }

  /// Finishes the current move operation.
  void finishMove() {
    _movingStrokeId = null;
    _movingLabelId = null;
    _moveStartPosition = null;
    notifyListeners();
  }

  // --- Clear ---

  void clear() {
    if (!hasContent && _pendingTextPosition == null) return;
    _strokes.clear();
    _textLabels.clear();
    _currentPoints = [];
    _pendingTextPosition = null;
    notifyListeners();
  }

  // --- Image rendering ---

  /// Renders all strokes and text labels to a PNG image and returns base64.
  Future<String?> toImageBase64(Size size) async {
    if (!hasContent) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Draw strokes
    for (final stroke in _strokes) {
      if (stroke.smoothedPoints.length < 2) continue;
      final path = Path()
        ..moveTo(
          stroke.smoothedPoints[0].dx,
          stroke.smoothedPoints[0].dy,
        );
      for (var i = 1; i < stroke.smoothedPoints.length; i++) {
        path.lineTo(
          stroke.smoothedPoints[i].dx,
          stroke.smoothedPoints[i].dy,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = stroke.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke.strokeWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // Draw text labels
    for (final label in _textLabels) {
      final textSpan = TextSpan(
        text: label.text,
        style: TextStyle(
          color: label.color,
          fontSize: label.fontSize,
          fontWeight: FontWeight.w500,
        ),
      );
      final painter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - label.position.dx);
      painter.paint(canvas, label.position);
    }

    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(
        math.max(1, size.width.round()),
        math.max(1, size.height.round()),
      );
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) return null;
      return base64Encode(byteData.buffer.asUint8List());
    } finally {
      image?.dispose();
      picture.dispose();
    }
  }

  // --- Chaikin curve smoothing ---

  /// Applies Chaikin's corner-cutting algorithm to smooth a polyline.
  /// Number of passes is derived from `_smoothingFactor`:
  /// `ceil(factor * 3)` passes. Each pass replaces consecutive point pairs
  /// with two new points at 25%/75% interpolation.
  List<Offset> _smoothPoints(List<Offset> points) {
    if (points.length < 3) return List.of(points);

    final passes = (_smoothingFactor * 3).ceil();
    var result = List<Offset>.of(points);

    for (var pass = 0; pass < passes; pass++) {
      final smoothed = <Offset>[result.first];
      for (var i = 0; i < result.length - 1; i++) {
        final p0 = result[i];
        final p1 = result[i + 1];
        smoothed.add(Offset(
          p0.dx * 0.75 + p1.dx * 0.25,
          p0.dy * 0.75 + p1.dy * 0.25,
        ));
        smoothed.add(Offset(
          p0.dx * 0.25 + p1.dx * 0.75,
          p0.dy * 0.25 + p1.dy * 0.75,
        ));
      }
      smoothed.add(result.last);
      result = smoothed;
    }

    return result;
  }
}
