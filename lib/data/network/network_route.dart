import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Where the app's traffic goes next (specs/001-warp-doh-anti-dpi): straight out, through WARP's local HTTP proxy, or through
/// Anti-DPI's local SOCKS5 proxy. Never both proxies at once (the controller keeps WARP and Anti-DPI exclusive).
sealed class NetworkRoute {
  const NetworkRoute();
  static const direct = DirectRoute();
}

class DirectRoute extends NetworkRoute {
  const DirectRoute();
  @override
  String toString() => 'direct';
}

/// WARP: a local HTTP proxy (`CONNECT` for https) on 127.0.0.1:[port].
class HttpProxyRoute extends NetworkRoute {
  const HttpProxyRoute(this.port);
  final int port;
  @override
  bool operator ==(Object other) => other is HttpProxyRoute && other.port == port;
  @override
  int get hashCode => Object.hash('http', port);
  @override
  String toString() => 'http-proxy:$port';
}

/// Anti-DPI: a local SOCKS5 proxy on 127.0.0.1:[port].
class SocksRoute extends NetworkRoute {
  const SocksRoute(this.port);
  final int port;
  @override
  bool operator ==(Object other) => other is SocksRoute && other.port == port;
  @override
  int get hashCode => Object.hash('socks', port);
  @override
  String toString() => 'socks5:$port';
}

/// Whether [host] is this device or its local network: those are never sent through a mode (TorrServer, casting, a router).
bool isLocalHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local') || h.endsWith('.lan') || h.endsWith('.home.arpa')) return true;
  final a = InternetAddress.tryParse(h.startsWith('[') ? h.substring(1, h.length - 1) : h);
  return a != null && isPrivateAddress(a);
}

/// Loopback, link-local, multicast and the private ranges (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7).
bool isPrivateAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 10 || b[0] == 0 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }
  if (b.length == 16) {
    if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7
    if (b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff) {
      return isPrivateAddress(InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))));
    }
  }
  return false;
}

/// An open connection to a destination, made through a route: write to [socket], read from [incoming]. (The socket's own stream
/// is already listened to by the handshake; [incoming] carries every byte after it.)
class Tunnel {
  Tunnel(this.socket, this.incoming);
  final Socket socket;
  final Stream<Uint8List> incoming;
  void close() => socket.destroy();
}

class TunnelError implements Exception {
  TunnelError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Opens a connection to [host]:[port] through [route]. [host] is a name or an address; through an HTTP proxy it is passed as given
/// (the proxy resolves it), through SOCKS5 a name is sent as a name unless [address] says what it resolves to.
Future<Tunnel> openTunnel(NetworkRoute route, String host, int port, {InternetAddress? address, Duration timeout = const Duration(seconds: 15)}) async {
  switch (route) {
    case DirectRoute():
      final s = await Socket.connect(address ?? host, port, timeout: timeout);
      return Tunnel(s, s.cast<Uint8List>());
    case HttpProxyRoute(port: final proxyPort):
      return _viaHttpProxy(proxyPort, host, port, timeout);
    case SocksRoute(port: final proxyPort):
      return _viaSocks5(proxyPort, address?.address ?? host, port, timeout);
  }
}

Future<Tunnel> _viaHttpProxy(int proxyPort, String host, int port, Duration timeout) async {
  final s = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort, timeout: timeout);
  final r = SocketReader(s);
  try {
    final target = host.contains(':') && !host.startsWith('[') ? '[$host]:$port' : '$host:$port';
    s.add(ascii.encode('CONNECT $target HTTP/1.1\r\nHost: $target\r\nProxy-Connection: keep-alive\r\n\r\n'));
    final head = await r.readUntil(const [13, 10, 13, 10], max: 16 * 1024).timeout(timeout);
    final line = ascii.decode(head, allowInvalid: true).split('\r\n').first;
    final code = int.tryParse(RegExp(r'^HTTP/\d(?:\.\d)?\s+(\d{3})').firstMatch(line)?.group(1) ?? '');
    if (code != 200) throw TunnelError('proxy refused the connection ($line)');
    return Tunnel(s, r.rest);
  } catch (_) {
    s.destroy();
    rethrow;
  }
}

