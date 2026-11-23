import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'dns_providers.dart';
import 'network_route.dart';

/// The loopback proxy that native players (ExoPlayer, mpv) are pointed at while a network mode is on, and that the app's own HTTP
/// clients use for the same reason (specs/001-warp-doh-anti-dpi/contracts/local-gateway.md): it applies the route (WARP's HTTP proxy,
/// Anti-DPI's SOCKS5 proxy) and the DNS choice for them. It carries `CONNECT` (https) and absolute-URI http requests, relays bytes
/// without touching TLS, and never reaches this device or its local network.
class GatewayServer {
  GatewayServer({
    this.route = NetworkRoute.direct,
    this.dohEndpoints = const [],
    this.maxConnections = 512,
    this.queueWait = const Duration(seconds: 30),
    this.idle = const Duration(seconds: 60),
    DohResolver? doh,
  }) : _doh = doh ?? DohResolver();

  final NetworkRoute route;

  /// DNS-over-HTTPS endpoints to resolve names with; empty = the system resolver.
  final List<String> dohEndpoints;

  /// How many tunnels are open at once; the ones beyond wait for a free place (up to [queueWait]) instead of being refused.
  final int maxConnections;
  final Duration queueWait;
  final Duration idle;
  final DohResolver _doh;
  ServerSocket? _server;
  int _active = 0;
  final _waiting = Queue<Completer<void>>();

  int get port => _server!.port;

  Future<int> bind() async {
    final s = _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(_accept, onError: (_) {});
    return s.port;
  }

  Future<void> close() async => _server?.close();

  void _accept(Socket c) => unawaited(_handle(c));

  /// A place for one more tunnel: at once, or when another one closes. False when none came free in [queueWait].
  Future<bool> _acquire() async {
    if (_active < maxConnections) {
      _active++;
      return true;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    try {
      await turn.future.timeout(queueWait); // (a place handed over keeps the count: see _release)
      return true;
    } on TimeoutException {
      if (turn.isCompleted) return true; // a place was handed over just as the time ran out: it is ours
      _waiting.remove(turn);
      return false;
    }
  }

  void _release() {
    while (_waiting.isNotEmpty) {
      final next = _waiting.removeFirst();
      if (!next.isCompleted) {
        next.complete();
        return; // the place goes straight to the one waiting
      }
    }
    _active--;
  }

  Future<void> _handle(Socket c) async {
    if (!await _acquire()) {
      c.add(ascii.encode('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'));
      c.destroy();
      return;
    }
    try {
      await _serve(c);
    } finally {
      _release();
    }
  }

  Future<void> _reply(Socket c, int code, String text) async {
    try {
      c.add(ascii.encode('HTTP/1.1 $code $text\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'));
      await c.flush();
    } catch (_) {}
    c.destroy();
  }

  Future<void> _serve(Socket client) async {
    final reader = SocketReader(client);
    try {
      final head = await reader.readUntil(const [13, 10, 13, 10], max: 32 * 1024).timeout(const Duration(seconds: 15));
      final lines = latin1.decode(head).split('\r\n');
      final parts = lines.first.split(' ');
      if (parts.length < 3) return await _reply(client, 400, 'Bad Request');
      final method = parts[0].toUpperCase();
      if (method == 'CONNECT') {
        final i = parts[1].lastIndexOf(':');
        final host = (i > 0 ? parts[1].substring(0, i) : parts[1]).replaceAll(RegExp(r'^\[|\]$'), '');
        final port = i > 0 ? int.tryParse(parts[1].substring(i + 1)) : 443;
        if (port == null || port < 1 || port > 65535 || host.isEmpty) return await _reply(client, 400, 'Bad Request');
        if (isLocalHost(host)) return await _reply(client, 403, 'Forbidden');
        final Tunnel t;
        try {
          t = await _open(host, port);
        } catch (_) {
          return await _reply(client, 502, 'Bad Gateway');
        }
        client.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
        return await _relay(client, reader.rest, t);
      }
      if (method == 'GET' || method == 'HEAD' || method == 'POST' || method == 'PUT' || method == 'DELETE' || method == 'OPTIONS') {
        final uri = Uri.tryParse(parts[1]);
        if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return await _reply(client, 400, 'Bad Request');
        if (isLocalHost(uri.host)) return await _reply(client, 403, 'Forbidden');
        final Tunnel t;
        try {
          t = await _open(uri.host, uri.hasPort ? uri.port : 80);
        } catch (_) {
          return await _reply(client, 502, 'Bad Gateway');
        }
        // origin-form request line; hop-by-hop headers dropped; one request per connection ("Connection: close")
        final out = StringBuffer('$method ${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''} ${parts[2]}\r\n');
        for (final l in lines.skip(1)) {
          if (l.isEmpty) continue;
          final name = l.split(':').first.trim().toLowerCase();
          if (name == 'proxy-connection' || name == 'connection' || name == 'proxy-authorization' || name == 'keep-alive') continue;
          out.write('$l\r\n');
        }
        out.write('Connection: close\r\n\r\n');
        t.socket.add(latin1.encode(out.toString()));
        return await _relay(client, reader.rest, t);
      }
      return await _reply(client, 405, 'Method Not Allowed');
    } catch (_) {
      client.destroy();
    }
  }

  /// Opens the destination through the route, resolving the name with the DNS choice where the route needs an address.
  Future<Tunnel> _open(String host, int port) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null || route is HttpProxyRoute) {
      // an address needs no lookup; WARP's proxy resolves names itself (inside its tunnel)
      return openTunnel(route, host, port, address: literal);
    }
    final addresses = dohEndpoints.isEmpty ? const <InternetAddress>[] : await _doh.resolve(host, dohEndpoints);
    Object? error;
    for (final a in addresses) {
      try {
        return await openTunnel(route, host, port, address: a, timeout: const Duration(seconds: 8));
      } catch (e) {
        error = e;
      }
    }
    if (addresses.isNotEmpty && route is DirectRoute) throw error!; // resolved and none reachable
    return openTunnel(route, host, port); // no DoH answer (or SOCKS5, which can resolve by name): the name goes as it is
  }

  Future<void> _relay(Socket client, Stream<Uint8List> fromClient, Tunnel t) {
    final done = Completer<void>();
    Timer? timer;
    void finish() {
      timer?.cancel();
      client.destroy();
      t.close();
      if (!done.isCompleted) done.complete();
    }

    void touch() {
      timer?.cancel();
      timer = Timer(idle, finish);
    }

    touch();
    t.incoming
        .map((d) {
          touch();
          return d;
        })
        .pipe(_SinkOf(client))
        .then((_) => finish(), onError: (_) => finish());
    fromClient
        .map((d) {
          touch();
          return d;
        })
        .pipe(_SinkOf(t.socket))
        .then((_) => finish(), onError: (_) => finish());
    return done.future;
  }
}

