import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide InspectorSelection;
import 'package:flutter/services.dart';
import 'package:flan_flutter/src/overlay/annotation_painter.dart';
import 'package:flan_flutter/src/overlay/drawing_painter.dart';
import 'package:flan_flutter/src/services/annotation_service.dart';
import 'package:flan_flutter/src/services/drawing_service.dart';
import 'package:flan_flutter/src/services/inspector_service.dart';
import 'package:flan_flutter/src/services/error_interceptor.dart';
import 'package:flan_flutter/src/services/github_issue_service.dart';
import 'package:flan_flutter/src/services/screenshot_service.dart';
import 'package:flan_flutter/src/services/user_message_service.dart';

void _noopAnnotationSubmittedCallback() {}

Uint8List? _decodeBase64Image(String? rawImage) {
  if (rawImage == null || rawImage.trim().isEmpty) {
    return null;
  }
  var normalized = rawImage.trim();
  final commaIndex = normalized.indexOf(',');
  if (normalized.startsWith('data:') && commaIndex != -1) {
    normalized = normalized.substring(commaIndex + 1);
  }
  try {
    return base64Decode(normalized);
  } catch (_) {
    return null;
  }
}

Rect? _rectFromBoundsValue(Object? value) {
  if (value is! Map) return null;
  final x = value['x'];
  final y = value['y'];
  final width = value['width'];
  final height = value['height'];
  if (x is! num || y is! num || width is! num || height is! num) {
    return null;
  }
  if (width <= 0 || height <= 0) return null;
  return Rect.fromLTWH(
    x.toDouble(),
    y.toDouble(),
    width.toDouble(),
    height.toDouble(),
  );
}

Rect _fitRectToAspect(Rect rect, double targetAspect, Size imageSize) {
  final currentAspect = rect.width / rect.height;
  var adjusted = rect;

  if (currentAspect > targetAspect) {
    final targetHeight = rect.width / targetAspect;
    adjusted = Rect.fromLTWH(
      rect.left,
      rect.center.dy - targetHeight / 2,
      rect.width,
      targetHeight,
    );
  } else {
    final targetWidth = rect.height * targetAspect;
    adjusted = Rect.fromLTWH(
      rect.center.dx - targetWidth / 2,
      rect.top,
      targetWidth,
      rect.height,
    );
  }

  if (adjusted.left < 0) {
    adjusted = adjusted.shift(Offset(-adjusted.left, 0));
  }
  if (adjusted.top < 0) {
    adjusted = adjusted.shift(Offset(0, -adjusted.top));
  }
  if (adjusted.right > imageSize.width) {
    adjusted = adjusted.shift(Offset(imageSize.width - adjusted.right, 0));
  }
  if (adjusted.bottom > imageSize.height) {
    adjusted = adjusted.shift(Offset(0, imageSize.height - adjusted.bottom));
  }

  final clampedWidth = adjusted.width.clamp(1.0, imageSize.width);
  final clampedHeight = adjusted.height.clamp(1.0, imageSize.height);
  return Rect.fromLTWH(
    adjusted.left.clamp(0.0, imageSize.width - clampedWidth).toDouble(),
    adjusted.top.clamp(0.0, imageSize.height - clampedHeight).toDouble(),
    clampedWidth.toDouble(),
    clampedHeight.toDouble(),
  );
}

