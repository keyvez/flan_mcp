import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flan_flutter/src/services/drawing_service.dart';

/// CustomPainter that renders drawing strokes, text labels, and tool cursors
/// on the text message overlay canvas.
class DrawingPainter extends CustomPainter {
  DrawingPainter({
    required this.strokes,
    required this.textLabels,
    required this.currentPoints,
    required this.activeTool,
    this.eraserPosition,
    this.pendingTextPosition,
    this.movingStrokeId,
    this.movingLabelId,
  });

  final List<DrawingStroke> strokes;
  final List<DrawingTextLabel> textLabels;
  final List<Offset> currentPoints;
  final DrawingTool activeTool;
  final Offset? eraserPosition;
  final Offset? pendingTextPosition;
  final int? movingStrokeId;
  final int? movingLabelId;

  static const _defaultStrokeColor = Color(0xFFFFFFFF);
  static const _eraserRadius = 16.0;

  static const _highlightColor = Color(0xFF00AAFF);

  @override
  void paint(Canvas canvas, Size size) {
    // Draw completed strokes
    for (final stroke in strokes) {
      final isMoving = movingStrokeId == stroke.id;
      _drawStroke(
          canvas, stroke.smoothedPoints, stroke.color, stroke.strokeWidth);
      if (isMoving) {
        _drawStrokeHighlight(canvas, stroke);
      }
    }

    // Draw in-progress stroke
    if (currentPoints.length >= 2) {
      _drawStroke(canvas, currentPoints, _defaultStrokeColor, 2.5);
    }

    // Draw text labels
    for (final label in textLabels) {
      final isMoving = movingLabelId == label.id;
      _drawTextLabel(canvas, label, size);
      if (isMoving) {
        _drawLabelHighlight(canvas, label, size);
      }
    }

    // Draw eraser cursor
    if (activeTool == DrawingTool.eraser && eraserPosition != null) {
      canvas.drawCircle(
        eraserPosition!,
        _eraserRadius,
        Paint()
          ..color = const Color(0x44FFFFFF)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        eraserPosition!,
        _eraserRadius,
        Paint()
          ..color = const Color(0x88FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }

    // Draw text placement cursor
    if (activeTool == DrawingTool.text && pendingTextPosition != null) {
      final pos = pendingTextPosition!;
      // Draw a blinking-cursor-style vertical line
      canvas.drawLine(
        Offset(pos.dx, pos.dy - 10),
        Offset(pos.dx, pos.dy + 10),
        Paint()
          ..color = _highlightColor
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _drawStroke(
      Canvas canvas, List<Offset> points, Color color, double width) {
    if (points.length < 2) return;
    final path = Path()..moveTo(points[0].dx, points[0].dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _drawTextLabel(Canvas canvas, DrawingTextLabel label, Size size) {
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
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: size.width - label.position.dx);

    // Draw a subtle background behind the text for readability
    final bgRect = Rect.fromLTWH(
      label.position.dx - 2,
      label.position.dy - 1,
      painter.width + 4,
      painter.height + 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bgRect, const Radius.circular(2)),
      Paint()..color = const Color(0x66000000),
    );

    painter.paint(canvas, label.position);
  }

  /// Draws a highlight border around a stroke being moved.
  void _drawStrokeHighlight(Canvas canvas, DrawingStroke stroke) {
    if (stroke.smoothedPoints.length < 2) return;
    // Draw the same path but thicker and with highlight color
    final path = Path()
      ..moveTo(stroke.smoothedPoints[0].dx, stroke.smoothedPoints[0].dy);
    for (var i = 1; i < stroke.smoothedPoints.length; i++) {
      path.lineTo(stroke.smoothedPoints[i].dx, stroke.smoothedPoints[i].dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = _highlightColor.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.strokeWidth + 4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  /// Draws a highlight border around a text label being moved.
  void _drawLabelHighlight(Canvas canvas, DrawingTextLabel label, Size size) {
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
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: size.width - label.position.dx);

    final rect = Rect.fromLTWH(
      label.position.dx - 4,
      label.position.dy - 3,
      painter.width + 8,
      painter.height + 6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()
        ..color = _highlightColor.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(DrawingPainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.textLabels != textLabels ||
        oldDelegate.currentPoints != currentPoints ||
        oldDelegate.activeTool != activeTool ||
        oldDelegate.eraserPosition != eraserPosition ||
        oldDelegate.pendingTextPosition != pendingTextPosition ||
        oldDelegate.movingStrokeId != movingStrokeId ||
        oldDelegate.movingLabelId != movingLabelId;
  }
}
