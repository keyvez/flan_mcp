import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide InspectorSelection;
import 'package:flutter/services.dart';
import 'package:flan_flutter/src/overlay/annotation_painter.dart';
import 'package:flan_flutter/src/overlay/drawing_painter.dart';
import 'package:flan_flutter/src/overlay/inspector_painter.dart';
import 'package:flan_flutter/src/services/annotation_service.dart';
import 'package:flan_flutter/src/services/drawing_service.dart';
import 'package:flan_flutter/src/services/inspector_service.dart';
import 'package:flan_flutter/src/services/screenshot_service.dart';
import 'package:flan_flutter/src/services/user_message_service.dart';

/// Overlay widget injected at the root of the app via
/// [FlanBinding.wrapWithDefaultView]. Renders inspector highlights
/// and annotation drawing UI on top of the app content.
class FlanOverlayWidget extends StatefulWidget {
  const FlanOverlayWidget({
    super.key,
    required this.inspectorService,
    required this.annotationService,
    required this.userMessageService,
    required this.screenshotService,
    required this.child,
  });

  final InspectorService inspectorService;
  final AnnotationService annotationService;
  final UserMessageService userMessageService;
  final ScreenshotService screenshotService;
  final Widget child;

  @override
  State<FlanOverlayWidget> createState() => _FlanOverlayWidgetState();
}

class _FlanOverlayWidgetState extends State<FlanOverlayWidget> {
  bool _showTextMessageOverlay = false;
  bool _textOverlayEverShown = false;

  /// Tracks the last time an Alt/Option key was pressed for double-tap detection.
  DateTime? _lastAltPressTime;

  @override
  void initState() {
    super.initState();
    widget.inspectorService.addListener(_onServiceChanged);
    widget.annotationService.addListener(_onServiceChanged);
    widget.userMessageService.addListener(_onUserMessageServiceChanged);
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    widget.inspectorService.removeListener(_onServiceChanged);
    widget.annotationService.removeListener(_onServiceChanged);
    widget.userMessageService.removeListener(_onUserMessageServiceChanged);
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

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  void _onUserMessageServiceChanged() {
    if (!mounted) return;
    // Dismiss the overlay when the waiting state clears (e.g. after hot reload).
    if (_showTextMessageOverlay &&
        !widget.userMessageService.waitingForActivity) {
      setState(() => _showTextMessageOverlay = false);
    }
  }

  /// Global keyboard shortcut handler.
  /// Ctrl+Shift+H toggles inspector/highlight mode.
  /// Ctrl+Shift+A toggles annotation mode.
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

    // Escape exits whichever mode is active (no modifiers needed).
    if (event.logicalKey == LogicalKeyboardKey.escape) {
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

    if (event.logicalKey == LogicalKeyboardKey.keyA) {
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
    // Mark waiting BEFORE sending so the listener doesn't dismiss
    // when sendMessage triggers notifyListeners.
    widget.userMessageService.markWaiting(displayText);
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
        final widgetSelection = widget.inspectorService.inspectAt(
          centerX.toDouble(),
          centerY.toDouble(),
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

    // Capture a screenshot to include with the message
    try {
      final screenshots = await widget.screenshotService.takeScreenshots();
      if (screenshots.isNotEmpty) {
        data['screenshot'] = screenshots.first;
      }
    } catch (_) {
      // Screenshot capture is best-effort; don't block sending the message.
    }

    widget.userMessageService.sendMessage({
      'type': 'user_feedback',
      'text': parts.join('\n'),
      'data': data,
    });

    // Clear annotations and disable active modes after sending
    widget.annotationService.clearAnnotations();
    if (widget.inspectorService.enabled) {
      widget.inspectorService.disable();
    }
    if (widget.annotationService.enabled) {
      widget.annotationService.disable();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          // The actual app content
          widget.child,
          // Inspector overlay (when active)
          if (widget.inspectorService.enabled)
            _InspectorOverlay(
              service: widget.inspectorService,
              userMessageService: widget.userMessageService,
            ),
          // Annotation overlay (when active)
          if (widget.annotationService.enabled)
            _AnnotationOverlay(
              service: widget.annotationService,
              userMessageService: widget.userMessageService,
              onAnnotationSubmitted: _sendToAgent,
            ),
          // Text message overlay — kept in tree to preserve state across dismiss
          if (_textOverlayEverShown)
            _TextMessageOverlay(
              visible: _showTextMessageOverlay,
              onDismiss: () => setState(() => _showTextMessageOverlay = false),
              onSubmitted: _onTextMessageSubmitted,
              userMessageService: widget.userMessageService,
            ),
        ],
      ),
    );
  }
}

/// Inspector overlay: intercepts all pointer events to highlight
/// widgets and allow selection. When a widget is tapped, shows a text
/// input for the user to type a message about the selected widget.
class _InspectorOverlay extends StatefulWidget {
  const _InspectorOverlay({
    required this.service,
    required this.userMessageService,
  });

