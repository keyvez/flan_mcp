import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' hide InspectorSelection;
import 'package:logging/logging.dart';

/// Highlight data for a single element at the inspected point.
class InspectorHighlight {
  const InspectorHighlight({
    required this.element,
    required this.bounds,
    required this.widgetType,
  });

  final Element element;
  final Rect bounds;
  final String widgetType;
}

/// Full selection data returned to the MCP client.
class InspectorSelection {
  const InspectorSelection({
    required this.widgetType,
    required this.widgetPath,
    this.sourceLocation,
    this.key,
    this.text,
    required this.bounds,
    this.properties = const {},
  });

  final String widgetType;
  final String widgetPath;
  final String? sourceLocation;
  final String? key;
  final String? text;
  final Rect bounds;
  final Map<String, String> properties;

  Map<String, dynamic> toJson() => {
        'widgetType': widgetType,
        'widgetPath': widgetPath,
        if (sourceLocation != null) 'sourceLocation': sourceLocation,
        if (key != null) 'key': key,
        if (text != null) 'text': text,
        'bounds': {
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        },
        if (properties.isNotEmpty) 'properties': properties,
      };
}

/// Service that implements widget inspector logic: hit testing all elements
/// at a point, building widget ancestor paths, extracting source locations,
/// and cycling through overlapping widgets.
class InspectorService extends ChangeNotifier {
  static const Duration _slowInspectThreshold = Duration(milliseconds: 50);
  static const int _notHitTestedRank = 1 << 30;
  static const Set<String> _overlaySubtreeTypes = {
    '_InspectorOverlay',
    '_AnnotationOverlay',
    '_TextMessageOverlay',
    '_QueuedMessagesPanel',
    '_QueuedMessagesBadge',
    '_AgentStatusIndicator',
    '_DrawingCanvas',
  };
  final Logger _logger = Logger('FlanInspector');

  bool _enabled = false;
  bool _locked = false;
  List<InspectorHighlight> _elementsAtPoint = [];
  int _currentElementIndex = -1;
  InspectorSelection? _lastSelection;

  bool get enabled => _enabled;
  bool get locked => _locked;
  List<InspectorHighlight> get elementsAtPoint => _elementsAtPoint;
  int get currentElementIndex => _currentElementIndex;
  InspectorHighlight? get currentHighlight => _currentElementIndex >= 0 &&
          _currentElementIndex < _elementsAtPoint.length
      ? _elementsAtPoint[_currentElementIndex]
      : null;
  InspectorSelection? get lastSelection => _lastSelection;

  void enable() {
    _enabled = true;
    _locked = false;
    _elementsAtPoint = [];
    _currentElementIndex = -1;
    _lastSelection = null;
    notifyListeners();
  }

  void disable() {
    _enabled = false;
    _locked = false;
    _elementsAtPoint = [];
    _currentElementIndex = -1;
    _lastSelection = null;
    notifyListeners();
  }

  /// Called when the pointer hovers / moves over the screen.
  /// Performs a hit test and collects all elements at that point.
  /// Ignored when the selection is locked (after a tap).
  void handlePointerHover(Offset position) {
    if (!_enabled || _locked) return;
    _elementsAtPoint = _findElementsAtPoint(position);
    _currentElementIndex = _elementsAtPoint.isNotEmpty ? 0 : -1;
    notifyListeners();
  }

  /// Cycles to the next element in the z-index stack at the current point.
  void cycleNextElement() {
    if (_elementsAtPoint.isEmpty) return;
    _currentElementIndex = (_currentElementIndex + 1) % _elementsAtPoint.length;
    notifyListeners();
  }

  /// Cycles to the previous element in the z-index stack.
  void cyclePreviousElement() {
    if (_elementsAtPoint.isEmpty) return;
    _currentElementIndex =
        (_currentElementIndex - 1 + _elementsAtPoint.length) %
            _elementsAtPoint.length;
    notifyListeners();
  }

  /// Selects the currently highlighted element, builds full selection data,
  /// and locks the selection so hover doesn't change it.
  /// If already locked, unlocks and returns to hover mode.
  InspectorSelection? selectCurrentElement() {
    if (_locked) {
      _locked = false;
      _lastSelection = null;
      notifyListeners();
      return null;
    }
    final highlight = currentHighlight;
    if (highlight == null) return null;
    _lastSelection = _buildSelection(highlight);
    _locked = true;
    notifyListeners();
    return _lastSelection;
  }

  /// Programmatically inspects the widget at the given coordinates,
  /// selecting the topmost element.
  InspectorSelection? inspectAt(double x, double y) {
    final position = Offset(x, y);
    _elementsAtPoint = _findElementsAtPoint(position);
    _currentElementIndex = _elementsAtPoint.isNotEmpty ? 0 : -1;
    if (_elementsAtPoint.isNotEmpty) {
      _lastSelection = _buildSelection(_elementsAtPoint[0]);
    } else {
      _lastSelection = null;
    }
    notifyListeners();
    return _lastSelection;
  }

