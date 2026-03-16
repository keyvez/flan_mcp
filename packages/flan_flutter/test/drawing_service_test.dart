import 'dart:ui';

import 'package:flan_flutter/src/services/drawing_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DrawingService service;

  setUp(() {
    service = DrawingService();
  });

  group('initial state', () {
    test('starts with no tool active', () {
      expect(service.activeTool, DrawingTool.none);
      expect(service.strokes, isEmpty);
      expect(service.textLabels, isEmpty);
      expect(service.currentPoints, isEmpty);
      expect(service.hasContent, isFalse);
      expect(service.pendingTextPosition, isNull);
      expect(service.movingStrokeId, isNull);
      expect(service.movingLabelId, isNull);
    });
  });

  group('tool management', () {
    test('setTool changes active tool and notifies', () {
      var notifications = 0;
      service.addListener(() => notifications++);

      service.setTool(DrawingTool.pencil);
      expect(service.activeTool, DrawingTool.pencil);
      expect(notifications, 1);

      service.setTool(DrawingTool.text);
      expect(service.activeTool, DrawingTool.text);
      expect(notifications, 2);
    });

    test('setTool to same tool does not notify', () {
      service.setTool(DrawingTool.pencil);
      var notifications = 0;
      service.addListener(() => notifications++);

      service.setTool(DrawingTool.pencil);
      expect(notifications, 0);
    });

    test('setTool cancels pending text placement', () {
      service.setTool(DrawingTool.text);
      service.startTextPlacement(const Offset(50, 50));
      expect(service.pendingTextPosition, isNotNull);

      service.setTool(DrawingTool.pencil);
      expect(service.pendingTextPosition, isNull);
    });

    test('setTool cancels move operation', () {
      service.setTool(DrawingTool.pencil);
      // Add a stroke first
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(20, 20));
      service.finishStroke();

      service.setTool(DrawingTool.move);
      service.startMove(const Offset(15, 15));
      expect(service.movingStrokeId, isNotNull);

      service.setTool(DrawingTool.pencil);
      expect(service.movingStrokeId, isNull);
      expect(service.movingLabelId, isNull);
    });
  });

  group('smoothing factor', () {
    test('setSmoothingFactor clamps value', () {
      service.setSmoothingFactor(0.5);
      expect(service.smoothingFactor, 0.5);

      service.setSmoothingFactor(-1.0);
      expect(service.smoothingFactor, 0.0);

      service.setSmoothingFactor(2.0);
      expect(service.smoothingFactor, 1.0);
    });
  });

  group('pencil / strokes', () {
    test('startStroke creates a current point', () {
      var notifications = 0;
      service.addListener(() => notifications++);

      service.startStroke(const Offset(10, 10));
      expect(service.currentPoints, hasLength(1));
      expect(notifications, 1);
    });

    test('addPoint adds to current points', () {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(20, 20));
      expect(service.currentPoints, hasLength(2));
    });

    test('finishStroke with fewer than 2 points discards', () {
      service.startStroke(const Offset(10, 10));
      service.finishStroke();
      expect(service.strokes, isEmpty);
      expect(service.currentPoints, isEmpty);
    });

    test('finishStroke with 2+ points creates a stroke', () {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(20, 20));
      service.finishStroke();

      expect(service.strokes, hasLength(1));
      expect(service.currentPoints, isEmpty);
      expect(service.hasContent, isTrue);
    });

    test('finishStroke with 3+ points applies smoothing', () {
      service.startStroke(const Offset(0, 0));
      service.addPoint(const Offset(50, 50));
      service.addPoint(const Offset(100, 0));
      service.finishStroke();

      final stroke = service.strokes.first;
      // Smoothed should have more points than raw due to Chaikin
      expect(stroke.smoothedPoints.length, greaterThan(stroke.rawPoints.length));
    });

    test('strokes have incrementing ids', () {
      service.startStroke(const Offset(0, 0));
      service.addPoint(const Offset(10, 10));
      service.finishStroke();

      service.startStroke(const Offset(20, 20));
      service.addPoint(const Offset(30, 30));
      service.finishStroke();

      expect(service.strokes[1].id, greaterThan(service.strokes[0].id));
    });
  });

  group('DrawingStroke', () {
    test('bounds calculates bounding rect', () {
      final stroke = DrawingStroke(
        id: 0,
        rawPoints: [const Offset(10, 20), const Offset(30, 40)],
        color: const Color(0xFFFFFFFF),
        strokeWidth: 2.0,
      );
      expect(stroke.bounds, const Rect.fromLTRB(10, 20, 30, 40));
    });

    test('bounds of empty points returns Rect.zero', () {
      final stroke = DrawingStroke(
        id: 0,
        rawPoints: const [],
        color: const Color(0xFFFFFFFF),
        strokeWidth: 2.0,
        smoothedPoints: const [],
      );
      expect(stroke.bounds, Rect.zero);
    });

    test('copyWithOffset shifts all points', () {
      final stroke = DrawingStroke(
        id: 0,
        rawPoints: [const Offset(10, 20)],
        color: const Color(0xFFFFFFFF),
        strokeWidth: 2.0,
      );
      final shifted = stroke.copyWithOffset(const Offset(5, 5));
      expect(shifted.rawPoints.first, const Offset(15, 25));
      expect(shifted.smoothedPoints.first, const Offset(15, 25));
      expect(shifted.id, 0);
    });
  });

  group('DrawingTextLabel', () {
    test('copyWithOffset shifts position', () {
      const label = DrawingTextLabel(
        id: 0,
        position: Offset(10, 20),
        text: 'hi',
        color: Color(0xFFFFFFFF),
        fontSize: 16,
      );
      final shifted = label.copyWithOffset(const Offset(5, -5));
      expect(shifted.position, const Offset(15, 15));
      expect(shifted.text, 'hi');
    });
  });

  group('text tool', () {
    test('startTextPlacement sets pending position', () {
      service.startTextPlacement(const Offset(50, 50));
      expect(service.pendingTextPosition, const Offset(50, 50));
    });

    test('submitText creates a text label', () {
      service.startTextPlacement(const Offset(50, 50));
      service.submitText('Hello');

      expect(service.textLabels, hasLength(1));
      expect(service.textLabels.first.text, 'Hello');
      expect(service.textLabels.first.position, const Offset(50, 50));
      expect(service.pendingTextPosition, isNull);
      expect(service.hasContent, isTrue);
    });

    test('submitText with empty text cancels placement', () {
      service.startTextPlacement(const Offset(50, 50));
      service.submitText('');

      expect(service.textLabels, isEmpty);
      expect(service.pendingTextPosition, isNull);
    });

    test('submitText trims whitespace', () {
      service.startTextPlacement(const Offset(50, 50));
      service.submitText('  trimmed  ');

      expect(service.textLabels.first.text, 'trimmed');
    });

    test('submitText without pending position does nothing', () {
      service.submitText('no position');
      expect(service.textLabels, isEmpty);
    });

    test('cancelTextPlacement clears pending position', () {
      service.startTextPlacement(const Offset(50, 50));
      service.cancelTextPlacement();
      expect(service.pendingTextPosition, isNull);
    });
  });

  group('eraser', () {
    test('eraseAt removes strokes within radius', () {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(20, 20));
      service.finishStroke();
      expect(service.strokes, hasLength(1));

      service.eraseAt(const Offset(15, 15), 10);
      expect(service.strokes, isEmpty);
    });

    test('eraseAt removes text labels within radius', () {
      service.startTextPlacement(const Offset(50, 50));
      service.submitText('remove me');
      expect(service.textLabels, hasLength(1));

      service.eraseAt(const Offset(50, 50), 5);
      expect(service.textLabels, isEmpty);
    });

    test('eraseAt does not remove distant elements', () {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(20, 20));
      service.finishStroke();

      service.eraseAt(const Offset(500, 500), 5);
      expect(service.strokes, hasLength(1));
    });

    test('eraseAt with no nearby elements does not notify', () {
      var notifications = 0;
      service.addListener(() => notifications++);

      service.eraseAt(const Offset(100, 100), 5);
      expect(notifications, 0);
    });
  });

  group('move tool', () {
    test('startMove finds nearest stroke', () {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(20, 20));
      service.finishStroke();

      service.startMove(const Offset(15, 15));
      expect(service.movingStrokeId, isNotNull);
      expect(service.movingLabelId, isNull);
    });

    test('startMove prefers text labels over strokes', () {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(20, 20));
      service.finishStroke();

      service.startTextPlacement(const Offset(15, 15));
      service.submitText('label');

      service.startMove(const Offset(15, 15));
      expect(service.movingLabelId, isNotNull);
      expect(service.movingStrokeId, isNull);
    });

    test('startMove with nothing nearby selects nothing', () {
      service.startMove(const Offset(500, 500));
      expect(service.movingStrokeId, isNull);
      expect(service.movingLabelId, isNull);
    });

    test('updateMove shifts stroke position', () {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(20, 20));
      service.finishStroke();

      final originalBounds = service.strokes.first.bounds;

      service.startMove(const Offset(15, 15));
      service.updateMove(const Offset(25, 25));

      final newBounds = service.strokes.first.bounds;
      expect(newBounds.left, closeTo(originalBounds.left + 10, 0.1));
      expect(newBounds.top, closeTo(originalBounds.top + 10, 0.1));
    });

    test('updateMove shifts label position', () {
      service.startTextPlacement(const Offset(50, 50));
      service.submitText('movable');

      service.startMove(const Offset(50, 50));
      service.updateMove(const Offset(60, 70));

      expect(service.textLabels.first.position, const Offset(60, 70));
    });

    test('updateMove without startMove does nothing', () {
      service.updateMove(const Offset(100, 100));
      // Should not throw
    });

    test('finishMove clears move state', () {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(20, 20));
      service.finishStroke();

      service.startMove(const Offset(15, 15));
      expect(service.movingStrokeId, isNotNull);

      service.finishMove();
      expect(service.movingStrokeId, isNull);
      expect(service.movingLabelId, isNull);
    });
  });

  group('clear', () {
    test('clears all strokes and labels', () {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(20, 20));
      service.finishStroke();

      service.startTextPlacement(const Offset(50, 50));
      service.submitText('text');

      service.clear();
      expect(service.strokes, isEmpty);
      expect(service.textLabels, isEmpty);
      expect(service.currentPoints, isEmpty);
      expect(service.hasContent, isFalse);
    });

    test('clear when empty does not notify', () {
      var notifications = 0;
      service.addListener(() => notifications++);

      service.clear();
      expect(notifications, 0);
    });

    test('clear with pending text notifies', () {
      service.startTextPlacement(const Offset(50, 50));

      var notifications = 0;
      service.addListener(() => notifications++);

      service.clear();
      expect(notifications, 1);
      expect(service.pendingTextPosition, isNull);
    });
  });

  group('toImageBase64', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('returns null when no content', () async {
      final result = await service.toImageBase64(const Size(100, 100));
      expect(result, isNull);
    });

    test('returns base64 string when content exists', () async {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(50, 50));
      service.finishStroke();

      final result = await service.toImageBase64(const Size(100, 100));
      expect(result, isNotNull);
      expect(result, isA<String>());
      expect(result!.isNotEmpty, isTrue);
    });

    test('renders text labels in image', () async {
      service.startTextPlacement(const Offset(20, 20));
      service.submitText('Label text');

      expect(service.textLabels, hasLength(1));
      expect(service.hasContent, isTrue);

      final result = await service.toImageBase64(const Size(200, 200));
      expect(result, isNotNull);
      expect(result, isA<String>());
      expect(result!.isNotEmpty, isTrue);
    });

    test('renders both strokes and text labels', () async {
      service.startStroke(const Offset(10, 10));
      service.addPoint(const Offset(50, 50));
      service.finishStroke();

      service.startTextPlacement(const Offset(60, 60));
      service.submitText('Combined');

      final result = await service.toImageBase64(const Size(200, 200));
      expect(result, isNotNull);
      expect(result!.isNotEmpty, isTrue);
    });
  });
}
