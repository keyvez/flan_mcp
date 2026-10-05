import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flan_flutter/src/services/annotation_service.dart';

/// CustomPainter that draws completed annotations and previews while drawing or editing.
class AnnotationPainter extends CustomPainter {
  AnnotationPainter({
    required this.annotations,
    this.dragStart,
    this.dragCurrent,
    this.pendingRect,
    required this.drawState,
    this.editingIndex,
    this.shape = AnnotationShape.box,
  });

  final AnnotationShape shape;
  final List<Annotation> annotations;
  final Offset? dragStart;
  final Offset? dragCurrent;
  final Rect? pendingRect;
  final AnnotationDrawState drawState;
  final int? editingIndex;

  static const _annotationFill = Color(0x22FF6600);
  static const _annotationBorder = Color(0xCCFF6600);
  static const _pendingFill = Color(0x1AFF6600);
  static const _pendingBorder = Color(0x88FF6600);
  static const _editingBorder = Color(0xFFFF6600);
  static const _labelBg = Color(0xDD000000);
  static const _labelText = Color(0xFFFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    // Draw completed annotations
    for (var i = 0; i < annotations.length; i++) {
      if (i == editingIndex) {
        final annotation = annotations[i];
        _drawShape(canvas, annotation.bounds, annotation.shape, _annotationFill,
            _editingBorder, 2,
            start: annotation.arrowStart, end: annotation.arrowEnd);
      } else {
        _drawAnnotation(canvas, annotations[i]);
      }
    }

    // Draw the drag rectangle while drawing
    if (drawState == AnnotationDrawState.drawing &&
        dragStart != null &&
        dragCurrent != null) {
      final rect = Rect.fromPoints(dragStart!, dragCurrent!);
      _drawShape(canvas, rect, shape, _pendingFill, _pendingBorder, 1.5,
          start: dragStart, end: dragCurrent);
    }

    // Draw the editing rectangle
    if (drawState == AnnotationDrawState.editing && pendingRect != null) {
      _drawShape(
          canvas, pendingRect!, shape, _annotationFill, _editingBorder, 2,
          start: dragStart, end: dragCurrent);
    }
  }

  void _drawAnnotation(Canvas canvas, Annotation annotation) {
    final rect = annotation.bounds;

    _drawShape(
        canvas, rect, annotation.shape, _annotationFill, _annotationBorder, 2,
        start: annotation.arrowStart, end: annotation.arrowEnd);

    // Label
    if (annotation.text.isNotEmpty) {
      _drawLabel(canvas, annotation.text, rect);
    }
  }

  void _drawShape(Canvas canvas, Rect rect, AnnotationShape shape, Color fill,
      Color border, double width,
      {Offset? start, Offset? end}) {
    final paint = Paint()
      ..color = border
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (shape) {
      case AnnotationShape.box:
        canvas.drawRect(rect, Paint()..color = fill);
        canvas.drawRect(rect, paint);
      case AnnotationShape.circle:
        canvas.drawOval(rect, Paint()..color = fill);
        canvas.drawOval(rect, paint);
      case AnnotationShape.arrow:
        final tail = start ?? rect.topLeft;
        final tip = end ?? rect.bottomRight;
        final delta = tip - tail;
        if (delta.distance == 0) return;
        final direction = delta / delta.distance;
        final normal = Offset(-direction.dy, direction.dx);
        final headLength = math.min(14.0, delta.distance * 0.35);
        final base = tip - direction * headLength;
        final left = base + normal * headLength * 0.5;
        final right = base - normal * headLength * 0.5;
        canvas.drawLine(tail, tip, paint);
        canvas.drawPath(
            Path()
              ..moveTo(left.dx, left.dy)
              ..lineTo(tip.dx, tip.dy)
              ..lineTo(right.dx, right.dy),
            paint);
    }
  }

  void _drawLabel(Canvas canvas, String text, Rect bounds) {
    final textSpan = TextSpan(
      text: text,
      style: const TextStyle(
        color: _labelText,
        fontSize: 11,
        fontWeight: FontWeight.w500,
      ),
    );
    final painter = TextPainter(
      text: textSpan,
      textDirection: ui.TextDirection.ltr,
      maxLines: 2,
      ellipsis: '...',
    )..layout(maxWidth: bounds.width.clamp(40, 300));

    final padding = 4.0;
    final bgWidth = painter.width + padding * 2;
    final bgHeight = painter.height + padding * 2;

    // Position label at top of the annotation box
    final labelX = bounds.left;
    final labelY = bounds.top;

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(labelX, labelY, bgWidth, bgHeight),
      const Radius.circular(2),
    );
    canvas.drawRRect(bgRect, Paint()..color = _labelBg);
    painter.paint(canvas, Offset(labelX + padding, labelY + padding));
  }

  @override
  bool shouldRepaint(AnnotationPainter oldDelegate) {
    return oldDelegate.shape != shape ||
        oldDelegate.annotations != annotations ||
        oldDelegate.dragStart != dragStart ||
        oldDelegate.dragCurrent != dragCurrent ||
        oldDelegate.pendingRect != pendingRect ||
        oldDelegate.drawState != drawState ||
        oldDelegate.editingIndex != editingIndex;
  }
}