Future<String?> _buildQueueThumbnailFromScreenshot({
  required String screenshotBase64,
  required Rect targetBounds,
  required Size viewportSize,
  int thumbnailWidth = 120,
  int thumbnailHeight = 72,
}) async {
  if (viewportSize.width <= 0 || viewportSize.height <= 0) {
    return null;
  }
  final screenshotBytes = _decodeBase64Image(screenshotBase64);
  if (screenshotBytes == null || screenshotBytes.isEmpty) {
    return null;
  }

  ui.Codec? codec;
  ui.Image? sourceImage;
  ui.Image? thumbnailImage;

  try {
    codec = await ui.instantiateImageCodec(screenshotBytes);
    final frame = await codec.getNextFrame();
    sourceImage = frame.image;

    final imageSize = Size(
      sourceImage.width.toDouble(),
      sourceImage.height.toDouble(),
    );
    final scaleX = imageSize.width / viewportSize.width;
    final scaleY = imageSize.height / viewportSize.height;

    final paddedBounds = targetBounds.inflate(20);
    final clampedBounds = Rect.fromLTRB(
      paddedBounds.left.clamp(0.0, viewportSize.width).toDouble(),
      paddedBounds.top.clamp(0.0, viewportSize.height).toDouble(),
      paddedBounds.right.clamp(0.0, viewportSize.width).toDouble(),
      paddedBounds.bottom.clamp(0.0, viewportSize.height).toDouble(),
    );
    if (clampedBounds.width <= 0 || clampedBounds.height <= 0) {
      return null;
    }

    final sourceRect = Rect.fromLTWH(
      clampedBounds.left * scaleX,
      clampedBounds.top * scaleY,
      clampedBounds.width * scaleX,
      clampedBounds.height * scaleY,
    );
    final fittedSourceRect = _fitRectToAspect(
      sourceRect,
      thumbnailWidth / thumbnailHeight,
      imageSize,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..filterQuality = FilterQuality.low;
    canvas.drawImageRect(
      sourceImage,
      fittedSourceRect,
      Rect.fromLTWH(
        0,
        0,
        thumbnailWidth.toDouble(),
        thumbnailHeight.toDouble(),
      ),
      paint,
    );
    final picture = recorder.endRecording();
    thumbnailImage = await picture.toImage(thumbnailWidth, thumbnailHeight);
    picture.dispose();

    final byteData = await thumbnailImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (byteData == null) return null;
    return base64Encode(byteData.buffer.asUint8List());
  } catch (_) {
    return null;
  } finally {
    thumbnailImage?.dispose();
    sourceImage?.dispose();
    codec?.dispose();
  }
}

Size _resolveViewportSize(BuildContext context) {
  final mediaSize = MediaQuery.maybeSizeOf(context);
  if (mediaSize != null && mediaSize.width > 0 && mediaSize.height > 0) {
    return mediaSize;
  }

  final view = View.maybeOf(context);
  if (view != null && view.devicePixelRatio > 0) {
    return Size(
      view.physicalSize.width / view.devicePixelRatio,
      view.physicalSize.height / view.devicePixelRatio,
    );
  }

  return Size.zero;
}

Future<void> _attachScreenshotAndQueueThumbnail({
  required BuildContext context,
  required ScreenshotService screenshotService,
  required Map<String, dynamic> data,
  Rect? previewBounds,
}) async {
  final screenshots = await screenshotService.takeScreenshots();
  if (screenshots.isEmpty) {
    return;
  }

  data['screenshot'] = screenshots.first;
  if (previewBounds == null) {
    return;
  }

  final viewportSize = _resolveViewportSize(context);
  if (viewportSize.width <= 0 || viewportSize.height <= 0) {
    return;
  }

  for (final screenshot in screenshots) {
    final queueThumbnail = await _buildQueueThumbnailFromScreenshot(
      screenshotBase64: screenshot,
      targetBounds: previewBounds,
      viewportSize: viewportSize,
    );
    if (queueThumbnail != null) {
      data['queueThumbnail'] = queueThumbnail;
      data['screenshot'] = screenshot;
      return;
    }
  }
}

/// Overlay widget injected at the root of the app via
/// [FlanBinding.wrapWithDefaultView]. Renders inspector interaction
/// and annotation drawing UI on top of the app content.
class FlanOverlayWidget extends StatefulWidget {
  const FlanOverlayWidget({
    super.key,
    required this.inspectorService,
    required this.annotationService,
    required this.userMessageService,
    required this.screenshotService,
    required this.errorInterceptor,
    required this.child,
  });

  final InspectorService inspectorService;
  final AnnotationService annotationService;
  final UserMessageService userMessageService;
  final ScreenshotService screenshotService;
  final ErrorInterceptor errorInterceptor;
  final Widget child;

  @override
  State<FlanOverlayWidget> createState() => _FlanOverlayWidgetState();
}

class _FlanOverlayWidgetState extends State<FlanOverlayWidget> {
  bool _showTextMessageOverlay = false;
  bool _textOverlayEverShown = false;
  bool _showQueuedMessagesPanel = false;
  bool _showErrorPanel = false;
  List<Map<String, dynamic>> _queuedMessagesSnapshot = const [];
  int? _annotationDraftQueueId;
  String _lastQueuedAnnotationsSignature = '';

  /// Guard flag to prevent the user-message listener from recreating
  /// an annotation draft while [_sendToAgent] is in progress.
  bool _isSendingToAgent = false;

  /// Guard flag to prevent [_onAnnotationServiceChanged] from upserting
  /// a new annotation draft while [_applyQueuedAnnotationEdit] is updating
  /// the annotation text (which triggers notifyListeners).
  bool _suppressAnnotationDraftUpsert = false;

  /// Tracks [UserMessageService.agentConsumeGeneration] so we can detect
  /// when the agent has consumed queued messages and clear annotations
  /// instead of re-creating a draft.
  int _lastSeenConsumeGeneration = 0;

  /// Tracks the last time an Alt/Option key was pressed for double-tap detection.
  DateTime? _lastAltPressTime;

  /// Tracks the last time a Ctrl key was pressed for double-tap detection.
  DateTime? _lastCtrlPressTime;

  @override
  void initState() {
    super.initState();
    _lastSeenConsumeGeneration =
        widget.userMessageService.agentConsumeGeneration;
    widget.inspectorService.addListener(_onServiceChanged);
    widget.annotationService.addListener(_onAnnotationServiceChanged);
    widget.userMessageService.addListener(_onUserMessageServiceChanged);
    widget.errorInterceptor.addListener(_onServiceChanged);
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    _onAnnotationServiceChanged();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    widget.inspectorService.removeListener(_onServiceChanged);
    widget.annotationService.removeListener(_onAnnotationServiceChanged);
    widget.userMessageService.removeListener(_onUserMessageServiceChanged);
    widget.errorInterceptor.removeListener(_onServiceChanged);
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();
    // Dismiss the text message overlay on hot reload.
    if (_showTextMessageOverlay) {
      setState(() => _showTextMessageOverlay = false);
    }
  }

  bool _serviceChangePending = false;

  void _onServiceChanged() {
    if (_showErrorPanel && widget.errorInterceptor.errors.isEmpty) {
      _showErrorPanel = false;
    }
    if (!mounted || _serviceChangePending) return;
    _serviceChangePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _serviceChangePending = false;
      if (mounted) setState(() {});
    });
  }

  void _onAnnotationServiceChanged() {
    if (_suppressAnnotationDraftUpsert) {
      if (mounted) setState(() {});
      return;
    }
    final annotations = widget.annotationService.getAnnotationsData();
    final signature = jsonEncode(annotations);
    if (signature != _lastQueuedAnnotationsSignature) {
      _lastQueuedAnnotationsSignature = signature;
      _upsertQueuedAnnotationDraft(annotations);
    }
    if (mounted) setState(() {});
  }

  void _upsertQueuedAnnotationDraft(List<Map<String, dynamic>> annotations) {
    if (annotations.isEmpty) {
      final queueId = _annotationDraftQueueId;
      if (queueId != null) {
        widget.userMessageService.removeMessageByQueueId(queueId);
      }
      _annotationDraftQueueId = null;
      return;
    }

    final enrichedAnnotations = annotations
        .map((annotation) => Map<String, dynamic>.from(annotation))
        .toList(growable: false);
    for (final annotation in enrichedAnnotations) {
      final bounds = annotation['bounds'] as Map<String, dynamic>?;
      if (bounds == null) continue;
      final x = bounds['x'];
      final y = bounds['y'];
      final width = bounds['width'];
      final height = bounds['height'];
      if (x is! num || y is! num || width is! num || height is! num) {
        continue;
      }
      final centerX = x + width / 2;
      final centerY = y + height / 2;
      final widgetSelection = widget.inspectorService.inspectAtForAgent(
        centerX.toDouble(),
        centerY.toDouble(),
        includeProperties: false,
      );
      if (widgetSelection != null) {
        annotation['widget'] = widgetSelection.toJson();
      }
    }

    final data = <String, dynamic>{
      'annotations': enrichedAnnotations,
      'annotationDraft': true,
    };
    final text = _rebuildQueuedMessageText(
      fallback: 'Annotation draft',
      data: data,
    );

    final queueId = _annotationDraftQueueId;
    if (queueId != null) {
      widget.userMessageService.updateMessageByQueueId(queueId, {
        'type': 'user_feedback',
        'text': text,
        'data': data,
      });
      // Attach a cropped thumbnail asynchronously.
      _attachDraftThumbnail(queueId, enrichedAnnotations, data);
      return;
    }

    widget.userMessageService.sendMessage({
      'type': 'user_feedback',
      'text': text,
      'data': data,
    });
    final pendingMessages = widget.userMessageService.peekMessages();
    for (final message in pendingMessages.reversed) {
      final messageData = _normalizedDataMap(message['data']);
      if (messageData['annotationDraft'] == true) {
        _annotationDraftQueueId = _queueIdOf(message);
        if (_annotationDraftQueueId != null) {
          break;
        }
      }
    }
    // Attach a cropped thumbnail asynchronously.
    if (_annotationDraftQueueId != null) {
      _attachDraftThumbnail(
          _annotationDraftQueueId!, enrichedAnnotations, data);
    }
  }

  /// Asynchronously captures a screenshot and attaches a cropped thumbnail
  /// to the draft message identified by [queueId].
  Future<void> _attachDraftThumbnail(
    int queueId,
    List<Map<String, dynamic>> annotations,
    Map<String, dynamic> data,
  ) async {
    final previewBounds = _resolveQueuePreviewBounds(
      selection: null,
      annotations: annotations,
    );
    try {
      await _attachScreenshotAndQueueThumbnail(
        context: context,
        screenshotService: widget.screenshotService,
        data: data,
        previewBounds: previewBounds,
      );
    } catch (_) {
      return;
    }
    // Update the message with the thumbnail if it still exists.
    if (_annotationDraftQueueId == queueId) {
      widget.userMessageService.updateMessageByQueueId(queueId, {
        'type': 'user_feedback',
        'text': _rebuildQueuedMessageText(
          fallback: 'Annotation draft',
          data: data,
        ),
        'data': data,
      });
    }
  }

  void _onUserMessageServiceChanged() {
    if (!mounted) return;

    // Detect whether the agent just consumed messages. If so, clear
    // annotations so the draft isn't immediately re-created.
    final currentGeneration =
        widget.userMessageService.agentConsumeGeneration;
    if (currentGeneration != _lastSeenConsumeGeneration) {
      _lastSeenConsumeGeneration = currentGeneration;
      _annotationDraftQueueId = null;
      _suppressAnnotationDraftUpsert = true;
      widget.annotationService.clearAnnotations();
      _lastQueuedAnnotationsSignature =
          jsonEncode(widget.annotationService.getAnnotationsData());
      _suppressAnnotationDraftUpsert = false;
    }

    final pendingMessages = widget.userMessageService.peekMessages();
    if (_annotationDraftQueueId != null &&
        !pendingMessages.any((m) => _queueIdOf(m) == _annotationDraftQueueId)) {
      _annotationDraftQueueId = null;
    }
    if (_annotationDraftQueueId == null) {
      for (final message in pendingMessages.reversed) {
        final data = _normalizedDataMap(message['data']);
        if (data['annotationDraft'] == true) {
          _annotationDraftQueueId = _queueIdOf(message);
          if (_annotationDraftQueueId != null) break;
        }
      }
      if (_annotationDraftQueueId == null &&
          !_suppressAnnotationDraftUpsert &&
          !_isSendingToAgent &&
          !widget.userMessageService.isAgentListening &&
          widget.annotationService.annotations.isNotEmpty) {
        // Only create a new draft if the annotations have changed since
        // the last send/queue. This prevents re-creating a draft after
        // _sendToAgent when the same annotations are still on screen.
        final currentSignature =
            jsonEncode(widget.annotationService.getAnnotationsData());
        if (currentSignature != _lastQueuedAnnotationsSignature) {
          _upsertQueuedAnnotationDraft(
              widget.annotationService.getAnnotationsData());
        }
      }
    }

    setState(() {
      // Dismiss the overlay when the waiting state clears (e.g. after hot
      // reload).
      if (_showTextMessageOverlay &&
          !widget.userMessageService.waitingForActivity) {
        _showTextMessageOverlay = false;
      }

      // Keep the open queue panel synchronized with the service queue.
      if (_showQueuedMessagesPanel) {
        _queuedMessagesSnapshot = pendingMessages
            .map((message) => Map<String, dynamic>.from(message))
            .toList();
        if (_queuedMessagesSnapshot.isEmpty) {
          _showQueuedMessagesPanel = false;
        }
      }
    });
  }

  /// Global keyboard shortcut handler.
  /// Ctrl+Shift+H toggles inspector mode.
  /// Double-tap Ctrl toggles annotation mode.
  /// Ctrl+Shift+Enter sends current data to the LLM agent.
  /// Escape exits the active mode.
  bool _handleGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    // Double-tap Alt/Option to open text message overlay.
    if (event.logicalKey == LogicalKeyboardKey.altLeft ||
        event.logicalKey == LogicalKeyboardKey.altRight) {
      final now = DateTime.now();
      if (_lastAltPressTime != null &&
          now.difference(_lastAltPressTime!).inMilliseconds < 500) {
        _lastAltPressTime = null;
        _openTextMessageOverlay();
        return true;
      }
      _lastAltPressTime = now;
      return false;
    }

    // Double-tap Ctrl to toggle annotation mode.
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      final now = DateTime.now();
      if (_lastCtrlPressTime != null &&
          now.difference(_lastCtrlPressTime!).inMilliseconds < 500) {
        _lastCtrlPressTime = null;
        if (widget.annotationService.enabled) {
          widget.annotationService.disable();
        } else {
          if (widget.inspectorService.enabled) {
            widget.inspectorService.disable();
          }
          widget.annotationService.enable();
        }
        return true;
      }
      _lastCtrlPressTime = now;
      return false;
    }

    // Escape exits whichever mode is active (no modifiers needed).
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_showErrorPanel) {
        setState(() => _showErrorPanel = false);
        return true;
      }
      if (_showTextMessageOverlay) {
        widget.userMessageService.clearWaiting();
        setState(() => _showTextMessageOverlay = false);
        return true;
      }
      if (widget.inspectorService.enabled) {
        widget.inspectorService.disable();
        return true;
      }
      if (widget.annotationService.enabled) {
        widget.annotationService.disable();
        return true;
      }
      return false;
    }

    // Use Ctrl+Shift only (not Cmd/Meta) to avoid browser shortcut conflicts.
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (!ctrl || !shift) return false;

    if (event.logicalKey == LogicalKeyboardKey.keyH) {
      if (widget.inspectorService.enabled) {
        widget.inspectorService.disable();
      } else {
        if (widget.annotationService.enabled) {
          widget.annotationService.disable();
        }
        widget.inspectorService.enable();
      }
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _sendToAgent();
      return true;
    }

    return false;
  }

  void _openTextMessageOverlay() {
    // Disable other modes
    if (widget.inspectorService.enabled) {
      widget.inspectorService.disable();
    }
    if (widget.annotationService.enabled) {
      widget.annotationService.disable();
    }
    setState(() {
      _showTextMessageOverlay = true;
      _textOverlayEverShown = true;
    });
  }

  void _onTextMessageSubmitted(String text, String? drawingBase64) {
    if (text.trim().isEmpty && drawingBase64 == null) {
      // Nothing to send — just dismiss
      setState(() => _showTextMessageOverlay = false);
      return;
    }
    final displayText = text.trim().isEmpty ? '(drawing attached)' : text;
    final shouldShowWaiting = widget.userMessageService.isAgentListening;
    if (shouldShowWaiting) {
      // Mark waiting BEFORE sending so the listener doesn't dismiss
      // when sendMessage triggers notifyListeners.
      widget.userMessageService.markWaiting(displayText);
    } else {
      // If no active listener is present, queue immediately in offline mode.
      widget.userMessageService.clearWaiting();
    }
    final data = <String, dynamic>{'userMessage': text};
    if (drawingBase64 != null) {
      data['drawingImage'] = drawingBase64;
    }
    widget.userMessageService.sendMessage({
      'type': 'user_feedback',
      'text': 'User message: $displayText',
      'data': data,
    });
  }

  /// Packages up the current inspector selection and/or annotations
  /// into a message and sends it to the LLM agent.
  Future<void> _sendToAgent() async {
    _isSendingToAgent = true;
    final annotationDraftQueueId = _annotationDraftQueueId;
    if (annotationDraftQueueId != null) {
      widget.userMessageService.removeMessageByQueueId(annotationDraftQueueId);
      _annotationDraftQueueId = null;
    }

    final parts = <String>[];
    final data = <String, dynamic>{};

    // Include inspector selection if available
    final selection = widget.inspectorService.lastSelection;
    if (selection != null) {
      data['inspectorSelection'] = selection.toJson();
      parts.add(
        'Selected widget: ${selection.widgetType} '
        'at ${selection.widgetPath}',
      );
      if (selection.sourceLocation != null) {
        parts.add('Source: ${selection.sourceLocation}');
      }
    }

    // Include annotations if any, with widget info for each
    final annotations = widget.annotationService.getAnnotationsData();
    if (annotations.isNotEmpty) {
      // For each annotation, find the widget under its center
      for (final a in annotations) {
        final bounds = a['bounds'] as Map<String, dynamic>;
        final centerX = (bounds['x'] as num) + (bounds['width'] as num) / 2;
        final centerY = (bounds['y'] as num) + (bounds['height'] as num) / 2;
        final widgetSelection = widget.inspectorService.inspectAtForAgent(
          centerX.toDouble(),
          centerY.toDouble(),
          includeProperties: false,
        );
        if (widgetSelection != null) {
          a['widget'] = widgetSelection.toJson();
        }
      }

      data['annotations'] = annotations;
      parts.add('${annotations.length} annotation(s):');
      for (final a in annotations) {
        final bounds = a['bounds'] as Map<String, dynamic>;
        final widgetInfo = a['widget'] as Map<String, dynamic>?;
        final annotationLine = StringBuffer(
          '  - "${a['text']}" at '
          '(${(bounds['x'] as num).round()}, '
          '${(bounds['y'] as num).round()}) '
          '${(bounds['width'] as num).round()}x'
          '${(bounds['height'] as num).round()}',
        );
        if (widgetInfo != null) {
          annotationLine.write(
            '\n    Widget: ${widgetInfo['widgetType']}'
            ' at ${widgetInfo['widgetPath']}',
          );
          if (widgetInfo['sourceLocation'] != null) {
            annotationLine.write(
              '\n    Source: ${widgetInfo['sourceLocation']}',
            );
          }
          if (widgetInfo['text'] != null) {
            annotationLine.write('\n    Text: "${widgetInfo['text']}"');
          }
        }
        parts.add(annotationLine.toString());
      }
    }

    if (parts.isEmpty) {
      parts.add(
        'User pressed send but no inspector selection or annotations '
        'are active. Ask the user what they need.',
      );
    }

    final previewBounds = _resolveQueuePreviewBounds(
      selection: selection,
      annotations: annotations,
    );

    // Capture a screenshot to include with the message.
    try {
      await _attachScreenshotAndQueueThumbnail(
        context: context,
        screenshotService: widget.screenshotService,
        data: data,
        previewBounds: previewBounds,
      );
    } catch (_) {
      // Screenshot capture is best-effort; don't block sending the message.
    }

    // Sync the signature to the current annotations so the listener
    // doesn't recreate a draft from the same data on the next change.
    _lastQueuedAnnotationsSignature =
        jsonEncode(widget.annotationService.getAnnotationsData());

    widget.userMessageService.sendMessage({
      'type': 'user_feedback',
      'text': parts.join('\n'),
      'data': data,
    });
    _isSendingToAgent = false;
  }

  void _sendErrorToAgent(InterceptedError error) {
    widget.userMessageService.sendMessage({
      'type': 'app_error',
      'text':
          'App error intercepted — please investigate:\n${error.details}',
      'data': <String, dynamic>{
        'kind': 'app_error',
        'summary': error.summary,
        'details': error.details,
        'timestamp': error.timestamp.toIso8601String(),
      },
    });
    widget.errorInterceptor.dismiss(error.id);
  }

  Future<void> _createIssueFromQueue() async {
    if (!GitHubIssueService.isConfigured) return;
    final messages = _queuedMessagesSnapshot
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    if (messages.isEmpty) return;

    // Hide the flan overlay so the screenshot shows the app cleanly.
    setState(() => _showQueuedMessagesPanel = false);
    // Wait for the frame to paint without the overlay.
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // Capture a fresh screenshot of the clean app.
    try {
      final screenshots =
          await widget.screenshotService.takeScreenshots();
      debugPrint(
        '[Flan] Screenshot capture: ${screenshots.length} image(s), '
        'first ${screenshots.firstOrNull?.length ?? 0} bytes',
      );
      if (screenshots.isNotEmpty) {
        for (final msg in messages) {
          final msgData = msg['data'];
          if (msgData is Map<String, dynamic>) {
            final copy = Map<String, dynamic>.from(msgData);
            copy['screenshot'] = screenshots.first;
            msg['data'] = copy;
          } else {
            msg['data'] = <String, dynamic>{
              'screenshot': screenshots.first,
            };
          }
        }
      }
    } catch (e) {
      debugPrint('[Flan] Screenshot capture failed: $e');
    }

    try {
      await GitHubIssueService.createIssueFromMessages(messages);
      // Clear annotations so the listener doesn't recreate a draft
      // after we clear the queue.
      widget.annotationService.clearAnnotations();
      _annotationDraftQueueId = null;
      _lastQueuedAnnotationsSignature = '';
      _isSendingToAgent = true;
      widget.userMessageService.clearMessages();
      _isSendingToAgent = false;
      if (mounted) {
        setState(() {
          _showQueuedMessagesPanel = false;
          _queuedMessagesSnapshot = const [];
        });
      }
    } catch (e) {
      _isSendingToAgent = false;
      debugPrint('[Flan] Failed to create issue: $e');
    }
  }

  Future<void> _createIssueFromError(InterceptedError error) async {
    if (!GitHubIssueService.isConfigured) return;

    try {
      await GitHubIssueService.createIssueFromError(
        summary: error.summary,
        details: error.details,
      );
      widget.errorInterceptor.dismiss(error.id);
    } catch (e) {
      debugPrint('[Flan] Failed to create issue from error: $e');
    }
  }

  void _removeQueuedMessage(int queueId) {
    // If the message being removed is an annotation draft, clear the
    // underlying annotations so the boxes disappear from the screen.
    final isAnnotationDraft = _annotationDraftQueueId == queueId;
    if (isAnnotationDraft) {
      _annotationDraftQueueId = null;
      _suppressAnnotationDraftUpsert = true;
      widget.annotationService.clearAnnotations();
      _lastQueuedAnnotationsSignature =
          jsonEncode(widget.annotationService.getAnnotationsData());
      _suppressAnnotationDraftUpsert = false;
    }

    final removed = widget.userMessageService.removeMessageByQueueId(queueId);
    if (!removed || !mounted) return;

    setState(() {
      _queuedMessagesSnapshot = _queuedMessagesSnapshot
          .where((message) => _queueIdOf(message) != queueId)
          .toList();
      if (_queuedMessagesSnapshot.isEmpty) {
        _showQueuedMessagesPanel = false;
      }
    });
  }

  void _clearQueuedMessages() {
    _annotationDraftQueueId = null;
    _lastQueuedAnnotationsSignature = '';
    _suppressAnnotationDraftUpsert = true;
    widget.annotationService.clearAnnotations();
    _lastQueuedAnnotationsSignature =
        jsonEncode(widget.annotationService.getAnnotationsData());
    _suppressAnnotationDraftUpsert = false;
    _isSendingToAgent = true;
    widget.userMessageService.clearMessages();
    _isSendingToAgent = false;
    if (!mounted) return;
    setState(() {
      _queuedMessagesSnapshot = const [];
      _showQueuedMessagesPanel = false;
    });
  }

  Future<void> _editQueuedAnnotation(
    int queueId,
    String annotationId,
    String currentText,
  ) async {
    if (!mounted) return;
    final controller = TextEditingController(text: currentText);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Edit annotation'),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Annotation text',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) {
              _applyQueuedAnnotationEdit(
                queueId,
                annotationId,
                controller.text,
              );
              Navigator.of(dialogContext).pop();
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                _removeQueuedAnnotation(queueId, annotationId);
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Delete'),
            ),
            FilledButton(
              onPressed: () {
                _applyQueuedAnnotationEdit(
                  queueId,
                  annotationId,
                  controller.text,
                );
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    controller.dispose();
  }

  void _applyQueuedAnnotationEdit(
    int queueId,
    String annotationId,
    String newText,
  ) {
    final trimmed = newText.trim();
    if (trimmed.isEmpty) {
      _removeQueuedAnnotation(queueId, annotationId);
      return;
    }
    _suppressAnnotationDraftUpsert = true;
    widget.annotationService.updateAnnotationTextById(annotationId, trimmed);
    _lastQueuedAnnotationsSignature =
        jsonEncode(widget.annotationService.getAnnotationsData());
    _updateQueuedAnnotationInMessage(
      queueId: queueId,
      annotationId: annotationId,
      updatedText: trimmed,
      remove: false,
    );
    _suppressAnnotationDraftUpsert = false;
  }

  void _removeQueuedAnnotation(int queueId, String annotationId) {
    widget.annotationService.removeAnnotationById(annotationId);
    _updateQueuedAnnotationInMessage(
      queueId: queueId,
      annotationId: annotationId,
      remove: true,
    );
  }

  void _updateQueuedAnnotationInMessage({
    required int queueId,
    required String annotationId,
    String? updatedText,
    required bool remove,
  }) {
    final pendingMessages = widget.userMessageService.peekMessages();
    final index = pendingMessages.indexWhere((m) => _queueIdOf(m) == queueId);
    if (index == -1) return;

    final originalMessage = pendingMessages[index];
    final data = _normalizedDataMap(originalMessage['data']);
    final annotations = _normalizedAnnotationMaps(data['annotations']);
    if (annotations.isEmpty) return;

    var changed = false;
    final updatedAnnotations = <Map<String, dynamic>>[];
    for (final annotation in annotations) {
      final id = annotation['id']?.toString();
      if (id == annotationId) {
        changed = true;
        if (remove) {
          continue;
        }
        updatedAnnotations.add({
          ...annotation,
          'text': updatedText ?? annotation['text'],
        });
        continue;
      }
      updatedAnnotations.add(annotation);
    }
    if (!changed) return;

    data['annotations'] = updatedAnnotations;
    final updatedMessage = Map<String, dynamic>.from(originalMessage);
    updatedMessage['data'] = data;
    updatedMessage['text'] = _rebuildQueuedMessageText(
      fallback: originalMessage['text']?.toString() ?? 'Queued message',
      data: data,
    );

    widget.userMessageService.updateMessageByQueueId(queueId, updatedMessage);

    if (!mounted) return;
    setState(() {
      _queuedMessagesSnapshot = _queuedMessagesSnapshot
          .map((message) => _queueIdOf(message) == queueId
              ? Map<String, dynamic>.from(updatedMessage)
              : message)
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final pendingMessages = widget.userMessageService.peekMessages();
    final pendingCount = pendingMessages.length;
    final displayCount = pendingCount;
    final viewPadding = MediaQuery.paddingOf(context);
    final badgeTop = viewPadding.top + 16;
    final badgeRight = viewPadding.right + 16;

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          // The actual app content
          widget.child,
          // Render existing annotations even when annotation mode is off.
          if (!widget.annotationService.enabled &&
              widget.annotationService.annotations.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: AnnotationPainter(
                    annotations: widget.annotationService.annotations,
                    dragStart: null,
                    dragCurrent: null,
                    pendingRect: null,
                    drawState: AnnotationDrawState.normal,
                    editingIndex: null,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          // Inspector overlay (when active)
          if (widget.inspectorService.enabled)
            _InspectorOverlay(
              service: widget.inspectorService,
              userMessageService: widget.userMessageService,
              screenshotService: widget.screenshotService,
            ),
          // Annotation overlay (when active)
          if (widget.annotationService.enabled)
            _AnnotationOverlay(
              service: widget.annotationService,
              userMessageService: widget.userMessageService,
              onAnnotationSubmitted: () {
                _sendToAgent();
              },
            ),
          if (widget.annotationService.enabled)
            Positioned(
              top: badgeTop,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xE6201410),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: const Color(0xFFFF6600),
                        width: 1,
                      ),
                    ),
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Text(
                        'Annotation mode ON  •  Drag to draw, Enter to save',
                        style: TextStyle(
                          color: Color(0xFFFFC8A0),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Error indicator dot (positioned to the left of the queue badge)
          if (widget.errorInterceptor.errors.isNotEmpty)
            Positioned(
              top: badgeTop,
              right: badgeRight + 40,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() {
                    _showErrorPanel = !_showErrorPanel;
                    if (_showErrorPanel) {
                      _showQueuedMessagesPanel = false;
                    }
                  });
                },
                child: _ErrorDot(
                  count: widget.errorInterceptor.errors.length,
                ),
              ),
            ),
          // Error panel (expands below the error dot)
          if (_showErrorPanel && widget.errorInterceptor.errors.isNotEmpty)
            Positioned(
              top: badgeTop + 40,
              right: badgeRight + 40,
              child: _ErrorPanel(
                errors: widget.errorInterceptor.errors,
                onDismiss: (id) {
                  widget.errorInterceptor.dismiss(id);
                  if (widget.errorInterceptor.errors.isEmpty) {
                    setState(() => _showErrorPanel = false);
                  }
                },
                onAddToQueue: (error) {
                  _sendErrorToAgent(error);
                  if (widget.errorInterceptor.errors.isEmpty) {
                    setState(() => _showErrorPanel = false);
                  }
                },
                onClearAll: () {
                  widget.errorInterceptor.clear();
                  setState(() => _showErrorPanel = false);
                },
              ),
            ),
          // Text message overlay — kept in tree to preserve state across dismiss
          if (_textOverlayEverShown)
            _TextMessageOverlay(
              visible: _showTextMessageOverlay,
              onDismiss: () => setState(() => _showTextMessageOverlay = false),
              onSubmitted: _onTextMessageSubmitted,
              userMessageService: widget.userMessageService,
            ),
          Positioned(
            top: badgeTop,
            right: badgeRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() {
                  _showErrorPanel = false;
                  if (_showQueuedMessagesPanel) {
                    _showQueuedMessagesPanel = false;
                    _queuedMessagesSnapshot = const [];
                    return;
                  }
                  if (pendingMessages.isEmpty) {
                    // Nothing queued — enter annotation mode.
                    if (!widget.annotationService.enabled) {
                      if (widget.inspectorService.enabled) {
                        widget.inspectorService.disable();
                      }
                      widget.annotationService.enable();
                    }
                    return;
                  }
                  _queuedMessagesSnapshot =
                      List<Map<String, dynamic>>.from(pendingMessages);
                  _showQueuedMessagesPanel = _queuedMessagesSnapshot.isNotEmpty;
                });
              },
              child: _QueuedMessagesBadge(
                count: displayCount,
                pushConnected:
                    widget.userMessageService.isPushCapableHostConnected,
              ),
            ),
          ),
          if (_showQueuedMessagesPanel && _queuedMessagesSnapshot.isNotEmpty)
            Positioned(
              top: badgeTop + 40,
              right: badgeRight,
              child: _QueuedMessagesPanel(
                messages: _queuedMessagesSnapshot,
                onDeleteMessage: _removeQueuedMessage,
                onClearAll: _clearQueuedMessages,
                onEditAnnotation: _editQueuedAnnotation,
                onDeleteAnnotation: _removeQueuedAnnotation,
                onCreateIssue: GitHubIssueService.isConfigured
                    ? _createIssueFromQueue
                    : null,
                isAnnotationModeActive:
                    widget.annotationService.enabled,
                onExitAnnotationMode: () {
                  widget.annotationService.disable();
                },
              ),
            ),
        ],
      ),
    );
  }

  static int? _queueIdOf(Map<String, dynamic> message) {
    final raw = message['queueId'];
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  Rect? _resolveQueuePreviewBounds({
    required InspectorSelection? selection,
    required List<Map<String, dynamic>> annotations,
  }) {
    Rect? combinedBounds;

    void includeRect(Rect? rect) {
      if (rect == null) return;
      if (combinedBounds == null) {
        combinedBounds = rect;
      } else {
        combinedBounds = combinedBounds!.expandToInclude(rect);
      }
    }

    includeRect(selection?.bounds);

    for (final annotation in annotations) {
      includeRect(_rectFromBoundsValue(annotation['bounds']));
      final widgetInfo = annotation['widget'];
      if (widgetInfo is Map) {
        includeRect(_rectFromBoundsValue(widgetInfo['bounds']));
      }
    }

    return combinedBounds;
  }

  static Map<String, dynamic> _normalizedDataMap(Object? rawData) {
    if (rawData is Map<String, dynamic>) {
      return Map<String, dynamic>.from(rawData);
    }
    if (rawData is Map) {
      return rawData.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return <String, dynamic>{};
  }

  static List<Map<String, dynamic>> _normalizedAnnotationMaps(
    Object? rawAnnotations,
  ) {
    if (rawAnnotations is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final item in rawAnnotations) {
      if (item is Map<String, dynamic>) {
        out.add(Map<String, dynamic>.from(item));
      } else if (item is Map) {
        out.add(item.map((key, value) => MapEntry(key.toString(), value)));
      }
    }
    return out;
  }

  static String _rebuildQueuedMessageText({
    required String fallback,
    required Map<String, dynamic> data,
  }) {
    final parts = <String>[];

    final selection = data['inspectorSelection'];
    if (selection is Map) {
      final widgetType = selection['widgetType']?.toString();
      final widgetPath = selection['widgetPath']?.toString();
      if (widgetType != null && widgetPath != null) {
        parts.add('Selected widget: $widgetType at $widgetPath');
      }
      final source = selection['sourceLocation']?.toString();
      if (source != null && source.isNotEmpty) {
        parts.add('Source: $source');
      }
    }

    final annotations = _normalizedAnnotationMaps(data['annotations']);
    if (annotations.isNotEmpty) {
      parts.add('${annotations.length} annotation(s):');
      for (final annotation in annotations) {
        parts.add(_formatAnnotationLine(annotation));
      }
    }

    final userMessage = data['userMessage']?.toString().trim();
    if (userMessage != null && userMessage.isNotEmpty) {
      parts.add('User message: $userMessage');
    }

    if (parts.isEmpty) return fallback;
    return parts.join('\n');
  }

  static String _formatAnnotationLine(Map<String, dynamic> annotation) {
    final bounds = _rectFromBoundsValue(annotation['bounds']);
    final text = annotation['text']?.toString() ?? '(no label)';
    final buffer = StringBuffer('  - "$text"');
    if (bounds != null) {
      buffer.write(
        ' at (${bounds.left.round()}, ${bounds.top.round()}) '
        '${bounds.width.round()}x${bounds.height.round()}',
      );
    }

    final widget = annotation['widget'];
    if (widget is Map) {
      final widgetType = widget['widgetType']?.toString();
      final widgetPath = widget['widgetPath']?.toString();
      if (widgetType != null && widgetPath != null) {
        buffer.write('\n    Widget: $widgetType at $widgetPath');
      }
      final source = widget['sourceLocation']?.toString();
      if (source != null && source.isNotEmpty) {
        buffer.write('\n    Source: $source');
      }
      final widgetText = widget['text']?.toString();
      if (widgetText != null && widgetText.isNotEmpty) {
        buffer.write('\n    Text: "$widgetText"');
      }
    }

    return buffer.toString();
  }
}

/// Inspector overlay: intercepts pointer events to select widgets.
/// When a widget is tapped, shows a text input for the user to type
/// a message about the selected widget.
class _InspectorOverlay extends StatefulWidget {
  const _InspectorOverlay({
    required this.service,
    required this.userMessageService,
    required this.screenshotService,
  });

  final InspectorService service;
  final UserMessageService userMessageService;
  final ScreenshotService screenshotService;

  @override
  State<_InspectorOverlay> createState() => _InspectorOverlayState();
}

class _InspectorOverlayState extends State<_InspectorOverlay> {
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onChanged);
    _focusNode.dispose();
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _submitMessage(String text) async {
    final selection = widget.service.lastSelection;
    if (selection == null) return;

    final parts = <String>[];
    final data = <String, dynamic>{};

    data['inspectorSelection'] = selection.toJson();
    parts.add(
      'Selected widget: ${selection.widgetType} '
      'at ${selection.widgetPath}',
    );
    if (selection.sourceLocation != null) {
      parts.add('Source: ${selection.sourceLocation}');
    }
    if (text.isNotEmpty) {
      parts.add('User message: $text');
      data['userMessage'] = text;
    }

    try {
      await _attachScreenshotAndQueueThumbnail(
        context: context,
        screenshotService: widget.screenshotService,
        data: data,
        previewBounds: selection.bounds,
      );
    } catch (_) {
      // Screenshot capture is best-effort; don't block sending the message.
    }

    widget.userMessageService.sendMessage({
      'type': 'user_feedback',
      'text': parts.join('\n'),
      'data': data,
    });

    _textController.clear();
    widget.service.disable();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        children: [
          // Gesture layer
          Positioned.fill(
            child: KeyboardListener(
              focusNode: _focusNode,
              autofocus: !widget.service.locked,
              onKeyEvent: _handleKeyEvent,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) {
                  // If locked, unlock previous selection first.
                  if (widget.service.locked) {
                    widget.service.selectCurrentElement(); // toggles unlock
                  }
                  // Find elements at the tap position, then lock selection
                  widget.service.handlePointerHover(event.position);
                  widget.service.selectCurrentElement();
                  // Focus the text field after locking
                  if (widget.service.locked) {
                    _textController.clear();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _textFocusNode.requestFocus();
                    });
                  }
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
          // Text input when selection is locked
          if (widget.service.locked && widget.service.lastSelection != null)
            Builder(
              builder: (context) {
                final screenSize = MediaQuery.of(context).size;
                return _buildTextField(
                  widget.service.lastSelection!.bounds,
                  screenSize,
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildTextField(Rect selectionBounds, Size screenSize) {
    const fieldHeight = 32.0;
    const gap = 8.0;
    final fieldWidth = selectionBounds.width.clamp(200.0, 400.0);

    // Try below the widget, fall back to above if no space
    var top = selectionBounds.bottom + gap;
    if (top + fieldHeight > screenSize.height) {
      top = selectionBounds.top - fieldHeight - gap;
    }
    // Clamp vertically
    top = top.clamp(0.0, screenSize.height - fieldHeight);

    // Clamp horizontally
    var left = selectionBounds.left;
    if (left + fieldWidth > screenSize.width) {
      left = screenSize.width - fieldWidth;
    }
    if (left < 0) left = 0;

    return Positioned(
      left: left,
      top: top,
      width: fieldWidth,
      height: fieldHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(6),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
          border: Border.all(
            color: const Color(0xFF00AAFF),
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: EditableText(
            controller: _textController,
            focusNode: _textFocusNode,
            style: const TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 13,
            ),
            cursorColor: const Color(0xFF00AAFF),
            backgroundCursorColor: const Color(0xFF333333),
            onSubmitted: _submitMessage,
          ),
        ),
      ),
    );
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        widget.service.cycleNextElement();
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        widget.service.cyclePreviousElement();
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (widget.service.locked) {
          widget.service.selectCurrentElement(); // unlock
        } else {
          widget.service.disable();
        }
      }
    }
  }
}

/// Annotation overlay: allows drawing rectangles and typing labels.
class _AnnotationOverlay extends StatefulWidget {
  const _AnnotationOverlay({
    required this.service,
    required this.userMessageService,
    this.onAnnotationSubmitted = _noopAnnotationSubmittedCallback,
  });

  final AnnotationService service;
  final UserMessageService userMessageService;
  // Compatibility field kept to avoid hot-reload class shape breakage.
  final VoidCallback onAnnotationSubmitted;

  @override
  State<_AnnotationOverlay> createState() => _AnnotationOverlayState();
}

class _AnnotationOverlayState extends State<_AnnotationOverlay> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onChanged);
    widget.userMessageService.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onChanged);
    widget.userMessageService.removeListener(_onChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        children: [
          // Gesture layer for drawing — use Listener for reliable
          // pointer tracking on all platforms including web
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                // If currently editing, re-focus the text field instead of
                // starting a new drawing.
                if (widget.service.drawState == AnnotationDrawState.editing ||
                    widget.service.drawState ==
                        AnnotationDrawState.editingExisting) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _textFocusNode.requestFocus();
                  });
                  return;
                }
                final tappedExisting =
                    widget.service.startDrawing(event.position);
                if (tappedExisting) {
                  final idx = widget.service.editingIndex;
                  if (idx != null &&
                      idx >= 0 &&
                      idx < widget.service.annotations.length) {
                    _textController.text = widget.service.annotations[idx].text;
                    _textController.selection = TextSelection(
                      baseOffset: 0,
                      extentOffset: _textController.text.length,
                    );
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _textFocusNode.requestFocus();
                    });
                  }
                }
              },
              onPointerMove: (event) {
                widget.service.updateDrawing(event.position);
              },
              onPointerUp: (_) {
                widget.service.finishDrawing();
                if (widget.service.drawState == AnnotationDrawState.editing) {
                  _textController.clear();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _textFocusNode.requestFocus();
                  });
                }
              },
              child: CustomPaint(
                painter: AnnotationPainter(
                  annotations: widget.service.annotations,
                  dragStart: widget.service.dragStart,
                  dragCurrent: widget.service.dragCurrent,
                  pendingRect: widget.service.pendingRect,
                  drawState: widget.service.drawState,
                  editingIndex: widget.service.editingIndex,
                ),
                size: Size.infinite,
              ),
            ),
          ),
          // Text input field when creating a new annotation
          if (widget.service.drawState == AnnotationDrawState.editing &&
              widget.service.pendingRect != null)
            Builder(
              builder: (context) {
                final screenSize = MediaQuery.of(context).size;
                return _buildTextField(
                  widget.service.pendingRect!,
                  screenSize,
                );
              },
            ),
          // Text input field when editing an existing annotation
          if (widget.service.drawState == AnnotationDrawState.editingExisting &&
              widget.service.editingIndex != null &&
              widget.service.editingIndex! >= 0 &&
              widget.service.editingIndex! < widget.service.annotations.length)
            Builder(
              builder: (context) {
                final screenSize = MediaQuery.of(context).size;
                final annotation =
                    widget.service.annotations[widget.service.editingIndex!];
                return _buildEditTextField(
                  annotation.bounds,
                  screenSize,
                  annotation.id,
                );
              },
            ),
        ],
      ),
    );
  }

  void _handleNewAnnotationSubmit(String text) {
    widget.service.submitAnnotationText(text);
    if (widget.service.annotations.isNotEmpty) {
      widget.onAnnotationSubmitted();
    }
  }

  void _handleEditAnnotationSubmit(String text) {
    widget.service.submitEditedAnnotationText(text);
    if (widget.service.annotations.isNotEmpty) {
      widget.onAnnotationSubmitted();
    }
  }

  Widget _buildTextField(Rect rect, Size screenSize) {
    const maxFieldHeight =
        68.0; // ~3 lines of text (13px * 1.4 height * 3 + padding)
    const gap = 4.0;
    final fieldWidth = rect.width.clamp(120.0, 400.0);

    // Try below the rect, fall back to above if no space
    var top = rect.bottom + gap;
    if (top + maxFieldHeight > screenSize.height) {
      top = rect.top - maxFieldHeight - gap;
    }
    top = top.clamp(0.0, screenSize.height - maxFieldHeight);

    // Clamp horizontally
    var left = rect.left;
    if (left + fieldWidth > screenSize.width) {
      left = screenSize.width - fieldWidth;
    }
    if (left < 0) left = 0;

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: fieldWidth,
          child: Container(
            constraints: const BoxConstraints(maxHeight: maxFieldHeight),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(4),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: EditableText(
                controller: _textController,
                focusNode: _textFocusNode,
                maxLines: null,
                style: const TextStyle(
                  color: Color(0xFFE0E0E0),
                  fontSize: 13,
                ),
                cursorColor: const Color(0xFFFF6600),
                backgroundCursorColor: const Color(0xFF333333),
                inputFormatters: [
                  _SubmitOnEnterFormatter(
                    onSubmit: () =>
                        _handleNewAnnotationSubmit(_textController.text),
                  ),
                ],
                onSubmitted: _handleNewAnnotationSubmit,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditTextField(Rect rect, Size screenSize, String annotationId) {
    const maxFieldHeight = 68.0; // ~3 lines of text
    const gap = 4.0;
    final fieldWidth = rect.width.clamp(120.0, 400.0);

    var top = rect.bottom + gap;
    if (top + maxFieldHeight > screenSize.height) {
      top = rect.top - maxFieldHeight - gap;
    }
    top = top.clamp(0.0, screenSize.height - maxFieldHeight);

    var left = rect.left;
    if (left + fieldWidth > screenSize.width) {
      left = screenSize.width - fieldWidth;
    }
    if (left < 0) left = 0;

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: fieldWidth,
          child: Container(
            constraints: const BoxConstraints(maxHeight: maxFieldHeight),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: const Color(0xFFFF6600),
                width: 1,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: EditableText(
                      controller: _textController,
                      focusNode: _textFocusNode,
                      maxLines: null,
                      style: const TextStyle(
                        color: Color(0xFFE0E0E0),
                        fontSize: 13,
                      ),
                      cursorColor: const Color(0xFFFF6600),
                      backgroundCursorColor: const Color(0xFF333333),
                      inputFormatters: [
                        _SubmitOnEnterFormatter(
                          onSubmit: () =>
                              _handleEditAnnotationSubmit(_textController.text),
                        ),
                      ],
                      onSubmitted: _handleEditAnnotationSubmit,
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      widget.service.removeAnnotationById(annotationId);
                      _textController.clear();
                    },
                    child: const Icon(
                      Icons.delete_outline,
                      size: 16,
                      color: Color(0xFFFF6666),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-screen text message overlay triggered by double-tapping Option/Alt.
/// Shows a large text box centered on screen for sending free-form messages
/// to the LLM agent without needing to select a widget first.
/// Includes drawing tools for visual annotation.
class _TextMessageOverlay extends StatefulWidget {
  const _TextMessageOverlay({
    required this.visible,
    required this.onDismiss,
    required this.onSubmitted,
    required this.userMessageService,
  });

  final bool visible;
  final VoidCallback onDismiss;
  final void Function(String text, String? drawingBase64) onSubmitted;
  final UserMessageService userMessageService;

  @override
  State<_TextMessageOverlay> createState() => _TextMessageOverlayState();
}

class _TextMessageOverlayState extends State<_TextMessageOverlay> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final DrawingService _drawingService = DrawingService();
  final TextEditingController _floatingTextController = TextEditingController();
  final FocusNode _floatingTextFocusNode = FocusNode();
  Offset? _offset; // null = centered
  bool _isDragging = false;
  Offset? _eraserPosition;
  BoxConstraints? _lastConstraints;
  bool _showShortcuts = false;

  @override
  void initState() {
    super.initState();
    widget.userMessageService.addListener(_onServiceChanged);
    _drawingService.addListener(_onDrawingChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant _TextMessageOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-focus text field when overlay becomes visible again
    if (widget.visible && !oldWidget.visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    widget.userMessageService.removeListener(_onServiceChanged);
    _drawingService.removeListener(_onDrawingChanged);
    _drawingService.dispose();
    _controller.dispose();
    _focusNode.dispose();
    _floatingTextController.dispose();
    _floatingTextFocusNode.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  void _onDrawingChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _handleSubmit() async {
    final text = _controller.text;
    String? drawingBase64;
    if (_drawingService.hasContent) {
      final size = MediaQuery.of(context).size;
      drawingBase64 = await _drawingService.toImageBase64(size);
    }
    if (text.trim().isEmpty && drawingBase64 == null) {
      // Nothing to send
      return;
    }
    // Clear content on successful submit
    _controller.clear();
    _drawingService.clear();
    _drawingService.setTool(DrawingTool.none);
    widget.onSubmitted(text, drawingBase64);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) {
      return const SizedBox.shrink();
    }

    final isWaiting = widget.userMessageService.waitingForActivity;
    final activeTool = _drawingService.activeTool;

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          const dialogWidth = 480.0;
          final maxDialogHeight = _showShortcuts ? 560.0 : 300.0;
          _lastConstraints = constraints;

          // Default to centered if no offset set yet.
          final offset = _offset ??
              Offset(
                (constraints.maxWidth - dialogWidth) / 2,
                (constraints.maxHeight - maxDialogHeight) / 2,
              );

          final isMarkupMode = activeTool != DrawingTool.none;

          return Stack(
            children: [
              // 1. Dark background + drawing canvas combined.
              // When no tool is active, tap-to-dismiss works.
              // When a tool is active (markup mode), taps route to the tool.
              Positioned.fill(
                child: GestureDetector(
                  onTap: isWaiting || isMarkupMode ? null : widget.onDismiss,
                  behavior: HitTestBehavior.opaque,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: isWaiting || !isMarkupMode
                        ? null
                        : (event) {
                            switch (activeTool) {
                              case DrawingTool.none:
                                break;
                              case DrawingTool.pencil:
                                _drawingService.startStroke(event.position);
                              case DrawingTool.text:
                                _drawingService
                                    .startTextPlacement(event.position);
                                _floatingTextController.clear();
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                  _floatingTextFocusNode.requestFocus();
                                });
                              case DrawingTool.eraser:
                                setState(
                                    () => _eraserPosition = event.position);
                                _drawingService.eraseAt(event.position, 16.0);
                              case DrawingTool.move:
                                _drawingService.startMove(event.position);
                            }
                          },
                    onPointerMove: isWaiting || !isMarkupMode
                        ? null
                        : (event) {
                            switch (activeTool) {
                              case DrawingTool.none:
                                break;
                              case DrawingTool.pencil:
                                _drawingService.addPoint(event.position);
                              case DrawingTool.text:
                                break;
                              case DrawingTool.eraser:
                                setState(
                                    () => _eraserPosition = event.position);
                                _drawingService.eraseAt(event.position, 16.0);
                              case DrawingTool.move:
                                _drawingService.updateMove(event.position);
                            }
                          },
                    onPointerUp: isWaiting || !isMarkupMode
                        ? null
                        : (event) {
                            switch (activeTool) {
                              case DrawingTool.none:
                                break;
                              case DrawingTool.pencil:
                                _drawingService.finishStroke();
                              case DrawingTool.text:
                                break;
                              case DrawingTool.eraser:
                                setState(() => _eraserPosition = null);
                              case DrawingTool.move:
                                _drawingService.finishMove();
                            }
                          },
                    child: CustomPaint(
                      foregroundPainter: DrawingPainter(
                        strokes: _drawingService.strokes,
                        textLabels: _drawingService.textLabels,
                        currentPoints: _drawingService.currentPoints,
                        activeTool: activeTool,
                        eraserPosition: _eraserPosition,
                        pendingTextPosition:
                            _drawingService.pendingTextPosition,
                        movingStrokeId: _drawingService.movingStrokeId,
                        movingLabelId: _drawingService.movingLabelId,
                      ),
                      child: const ColoredBox(color: Color(0x88000000)),
                    ),
                  ),
                ),
              ),

              // 2. Dialog
              Positioned(
                left: offset.dx,
                top: offset.dy,
                child: Opacity(
                  opacity: _isDragging ? 0.5 : 1.0,
                  child: GestureDetector(
                    onTap: () {}, // prevent dismiss when tapping the box
                    child: Container(
                      width: dialogWidth,
                      constraints: BoxConstraints(maxHeight: maxDialogHeight),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x88000000),
                            blurRadius: 24,
                            offset: Offset(0, 8),
                          ),
                        ],
                        border: Border.all(
                          color: const Color(0xFF00AAFF),
                          width: 1.5,
                        ),
                      ),
                      child:
                          isWaiting ? _buildWaitingState() : _buildInputState(),
                    ),
                  ),
                ),
              ),

              // 3. Floating text input at pending text position
              if (_drawingService.pendingTextPosition != null)
                _buildFloatingTextInput(_drawingService.pendingTextPosition!),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFloatingTextInput(Offset position) {
    const fieldWidth = 200.0;
    const fieldHeight = 28.0;

    return Positioned(
      left: position.dx,
      top: position.dy,
      width: fieldWidth,
      height: fieldHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: const Color(0xFF00AAFF),
            width: 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: EditableText(
            controller: _floatingTextController,
            focusNode: _floatingTextFocusNode,
            style: const TextStyle(
              color: Color(0xFFFFFFFF),
              fontSize: 14,
            ),
            cursorColor: const Color(0xFF00AAFF),
            backgroundCursorColor: const Color(0xFF333333),
            onSubmitted: (text) {
              _drawingService.submitText(text);
              // Return focus to the main text field
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _focusNode.requestFocus();
              });
            },
          ),
        ),
      ),
    );
  }

  Widget _buildDragHandle({required Widget child}) {
    return GestureDetector(
      onPanStart: (_) => setState(() => _isDragging = true),
      onPanUpdate: (details) {
        const dialogWidth = 480.0;
        const maxDialogHeight = 300.0;
        final c = _lastConstraints;
        if (c == null) return;
        setState(() {
          final current = _offset ??
              Offset(
                (c.maxWidth - dialogWidth) / 2,
                (c.maxHeight - maxDialogHeight) / 2,
              );
          _offset = Offset(
            (current.dx + details.delta.dx).clamp(
              0,
              c.maxWidth - dialogWidth,
            ),
            (current.dy + details.delta.dy).clamp(
              0,
              c.maxHeight - maxDialogHeight,
            ),
          );
        });
      },
      onPanEnd: (_) => setState(() => _isDragging = false),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: child,
      ),
    );
  }

  Widget _buildWaitingState() {
    final sentText = widget.userMessageService.sentMessageText ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildDragHandle(
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF00AAFF),
                  ),
                ),
                SizedBox(width: 10),
                Text(
                  'Agent is working...',
                  style: TextStyle(
                    color: Color(0xFF00AAFF),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFF333344)),
        Flexible(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              sentText,
              style: const TextStyle(
                color: Color(0xFFE0E0E0),
                fontSize: 14,
                height: 1.5,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInputState() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildDragHandle(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Send message to agent',
                    style: TextStyle(
                      color: Color(0xFF00AAFF),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                _AgentStatusIndicator(
                  isListening: widget.userMessageService.isAgentListening,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFF333344)),
        // Drawing toolbar
        _buildToolbar(),
        const Divider(height: 1, color: Color(0xFF333344)),
        Flexible(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: EditableText(
              controller: _controller,
              focusNode: _focusNode,
              maxLines: null,
              style: const TextStyle(
                color: Color(0xFFE0E0E0),
                fontSize: 14,
                height: 1.5,
              ),
              cursorColor: const Color(0xFF00AAFF),
              backgroundCursorColor: const Color(0xFF333333),
              selectionColor: const Color(0x4400AAFF),
              enableInteractiveSelection: true,
              keyboardType: TextInputType.multiline,
              inputFormatters: [
                _SubmitOnEnterFormatter(
                  onSubmit: _handleSubmit,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFF333344)),
        if (_showShortcuts) _buildShortcutsPanel(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Enter to send  \u2022  Shift+Enter for new line',
                  style: TextStyle(
                    color: const Color(0xFFE0E0E0).withValues(alpha: 0.5),
                    fontSize: 11,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() => _showShortcuts = !_showShortcuts);
                },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.keyboard,
                    size: 18,
                    color: _showShortcuts
                        ? const Color(0xFF00AAFF)
                        : const Color(0xFF888888),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildShortcutsPanel() {
    final isMac = Theme.of(context).platform == TargetPlatform.macOS;
    // Platform-aware modifier key icons
    final altKey = isMac
        ? const _KeyCapIcon(Icons.keyboard_option_key)
        : const _KeyCapText('Alt');
    final ctrlKey = isMac
        ? const _KeyCapIcon(Icons.keyboard_control_key)
        : const _KeyCapText('Ctrl');
    const shiftKey = _KeyCapText('\u21E7');
    final enterKey = const _KeyCapIcon(Icons.keyboard_return);
    const escKey = _KeyCapText('Esc');
    const scrollKey = _KeyCapIcon(Icons.mouse);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D1A),
        border: Border(
          bottom: BorderSide(color: Color(0xFF333344)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Flan Shortcuts',
              style: TextStyle(
                color: Color(0xFF00AAFF),
                fontSize: 14,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.none,
              )),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                  child: _ShortcutRow(
                      keyCaps: [altKey, altKey], label: 'Open overlay')),
              Expanded(
                  child: _ShortcutRow(keyCaps: [escKey], label: 'Dismiss')),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child: _ShortcutRow(
                      keyCaps: [ctrlKey, shiftKey, const _KeyCapText('H')],
                      label: 'Inspector')),
              Expanded(
                  child: _ShortcutRow(
                      keyCaps: [ctrlKey, ctrlKey],
                      label: 'Annotate')),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child: _ShortcutRow(
                      keyCaps: [ctrlKey, shiftKey, enterKey],
                      label: 'Send to agent')),
              Expanded(
                  child: _ShortcutRow(
                      keyCaps: [scrollKey], label: 'Cycle widgets')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final activeTool = _drawingService.activeTool;
    const activeColor = Color(0xFF00AAFF);
    const inactiveColor = Color(0xFF888888);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          _ToolButton(
            icon: Icons.edit,
            tooltip: 'Pencil',
            isActive: activeTool == DrawingTool.pencil,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            onTap: () {
              _drawingService.setTool(
                activeTool == DrawingTool.pencil
                    ? DrawingTool.none
                    : DrawingTool.pencil,
              );
              _focusNode.requestFocus();
            },
          ),
          const SizedBox(width: 4),
          _ToolButton(
            icon: Icons.text_fields,
            tooltip: 'Text',
            isActive: activeTool == DrawingTool.text,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            onTap: () {
              _drawingService.setTool(
                activeTool == DrawingTool.text
                    ? DrawingTool.none
                    : DrawingTool.text,
              );
            },
          ),
          const SizedBox(width: 4),
          _ToolButton(
            icon: Icons.auto_fix_high,
            tooltip: 'Eraser',
            isActive: activeTool == DrawingTool.eraser,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            onTap: () {
              _drawingService.setTool(
                activeTool == DrawingTool.eraser
                    ? DrawingTool.none
                    : DrawingTool.eraser,
              );
            },
          ),
          const SizedBox(width: 4),
          _ToolButton(
            icon: Icons.open_with,
            tooltip: 'Move',
            isActive: activeTool == DrawingTool.move,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            onTap: () {
              _drawingService.setTool(
                activeTool == DrawingTool.move
                    ? DrawingTool.none
                    : DrawingTool.move,
              );
            },
          ),
          const Spacer(),
          if (_drawingService.hasContent || _controller.text.isNotEmpty)
            _ToolButton(
              icon: Icons.delete_outline,
              tooltip: 'Clear all',
              isActive: false,
              activeColor: activeColor,
              inactiveColor: const Color(0xFFFF5252),
              onTap: () {
                _drawingService.clear();
                _controller.clear();
                _focusNode.requestFocus();
              },
            ),
        ],
      ),
    );
  }
}