  final InspectorService service;
  final UserMessageService userMessageService;

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

  void _submitMessage(String text) {
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
          // Gesture + paint layer
          Positioned.fill(
            child: KeyboardListener(
              focusNode: _focusNode,
              autofocus: !widget.service.locked,
              onKeyEvent: _handleKeyEvent,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerHover: (event) {
                  widget.service.handlePointerHover(event.position);
                },
                onPointerMove: (event) {
                  widget.service.handlePointerHover(event.position);
                },
                onPointerDown: (event) {
                  // If locked, unlock first so hover can update
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
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    // Scroll wheel cycles through elements
                    if (event.scrollDelta.dy > 0) {
                      widget.service.cycleNextElement();
                    } else if (event.scrollDelta.dy < 0) {
                      widget.service.cyclePreviousElement();
                    }
                  }
                },
                child: CustomPaint(
                  painter: InspectorPainter(
                    highlights: widget.service.elementsAtPoint,
                    currentIndex: widget.service.currentElementIndex,
                    selection: widget.service.lastSelection,
                  ),
                  size: Size.infinite,
                ),
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
    required this.onAnnotationSubmitted,
  });

  final AnnotationService service;
  final UserMessageService userMessageService;
  final VoidCallback onAnnotationSubmitted;

  @override
  State<_AnnotationOverlay> createState() => _AnnotationOverlayState();
}

class _AnnotationOverlayState extends State<_AnnotationOverlay> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  bool _showDisconnectedWarning = false;

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
      // Dismiss warning when agent connects
      if (widget.userMessageService.isAgentListening &&
          _showDisconnectedWarning) {
        _showDisconnectedWarning = false;
      }
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
                _showDisconnectedWarning = false;
                final tappedExisting =
                    widget.service.startDrawing(event.position);
                if (tappedExisting) {
                  final idx = widget.service.editingIndex;
                  if (idx != null) {
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
              widget.service.editingIndex != null)
            Builder(
              builder: (context) {
                final screenSize = MediaQuery.of(context).size;
                final annotation =
                    widget.service.annotations[widget.service.editingIndex!];
                return _buildEditTextField(
                  annotation.bounds,
                  screenSize,
                );
              },
            ),
        ],
      ),
    );
  }

  void _handleNewAnnotationSubmit(String text) {
    if (!widget.userMessageService.isAgentListening) {
      setState(() => _showDisconnectedWarning = true);
      // Re-focus the text field so user can retry
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _textFocusNode.requestFocus();
      });
      return;
    }
    _showDisconnectedWarning = false;
    widget.service.submitAnnotationText(text);
    widget.onAnnotationSubmitted();
  }

  void _handleEditAnnotationSubmit(String text) {
    if (!widget.userMessageService.isAgentListening) {
      setState(() => _showDisconnectedWarning = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _textFocusNode.requestFocus();
      });
      return;
    }
    _showDisconnectedWarning = false;
    widget.service.submitEditedAnnotationText(text);
    widget.onAnnotationSubmitted();
  }

  Widget _buildDisconnectedWarning(double left, double top, double fieldWidth) {
    return Positioned(
      left: left,
      top: top,
      width: fieldWidth,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A3E),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF444466)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFFF5252),
              ),
            ),
            const SizedBox(width: 6),
            const Flexible(
              child: Text(
                'Agent disconnected — ask the agent to call watch_flan',
                style: TextStyle(
                  color: Color(0xFFFF5252),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
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

    final warningTop = top + maxFieldHeight + gap;

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
                onSubmitted: _handleNewAnnotationSubmit,
              ),
            ),
          ),
        ),
        if (_showDisconnectedWarning)
          _buildDisconnectedWarning(left, warningTop, fieldWidth),
      ],
    );
  }

  Widget _buildEditTextField(Rect rect, Size screenSize) {
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

    final warningTop = top + maxFieldHeight + gap;

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
                onSubmitted: _handleEditAnnotationSubmit,
              ),
            ),
          ),
        ),
        if (_showDisconnectedWarning)
          _buildDisconnectedWarning(left, warningTop, fieldWidth),
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
                      keyCaps: [ctrlKey, shiftKey, const _KeyCapText('A')],
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
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < keyCaps.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            keyCaps[i],
          ],
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFFAAAAAA),
              fontSize: 13,
              decoration: TextDecoration.none,
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
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
        if (_showHelp && !widget.isListening)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A3E),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF444466)),
              ),
              child: const Text(
                'Ask the agent to call\nwatch_flan',
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
