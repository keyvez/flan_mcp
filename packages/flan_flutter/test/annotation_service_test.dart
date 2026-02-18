import 'package:flan_flutter/src/services/annotation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clearAnnotations resets editing state', () {
    final service = AnnotationService()..enable();
    service.addAnnotationProgrammatically(
      x: 10,
      y: 10,
      width: 40,
      height: 40,
      text: 'note',
    );

    final tapped = service.startDrawing(const Offset(20, 20));
    expect(tapped, isTrue);
    expect(service.drawState, AnnotationDrawState.editingExisting);
    expect(service.editingIndex, 0);

    service.clearAnnotations();

    expect(service.annotations, isEmpty);
    expect(service.drawState, AnnotationDrawState.normal);
    expect(service.editingIndex, isNull);
  });

  test('removing earlier annotation keeps editing index in sync', () {
    final service = AnnotationService()..enable();
    final first = service.addAnnotationProgrammatically(
      x: 10,
      y: 10,
      width: 40,
      height: 40,
      text: 'first',
    );
    final second = service.addAnnotationProgrammatically(
      x: 80,
      y: 10,
      width: 40,
      height: 40,
      text: 'second',
    );

    final tapped = service.startDrawing(const Offset(90, 20));
    expect(tapped, isTrue);
    expect(service.editingIndex, 1);

    expect(service.removeAnnotationById(first.id), isTrue);
    expect(service.editingIndex, 0);
    expect(service.drawState, AnnotationDrawState.editingExisting);

    service.submitEditedAnnotationText('updated');
    expect(service.drawState, AnnotationDrawState.normal);
    expect(service.editingIndex, isNull);
    expect(service.annotations.single.id, second.id);
    expect(service.annotations.single.text, 'updated');
  });
}
