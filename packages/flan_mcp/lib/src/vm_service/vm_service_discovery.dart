import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

final _logger = logging.Logger('VmServiceDiscovery');

/// Discovers running Flutter app VM service URIs by scanning for
/// `flutter run` processes and probing their DDS (Dart Development Service)
/// endpoints.
///
/// Returns a list of ws:// URIs that can be passed to [VmServiceConnector.connect].
Future<List<String>> discoverVmServiceUris() async {
  final uris = <String>[];

  // Step 1: Find `flutter run` processes.
  final flutterPids = await _findFlutterRunPids();
  if (flutterPids.isEmpty) {
    _logger.fine('No flutter run processes found');
    return uris;
  }

  _logger.fine('Found flutter run PIDs: $flutterPids');

  // Step 2: For each flutter run process, find localhost-bound listening ports.
  for (final pid in flutterPids) {
    final ports = await _findLocalhostListeningPorts(pid);
    if (ports.isEmpty) continue;

    _logger.fine('PID $pid listening on ports: $ports');

    // Step 3: Probe each port to find the VM service / DDS URI.
    for (final port in ports) {
      final uri = await _probeForVmService(port);
      if (uri != null) {
        uris.add(uri);
        break; // One URI per flutter run process is enough.
      }
    }
  }

  return uris;
}

/// Find PIDs of `flutter run` processes.
Future<List<int>> _findFlutterRunPids() async {
  try {
    // Look for dart processes running flutter_tools.snapshot with 'run'
    final result = await Process.run('/bin/ps', ['-eo', 'pid,command']);
    if (result.exitCode != 0) return [];

    final pids = <int>[];
    for (final line in (result.stdout as String).split('\n')) {
      if (line.contains('flutter_tools.snapshot') && line.contains(' run ')) {
        final pid = int.tryParse(line.trim().split(RegExp(r'\s+')).first);
        if (pid != null) pids.add(pid);
      }
    }
    return pids;
  } catch (e) {
    _logger.fine('Failed to find flutter run processes: $e');
    return [];
  }
}

/// Find localhost-bound listening TCP ports for a given PID.
Future<List<int>> _findLocalhostListeningPorts(int pid) async {
  try {
    final result = await Process.run('/usr/sbin/lsof', [
      '-i',
      'TCP',
      '-a',
      '-p',
      '$pid',
      '-a',
      '-s',
      'TCP:LISTEN',
      '-n',
      '-P',
    ]);
    if (result.exitCode != 0) return [];

    final ports = <int>[];
    for (final line in (result.stdout as String).split('\n')) {
      // Match lines like: dartvm PID ... TCP 127.0.0.1:PORT (LISTEN)
      if (!line.contains('LISTEN')) continue;
      // Only want localhost-bound ports (127.0.0.1 or [::1])
      final match =
          RegExp(r'(?:127\.0\.0\.1|localhost|\[::1\]):(\d+)').firstMatch(line);
      if (match != null) {
        final port = int.tryParse(match.group(1)!);
        if (port != null) ports.add(port);
      }
    }
    return ports;
  } catch (e) {
    _logger.fine('Failed to find ports for PID $pid: $e');
    return [];
  }
}

/// Probe a port to check if it's a Dart VM service or DDS endpoint.
///
/// The raw VM service responds with a redirect to the DDS URI when DDS is
/// active. We parse that to construct the ws:// URI.
///
/// Returns a ws:// URI or null if this port isn't a VM service.
Future<String?> _probeForVmService(int port) async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
    final request = await client.get('127.0.0.1', port, '/');
    final response = await request.close().timeout(
      const Duration(seconds: 3),
    );
    final body = await response.transform(utf8.decoder).join();
    client.close(force: true);

    // Case 1: Raw VM service redirects to DDS.
    // Response body looks like:
    // "Cannot connect directly to the VM service as a Dart Development Service
    //  (DDS) instance has taken control and can be found at
    //  http://127.0.0.1:PORT/AUTH_CODE/."
    if (body.contains('Dart Development Service')) {
      final match = RegExp(
        r'http://([^/]+):(\d+)/([^/]+)/',
      ).firstMatch(body);
      if (match != null) {
        final host = match.group(1)!;
        final ddsPort = match.group(2)!;
        final authCode = match.group(3)!;
        final uri = 'ws://$host:$ddsPort/$authCode/ws';
        _logger.info('Discovered DDS VM service at $uri (via port $port)');
        return uri;
      }
    }

    // Case 2: Direct VM service (no DDS).
    // Try to see if this responds to a JSON-RPC getVM call.
    if (body.contains('vm_service') || body.contains('getVM')) {
      final uri = 'ws://127.0.0.1:$port/ws';
      _logger.info('Discovered direct VM service at $uri');
      return uri;
    }

    return null;
  } catch (e) {
    _logger.fine('Port $port probe failed: $e');
    return null;
  }
}