class _QueuedMessagesBadge extends StatelessWidget {
  const _QueuedMessagesBadge({
    required this.count,
    required this.pushConnected,
  });

  final int count;
  final bool? pushConnected;

  @override
  Widget build(BuildContext context) {
    final text = count > 99 ? '99+' : '$count';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: const Color(0xFF005FCC),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: (pushConnected ?? false)
                  ? const Color(0xFF38D76A)
                  : const Color(0xFFFFFFFF),
              width: 2,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0xAA000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: const Center(
            child: Text(
              'Q',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 12,
                fontWeight: FontWeight.w800,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
        Positioned(
          right: -8,
          top: -8,
          child: Container(
            constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFE53935),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFFFFFFFF), width: 1.5),
            ),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 9,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _QueuedMessagesPanel extends StatelessWidget {
  const _QueuedMessagesPanel({
    required this.messages,
    required this.onDeleteMessage,
    required this.onClearAll,
    required this.onEditAnnotation,
    required this.onDeleteAnnotation,
    this.onCreateIssue,
    this.onExitAnnotationMode,
    this.isAnnotationModeActive = false,
  });

  final List<Map<String, dynamic>> messages;
  final void Function(int queueId) onDeleteMessage;
  final VoidCallback onClearAll;
  final Future<void> Function(
    int queueId,
    String annotationId,
    String currentText,
  ) onEditAnnotation;
  final void Function(int queueId, String annotationId) onDeleteAnnotation;
  final VoidCallback? onCreateIssue;
  final VoidCallback? onExitAnnotationMode;
  final bool isAnnotationModeActive;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 340,
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF00AAFF), width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x88000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Queued messages (${messages.length})',
                    style: const TextStyle(
                      color: Color(0xFF00AAFF),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                if (isAnnotationModeActive &&
                    onExitAnnotationMode != null) ...[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onExitAnnotationMode,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFAA00).withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            size: 12,
                            color: Color(0xFFFFCC44),
                          ),
                          SizedBox(width: 3),
                          Text(
                            'Done',
                            style: TextStyle(
                              color: Color(0xFFFFCC44),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                if (messages.isNotEmpty) ...[
                  if (onCreateIssue != null) ...[
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onCreateIssue,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2EA043).withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.bug_report_outlined,
                              size: 12,
                              color: Color(0xFF7EE787),
                            ),
                            SizedBox(width: 3),
                            Text(
                              'Create Issue',
                              style: TextStyle(
                                color: Color(0xFF7EE787),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onClearAll,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                      child: Icon(
                        Icons.delete_sweep_outlined,
                        size: 15,
                        color: Color(0xFFFF7777),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onClearAll,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00AAFF).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'Flush',
                        style: TextStyle(
                          color: Color(0xFF00AAFF),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF333344)),
          Flexible(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              shrinkWrap: true,
              itemBuilder: (context, index) {
                final message = messages[index];
                final summary = _summarizeMessage(message);
                final previewBytes = _previewBytesForMessage(message);
                final timestamp = _formatTimestamp(
                  message['timestamp'] as String?,
                );
                final queueId = _queueIdOf(message);
                final annotations = _annotationsFromMessage(message);

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (previewBytes != null) ...[
                            _QueueMessageThumbnail(bytes: previewBytes),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFE0E0E0),
                                fontSize: 12,
                                height: 1.4,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                          if (queueId != null) ...[
                            const SizedBox(width: 6),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => onDeleteMessage(queueId),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 2,
                                  vertical: 2,
                                ),
                                child: Icon(
                                  Icons.delete_outline,
                                  size: 14,
                                  color: Color(0xFFFF7777),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (queueId != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'id: $queueId',
                          style: const TextStyle(
                            color: Color(0xFF8E8EA0),
                            fontSize: 10,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                      if (timestamp != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          timestamp,
                          style: const TextStyle(
                            color: Color(0xFF8E8EA0),
                            fontSize: 10,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                      if (queueId != null && annotations.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: annotations.map((annotation) {
                            final annotationId =
                                annotation['id']?.toString() ?? '';
                            final annotationText =
                                annotation['text']?.toString() ?? '(no label)';
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0x33226688),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: const Color(0x664488CC),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 150,
                                    ),
                                    child: Text(
                                      annotationText,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFFB9D9FF),
                                        fontSize: 10,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () async {
                                      if (annotationId.isEmpty) return;
                                      await onEditAnnotation(
                                        queueId,
                                        annotationId,
                                        annotationText,
                                      );
                                    },
                                    child: const Icon(
                                      Icons.edit_outlined,
                                      size: 12,
                                      color: Color(0xFFB9D9FF),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      if (annotationId.isEmpty) return;
                                      onDeleteAnnotation(queueId, annotationId);
                                    },
                                    child: const Icon(
                                      Icons.close,
                                      size: 12,
                                      color: Color(0xFFFF9999),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ),
                );
              },
              separatorBuilder: (_, __) =>
                  const Divider(height: 12, color: Color(0xFF2A2A3A)),
              itemCount: messages.length,
            ),
          ),
        ],
      ),
    );
  }

  static String _summarizeMessage(Map<String, dynamic> message) {
    final text = message['text'] as String?;
    if (text != null && text.trim().isNotEmpty) {
      return text.trim();
    }
    final data = message['data'];
    if (data != null) {
      return data.toString();
    }
    return 'Queued message';
  }

  static Uint8List? _previewBytesForMessage(Map<String, dynamic> message) {
    final data = message['data'];
    if (data is! Map) return null;

    final queueThumbnail = data['queueThumbnail'];
    if (queueThumbnail is String) {
      final bytes = _decodeBase64Image(queueThumbnail);
      if (bytes != null) return bytes;
    }

    final drawingImage = data['drawingImage'];
    if (drawingImage is String) {
      return _decodeBase64Image(drawingImage);
    }

    return null;
  }

  static List<Map<String, dynamic>> _annotationsFromMessage(
    Map<String, dynamic> message,
  ) {
    final data = message['data'];
    if (data is! Map) return const [];
    final annotations = data['annotations'];
    if (annotations is! List) return const [];

    final out = <Map<String, dynamic>>[];
    for (final annotation in annotations) {
      if (annotation is Map<String, dynamic>) {
        out.add(annotation);
      } else if (annotation is Map) {
        out.add(annotation.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    return out;
  }

  static int? _queueIdOf(Map<String, dynamic> message) {
    final raw = message['queueId'];
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static String? _formatTimestamp(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) {
      return null;
    }
    final parsed = DateTime.tryParse(timestamp);
    if (parsed == null) {
      return timestamp;
    }
    final local = parsed.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute:$second';
  }
}

class _QueueMessageThumbnail extends StatelessWidget {
  const _QueueMessageThumbnail({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF2F3A57), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
      ),
    );
  }
}

/// A [TextInputFormatter] that intercepts bare Enter (without Shift) to
/// trigger submission, while allowing Shift+Enter to insert a newline.
class _SubmitOnEnterFormatter extends TextInputFormatter {
  _SubmitOnEnterFormatter({required this.onSubmit});

  final VoidCallback onSubmit;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Detect a newline insertion that wasn't caused by Shift being held.
    if (newValue.text.length == oldValue.text.length + 1 &&
        newValue.text.contains('\n') &&
        !HardwareKeyboard.instance.isShiftPressed) {
      // Strip the newline and schedule submission.
      WidgetsBinding.instance.addPostFrameCallback((_) => onSubmit());
      return oldValue;
    }
    return newValue;
  }
}

/// A compact toolbar button for drawing tools.
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.activeColor,
    required this.inactiveColor,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool isActive;
  final Color activeColor;
  final Color inactiveColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isActive
              ? activeColor.withValues(alpha: 0.3)
              : const Color(0x00000000),
          borderRadius: BorderRadius.circular(6),
          border: isActive
              ? Border.all(color: activeColor.withValues(alpha: 0.5))
              : null,
        ),
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            icon,
            size: 18,
            color: isActive ? activeColor : inactiveColor,
          ),
        ),
      ),
    );
  }
}

