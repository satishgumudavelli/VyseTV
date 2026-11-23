import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/network/network_route.dart';

import 'network_test_support.dart';

void main() {
  test('through an HTTP proxy: CONNECT to the target, then bytes both ways', () async {
    final proxy = await FakeHttpProxy.start();
    addTearDown(proxy.close);
    final t = await openTunnel(HttpProxyRoute(proxy.port), 'media.example', 443);
    t.socket.add(utf8.encode('hello'));
    expect(utf8.decode(await takeBytes(t.incoming, 5)), 'hello');
    expect(proxy.targets, ['media.example:443']);
    t.close();
  });

  test('an HTTP proxy that refuses is an error, not a socket', () async {
    final proxy = await FakeHttpProxy.start(status: 407);
    addTearDown(proxy.close);
    await expectLater(openTunnel(HttpProxyRoute(proxy.port), 'media.example', 443), throwsA(isA<TunnelError>()));
  });

  test('through SOCKS5: a name goes as a name, a resolved address as an address, IPv6 too', () async {
    final socks = await FakeSocks.start();
    addTearDown(socks.close);
    final a = await openTunnel(SocksRoute(socks.port), 'media.example', 443);
    a.socket.add(utf8.encode('abc'));
    expect(utf8.decode(await takeBytes(a.incoming, 3)), 'abc');
    final b = await openTunnel(SocksRoute(socks.port), 'media.example', 8443, address: InternetAddress('93.184.216.34'));
    b.socket.add(utf8.encode('xy'));
    expect(utf8.decode(await takeBytes(b.incoming, 2)), 'xy');
    final c = await openTunnel(SocksRoute(socks.port), '2606:4700::1111', 443);
    c.socket.add(utf8.encode('z'));
    expect(utf8.decode(await takeBytes(c.incoming, 1)), 'z');
    expect(socks.requests.map((r) => (r.atyp, r.host, r.port)).toList(), [(3, 'media.example', 443), (1, '93.184.216.34', 8443), (4, '2606:4700::1111', 443)]);
    for (final t in [a, b, c]) {
      t.close();
    }
  });

  test('SOCKS5 refusal and a server that is not SOCKS5', () async {
    final refuse = await FakeSocks.start(reply: 5);
    addTearDown(refuse.close);
    await expectLater(openTunnel(SocksRoute(refuse.port), 'media.example', 443), throwsA(isA<TunnelError>()));
    final other = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(other.close);
    other.listen((s) {
      s.add(const [0x48, 0x54]);
      s.close();
    });
    await expectLater(openTunnel(SocksRoute(other.port), 'media.example', 443), throwsA(anything));
  });

  test('direct: a plain connection; nothing listening is an error', () async {
    final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(echo.close);
    echo.listen((s) => s.listen(s.add, onDone: s.destroy));
    final t = await openTunnel(NetworkRoute.direct, '127.0.0.1', echo.port);
    t.socket.add(utf8.encode('ok'));
    expect(utf8.decode(await takeBytes(t.incoming, 2)), 'ok');
    t.close();
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close();
    await expectLater(openTunnel(NetworkRoute.direct, '127.0.0.1', port), throwsA(isA<SocketException>()));
  });

  test('this device and its local network are never sent through a mode', () {
    for (final h in [
      'localhost',
      '127.0.0.1',
      '10.0.0.5',
      '172.16.1.1',
      '172.31.9.9',
      '192.168.1.37',
      '169.254.1.1',
      '100.64.0.1',
      '[::1]',
      'fd00::1',
      '::ffff:192.168.1.5',
      'tv.local',
      'nas.lan',
      'x.localhost',
    ]) {
      expect(isLocalHost(h), isTrue, reason: h);
    }
    for (final h in ['example.com', '8.8.8.8', '172.32.0.1', '100.128.0.1', '2606:4700::1111', 'api.themoviedb.org']) {
      expect(isLocalHost(h), isFalse, reason: h);
    }
  });
}
