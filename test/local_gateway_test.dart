import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/network/dns_providers.dart';
import 'package:vyse_tv/data/network/local_gateway.dart';
import 'package:vyse_tv/data/network/network_route.dart';

import 'network_test_support.dart';

class _FakeDoh extends DohResolver {
  _FakeDoh(this.answer);
  final List<InternetAddress> answer;
  final asked = <String>[];
  @override
  Future<List<InternetAddress>> resolve(String host, List<String> endpoints) async {
    asked.add(host);
    return answer;
  }
}

/// Sends [request] to the gateway and returns (answer head, reader for what follows).
Future<(String, SocketReader, Socket)> _ask(int port, String request) async {
  final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final r = SocketReader(s);
  s.add(utf8.encode(request));
  final head = await r.readUntil(const [13, 10, 13, 10], max: 64 * 1024).timeout(const Duration(seconds: 5));
  return (latin1.decode(head), r, s);
}

Future<GatewayServer> _gateway({
  NetworkRoute route = NetworkRoute.direct,
  List<String> doh = const [],
  DohResolver? resolver,
  int max = 64,
  Duration queueWait = const Duration(seconds: 5),
  Duration idle = const Duration(seconds: 30),
}) async {
  final g = GatewayServer(route: route, dohEndpoints: doh, doh: resolver, maxConnections: max, queueWait: queueWait, idle: idle);
  await g.bind();
  addTearDown(g.close);
  return g;
}