/// A socket as a stream consumer that does not close it when the stream ends (the other direction may still be running).
class _SinkOf implements StreamConsumer<Uint8List> {
  _SinkOf(this.s);
  final Socket s;
  @override
  Future<void> addStream(Stream<Uint8List> stream) => s.addStream(stream);
  @override
  Future<void> close() async {}
}

/// A running gateway: where to point clients, and how to stop it (tests use fakes).
abstract class GatewayHandle {
  int get port;
  Future<void> stop();
}

/// The gateway running in a background isolate (so that carrying a video never competes with the interface for the main one).
class LocalGateway implements GatewayHandle {
  LocalGateway._(this.port, this._isolate, this._control);
  @override
  final int port;
  final Isolate _isolate;
  final SendPort _control;

  static Future<LocalGateway> start({required NetworkRoute route, List<String> dohEndpoints = const []}) async {
    final ready = ReceivePort();
    final iso = await Isolate.spawn(_entry, [ready.sendPort, _routeToList(route), dohEndpoints], onError: ready.sendPort, debugName: 'network-gateway');
    final first = await ready.first.timeout(const Duration(seconds: 5), onTimeout: () => null);
    if (first is! List || first.length != 2 || first[0] is! int) {
      iso.kill(priority: Isolate.immediate);
      throw StateError('the gateway did not start: $first');
    }
    return LocalGateway._(first[0] as int, iso, first[1] as SendPort);
  }

  @override
  Future<void> stop() async {
    _control.send('stop');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

List<Object> _routeToList(NetworkRoute r) => switch (r) {
  HttpProxyRoute(:final port) => ['http', port],
  SocksRoute(:final port) => ['socks', port],
  DirectRoute() => ['direct', 0],
};

NetworkRoute _routeFromList(List<Object?> l) => switch (l[0]) {
  'http' => HttpProxyRoute(l[1]! as int),
  'socks' => SocksRoute(l[1]! as int),
  _ => NetworkRoute.direct,
};

Future<void> _entry(List<Object?> args) async {
  final out = args[0]! as SendPort;
  final control = ReceivePort();
  try {
    final server = GatewayServer(route: _routeFromList(args[1]! as List<Object?>), dohEndpoints: (args[2]! as List).cast<String>());
    final port = await server.bind();
    control.listen((m) {
      if (m == 'stop') {
        server.close();
        control.close();
      }
    });
    out.send([port, control.sendPort]);
  } catch (e) {
    out.send('$e');
  }
}
