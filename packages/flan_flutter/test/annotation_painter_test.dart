import 'package:flan_flutter/src/overlay/annotation_painter.dart';
import 'package:flan_flutter/src/services/annotation_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AnnotationPainter shouldRepaint', () {
    test('returns false for identical delegates', () {
      final painter1 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.normal,
      );
      final painter2 = AnnotationPainter(
        annotations: painter1.annotations,
        drawState: AnnotationDrawState.normal,
      );
      expect(painter1.shouldRepaint(painter2), isFalse);
    });

    test('returns true when annotations change', () {
      final painter1 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.normal,
      );
      final painter2 = AnnotationPainter(
        annotations: [
          Annotation(
            id: '1',
            bounds: const Rect.fromLTWH(0, 0, 50, 50),
            text: 'test',
          ),
        ],
        drawState: AnnotationDrawState.normal,
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when drawState changes', () {
      final painter1 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.normal,
      );
      final painter2 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.drawing,
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when dragStart changes', () {
      final painter1 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.drawing,
      );
      final painter2 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.drawing,
        dragStart: const Offset(10, 10),
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when dragCurrent changes', () {
      final painter1 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.drawing,
        dragStart: const Offset(10, 10),
      );
      final painter2 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.drawing,
        dragStart: const Offset(10, 10),
        dragCurrent: const Offset(50, 50),
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when pendingRect changes', () {
      final painter1 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.editing,
      );
      final painter2 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.editing,
        pendingRect: const Rect.fromLTWH(10, 10, 80, 60),
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    test('returns true when editingIndex changes', () {
      final painter1 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.editingExisting,
      );
      final painter2 = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.editingExisting,
        editingIndex: 0,
      );
      expect(painter2.shouldRepaint(painter1), isTrue);
    });
  });

  group('AnnotationPainter paint', () {
    testWidgets('paints completed annotations', (tester) async {
      final painter = AnnotationPainter(
        annotations: [
          Annotation(
            id: '1',
            bounds: const Rect.fromLTWH(10, 10, 80, 60),
            text: 'Label',
          ),
        ],
        drawState: AnnotationDrawState.normal,
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

    testWidgets('paints drag rectangle', (tester) async {
      final painter = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.drawing,
        dragStart: const Offset(10, 10),
        dragCurrent: const Offset(80, 60),
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

    testWidgets('paints editing rectangle', (tester) async {
      final painter = AnnotationPainter(
        annotations: const [],
        drawState: AnnotationDrawState.editing,
        pendingRect: const Rect.fromLTWH(10, 10, 80, 60),
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

    testWidgets('paints editing existing annotation with highlight',
        (tester) async {
      final painter = AnnotationPainter(
        annotations: [
          Annotation(
            id: '1',
            bounds: const Rect.fromLTWH(10, 10, 80, 60),
            text: 'Editing this',
          ),
        ],
        drawState: AnnotationDrawState.editingExisting,
        editingIndex: 0,
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

    testWidgets('paints annotation without text', (tester) async {
      final painter = AnnotationPainter(
        annotations: [
          Annotation(
            id: '1',
            bounds: const Rect.fromLTWH(10, 10, 80, 60),
            text: '',
          ),
        ],
        drawState: AnnotationDrawState.normal,
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

    testWidgets('paints multiple annotations', (tester) async {
      final painter = AnnotationPainter(
        annotations: [
          Annotation(
            id: '1',
            bounds: const Rect.fromLTWH(10, 10, 60, 40),
            text: 'First',
          ),
          Annotation(
            id: '2',
            bounds: const Rect.fromLTWH(100, 100, 80, 50),
            text: 'Second',
          ),
        ],
        drawState: AnnotationDrawState.normal,
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: painter,
            size: const Size(300, 300),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