void main() {
  test('CONNECT is relayed through the route, bytes both ways, TLS untouched', () async {
    final warp = await FakeHttpProxy.start();
    addTearDown(warp.close);
    final g = await _gateway(route: HttpProxyRoute(warp.port));
    final (head, r, s) = await _ask(g.port, 'CONNECT media.example:443 HTTP/1.1\r\nHost: media.example:443\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 200'));
    s.add(utf8.encode('\x16\x03\x01 client hello'));
    expect(latin1.decode(await takeBytes(r.rest, 16)), '\x16\x03\x01 client hello');
    expect(warp.targets, ['media.example:443']);
    s.destroy();
  });

  test('a plain http request is forwarded in origin form, with its Range, and without proxy headers', () async {
    final warp = await FakeHttpProxy.start();
    addTearDown(warp.close);
    final g = await _gateway(route: HttpProxyRoute(warp.port));
    // (the fake origin behind WARP echoes what it receives, so the "answer" is the request as the origin saw it)
    final (seen, _, s) = await _ask(
      g.port,
      'GET http://media.example/a/b?x=1 HTTP/1.1\r\nHost: media.example\r\nProxy-Connection: keep-alive\r\nRange: bytes=0-9\r\n\r\n',
    );
    s.destroy();
    expect(warp.targets, ['media.example:80']);
    expect(seen, startsWith('GET /a/b?x=1 HTTP/1.1\r\n'));
    expect(seen, contains('Range: bytes=0-9\r\n'));
    expect(seen, contains('Host: media.example\r\n'));
    expect(seen, contains('Connection: close\r\n'));
    expect(seen.toLowerCase(), isNot(contains('proxy-connection')));
  });

  test('this device and its network are refused (403); an upstream refusal is 502; other methods 405', () async {
    final refusing = await FakeHttpProxy.start(status: 502);
    addTearDown(refusing.close);
    final g = await _gateway(route: HttpProxyRoute(refusing.port));
    for (final target in ['127.0.0.1:80', '192.168.1.5:443', '10.0.0.1:80', 'tv.local:80', '[::1]:80']) {
      final (head, _, s) = await _ask(g.port, 'CONNECT $target HTTP/1.1\r\n\r\n');
      expect(head, startsWith('HTTP/1.1 403'), reason: target);
      s.destroy();
    }
    var (head, _, s) = await _ask(g.port, 'GET http://127.0.0.1:8090/x HTTP/1.1\r\nHost: x\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 403'));
    s.destroy();
    (head, _, s) = await _ask(g.port, 'CONNECT media.example:443 HTTP/1.1\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 502'));
    s.destroy();
    (head, _, s) = await _ask(g.port, 'TRACE http://media.example/ HTTP/1.1\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 405'));
    s.destroy();
    (head, _, s) = await _ask(g.port, 'NONSENSE\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 400'));
    s.destroy();
  });

  test('over the connection limit a connection waits for a free place and is served when one closes', () async {
    final warp = await FakeHttpProxy.start();
    addTearDown(warp.close);
    final g = await _gateway(route: HttpProxyRoute(warp.port), max: 1);
    final (h1, _, s1) = await _ask(g.port, 'CONNECT media.example:443 HTTP/1.1\r\n\r\n');
    expect(h1, startsWith('HTTP/1.1 200'));
    final second = _ask(g.port, 'CONNECT other.example:443 HTTP/1.1\r\n\r\n'); // no place: it waits, nothing is refused
    await Future<void>.delayed(const Duration(milliseconds: 300));
    s1.destroy(); // the first closes: its place goes to the waiting one
    final (h2, _, s2) = await second;
    expect(h2, startsWith('HTTP/1.1 200'));
    expect(warp.targets, ['media.example:443', 'other.example:443']);
    s2.destroy();
  });

  test('a connection that waits longer than the queue allows gets 503, and the place count stays right', () async {
    final warp = await FakeHttpProxy.start();
    addTearDown(warp.close);
    final g = await _gateway(route: HttpProxyRoute(warp.port), max: 1, queueWait: const Duration(milliseconds: 300));
    final (_, _, s1) = await _ask(g.port, 'CONNECT media.example:443 HTTP/1.1\r\n\r\n');
    final (h2, _, s2) = await _ask(g.port, 'CONNECT other.example:443 HTTP/1.1\r\n\r\n');
    expect(h2, startsWith('HTTP/1.1 503'));
    s2.destroy();
    s1.destroy(); // the one that held the place closes: a new connection is served at once again
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final (h3, _, s3) = await _ask(g.port, 'CONNECT again.example:443 HTTP/1.1\r\n\r\n');
    expect(h3, startsWith('HTTP/1.1 200'));
    s3.destroy();
  });

  test('a hundred tunnels at once are all served with the default limit', () async {
    final warp = await FakeHttpProxy.start();
    addTearDown(warp.close);
    final g = GatewayServer(route: HttpProxyRoute(warp.port));
    await g.bind();
    addTearDown(g.close);
    final answers = await Future.wait([for (var i = 0; i < 100; i++) _ask(g.port, 'CONNECT host$i.example:443 HTTP/1.1\r\n\r\n')]);
    expect(answers.where((a) => a.$1.startsWith('HTTP/1.1 200')).length, 100);
    for (final a in answers) {
      a.$3.destroy();
    }
  });

  test('SOCKS5 route with Secure DNS: the name is resolved over DoH and the address is what goes to the proxy', () async {
    final socks = await FakeSocks.start();
    addTearDown(socks.close);
    final doh = _FakeDoh([InternetAddress('10.1.2.3')]); // (a public-looking test answer; the check is on the proxy's request)
    final g = await _gateway(route: SocksRoute(socks.port), doh: ['https://dns.example/q'], resolver: doh);
    final (head, _, s) = await _ask(g.port, 'CONNECT sinkholed.example:443 HTTP/1.1\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 200'));
    expect(doh.asked, ['sinkholed.example']);
    expect(socks.requests.single.atyp, 1);
    expect(socks.requests.single.host, '10.1.2.3');
    s.destroy();
  });

  test('SOCKS5 route and DoH has no answer: the name goes as it is; without Secure DNS too', () async {
    final socks = await FakeSocks.start();
    addTearDown(socks.close);
    final g1 = await _gateway(route: SocksRoute(socks.port), doh: ['https://dns.example/q'], resolver: _FakeDoh([]));
    var (head, _, s) = await _ask(g1.port, 'CONNECT media.example:443 HTTP/1.1\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 200'));
    s.destroy();
    final g2 = await _gateway(route: SocksRoute(socks.port));
    (head, _, s) = await _ask(g2.port, 'CONNECT other.example:443 HTTP/1.1\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 200'));
    s.destroy();
    expect(socks.requests.map((r) => (r.atyp, r.host)).toList(), [(3, 'media.example'), (3, 'other.example')]);
  });

  test('WARP route: the name goes to WARP unresolved even when Secure DNS is chosen (WARP resolves inside its tunnel)', () async {
    final warp = await FakeHttpProxy.start();
    addTearDown(warp.close);
    final doh = _FakeDoh([InternetAddress('10.1.2.3')]);
    final g = await _gateway(route: HttpProxyRoute(warp.port), doh: ['https://dns.example/q'], resolver: doh);
    final (head, _, s) = await _ask(g.port, 'CONNECT media.example:443 HTTP/1.1\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 200'));
    expect(doh.asked, isEmpty);
    expect(warp.targets, ['media.example:443']);
    s.destroy();
  });

  test('idle connections are closed', () async {
    final warp = await FakeHttpProxy.start();
    addTearDown(warp.close);
    final g = await _gateway(route: HttpProxyRoute(warp.port), idle: const Duration(milliseconds: 300));
    final (head, r, s) = await _ask(g.port, 'CONNECT media.example:443 HTTP/1.1\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 200'));
    final closed = Completer<void>();
    r.rest.listen((_) {}, onDone: closed.complete, onError: (_) => closed.complete());
    await closed.future.timeout(const Duration(seconds: 3));
    s.destroy();
  });

  test('the isolate version starts, answers and stops', () async {
    final warp = await FakeHttpProxy.start();
    addTearDown(warp.close);
    final gw = await LocalGateway.start(route: HttpProxyRoute(warp.port));
    final (head, _, s) = await _ask(gw.port, 'CONNECT media.example:443 HTTP/1.1\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 200'));
    s.destroy();
    await gw.stop();
  });
}
