import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Formats queued flan messages into a GitHub issue and POSTs
/// to the configured backend endpoint.
class GitHubIssueService {
  GitHubIssueService._();

  static String? _endpointUrl;
  static Map<String, String> Function()? _headersBuilder;

  /// Whether the issue endpoint has been configured.
  static bool get isConfigured =>
      _endpointUrl != null && _headersBuilder != null;

  /// Configures the backend endpoint and auth headers builder.
  static void configure({
    required String url,
    required Map<String, String> Function() headersBuilder,
  }) {
    _endpointUrl = url;
    _headersBuilder = headersBuilder;
  }

  /// Clears the configured endpoint (e.g. on logout).
  static void reset() {
    _endpointUrl = null;
    _headersBuilder = null;
  }

  /// Creates a GitHub issue from a list of queued messages.
  /// Returns the created issue URL on success.
  static Future<String> createIssueFromMessages(
    List<Map<String, dynamic>> messages,
  ) async {
    if (!isConfigured) {
      throw StateError('Issue endpoint not configured');
    }

    // Extract screenshots from ALL messages before filtering,
    // since drafts may have screenshots attached at send time.
    final screenshots = _extractScreenshots(messages);
    debugPrint(
      '[Flan] Issue: ${messages.length} message(s), '
      '${screenshots.length} screenshot(s), '
      'first data keys: ${(messages.firstOrNull?['data'] as Map?)?.keys.toList()}',
    );

    // Filter out annotation drafts for the issue body/title.
    final filtered = messages.where((m) {
      final data = m['data'] as Map<String, dynamic>?;
      return data?['annotationDraft'] != true;
    }).toList(growable: false);
    final effective = filtered.isNotEmpty ? filtered : messages;

    final title = _buildTitle(effective);
    final body = _buildBody(effective);

    final payload = <String, dynamic>{
      'title': title,
      'body': body,
      'labels': ['flan', 'dev-site'],
      'screenshots': screenshots,
    };

    final headers = {
      ..._headersBuilder!(),
      'Content-Type': 'application/json',
    };

    final response = await http.post(
      Uri.parse(_endpointUrl!),
      headers: headers,
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to create issue: ${response.statusCode} '
        '${response.body}',
      );
    }

