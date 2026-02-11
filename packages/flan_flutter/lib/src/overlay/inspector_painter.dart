import 'dart:ui' as ui;

import 'package:flutter/material.dart'
    hide InspectorSelection;
import 'package:flan_flutter/src/services/inspector_service.dart';

/// CustomPainter that draws inspector highlights, selection borders,
/// widget type labels, z-index indicators, and an info panel.
class InspectorPainter extends CustomPainter {
  InspectorPainter({
    required this.highlights,
    required this.currentIndex,
    this.selection,
  });

  final List<InspectorHighlight> highlights;
  final int currentIndex;
  final InspectorSelection? selection;

  static const _highlightColor = Color(0x3300AAFF);
  static const _selectedBorderColor = Color(0xFF00AAFF);
  static const _otherBorderColor = Color(0x5500AAFF);
  static const _labelBgColor = Color(0xDD000000);
  static const _labelTextColor = Color(0xFFFFFFFF);
  static const _infoPanelBg = Color(0xEE1A1A2E);
  static const _infoPanelText = Color(0xFFE0E0E0);

  @override
  void paint(Canvas canvas, Size size) {
    if (highlights.isEmpty || currentIndex < 0) return;

    // Only draw the current element highlight (like Chrome DevTools)
    final current = highlights[currentIndex];

    // Fill highlight
    final fillPaint = Paint()
      ..color = _highlightColor
      ..style = PaintingStyle.fill;
    canvas.drawRect(current.bounds, fillPaint);

    // Border
    final borderPaint = Paint()
      ..color = _selectedBorderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(current.bounds, borderPaint);

    // Widget type label above the highlight rect
    _drawLabel(
      canvas,
      current.widgetType,
      current.bounds,
      size,
    );

    // Info panel at top of screen when selection is available
    if (selection != null) {
      _drawInfoPanel(canvas, size, selection!);
    }
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Rect bounds,
    Size size,
  ) {
    final textSpan = TextSpan(
      text: text,
      style: const TextStyle(
        color: _labelTextColor,
        fontSize: 11,
        fontWeight: FontWeight.w500,
      ),
    );
    final painter = TextPainter(
      text: textSpan,
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final padding = 4.0;
    final bgWidth = painter.width + padding * 2;
    final bgHeight = painter.height + padding * 2;

    // Position label above the bounds, or below if no space above
    var labelY = bounds.top - bgHeight - 2;
    if (labelY < 0) {
      labelY = bounds.bottom + 2;
    }
    var labelX = bounds.left;
    if (labelX + bgWidth > size.width) {
      labelX = size.width - bgWidth;
    }
    if (labelX < 0) labelX = 0;

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(labelX, labelY, bgWidth, bgHeight),
      const Radius.circular(3),
    );
    canvas.drawRRect(bgRect, Paint()..color = _labelBgColor);
    painter.paint(canvas, Offset(labelX + padding, labelY + padding));
  }

  void _drawZIndexIndicator(
    Canvas canvas,
    int current,
    int total,
    Rect bounds,
    Size size,
  ) {
    final text = '$current/$total';
    final textSpan = TextSpan(
      text: text,
      style: const TextStyle(
        color: _labelTextColor,
        fontSize: 10,
        fontWeight: FontWeight.bold,
      ),
    );
    final painter = TextPainter(
      text: textSpan,
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final padding = 3.0;
    final bgWidth = painter.width + padding * 2;
    final bgHeight = painter.height + padding * 2;

    // Position at top-right of the bounds
    var x = bounds.right - bgWidth;
    var y = bounds.top + 2;
    if (x < 0) x = 0;
    if (y + bgHeight > size.height) y = size.height - bgHeight;

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(x, y, bgWidth, bgHeight),
      const Radius.circular(3),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xDD0066CC));
    painter.paint(canvas, Offset(x + padding, y + padding));
  }

  void _drawInfoPanel(Canvas canvas, Size size, InspectorSelection sel) {
    final lines = <String>[
      sel.widgetType,
      sel.widgetPath,
    ];
    if (sel.sourceLocation != null) {
      lines.add(sel.sourceLocation!);
    }
    if (sel.key != null) {
      lines.add('key: ${sel.key}');
    }
    if (sel.text != null) {
      lines.add('text: "${sel.text}"');
    }

    final textSpans = lines
        .map((line) => TextSpan(
              text: '$line\n',
              style: const TextStyle(
                color: _infoPanelText,
                fontSize: 11,
                height: 1.4,
              ),
            ))
        .toList();

    final painter = TextPainter(
      text: TextSpan(children: textSpans),
      textDirection: ui.TextDirection.ltr,
      maxLines: lines.length,
    )..layout(maxWidth: size.width - 24);

    final panelPadding = 8.0;
    final panelWidth = painter.width + panelPadding * 2;
    final panelHeight = painter.height + panelPadding * 2;
    final panelX = (size.width - panelWidth) / 2;
    final panelY = 8.0;

    final panelRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(panelX, panelY, panelWidth, panelHeight),
      const Radius.circular(6),
    );
    canvas.drawRRect(panelRect, Paint()..color = _infoPanelBg);

    // Thin border
    canvas.drawRRect(
      panelRect,
      Paint()
        ..color = _selectedBorderColor.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    painter.paint(
      canvas,
      Offset(panelX + panelPadding, panelY + panelPadding),
    );
  }

  @override
  bool shouldRepaint(InspectorPainter oldDelegate) {
    return oldDelegate.highlights != highlights ||
        oldDelegate.currentIndex != currentIndex ||
        oldDelegate.selection != selection;
  }
}