/// A row showing a keyboard shortcut and its description.
class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.keyCaps, required this.label});

  final List<Widget> keyCaps;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          for (var i = 0; i < keyCaps.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            keyCaps[i],
          ],
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: const TextStyle(
                color: Color(0xFFAAAAAA),
                fontSize: 13,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A keycap with a text label.
class _KeyCapText extends StatelessWidget {
  const _KeyCapText(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF555577)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x44000000),
            offset: Offset(0, 2),
            blurRadius: 0,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFDDDDEE),
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
          decoration: TextDecoration.none,
          height: 1.2,
        ),
      ),
    );
  }
}

/// A keycap with a Material icon.
class _KeyCapIcon extends StatelessWidget {
  const _KeyCapIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF555577)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x44000000),
            offset: Offset(0, 2),
            blurRadius: 0,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 16, color: const Color(0xFFDDDDEE)),
    );
  }
}

/// Small status indicator showing whether the agent is listening.
/// When disconnected, tapping shows a help tooltip.
class _AgentStatusIndicator extends StatefulWidget {
  const _AgentStatusIndicator({required this.isListening});

  final bool isListening;

  @override
  State<_AgentStatusIndicator> createState() => _AgentStatusIndicatorState();
}

class _AgentStatusIndicatorState extends State<_AgentStatusIndicator> {
  bool _showHelp = false;