  /// Programmatically inspects the widget at the given coordinates without
  /// mutating inspector UI state (highlights/selection/lock).
  ///
  /// This is intended for MCP/automation use-cases where we need a fast,
  /// side-effect-free inspection call.
  InspectorSelection? inspectAtForAgent(
    double x,
    double y, {
    bool includeProperties = false,
  }) {
    final stopwatch = Stopwatch()..start();
    final highlight = _findBestElementAtPoint(Offset(x, y));
    final selection = highlight == null
        ? null
        : _buildSelection(highlight, includeProperties: includeProperties);
    stopwatch.stop();

    final elapsed = stopwatch.elapsed;
    final isSlow = elapsed >= _slowInspectThreshold;
    final elapsedMs = (elapsed.inMicroseconds / 1000).toStringAsFixed(1);
    final message =
        'inspectAtForAgent @(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}) '
        'took ${elapsedMs}ms '
        '[found=${selection != null}, includeProperties=$includeProperties]';

    if (isSlow) {
      _logger.warning('SLOW $message');
    } else {
      _logger.info(message);
    }

    return selection;
  }

  /// Finds all elements at the given position by walking the entire element
  /// tree and checking which render boxes contain the point.
  ///
  /// This approach avoids hit-testing (which would hit the overlay itself)
  /// and instead geometrically checks every element in the app's widget tree.
  /// Results are sorted by area (smallest first) so the most specific widget
  /// is at index 0, similar to Chrome DevTools behavior.
  List<InspectorHighlight> _findElementsAtPoint(Offset position) {
    final binding = WidgetsBinding.instance;
    final rootElement = binding.rootElement;
    if (rootElement == null) return [];

    final highlights = <InspectorHighlight>[];
    final hitOrder = _hitTestRenderBoxOrder(position);
    // Track render objects we've already seen to avoid duplicates
    // (multiple elements can share the same RenderBox).
    final seenRenderObjects = <RenderBox>{};

    void visitor(Element element) {
      final renderObject = element.renderObject;
      if (renderObject != null &&
          renderObject is RenderBox &&
          renderObject.hasSize &&
          renderObject.attached) {
        try {
          final offset = renderObject.localToGlobal(Offset.zero);
          final bounds = offset & renderObject.size;
          if (bounds.contains(position)) {
            final widgetType = element.widget.runtimeType.toString();
            if (_isInspectableElement(element, widgetType) &&
                seenRenderObjects.add(renderObject)) {
              highlights.add(InspectorHighlight(
                element: element,
                bounds: bounds,
                widgetType: widgetType,
              ));
            }
          }
        } catch (_) {
          // Ignore elements where we can't compute bounds
        }
      }
      element.visitChildren(visitor);
    }

    visitor(rootElement);

    // Sort by area (smallest first) so the most specific widget is at index 0
    highlights.sort((a, b) {
      final rankA = _hitRankForHighlight(a, hitOrder);
      final rankB = _hitRankForHighlight(b, hitOrder);
      if (rankA != rankB) {
        return rankA.compareTo(rankB);
      }
      final areaA = a.bounds.width * a.bounds.height;
      final areaB = b.bounds.width * b.bounds.height;
      return areaA.compareTo(areaB);
    });

    return highlights;
  }

  /// Finds the single best (most specific) element at a point.
  ///
  /// This avoids building/sorting the full overlap stack and is optimized for
  /// programmatic MCP inspection calls.
  InspectorHighlight? _findBestElementAtPoint(Offset position) {
    final binding = WidgetsBinding.instance;
    final rootElement = binding.rootElement;
    if (rootElement == null) return null;

    InspectorHighlight? bestHighlight;
    final hitOrder = _hitTestRenderBoxOrder(position);
    var bestRank = _notHitTestedRank;
    var bestArea = double.infinity;
    final seenRenderObjects = <RenderBox>{};

    void visitor(Element element) {
      final renderObject = element.renderObject;
      if (renderObject != null &&
          renderObject is RenderBox &&
          renderObject.hasSize &&
          renderObject.attached) {
        try {
          final offset = renderObject.localToGlobal(Offset.zero);
          final bounds = offset & renderObject.size;
          if (bounds.contains(position)) {
            final widgetType = element.widget.runtimeType.toString();
            if (_isInspectableElement(element, widgetType) &&
                seenRenderObjects.add(renderObject)) {
              final rank = hitOrder[renderObject] ?? _notHitTestedRank;
              final area = bounds.width * bounds.height;
              if (rank < bestRank || (rank == bestRank && area < bestArea)) {
                bestRank = rank;
                bestArea = area;
                bestHighlight = InspectorHighlight(
                  element: element,
                  bounds: bounds,
                  widgetType: widgetType,
                );
              }
            }
          }
        } catch (_) {
          // Ignore elements where we can't compute bounds
        }
      }
      element.visitChildren(visitor);
    }

    visitor(rootElement);
    return bestHighlight;
  }

