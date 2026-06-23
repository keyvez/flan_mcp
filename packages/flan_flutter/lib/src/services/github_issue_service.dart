import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Formats queued flan messages into a GitHub issue and POSTs
/// to the configured backend endpoint.
class GitHubIssueService {
  GitHubIssueService._();

  static String? _endpointUrl;
  static Map<String, String> Function()? _headersBuilder;
  static Map<String, String>? _userInfo;
  static void Function()? _onAuthRequired;
  static void Function()? _onSessionExpired;

  /// Optional provider of report metadata, set by the host app. Returns a map
  /// that may include a `breadcrumb` (e.g. "Company > Settings") used in the
  /// issue title, and version/env tags applied as issue labels — keys like
  /// `build`, `flutter`, `backend`, `extraction`, `pdf-parser`, `rustc`,
  /// `screen`. Evaluated at issue-creation time so values stay current.
  static Map<String, String> Function()? metadataProvider;

  /// Set the metadata provider.
  static void configureMetadata(Map<String, String> Function()? provider) {
    metadataProvider = provider;
  }

  /// Whether the issue endpoint has been configured.
  static bool get isConfigured =>
      _endpointUrl != null && _headersBuilder != null;

  /// Configures the backend endpoint and auth headers builder.
  ///
  /// [userInfo] is an optional map of user details (e.g. `{'name': '...', 'email': '...'}`).
  /// When provided, these details are included in the issue payload.
  /// [onAuthRequired] is called on 403 (GitHub token missing).
  /// [onSessionExpired] is called on 401 (session expired).
  static void configure({
    required String url,
    required Map<String, String> Function() headersBuilder,
    Map<String, String>? userInfo,
    void Function()? onAuthRequired,
    void Function()? onSessionExpired,
  }) {
    _endpointUrl = url;
    _headersBuilder = headersBuilder;
    _userInfo = userInfo;
    _onAuthRequired = onAuthRequired;
    _onSessionExpired = onSessionExpired;
  }

  /// Clears the configured endpoint (e.g. on logout).
  static void reset() {
    _endpointUrl = null;
    _headersBuilder = null;
    _userInfo = null;
    _onAuthRequired = null;
    _onSessionExpired = null;
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

    final title = _buildTitle(messages);
    final body = _buildBody(messages);

    final payload = <String, dynamic>{
      'title': title,
      'body': body,
      'labels': _buildLabels(),
      'screenshots': screenshots,
      if (_userInfo != null) 'createdBy': _userInfo,
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

    _check403(response);

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to create issue: ${response.statusCode} '
        '${response.body}',
      );
    }