  @override
  void didUpdateWidget(_AgentStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Dismiss help when agent connects
    if (widget.isListening && !oldWidget.isListening) {
      _showHelp = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.isListening ? 'Agent listening' : 'Agent disconnected';
    final color =
        widget.isListening ? const Color(0xFF4CAF50) : const Color(0xFFFF5252);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        GestureDetector(
          onTap: widget.isListening
              ? null
              : () => setState(() => _showHelp = !_showHelp),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_showHelp && !widget.isListening)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF00AAFF).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'Ask the agent to call\nprocess_queue',
                style: TextStyle(
                  color: Color(0xFFCCCCCC),
                  fontSize: 10,
                  height: 1.4,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A small red dot that indicates intercepted errors.
/// Shows error count as a badge.
class _ErrorDot extends StatelessWidget {
  const _ErrorDot({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final text = count > 99 ? '99+' : '$count';
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFFD32F2F),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFFFFFFFF),
          width: 2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0xAA000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}

/// Panel that expands below the error dot showing error details with
/// "Add to Queue" and dismiss buttons for each error.
class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({
    required this.errors,
    required this.onDismiss,
    required this.onAddToQueue,
    required this.onClearAll,
  });

  final List<InterceptedError> errors;
  final ValueChanged<int> onDismiss;
  final ValueChanged<InterceptedError> onAddToQueue;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    // Show up to 5 most recent errors.
    final visible =
        errors.length > 5 ? errors.sublist(errors.length - 5) : errors;

    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: 340,
        constraints: const BoxConstraints(maxHeight: 400),
        decoration: BoxDecoration(
          color: const Color(0xF02A1010),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: const Color(0xFFD32F2F),
            width: 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x60000000),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0x33FF5252)),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Color(0xFFFF5252),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${errors.length} error${errors.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      color: Color(0xFFFF8A80),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const Spacer(),
                  if (errors.length > 1)
                    _ErrorPanelButton(
                      label: 'Clear all',
                      onTap: onClearAll,
                    ),
                ],
              ),
            ),
            // Error list
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final error in visible)
                      _ErrorPanelItem(
                        error: error,
                        onDismiss: () => onDismiss(error.id),
                        onAddToQueue: () => onAddToQueue(error),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPanelItem extends StatelessWidget {
  const _ErrorPanelItem({
    required this.error,
    required this.onDismiss,
    required this.onAddToQueue,
  });

  final InterceptedError error;
  final VoidCallback onDismiss;
  final VoidCallback onAddToQueue;

  @override
  Widget build(BuildContext context) {
    final display = error.summary.length > 200
        ? '${error.summary.substring(0, 200)}...'
        : error.summary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0x20FF5252),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                display,
                style: const TextStyle(
                  color: Color(0xFFFFCDD2),
                  fontSize: 11,
                  height: 1.4,
                  decoration: TextDecoration.none,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _ErrorPanelButton(
                    label: 'Add to queue',
                    onTap: onAddToQueue,
                  ),
                  const SizedBox(width: 4),
                  _ErrorPanelButton(
                    label: 'Dismiss',
                    onTap: onDismiss,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorPanelButton extends StatelessWidget {
  const _ErrorPanelButton({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0x33FF5252),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFFFF8A80),
            fontSize: 10,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}
