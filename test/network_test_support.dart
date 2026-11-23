import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A stand-in for WARP's local HTTP proxy: answers `CONNECT host:port` with 200 (or [status]) and then echoes everything back.
class FakeHttpProxy {
  FakeHttpProxy._(this.server, this.status);
  final ServerSocket server;
  final int status;
  final targets = <String>[];
  int get port => server.port;

  static Future<FakeHttpProxy> start({int status = 200}) async {
    final p = FakeHttpProxy._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), status);
    p.server.listen((s) {
      final buf = BytesBuilder();
      var tunnelled = false;
      s.listen(
        (d) {
          if (tunnelled) return s.add(d);
          buf.add(d);
          final text = latin1.decode(buf.toBytes());
          final end = text.indexOf('\r\n\r\n');
          if (end < 0) return;
          final first = text.split('\r\n').first.split(' ');
          p.targets.add(first.length > 1 ? first[1] : '?');
          if (p.status != 200) {
            s.add(ascii.encode('HTTP/1.1 ${p.status} No\r\nContent-Length: 0\r\n\r\n'));
            s.close();
            return;
          }
          s.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
          tunnelled = true;
          final rest = latin1.encode(text.substring(end + 4));
          if (rest.isNotEmpty) s.add(rest);
        },
        onError: (_) {},
        onDone: () => s.destroy(),
      );
    });
    return p;
  }

  Future<void> close() => server.close();
}

/// A stand-in for Anti-DPI's SOCKS5 proxy: records the requested destination, answers success (or [reply] as the failure code) and echoes.
class FakeSocks {
  FakeSocks._(this.server, this.reply);
  final ServerSocket server;
  final int reply;
  final requests = <({int atyp, String host, int port})>[];
  int get port => server.port;

  static Future<FakeSocks> start({int reply = 0}) async {
    final p = FakeSocks._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), reply);
    p.server.listen((s) {
      final buf = BytesBuilder();
      var stage = 0;
      s.listen(
        (d) {
          if (stage == 2) return s.add(d);
          buf.add(d);
          final b = buf.toBytes();
          if (stage == 0 && b.length >= 3) {
            s.add([5, 0]);
            buf.clear();
            buf.add(b.sublist(3));
            stage = 1;
          }
          final c = buf.toBytes();
          if (stage == 1 && c.length >= 5) {
            final atyp = c[3];
            final addrLen = atyp == 1
                ? 4
                : atyp == 4
                ? 16
                : c[4] + 1;
            final need = 4 + addrLen + 2;
            if (c.length < need) return;
            final host = atyp == 3
                ? utf8.decode(c.sublist(5, 5 + c[4]))
                : InternetAddress.fromRawAddress(Uint8List.fromList(c.sublist(4, 4 + addrLen))).address;
            p.requests.add((atyp: atyp, host: host, port: (c[need - 2] << 8) | c[need - 1]));
            s.add([5, p.reply, 0, 1, 0, 0, 0, 0, 0, 0]);
            if (p.reply != 0) {
              s.close();
              return;
            }
            stage = 2;
            if (c.length > need) s.add(c.sublist(need));
          }
        },
        onError: (_) {},
        onDone: () => s.destroy(),
      );
    });
    return p;
  }

  Future<void> close() => server.close();
}

/// Reads exactly [n] bytes from a tunnel's [incoming] stream (collecting what arrives).
Future<List<int>> takeBytes(Stream<Uint8List> incoming, int n) async {
  final out = <int>[];
  final done = Completer<List<int>>();
  late StreamSubscription<Uint8List> sub;
  sub = incoming.listen(
    (d) {
      out.addAll(d);
      if (out.length >= n && !done.isCompleted) {
        sub.cancel();
        done.complete(out.sublist(0, n));
      }
    },
    onDone: () {
      if (!done.isCompleted) done.complete(out);
    },
  );
  return done.future.timeout(const Duration(seconds: 5), onTimeout: () => out);
}