  Map<RenderBox, int> _hitTestRenderBoxOrder(Offset position) {
    final renderBoxOrder = <RenderBox, int>{};
    final binding = WidgetsBinding.instance;

    for (final renderView in binding.renderViews) {
      final result = HitTestResult();
      renderView.hitTest(result, position: position);
      var index = 0;
      for (final entry in result.path) {
        final target = entry.target;
        if (target is RenderBox) {
          renderBoxOrder.putIfAbsent(target, () => index);
          index++;
        }
      }
    }

    return renderBoxOrder;
  }

  int _hitRankForHighlight(
    InspectorHighlight highlight,
    Map<RenderBox, int> hitOrder,
  ) {
    final renderObject = highlight.element.renderObject;
    if (renderObject is RenderBox) {
      return hitOrder[renderObject] ?? _notHitTestedRank;
    }
    return _notHitTestedRank;
  }

  bool _isInspectableElement(Element element, String widgetType) {
    return _isInspectableWidgetType(widgetType) &&
        !_isInOverlaySubtree(element, widgetType);
  }

  /// Builds full selection data from a highlight.
  InspectorSelection _buildSelection(
    InspectorHighlight highlight, {
    bool includeProperties = true,
  }) {
    final element = highlight.element;
    final widget = element.widget;

    return InspectorSelection(
      widgetType: highlight.widgetType,
      widgetPath: _buildWidgetPath(element),
      sourceLocation: _getSourceLocation(element),
      key: _extractKey(widget.key),
      text: _extractText(widget),
      bounds: highlight.bounds,
      properties: includeProperties ? _extractProperties(widget) : const {},
    );
  }

  bool _isInspectableWidgetType(String widgetType) {
    // Skip private framework widgets and our own top-level overlay widget.
    return !widgetType.startsWith('_') && widgetType != 'FlanOverlayWidget';
  }

  bool _isInOverlaySubtree(Element element, String widgetType) {
    if (_overlaySubtreeTypes.contains(widgetType)) {
      return true;
    }
    var inOverlaySubtree = false;
    element.visitAncestorElements((ancestor) {
      final ancestorType = ancestor.widget.runtimeType.toString();
      if (_overlaySubtreeTypes.contains(ancestorType)) {
        inOverlaySubtree = true;
        return false;
      }
      return true;
    });
    return inOverlaySubtree;
  }

  /// Walks ancestor elements to build a path like
  /// "MaterialApp > Scaffold > Column > ElevatedButton".
  String _buildWidgetPath(Element element) {
    final path = <String>[];
    path.add(element.widget.runtimeType.toString());

    element.visitAncestorElements((ancestor) {
      final typeName = ancestor.widget.runtimeType.toString();
      if (!typeName.startsWith('_')) {
        path.add(typeName);
      }
      return true;
    });

    return path.reversed.join(' > ');
  }

  /// Attempts to get the source location using widget diagnostics
  /// creation location tracking (available in debug mode with
  /// --track-widget-creation, which is on by default).
  String? _getSourceLocation(Element element) {
    try {
      final json = element.widget
          .toDiagnosticsNode()
          .toJsonMap(const DiagnosticsSerializationDelegate(
            subtreeDepth: 0,
            includeProperties: false,
          ));
      final location = json['creationLocation'];
      if (location is Map<String, Object?>) {
        final file = location['file'];
        final line = location['line'];
        final column = location['column'];
        if (file != null) {
          return '$file:$line:$column';
        }
      }
    } catch (_) {
      // Source location not available
    }
    return null;
  }

  String? _extractKey(Key? key) {
    if (key is ValueKey<String>) {
      return key.value;
    }
    if (key != null) {
      return key.toString();
    }
    return null;
  }

  String? _extractText(Widget widget) {
    if (widget is Text) {
      return widget.data ?? widget.textSpan?.toPlainText();
    }
    if (widget is RichText) {
      return widget.text.toPlainText();
    }
    if (widget is EditableText) {
      return widget.controller.text;
    }
    return null;
  }

  Map<String, String> _extractProperties(Widget widget) {
    final props = <String, String>{};
    try {
      final builder = DiagnosticPropertiesBuilder();
      widget.debugFillProperties(builder);
      for (final p in builder.properties) {
        if (p.name != null && p.value != null) {
          final val = p.value.toString();
          if (val.length <= 120) {
            props[p.name!] = val;
          }
        }
      }
    } catch (_) {
      // Ignore diagnostic extraction failures
    }
    return props;
  }
}
