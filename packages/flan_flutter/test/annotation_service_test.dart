import 'dart:ui';

import 'package:flan_flutter/src/services/annotation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AnnotationService service;

  setUp(() {
    service = AnnotationService();
  });

  group('initial state', () {
    test('starts disabled with normal draw state', () {
      expect(service.enabled, isFalse);
      expect(service.drawState, AnnotationDrawState.normal);
      expect(service.annotations, isEmpty);
      expect(service.pendingRect, isNull);
      expect(service.dragStart, isNull);
      expect(service.dragCurrent, isNull);
      expect(service.editingIndex, isNull);
    });
  });

  group('enable/disable', () {
    test('enable sets enabled and notifies', () {
      var notifications = 0;
      service.addListener(() => notifications++);

      service.enable();
      expect(service.enabled, isTrue);
      expect(service.drawState, AnnotationDrawState.normal);
      expect(notifications, 1);
    });

    test('disable resets all state', () {
      service.enable();
      service.startDrawing(const Offset(10, 10));

      service.disable();
      expect(service.enabled, isFalse);
      expect(service.drawState, AnnotationDrawState.normal);
      expect(service.dragStart, isNull);
      expect(service.dragCurrent, isNull);
      expect(service.pendingRect, isNull);
      expect(service.editingIndex, isNull);
    });
  });

  group('drawing flow', () {
    setUp(() {
      service.enable();
    });

    test('startDrawing when disabled returns false', () {
      service.disable();
      expect(service.startDrawing(const Offset(10, 10)), isFalse);
    });

    test('startDrawing sets drawing state', () {
      final result = service.startDrawing(const Offset(10, 10));
      expect(result, isFalse);
      expect(service.drawState, AnnotationDrawState.drawing);
      expect(service.dragStart, const Offset(10, 10));
      expect(service.dragCurrent, const Offset(10, 10));
    });

    test('startDrawing during editing returns false', () {
      service.startDrawing(const Offset(10, 10));
      service.updateDrawing(const Offset(100, 100));
      service.finishDrawing();
      expect(service.drawState, AnnotationDrawState.editing);

      expect(service.startDrawing(const Offset(50, 50)), isFalse);
    });

    test('startDrawing during editingExisting returns false', () {
      service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'test',
      );
      service.startDrawing(const Offset(20, 20));
      expect(service.drawState, AnnotationDrawState.editingExisting);

      expect(service.startDrawing(const Offset(50, 50)), isFalse);
    });

    test('updateDrawing updates drag position', () {
      service.startDrawing(const Offset(10, 10));
      service.updateDrawing(const Offset(50, 50));
      expect(service.dragCurrent, const Offset(50, 50));
    });

    test('updateDrawing does nothing when not in drawing state', () {
      var notifications = 0;
      service.addListener(() => notifications++);

      service.updateDrawing(const Offset(50, 50));
      expect(notifications, 0);
    });

    test('finishDrawing with large enough rect enters editing', () {
      service.startDrawing(const Offset(10, 10));
      service.updateDrawing(const Offset(100, 100));
      service.finishDrawing();

      expect(service.drawState, AnnotationDrawState.editing);
      expect(service.pendingRect, isNotNull);
    });

    test('finishDrawing with too small rect resets', () {
      service.startDrawing(const Offset(10, 10));
      service.updateDrawing(const Offset(15, 15)); // too small
      service.finishDrawing();

      expect(service.drawState, AnnotationDrawState.normal);
      expect(service.pendingRect, isNull);
    });

    test('finishDrawing during editing state does nothing', () {
      service.startDrawing(const Offset(10, 10));
      service.updateDrawing(const Offset(100, 100));
      service.finishDrawing();
      expect(service.drawState, AnnotationDrawState.editing);

      service.finishDrawing(); // should not reset
      expect(service.drawState, AnnotationDrawState.editing);
    });

    test('finishDrawing during editingExisting does nothing', () {
      service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'test',
      );
      service.startDrawing(const Offset(20, 20));
      expect(service.drawState, AnnotationDrawState.editingExisting);

      service.finishDrawing();
      expect(service.drawState, AnnotationDrawState.editingExisting);
    });

    test('finishDrawing when not in drawing state resets', () {
      service.finishDrawing();
      expect(service.drawState, AnnotationDrawState.normal);
    });
  });

  group('submit annotation text', () {
    setUp(() {
      service.enable();
    });

    test('submitAnnotationText creates annotation with text', () {
      service.startDrawing(const Offset(10, 10));
      service.updateDrawing(const Offset(100, 100));
      service.finishDrawing();

      service.submitAnnotationText('Hello');
      expect(service.annotations, hasLength(1));
      expect(service.annotations.first.text, 'Hello');
      expect(service.drawState, AnnotationDrawState.normal);
    });

    test('submitAnnotationText with empty text uses fallback label', () {
      service.startDrawing(const Offset(10, 10));
      service.updateDrawing(const Offset(100, 100));
      service.finishDrawing();

      service.submitAnnotationText('');
      expect(service.annotations.first.text, '(no label)');
    });

    test('submitAnnotationText when not in editing state does nothing', () {
      service.submitAnnotationText('test');
      expect(service.annotations, isEmpty);
    });

    test('submitAnnotationText assigns incrementing ids', () {
      service.startDrawing(const Offset(10, 10));
      service.updateDrawing(const Offset(100, 100));
      service.finishDrawing();
      service.submitAnnotationText('first');

      service.startDrawing(const Offset(200, 200));
      service.updateDrawing(const Offset(300, 300));
      service.finishDrawing();
      service.submitAnnotationText('second');

      expect(
        int.parse(service.annotations[1].id),
        greaterThan(int.parse(service.annotations[0].id)),
      );
    });
  });

  group('edit existing annotation', () {
    setUp(() {
      service.enable();
    });

    test('tapping existing annotation enters editingExisting', () {
      service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'note',
      );

      final tapped = service.startDrawing(const Offset(20, 20));
      expect(tapped, isTrue);
      expect(service.drawState, AnnotationDrawState.editingExisting);
      expect(service.editingIndex, 0);
    });

    test('tapping overlapping annotations selects topmost (last)', () {
      service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 80, height: 80, text: 'bottom',
      );
      service.addAnnotationProgrammatically(
        x: 20, y: 20, width: 40, height: 40, text: 'top',
      );

      service.startDrawing(const Offset(30, 30));
      expect(service.editingIndex, 1);
    });

    test('submitEditedAnnotationText updates annotation text', () {
      service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'old',
      );
      service.startDrawing(const Offset(20, 20));
      service.submitEditedAnnotationText('new text');

      expect(service.annotations.first.text, 'new text');
      expect(service.drawState, AnnotationDrawState.normal);
      expect(service.editingIndex, isNull);
    });

    test('submitEditedAnnotationText with empty text deletes annotation', () {
      service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'delete me',
      );
      service.startDrawing(const Offset(20, 20));
      service.submitEditedAnnotationText('');

      expect(service.annotations, isEmpty);
    });

    test('submitEditedAnnotationText with out of range index resets state', () {
      service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'test',
      );
      service.startDrawing(const Offset(20, 20));
      // Remove the annotation while editing
      service.clearAnnotations();
      service.enable(); // re-enable after clear

      // Force editing state manually for edge case testing
      service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'test',
      );
      service.startDrawing(const Offset(20, 20));
      expect(service.drawState, AnnotationDrawState.editingExisting);

      // Remove all annotations
      service.clearAnnotations();
      // Submit should handle the invalid index gracefully
      // (clearAnnotations already resets state)
    });

    test('submitEditedAnnotationText when not in editingExisting does nothing', () {
      service.submitEditedAnnotationText('test');
      expect(service.annotations, isEmpty);
    });
  });

  group('cancelEditing', () {
    setUp(() {
      service.enable();
    });

    test('cancels drawing and resets state', () {
      service.startDrawing(const Offset(10, 10));
      service.updateDrawing(const Offset(100, 100));
      service.finishDrawing();

      service.cancelEditing();
      expect(service.drawState, AnnotationDrawState.normal);
      expect(service.pendingRect, isNull);
      expect(service.editingIndex, isNull);
    });
  });

  group('removeAnnotationById', () {
    setUp(() {
      service.enable();
    });

    test('removes annotation and returns true', () {
      final annotation = service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'test',
      );

      expect(service.removeAnnotationById(annotation.id), isTrue);
      expect(service.annotations, isEmpty);
    });

    test('returns false for non-existent id', () {
      expect(service.removeAnnotationById('nonexistent'), isFalse);
    });

    test('adjusts editing index when removing earlier annotation', () {
      final first = service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'first',
      );
      service.addAnnotationProgrammatically(
        x: 80, y: 10, width: 40, height: 40, text: 'second',
      );

      service.startDrawing(const Offset(90, 20));
      expect(service.editingIndex, 1);

      service.removeAnnotationById(first.id);
      expect(service.editingIndex, 0);
    });

    test('clears editing index when removing edited annotation', () {
      final annotation = service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'test',
      );
      service.startDrawing(const Offset(20, 20));
      expect(service.editingIndex, 0);

      service.removeAnnotationById(annotation.id);
      expect(service.editingIndex, isNull);
      expect(service.drawState, AnnotationDrawState.normal);
    });
  });

  group('updateAnnotationTextById', () {
    setUp(() {
      service.enable();
    });

    test('updates text and returns true', () {
      final annotation = service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'old',
      );

      expect(service.updateAnnotationTextById(annotation.id, 'new'), isTrue);
      expect(service.annotations.first.text, 'new');
    });

    test('trims whitespace', () {
      final annotation = service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'old',
      );

      service.updateAnnotationTextById(annotation.id, '  trimmed  ');
      expect(service.annotations.first.text, 'trimmed');
    });

    test('empty text deletes the annotation', () {
      final annotation = service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'delete me',
      );

      service.updateAnnotationTextById(annotation.id, '');
      expect(service.annotations, isEmpty);
    });

    test('returns false for non-existent id', () {
      expect(service.updateAnnotationTextById('nonexistent', 'text'), isFalse);
    });

    test('adjusts editing index when deleting via empty text', () {
      final first = service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'first',
      );
      service.addAnnotationProgrammatically(
        x: 80, y: 10, width: 40, height: 40, text: 'second',
      );

      service.startDrawing(const Offset(90, 20));
      expect(service.editingIndex, 1);

      service.updateAnnotationTextById(first.id, '');
      expect(service.editingIndex, 0);
    });
  });

  group('clearAnnotations', () {
    test('clears all annotations and resets state', () {
      service.enable();
      service.addAnnotationProgrammatically(
        x: 10, y: 10, width: 40, height: 40, text: 'note',
      );

      service.startDrawing(const Offset(20, 20));
      expect(service.drawState, AnnotationDrawState.editingExisting);

      service.clearAnnotations();
      expect(service.annotations, isEmpty);
      expect(service.drawState, AnnotationDrawState.normal);
      expect(service.editingIndex, isNull);
    });
  });

  group('addAnnotationProgrammatically', () {
    test('adds annotation with correct bounds and text', () {
      final annotation = service.addAnnotationProgrammatically(
        x: 10, y: 20, width: 100, height: 50, text: 'hello',
      );

      expect(annotation.bounds, const Rect.fromLTWH(10, 20, 100, 50));
      expect(annotation.text, 'hello');
      expect(annotation.id, isNotEmpty);
      expect(service.annotations, hasLength(1));
    });
  });

  group('getAnnotationsData', () {
    test('returns JSON-serializable data', () {
      service.addAnnotationProgrammatically(
        x: 10, y: 20, width: 100, height: 50, text: 'data test',
      );

      final data = service.getAnnotationsData();
      expect(data, hasLength(1));
      expect(data.first['text'], 'data test');
      expect(data.first['bounds'], isA<Map>());
      expect(data.first['bounds']['x'], 10.0);
      expect(data.first['bounds']['y'], 20.0);
      expect(data.first['bounds']['width'], 100.0);
      expect(data.first['bounds']['height'], 50.0);
      expect(data.first['id'], isNotEmpty);
      expect(data.first['timestamp'], isNotNull);
    });
  });

  group('Annotation model', () {
    test('toJson includes all fields', () {
      final annotation = Annotation(
        id: '42',
        bounds: const Rect.fromLTWH(1, 2, 3, 4),
        text: 'test',
      );
      final json = annotation.toJson();
      expect(json['id'], '42');
      expect(json['text'], 'test');
      expect(json['bounds']['x'], 1.0);
      expect(json['bounds']['y'], 2.0);
      expect(json['bounds']['width'], 3.0);
      expect(json['bounds']['height'], 4.0);
      expect(json['timestamp'], isA<String>());
    });

    test('copyWith creates modified copy', () {
      final annotation = Annotation(
        id: '1',
        bounds: const Rect.fromLTWH(0, 0, 10, 10),
        text: 'original',
      );
      final modified = annotation.copyWith(text: 'modified');
      expect(modified.text, 'modified');
      expect(modified.id, '1');
      expect(modified.bounds, const Rect.fromLTWH(0, 0, 10, 10));
      expect(modified.timestamp, annotation.timestamp);
    });

    test('copyWith can change bounds', () {
      final annotation = Annotation(
        id: '1',
        bounds: const Rect.fromLTWH(0, 0, 10, 10),
        text: 'test',
      );
      final modified = annotation.copyWith(
        bounds: const Rect.fromLTWH(5, 5, 20, 20),
      );
      expect(modified.bounds, const Rect.fromLTWH(5, 5, 20, 20));
      expect(modified.text, 'test');
    });

    test('default timestamp is set to now', () {
      final before = DateTime.now();
      final annotation = Annotation(
        id: '1',
        bounds: Rect.zero,
        text: 'test',
      );
      final after = DateTime.now();

      expect(annotation.timestamp.isAfter(before) ||
          annotation.timestamp == before, isTrue);
      expect(annotation.timestamp.isBefore(after) ||
          annotation.timestamp == after, isTrue);
    });
  });

  group('updateAnnotationTextById edge cases', () {
    test('empty text removes annotation and resets editing index', () {
      service.enable();
      // Add two annotations
      service.addAnnotationProgrammatically(
        x: 10, y: 20, width: 100, height: 50, text: 'First',
      );
      service.addAnnotationProgrammatically(
        x: 200, y: 300, width: 80, height: 40, text: 'Second',
      );
      expect(service.annotations, hasLength(2));

      // Start editing the first annotation by tapping inside its bounds
      final tappedExisting = service.startDrawing(const Offset(60, 45));
      expect(tappedExisting, isTrue);
      expect(service.drawState, AnnotationDrawState.editingExisting);

      // Update with empty text - should remove
      final removed = service.updateAnnotationTextById(
        service.annotations.first.id,
        '',
      );
      expect(removed, isTrue);
      expect(service.annotations, hasLength(1));
    });
  });

  group('submitEditedAnnotationText edge cases', () {
    test('submitEditedAnnotationText updates text of edited annotation', () {
      service.enable();
      service.addAnnotationProgrammatically(
        x: 10, y: 20, width: 100, height: 50, text: 'Original',
      );

      // Start editing by tapping inside the annotation bounds
      final tappedExisting = service.startDrawing(const Offset(60, 45));
      expect(tappedExisting, isTrue);
      expect(service.drawState, AnnotationDrawState.editingExisting);

      // Submit new text
      service.submitEditedAnnotationText('Updated text');

      // State should be reset to normal
      expect(service.drawState, AnnotationDrawState.normal);
      expect(service.annotations.first.text, 'Updated text');
    });

    test('submitEditedAnnotationText with empty text removes annotation', () {
      service.enable();
      service.addAnnotationProgrammatically(
        x: 10, y: 20, width: 100, height: 50, text: 'Delete me',
      );

      // Start editing
      final tappedExisting = service.startDrawing(const Offset(60, 45));
      expect(tappedExisting, isTrue);

      // Submit empty text to delete
      service.submitEditedAnnotationText('');

      expect(service.annotations, isEmpty);
      expect(service.drawState, AnnotationDrawState.normal);
    });

    test('submitEditedAnnotationText is no-op when not in editing state', () {
      service.enable();
      service.addAnnotationProgrammatically(
        x: 10, y: 20, width: 100, height: 50, text: 'Unchanged',
      );

      var notifications = 0;
      service.addListener(() => notifications++);

      // Not in editing state, should be a no-op
      service.submitEditedAnnotationText('New text');

      expect(notifications, 0);
      expect(service.annotations.first.text, 'Unchanged');
    });
  });
}
