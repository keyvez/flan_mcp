import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' hide InspectorSelection;
import 'package:flan_flutter/src/binding/flan_configuration.dart';
import 'package:flan_flutter/src/overlay/flan_overlay_widget.dart';
import 'package:flan_flutter/src/services/annotation_service.dart';
import 'package:flan_flutter/src/services/element_tree_finder.dart';
import 'package:flan_flutter/src/services/gesture_dispatcher.dart';
import 'package:flan_flutter/src/services/inspector_service.dart';
import 'package:flan_flutter/src/services/error_interceptor.dart';
import 'package:flan_flutter/src/services/github_issue_service.dart';
import 'package:flan_flutter/src/services/log_collector.dart';
import 'package:flan_flutter/src/services/user_message_service.dart';
import 'package:flan_flutter/src/services/screenshot_service.dart';
import 'package:flan_flutter/src/services/scroll_simulator.dart';
import 'package:flan_flutter/src/services/text_input_simulator.dart';
import 'package:flan_flutter/src/services/widget_finder.dart';
import 'package:flan_flutter/src/services/widget_matcher.dart';
import 'package:flan_flutter/src/utils/num_parser.dart';

/// A custom binding that extends Flutter's default binding to provide
/// integration points for the Flan MCP.
class FlanBinding extends WidgetsFlutterBinding {
  /// Creates and initializes the binding with the given configuration.
  ///
  /// Returns the singleton instance of [FlanBinding].
  static FlanBinding ensureInitialized([
    FlanConfiguration configuration = const FlanConfiguration(),
  ]) {
    if (_instance == null) {
      FlanBinding._(configuration);
    }
    return instance;
  }

  /// The singleton instance of [FlanBinding].
  static FlanBinding get instance => BindingBase.checkInstance(_instance);
  static FlanBinding? _instance;

  /// Configures the backend endpoint for GitHub issue creation.
  ///
  /// [url] is the full URL (e.g. `https://dev-api.fasmac.workers.dev/api/github/issues`).
  /// [headersBuilder] returns auth headers for each request.
  /// [userInfo] optional user details included in the issue payload (e.g. `{'name': '...', 'email': '...'}`).
  static void configureIssueEndpoint({
    required String url,
    required Map<String, String> Function() headersBuilder,
    Map<String, String>? userInfo,
  }) {
    GitHubIssueService.configure(
      url: url,
      headersBuilder: headersBuilder,
      userInfo: userInfo,
    );
  }

  /// Whether the issue endpoint has been configured.
  static bool get issueEndpointConfigured => GitHubIssueService.isConfigured;

  /// Attempts to enqueue a message for the connected agent.
  ///
  /// Returns `true` if Flan is initialized and the message was queued.
  /// Returns `false` when Flan is not active (for example, release mode).
  static bool trySendToAgent({
    required String text,
    String type = 'user_message',
    Map<String, dynamic>? data,
  }) {
    final binding = _instance;
    if (binding == null) return false;

    final payload = <String, dynamic>{
      'text': text,
      'type': type,
      if (data != null) 'data': data,
    };
    binding._userMessageService.warmUp();
    binding._userMessageService.sendMessage(payload);
    return true;
  }

  FlanBinding._(this.configuration);

  /// Configuration for the Flan extensions.
  final FlanConfiguration configuration;

  // Service instances
  late final ElementTreeFinder _elementTreeFinder;
  late final GestureDispatcher _gestureDispatcher;
  late final LogCollector _logCollector;
  late final ScreenshotService _screenshotService;
  late final ScrollSimulator _scrollSimulator;
  late final TextInputSimulator _textInputSimulator;
  late final WidgetFinder _widgetFinder;
  late final InspectorService _inspectorService;
  late final AnnotationService _annotationService;
  late final UserMessageService _userMessageService;
  late final ErrorInterceptor _errorInterceptor;

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;

    // Initialize services
    _widgetFinder = WidgetFinder();
    _elementTreeFinder = ElementTreeFinder(configuration);
    _gestureDispatcher = GestureDispatcher();
    _logCollector = LogCollector();
    _screenshotService = ScreenshotService(
      maxScreenshotSize: configuration.maxScreenshotSize,
    );
    _scrollSimulator = ScrollSimulator(_gestureDispatcher, _widgetFinder);
    _textInputSimulator = TextInputSimulator(_widgetFinder);
    _inspectorService = InspectorService();
    _annotationService = AnnotationService();
    _userMessageService = UserMessageService(pollServer: true);
    _userMessageService.warmUp();
    _errorInterceptor = ErrorInterceptor();
    _errorInterceptor.install();

