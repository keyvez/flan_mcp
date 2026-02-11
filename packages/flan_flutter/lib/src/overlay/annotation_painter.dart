import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flan_flutter/src/services/annotation_service.dart';

/// CustomPainter that draws completed annotation boxes, the pending
/// drag rectangle, and the editing rectangle.
class AnnotationPainter extends CustomPainter {
  AnnotationPainter({
    required this.annotations,
    this.dragStart,
    this.dragCurrent,
    this.pendingRect,
    required this.drawState,
  });

  final List<Annotation> annotations;
  final Offset? dragStart;
  final Offset? dragCurrent;
  final Rect? pendingRect;
  final AnnotationDrawState drawState;

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
    for (final annotation in annotations) {
      _drawAnnotation(canvas, annotation);
    }

    // Draw the drag rectangle while drawing
    if (drawState == AnnotationDrawState.drawing &&
        dragStart != null &&
        dragCurrent != null) {
      final rect = Rect.fromPoints(dragStart!, dragCurrent!);
      _drawPendingRect(canvas, rect);
    }

    // Draw the editing rectangle
    if (drawState == AnnotationDrawState.editing && pendingRect != null) {
      _drawEditingRect(canvas, pendingRect!);
    }
  }

  void _drawAnnotation(Canvas canvas, Annotation annotation) {
    final rect = annotation.bounds;

    // Fill
    canvas.drawRect(rect, Paint()..color = _annotationFill);

    // Border
    canvas.drawRect(
      rect,
      Paint()
        ..color = _annotationBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Label
    if (annotation.text.isNotEmpty) {
      _drawLabel(canvas, annotation.text, rect);
    }
  }

  void _drawPendingRect(Canvas canvas, Rect rect) {
    canvas.drawRect(rect, Paint()..color = _pendingFill);
    canvas.drawRect(
      rect,
      Paint()
        ..color = _pendingBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _drawEditingRect(Canvas canvas, Rect rect) {
    canvas.drawRect(rect, Paint()..color = _annotationFill);

    // Dashed-style border (solid with different color to indicate editing)
    canvas.drawRect(
      rect,
      Paint()
        ..color = _editingBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
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
    return oldDelegate.annotations != annotations ||
        oldDelegate.dragStart != dragStart ||
        oldDelegate.dragCurrent != dragCurrent ||
        oldDelegate.pendingRect != pendingRect ||
        oldDelegate.drawState != drawState;
  }
}
