import 'package:flan_flutter/src/overlay/drawing_painter.dart';
import 'package:flan_flutter/src/services/drawing_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DrawingPainter shouldRepaint', () {
    test('returns false for identical delegates', () {
      final painter1 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.none,
      );
      final painter2 = DrawingPainter(
        strokes: painter1.strokes,
        textLabels: painter1.textLabels,
        currentPoints: painter1.currentPoints,
        activeTool: painter1.activeTool,
      );
      expect(painter1.shouldRepaint(painter2), isFalse);
    });

    test('returns true when strokes change', () {
      final painter1 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.none,
      );
      final painter2 = DrawingPainter(
        strokes: [
          DrawingStroke(
            id: 0,
            rawPoints: [const Offset(0, 0), const Offset(10, 10)],
            color: const Color(0xFFFFFFFF),
            strokeWidth: 2.0,
          ),
        ],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.none,
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when activeTool changes', () {
      final painter1 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.none,
      );
      final painter2 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.pencil,
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when textLabels change', () {
      final painter1 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.none,
      );
      final painter2 = DrawingPainter(
        strokes: const [],
        textLabels: const [
          DrawingTextLabel(
            id: 0,
            position: Offset.zero,
            text: 'hi',
            color: Color(0xFFFFFFFF),
            fontSize: 16,
          ),
        ],
        currentPoints: const [],
        activeTool: DrawingTool.none,
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when currentPoints change', () {
      final painter1 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.none,
      );
      final painter2 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [Offset(10, 10)],
        activeTool: DrawingTool.none,
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when eraserPosition changes', () {
      final painter1 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.eraser,
      );
      final painter2 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.eraser,
        eraserPosition: const Offset(50, 50),
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when pendingTextPosition changes', () {
      final painter1 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.text,
      );
      final painter2 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.text,
        pendingTextPosition: const Offset(50, 50),
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when movingStrokeId changes', () {
      final painter1 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.move,
      );
      final painter2 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.move,
        movingStrokeId: 1,
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when movingLabelId changes', () {
      final painter1 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.move,
      );
      final painter2 = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.move,
        movingLabelId: 1,
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });
  });

  group('DrawingPainter paint', () {
    testWidgets('paints completed strokes', (tester) async {
      final painter = DrawingPainter(
        strokes: [
          DrawingStroke(
            id: 0,
            rawPoints: [const Offset(10, 10), const Offset(50, 50)],
            color: const Color(0xFFFFFFFF),
            strokeWidth: 2.5,
          ),
        ],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.none,
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: painter,
            size: const Size(200, 200),
          ),
        ),
      );

      // Painter should render without errors
      expect(tester.takeException(), isNull);
    });

    testWidgets('paints in-progress stroke', (tester) async {
      final painter = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [Offset(10, 10), Offset(50, 50)],
        activeTool: DrawingTool.pencil,
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: painter,
            size: const Size(200, 200),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('paints text labels', (tester) async {
      final painter = DrawingPainter(
        strokes: const [],
        textLabels: const [
          DrawingTextLabel(
            id: 0,
            position: Offset(20, 20),
            text: 'Hello',
            color: Color(0xFFFFFFFF),
            fontSize: 16,
          ),
        ],
        currentPoints: const [],
        activeTool: DrawingTool.none,
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: painter,
            size: const Size(200, 200),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('paints eraser cursor', (tester) async {
      final painter = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.eraser,
        eraserPosition: const Offset(50, 50),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: painter,
            size: const Size(200, 200),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('paints text placement cursor', (tester) async {
      final painter = DrawingPainter(
        strokes: const [],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.text,
        pendingTextPosition: const Offset(50, 50),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: painter,
            size: const Size(200, 200),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('paints stroke highlight when moving', (tester) async {
      final painter = DrawingPainter(
        strokes: [
          DrawingStroke(
            id: 5,
            rawPoints: [const Offset(10, 10), const Offset(50, 50)],
            color: const Color(0xFFFFFFFF),
            strokeWidth: 2.5,
          ),
        ],
        textLabels: const [],
        currentPoints: const [],
        activeTool: DrawingTool.move,
        movingStrokeId: 5,
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: painter,
            size: const Size(200, 200),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('paints label highlight when moving', (tester) async {
      final painter = DrawingPainter(
        strokes: const [],
        textLabels: const [
          DrawingTextLabel(
            id: 3,
            position: Offset(20, 20),
            text: 'Move me',
            color: Color(0xFFFFFFFF),
            fontSize: 16,
          ),
        ],
        currentPoints: const [],
        activeTool: DrawingTool.move,
        movingLabelId: 3,
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: painter,
            size: const Size(200, 200),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