    // Initialize log collection
    _logCollector.initialize();
  }

  @override
  Widget wrapWithDefaultView(Widget rootWidget) {
    return super.wrapWithDefaultView(
      FlanOverlayWidget(
        inspectorService: _inspectorService,
        annotationService: _annotationService,
        userMessageService: _userMessageService,
        screenshotService: _screenshotService,
        errorInterceptor: _errorInterceptor,
        child: rootWidget,
      ),
    );
  }

  @override
  void initServiceExtensions() {
    super.initServiceExtensions();

    // Extension: Get interactive elements tree
    registerServiceExtension(
      name: 'flan.interactiveElements',
      callback: (params) async {
        try {
          final elements = _elementTreeFinder.findInteractiveElements();
          return <String, dynamic>{'status': 'Success', 'elements': elements};
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    // Extension: Tap element by matcher
    registerServiceExtension(
      name: 'flan.tap',
      callback: (params) async {
        try {
          final matcher = WidgetMatcher.fromJson(params);
          await _gestureDispatcher.tap(matcher, _widgetFinder, configuration);

          return <String, dynamic>{
            'status': 'Success',
            'message': 'Tapped element matching: ${matcher.toJson()}',
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    // Extension: Enter text into a text field
    registerServiceExtension(
      name: 'flan.enterText',
      callback: (params) async {
        try {
          final matcher = WidgetMatcher.fromJson(params);
          final input = params['input'];

          if (input == null) {
            return <String, dynamic>{
              'status': 'Error',
              'error': 'Missing required parameter: input',
            };
          }

          await _textInputSimulator.enterText(matcher, input, configuration);

          return <String, dynamic>{
            'status': 'Success',
            'message':
                'Entered text into element matching: ${matcher.toJson()}',
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    // Extension: Scroll until widget is visible
    registerServiceExtension(
      name: 'flan.scrollTo',
      callback: (params) async {
        try {
          final matcher = WidgetMatcher.fromJson(params);

          await _scrollSimulator.scrollUntilVisible(matcher, configuration);

          return <String, dynamic>{
            'status': 'Success',
            'message': 'Scrolled to element matching: ${matcher.toJson()}',
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    // Extension: Get logs
    registerServiceExtension(
      name: 'flan.getLogs',
      callback: (params) async {
        try {
          final logs = _logCollector.getFormattedLogs();

          return <String, dynamic>{
            'status': 'Success',
            'logs': logs,
            'count': logs.length,
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    // Extension: Get intercepted errors
    registerServiceExtension(
      name: 'flan.getErrors',
      callback: (params) async {
        try {
          final errors = _errorInterceptor.errors
              .map((e) => <String, dynamic>{
                    'id': e.id,
                    'summary': e.summary,
                    'details': e.details,
                    'timestamp': e.timestamp.toIso8601String(),
                  })
              .toList();
          return <String, dynamic>{
            'status': 'Success',
            'errors': errors,
            'count': errors.length,
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    // Extension: Take screenshots
    registerServiceExtension(
      name: 'flan.takeScreenshots',
      callback: (params) async {
        try {
          final screenshots = await _screenshotService.takeScreenshots();

          return <String, dynamic>{
            'status': 'Success',
            'screenshots': screenshots,
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    // --- Inspector extensions ---

    registerServiceExtension(
      name: 'flan.inspectorEnable',
      callback: (params) async {
        try {
          // Disable annotation mode if active (mutually exclusive)
          if (_annotationService.enabled) {
            _annotationService.disable();
          }
          _inspectorService.enable();
          return <String, dynamic>{
            'status': 'Success',
            'message': 'Inspector mode enabled',
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.inspectorDisable',
      callback: (params) async {
        try {
          _inspectorService.disable();
          return <String, dynamic>{
            'status': 'Success',
            'message': 'Inspector mode disabled',
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.inspectorGetSelection',
      callback: (params) async {
        try {
          final selection = _inspectorService.lastSelection;
          return <String, dynamic>{
            'status': 'Success',
            'selection': selection?.toJson(),
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.inspectorCycleElement',
      callback: (params) async {
        try {
          _inspectorService.cycleNextElement();
          final highlight = _inspectorService.currentHighlight;
          return <String, dynamic>{
            'status': 'Success',
            'currentElement': highlight?.widgetType,
            'elementCount': _inspectorService.elementsAtPoint.length,
            'currentIndex': _inspectorService.currentElementIndex,
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.inspectorSelectAt',
      callback: (params) async {
        try {
          final x = parseRequiredDoubleParam(params['x'], 'x');
          final y = parseRequiredDoubleParam(params['y'], 'y');
          final selection = _inspectorService.inspectAtForAgent(
            x,
            y,
            includeProperties: false,
          );
          return <String, dynamic>{
            'status': 'Success',
            'selection': selection?.toJson(),
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    // --- Annotation extensions ---

    registerServiceExtension(
      name: 'flan.annotationEnable',
      callback: (params) async {
        try {
          // Disable inspector mode if active (mutually exclusive)
          if (_inspectorService.enabled) {
            _inspectorService.disable();
          }
          _annotationService.enable();
          return <String, dynamic>{
            'status': 'Success',
            'message': 'Annotation mode enabled',
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.annotationDisable',
      callback: (params) async {
        try {
          _annotationService.disable();
          return <String, dynamic>{
            'status': 'Success',
            'message': 'Annotation mode disabled',
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.annotationGetAll',
      callback: (params) async {
        try {
          final annotations = _annotationService.getAnnotationsData();
          return <String, dynamic>{
            'status': 'Success',
            'annotations': annotations,
            'count': annotations.length,
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.annotationClear',
      callback: (params) async {
        try {
          _annotationService.clearAnnotations();
          return <String, dynamic>{
            'status': 'Success',
            'message': 'All annotations cleared',
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.annotationRemove',
      callback: (params) async {
        try {
          final id = params['id'] as String;
          final removed = _annotationService.removeAnnotationById(id);
          if (!removed) {
            return <String, dynamic>{
              'status': 'Error',
              'error': 'Annotation with id "$id" not found',
            };
          }
          return <String, dynamic>{
            'status': 'Success',
            'message': 'Annotation "$id" removed',
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    // --- User message extensions ---

    registerServiceExtension(
      name: 'flan.sendToAgent',
      callback: (params) async {
        try {
          await _userMessageService.ensureHydrated();
          final message = <String, dynamic>{};
          if (params.containsKey('text')) {
            message['text'] = params['text'];
          }
          if (params.containsKey('type')) {
            message['type'] = params['type'];
          }
          if (params.containsKey('data')) {
            message['data'] = params['data'];
          }
          _userMessageService.sendMessage(message);
          return <String, dynamic>{
            'status': 'Success',
            'message': 'Message queued for agent',
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.consumeUserMessages',
      callback: (params) async {
        try {
          await _userMessageService.ensureHydrated();
          final allCount = _userMessageService.peekMessages().length;
          final consumableCount =
              _userMessageService.peekConsumableMessages().length;
          developer.log(
            'flan.consumeUserMessages: '
            'total=$allCount consumable=$consumableCount',
            name: 'flan',
          );
          final messages = _userMessageService.consumeMessages();
          developer.log(
            'flan.consumeUserMessages: consumed=${messages.length}',
            name: 'flan',
          );
          return <String, dynamic>{
            'status': 'Success',
            'messages': messages,
            'count': messages.length,
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.peekUserMessages',
      callback: (params) async {
        try {
          await _userMessageService.ensureHydrated();
          final allCount = _userMessageService.peekMessages().length;
          final consumableCount =
              _userMessageService.peekConsumableMessages().length;
          developer.log(
            'flan.peekUserMessages: '
            'total=$allCount consumable=$consumableCount',
            name: 'flan',
          );
          return <String, dynamic>{
            'status': 'Success',
            'count': consumableCount,
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.setAgentListening',
      callback: (params) async {
        try {
          final listening =
              params['listening'] == 'true' || params['listening'] == true;
          _userMessageService.isAgentListening = listening;
          return <String, dynamic>{
            'status': 'Success',
            'listening': listening,
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.setAgentWorking',
      callback: (params) async {
        try {
          final working =
              params['working'] == 'true' || params['working'] == true;
          final message = params['message'] as String?;

          if (!working) {
            _userMessageService.markDone(message: message);
          } else if (message != null && message.isNotEmpty) {
            _userMessageService.updateAgentStatus(message);
          } else {
            _userMessageService.isAgentWorking = true;
          }

          return <String, dynamic>{
            'status': 'Success',
            'working': working,
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.setHostConnectionState',
      callback: (params) async {
        try {
          final connected =
              params['connected'] == 'true' || params['connected'] == true;
          final pushCapable =
              params['pushCapable'] == 'true' || params['pushCapable'] == true;
          _userMessageService.setHostConnectionState(
            connected: connected,
            pushCapable: pushCapable,
          );
          return <String, dynamic>{
            'status': 'Success',
            'connected': connected,
            'pushCapable': pushCapable,
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );

    registerServiceExtension(
      name: 'flan.annotationAdd',
      callback: (params) async {
        try {
          final x = parseRequiredDoubleParam(params['x'], 'x');
          final y = parseRequiredDoubleParam(params['y'], 'y');
          final width = parseRequiredDoubleParam(params['width'], 'width');
          final height = parseRequiredDoubleParam(params['height'], 'height');
          final text = params['text'] as String;
          final annotation = _annotationService.addAnnotationProgrammatically(
            x: x,
            y: y,
            width: width,
            height: height,
            text: text,
          );
          return <String, dynamic>{
            'status': 'Success',
            'annotation': annotation.toJson(),
          };
        } catch (err, st) {
          return <String, dynamic>{
            'status': 'Error',
            'error': err.toString(),
            'stackTrace': st.toString(),
          };
        }
      },
    );
  }

  @override
  Future<void> reassembleApplication() {
    _logCollector.clear();
    _userMessageService.clearWaiting();
    return super.reassembleApplication();
  }
}
