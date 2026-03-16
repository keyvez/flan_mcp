import 'package:flan_flutter/src/services/log_collector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  late LogCollector collector;

  setUp(() {
    collector = LogCollector();
  });

  test('starts empty', () {
    expect(collector.count, 0);
    expect(collector.getFormattedLogs(), isEmpty);
    expect(collector.getFormattedLogsAsText(), isEmpty);
  });

  test('initialize captures logs from Logger', () {
    collector.initialize();

    final logger = Logger('TestLogger');
    logger.info('test message');

    expect(collector.count, 1);
    final logs = collector.getFormattedLogs();
    expect(logs, hasLength(1));
    expect(logs.first, contains('TestLogger'));
    expect(logs.first, contains('test message'));
    expect(logs.first, contains('INFO'));
  });

  test('initialize is idempotent', () {
    collector.initialize();
    collector.initialize(); // second call should be a no-op

    final logger = Logger('TestLogger');
    logger.info('only once');

    // Should only capture once, not twice
    expect(collector.count, 1);
  });

  test('getFormattedLogsAsText joins logs with newlines', () {
    collector.initialize();

    final logger = Logger('TestLogger');
    logger.info('first');
    logger.info('second');

    final text = collector.getFormattedLogsAsText();
    expect(text, contains('first'));
    expect(text, contains('second'));
    expect(text, contains('\n'));
  });

  test('clear removes all logs', () {
    collector.initialize();

    final logger = Logger('TestLogger');
    logger.info('to be cleared');

    expect(collector.count, greaterThan(0));
    collector.clear();
    expect(collector.count, 0);
    expect(collector.getFormattedLogs(), isEmpty);
  });

  test('log format includes timestamp', () {
    collector.initialize();

    final logger = Logger('TestLogger');
    logger.info('timed entry');

    final log = collector.getFormattedLogs().first;
    // Should contain time format like [HH:MM:SS.mmm]
    expect(log, matches(RegExp(r'\[\d{2}:\d{2}:\d{2}\.\d{3}\]')));
  });

  test('log format includes error info when present', () {
    collector.initialize();

    final logger = Logger('TestLogger');
    logger.severe('failed', Exception('boom'), StackTrace.current);

    final log = collector.getFormattedLogs().last;
    expect(log, contains('SEVERE'));
    expect(log, contains('failed'));
    expect(log, contains('Error:'));
    expect(log, contains('boom'));
    expect(log, contains('Stack trace:'));
  });

  test('caps at 1000 logs', () {
    collector.initialize();

    final logger = Logger('TestLogger');
    for (var i = 0; i < 1010; i++) {
      logger.info('log $i');
    }

    expect(collector.count, 1000);
  });
}