    final result = jsonDecode(response.body) as Map<String, dynamic>;
    return result['url'] as String;
  }

  /// Handles the two distinct 403 cases (and 401) consistently:
  ///   - session expired (401) → onSessionExpired, prompt re-login.
  ///   - GitHub not connected (403, "connect"/"not connected") → onAuthRequired,
  ///     redirect to GitHub OAuth.
  ///   - not a repo collaborator (403, "collaborat") → DON'T redirect (re-OAuth
  ///     won't grant repo access); surface an actionable message telling the
  ///     user to request repo collaboration access.
  /// Returns normally when the response is not one of these auth cases.
  static void _check403(http.Response response) {
    if (response.statusCode == 401 && _onSessionExpired != null) {
      _onSessionExpired!();
      throw Exception('Session expired. Please log in again.');
    }
    if (response.statusCode == 403) {
      final body = response.body.toLowerCase();
      final notCollaborator = body.contains('collaborat');
      if (notCollaborator) {
        // The user is authenticated but lacks repo write access. Re-OAuth
        // can't fix this, so do not redirect — just tell them what to do.
        throw Exception(
          "You're signed in, but your GitHub account isn't a collaborator on "
          'the issue repository, so you cannot file issues. Please request '
          'repo collaboration access from an admin, then try again.',
        );
      }
      if (_onAuthRequired != null) {
        _onAuthRequired!();
        throw Exception(
          'GitHub authentication required. Connect your GitHub account to file '
          'issues. Redirecting...',
        );
      }
    }
  }

  /// Creates a GitHub issue from a single error.
  static Future<String> createIssueFromError({
    required String summary,
    required String details,
  }) async {
    if (!isConfigured) {
      throw StateError('Issue endpoint not configured');
    }

    final meta = metadataProvider?.call() ?? const {};
    final breadcrumb = (meta['breadcrumb'] ?? '').trim();
    final prefix = breadcrumb.isNotEmpty ? breadcrumb : 'Flan';
    final title = '[$prefix] ${_truncate(_cleanSummary(summary), 80)}';
    final body = StringBuffer()
      ..writeln('## Error')
      ..writeln()
      ..writeln('**Summary:** $summary')
      ..writeln()
      ..writeln('```')
      ..writeln(details)
      ..writeln('```')
      ..writeln()
      ..write(_buildEnvSection())
      ..writeln(
        '_Created automatically by ${_userInfo?['name'] ?? 'flan'} via flan on '
        '${DateTime.now().toIso8601String()}_',
      );

    final payload = <String, dynamic>{
      'title': title,
      'body': body.toString(),
      'labels': _buildLabels(['bug']),
      'screenshots': <Map<String, dynamic>>[],
      if (_userInfo != null) 'createdBy': _userInfo,
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

    _check403(response);

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
    // Breadcrumb (e.g. "Company > Settings") for the [...] prefix; falls back
    // to "Flan" when the app didn't supply one.
    final meta = metadataProvider?.call() ?? const {};
    final breadcrumb = (meta['breadcrumb'] ?? '').trim();
    final prefix = breadcrumb.isNotEmpty ? breadcrumb : 'Flan';

    // Prefer an error summary, else the cleanest message/annotation text.
    for (final msg in messages) {
      if ((msg['type']?.toString() ?? '') == 'error') {
        final summary =
            (msg['data'] as Map<String, dynamic>?)?['summary']?.toString();
        if (summary != null && summary.isNotEmpty) {
          return '[$prefix] ${_truncate(_cleanSummary(summary), 80)}';
        }
      }
    }

    for (final msg in messages) {
      final clean = _cleanSummary(msg['text']?.toString() ?? '');
      if (clean.isNotEmpty) return '[$prefix] ${_truncate(clean, 80)}';
    }

    return '[$prefix] Dev site feedback '
        '(${DateTime.now().toIso8601String().substring(0, 10)})';
  }

  /// Reduce a raw report blob to a clean one-line summary. Strips the
  /// "N annotation(s):" wrapper, the leading "- ", surrounding quotes, and any
  /// trailing "at (x, y) WxH" coordinate suffix so the title reads cleanly.
  static String _cleanSummary(String raw) {
    var s = raw.trim();
    // Take the annotation label line if present.
    final annLine = RegExp(r'-\s*"([^"]+)"').firstMatch(s);
    if (annLine != null) {
      s = annLine.group(1)!.trim();
    } else {
      // Drop a leading "N annotation(s):" header if it's the whole lead.
      s = s.replaceFirst(RegExp(r'^\d+\s+annotation\(s\):\s*'), '').trim();
      // First non-empty line only.
      s = s.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => s).trim();
      s = s.replaceFirst(RegExp(r'^-\s*'), '').replaceAll('"', '').trim();
    }
    // Strip a trailing coordinate suffix: "... at (286, 341) 1555x101".
    s = s.replaceFirst(RegExp(r'\s+at\s*\(\s*\d+.*$'), '').trim();
    return s;
  }

  /// Issue labels: the base flan tags plus version/env tags from the metadata
  /// provider (e.g. `build:1.0.0+1`, `flutter:3.x`, `backend:0.1.0`,
  /// `extraction:0.1.0`, `pdf-parser:0.4.0`, `rustc:1.91`, `screen:settings`).
  static List<String> _buildLabels([List<String> extra = const []]) {
    final labels = <String>['flan', 'dev-site', ...extra];
    final meta = metadataProvider?.call() ?? const {};
    // Order matters for readability in the GitHub UI.
    const tagKeys = [
      'screen',
      'frontend',
      'flutter',
      'backend',
      'extraction',
      'pdf-parser',
      'rustc',
    ];
    for (final key in tagKeys) {
      final v = meta[key]?.trim();
      if (v != null && v.isNotEmpty) {
        // Keep labels GitHub-friendly (no whitespace; cap length).
        labels.add(_truncate('$key:${v.replaceAll(RegExp(r'\s+'), '-')}', 48));
      }
    }
    return labels;
  }

  /// A markdown environment section for the issue body, mirroring the labels.
  static String _buildEnvSection() {
    final meta = metadataProvider?.call() ?? const {};
    if (meta.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('### Environment')
      ..writeln();
    for (final e in meta.entries) {
      if (e.key == 'breadcrumb') continue;
      if (e.value.trim().isEmpty) continue;
      buf.writeln('- **${e.key}:** ${e.value}');
    }
    buf.writeln();
    return buf.toString();
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
    buf.write(_buildEnvSection());
    final createdBy = _userInfo?['name'] ?? 'flan';
    buf.writeln(
      '_Created by $createdBy via flan on '
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