    final result = jsonDecode(response.body) as Map<String, dynamic>;
    return result['url'] as String;
  }

  /// Creates a GitHub issue from a single error.
  static Future<String> createIssueFromError({
    required String summary,
    required String details,
  }) async {
    if (!isConfigured) {
      throw StateError('Issue endpoint not configured');
    }

    final title = '[Error] ${_truncate(summary, 80)}';
    final body = StringBuffer()
      ..writeln('## Error')
      ..writeln()
      ..writeln('**Summary:** $summary')
      ..writeln()
      ..writeln('```')
      ..writeln(details)
      ..writeln('```')
      ..writeln()
      ..writeln(
        '_Created automatically by flan on '
        '${DateTime.now().toIso8601String()}_',
      );

    final payload = <String, dynamic>{
      'title': title,
      'body': body.toString(),
      'labels': ['flan', 'dev-site', 'bug'],
      'screenshots': <Map<String, dynamic>>[],
    };

    final headers = {
      ..._headersBuilder!(),
      'Content-Type': 'application/json',
    };

    final response = await http.post(
      Uri.parse(_endpointUrl!),
      headers: headers,
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to create issue: ${response.statusCode} '
        '${response.body}',
      );
    }

    final result = jsonDecode(response.body) as Map<String, dynamic>;
    return result['url'] as String;
  }

  static String _buildTitle(List<Map<String, dynamic>> messages) {
    // Use first error summary, annotation text, or generic title
    for (final msg in messages) {
      final type = msg['type']?.toString() ?? '';
      if (type == 'error') {
        final data = msg['data'] as Map<String, dynamic>?;
        final summary = data?['summary']?.toString();
        if (summary != null && summary.isNotEmpty) {
          return '[Error] ${_truncate(summary, 80)}';
        }
      }
    }

    for (final msg in messages) {
      final text = msg['text']?.toString();
      if (text != null && text.isNotEmpty) {
        return '[Flan] ${_truncate(text, 80)}';
      }
    }

    return '[Flan] Dev site feedback '
        '(${DateTime.now().toIso8601String().substring(0, 10)})';
  }

  static String _buildBody(List<Map<String, dynamic>> messages) {
    final buf = StringBuffer();

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final type = msg['type']?.toString() ?? 'user_message';
      final text = msg['text']?.toString() ?? '';

      if (messages.length > 1) {
        buf.writeln('## Message ${i + 1}');
        buf.writeln();
      }

      if (text.isNotEmpty) {
        buf.writeln(text);
        buf.writeln();
      }

      // Error details
      if (type == 'error') {
        final data = msg['data'] as Map<String, dynamic>?;
        if (data != null) {
          buf.writeln('### Error Details');
          buf.writeln();
          buf.writeln('**Summary:** ${data['summary'] ?? 'N/A'}');
          buf.writeln();
          final details = data['details']?.toString();
          if (details != null && details.isNotEmpty) {
            buf.writeln('```');
            buf.writeln(details);
            buf.writeln('```');
            buf.writeln();
          }
        }
      }

      // Widget selection info — stored inside data
      final msgData = msg['data'] as Map<String, dynamic>?;
      final selection =
          (msgData?['inspectorSelection'] ?? msg['selection'])
              as Map<String, dynamic>?;
      if (selection != null) {
        buf.writeln('### Widget Selection');
        buf.writeln();
        final widgetType = selection['widgetType']?.toString();
        final sourceLoc = selection['sourceLocation']?.toString();
        final path = selection['path']?.toString();
        if (widgetType != null) buf.writeln('- **Type:** `$widgetType`');
        if (sourceLoc != null) buf.writeln('- **Source:** `$sourceLoc`');
        if (path != null) buf.writeln('- **Path:** `$path`');
        buf.writeln();
      }

      // Annotations
      final annotations = _annotationsFromMsg(msg);
      if (annotations.isNotEmpty) {
        buf.writeln('### Annotations');
        buf.writeln();
        for (final ann in annotations) {
          final label = ann['text']?.toString() ?? '(no label)';
          final bounds = ann['bounds'] as Map<String, dynamic>?;
          buf.write('- **$label**');
          if (bounds != null) {
            buf.write(
              ' at (${bounds['x']}, ${bounds['y']}) '
              '${bounds['width']}x${bounds['height']}',
            );
          }
          buf.writeln();
        }
        buf.writeln();
      }

      // Screenshot placeholders — filename must match _extractScreenshots
      final screenshot = _screenshotFromMsg(msg);
      if (screenshot != null && screenshot.isNotEmpty) {
        buf.writeln('![screenshot_$i.png](placeholder)');
        buf.writeln();
      }
    }

    buf.writeln('---');
    buf.writeln(
      '_Created by flan on '
      '${DateTime.now().toIso8601String()}_',
    );

    return buf.toString();
  }

  static List<Map<String, dynamic>> _extractScreenshots(
    List<Map<String, dynamic>> messages,
  ) {
    final screenshots = <Map<String, dynamic>>[];
    for (var i = 0; i < messages.length; i++) {
      final screenshot = _screenshotFromMsg(messages[i]);
      if (screenshot != null && screenshot.isNotEmpty) {
        screenshots.add({
          'filename': 'screenshot_$i.png',
          'data': screenshot,
        });
      }
    }
    return screenshots;
  }

  /// Screenshot is stored at data.screenshot, not at the top level.
  static String? _screenshotFromMsg(Map<String, dynamic> msg) {
    final data = msg['data'] as Map<String, dynamic>?;
    return data?['screenshot'] as String?;
  }

  static List<Map<String, dynamic>> _annotationsFromMsg(
    Map<String, dynamic> msg,
  ) {
    final data = msg['data'] as Map<String, dynamic>?;
    final annotations = data?['annotations'];
    if (annotations is List) {
      return annotations
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
    }
    return const [];
  }

  static String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}...';
  }
}
