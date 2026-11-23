import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/net.dart';
import 'package:vyse_tv/data/network/net_state.dart';

// (a top-level helper: a closure made inside the test would carry the test's own objects, like the server, into the isolate)
Future<String> _askInIsolate(String url) => Isolate.run(() async {
  final r = await netClient.get(Uri.parse(url));
  return '${r.statusCode} ${r.body}';
});

void main() {
  test('the app\'s HTTP client works inside a background isolate (plugins run in one; it must not need a platform channel)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) {
      r.response.write('hello');
      r.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/';
    expect(await _askInIsolate(url), '200 hello');
  });

  test('a background isolate gets the network state it is handed, and starts with none', () async {
    NetState.apply((proxyPort: 4321, doh: const ['https://dns.example/q']));
    final snap = NetState.snapshot();
    final inside = await Isolate.run(() {
      final before = '${NetState.proxyPort} ${NetState.doh.length}'; // a fresh isolate: nothing yet
      NetState.apply(snap);
      return '$before | ${NetState.proxyPort} ${NetState.doh.first}';
    });
    expect(inside, 'null 0 | 4321 https://dns.example/q');
    NetState.apply((proxyPort: null, doh: const []));
  });
}