Future<Tunnel> _viaSocks5(int proxyPort, String host, int port, Duration timeout) async {
  final s = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort, timeout: timeout);
  final r = SocketReader(s);
  try {
    s.add(const [5, 1, 0]); // version 5, one method: none
    final hello = await r.read(2).timeout(timeout);
    if (hello[0] != 5 || hello[1] != 0) throw TunnelError('SOCKS5 proxy wants authentication or speaks another protocol');
    final ip = InternetAddress.tryParse(host);
    final req = BytesBuilder()..add(const [5, 1, 0]);
    if (ip != null && ip.type == InternetAddressType.IPv4) {
      req
        ..addByte(1)
        ..add(ip.rawAddress);
    } else if (ip != null) {
      req
        ..addByte(4)
        ..add(ip.rawAddress);
    } else {
      final name = utf8.encode(host);
      if (name.isEmpty || name.length > 255) throw TunnelError('bad host name');
      req
        ..addByte(3)
        ..addByte(name.length)
        ..add(name);
    }
    req
      ..addByte(port >> 8)
      ..addByte(port & 255);
    s.add(req.toBytes());
    final head = await r.read(4).timeout(timeout);
    if (head[0] != 5) throw TunnelError('bad SOCKS5 reply');
    if (head[1] != 0) throw TunnelError('SOCKS5 proxy refused the connection (code ${head[1]})');
    final addrLen = switch (head[3]) {
      1 => 4,
      4 => 16,
      3 => (await r.read(1).timeout(timeout))[0],
      _ => throw TunnelError('bad SOCKS5 reply'),
    };
    await r.read(addrLen + 2).timeout(timeout); // bound address and port: not needed
    return Tunnel(s, r.rest);
  } catch (_) {
    s.destroy();
    rethrow;
  }
}

/// Reads a handshake or a request head from a socket, then hands every later byte on through [rest] (a socket can be listened to only once).
class SocketReader {
  SocketReader(Socket s) {
    _sub = s.listen(
      (d) {
        if (_handedOn) {
          _rest.add(d);
        } else {
          _buf.add(d);
          _wake();
        }
      },
      onError: (Object e) {
        _error = e;
        _wake();
        if (_handedOn) _rest.addError(e);
      },
      onDone: () {
        _done = true;
        _wake();
        if (_handedOn) _rest.close();
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder(copy: false);
  final _rest = StreamController<Uint8List>();
  Completer<void>? _waiting;
  bool _done = false, _handedOn = false;
  Object? _error;

  void _wake() {
    final w = _waiting;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _more() {
    if (_error != null) throw _error!;
    if (_done) throw TunnelError('connection closed during the handshake');
    return (_waiting = Completer<void>()).future;
  }

  Future<Uint8List> read(int n) async {
    while (_buf.length < n) {
      await _more();
    }
    final all = _buf.takeBytes();
    _buf.add(Uint8List.sublistView(all, n));
    return Uint8List.sublistView(all, 0, n);
  }

  Future<Uint8List> readUntil(List<int> pattern, {required int max}) async {
    var from = 0;
    while (true) {
      final all = _buf.takeBytes();
      _buf.add(all);
      final at = _indexOf(all, pattern, from);
      if (at >= 0) {
        final end = at + pattern.length;
        _buf.clear();
        _buf.add(Uint8List.sublistView(all, end));
        return Uint8List.sublistView(all, 0, end);
      }
      if (all.length > max) throw TunnelError('proxy answer too long');
      from = all.length > pattern.length ? all.length - pattern.length : 0;
      await _more();
    }
  }

  /// Everything after the handshake (the bytes already received first).
  Stream<Uint8List> get rest {
    if (!_handedOn) {
      _handedOn = true;
      if (_buf.length > 0) _rest.add(_buf.takeBytes());
      if (_error != null) {
        _rest.addError(_error!);
      } else if (_done) {
        _rest.close();
      }
      _rest.onCancel = () => _sub.cancel();
      _rest.onPause = _sub.pause;
      _rest.onResume = _sub.resume;
    }
    return _rest.stream;
  }
}

int _indexOf(List<int> data, List<int> pattern, int from) {
  for (var i = from; i <= data.length - pattern.length; i++) {
    var ok = true;
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}
