import 'package:flan_flutter/src/services/github_issue_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    GitHubIssueService.reset();
  });

  group('isConfigured', () {
    test('returns false when not configured', () {
      expect(GitHubIssueService.isConfigured, isFalse);
    });

    test('returns true after configure', () {
      GitHubIssueService.configure(
        url: 'https://example.com/api/issues',
        headersBuilder: () => {'Authorization': 'Bearer token'},
      );
      expect(GitHubIssueService.isConfigured, isTrue);
    });

    test('returns false after reset', () {
      GitHubIssueService.configure(
        url: 'https://example.com/api/issues',
        headersBuilder: () => {'Authorization': 'Bearer token'},
      );
      GitHubIssueService.reset();
      expect(GitHubIssueService.isConfigured, isFalse);
    });
  });

  group('createIssueFromMessages', () {
    test('throws when not configured', () async {
      expect(
        () => GitHubIssueService.createIssueFromMessages([]),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('createIssueFromError', () {
    test('throws when not configured', () async {
      expect(
        () => GitHubIssueService.createIssueFromError(
          summary: 'test error',
          details: 'details',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
