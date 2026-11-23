import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/network/desktop_network_platform.dart';
import 'package:vyse_tv/data/network/network_channel.dart';

/// A stand-in for usque: `register` writes the configuration; `http-proxy` prints the "listening" line and stays up.
const _fakeUsque = r'''#!/bin/sh
echo "$@" >> "$(dirname "$0")/usque-calls.txt"
case " $* " in
  *" register "*)
    cfg=""; prev=""
    for a in "$@"; do if [ "$prev" = "-c" ]; then cfg="$a"; fi; prev="$a"; done
    echo '{"private_key":"x"}' > "$cfg"; exit 0 ;;
esac
port=""; prev=""
for a in "$@"; do if [ "$prev" = "-p" ]; then port="$a"; fi; prev="$a"; done
echo $$ > "$(dirname "$0")/usque-pid.txt"
echo "listening on 127.0.0.1:$port"
exec sleep 60
''';

/// A stand-in for ByeDPI: listens on the -p port (python3), prints nothing.
const _fakeCiadpi = r'''#!/bin/sh
port=""; prev=""
for a in "$@"; do if [ "$prev" = "-p" ]; then port="$a"; fi; prev="$a"; done
echo "$@" >> "$(dirname "$0")/ciadpi-calls.txt"
exec python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', int('$port'))); s.listen(5); time.sleep(60)"
''';

const _crashing = '#!/bin/sh\necho "could not open the tunnel" >&2\nexit 3\n';

void _write(Directory d, String name, String body) {
  final f = File('${d.path}/$name')..writeAsStringSync(body);
  Process.runSync('chmod', ['+x', f.path]);
}

void main() {
  late Directory bin, data;
  late DesktopNetworkPlatform platform;
  final verified = <int>[];
  List<String?> verdicts = [null];

  DesktopNetworkPlatform make() => DesktopNetworkPlatform(
    binDir: bin,
    dataDir: data,
    verifyWarp: (port) async {
      verified.add(port);
      return verdicts.length >= verified.length ? verdicts[verified.length - 1] : verdicts.last;
    },
    antiDpiWait: const Duration(seconds: 3),
  );

  setUp(() {
    bin = Directory.systemTemp.createTempSync('net_bin');
    data = Directory.systemTemp.createTempSync('net_data');
    verified.clear();
    verdicts = [null];
    _write(bin, 'usque', _fakeUsque);
    _write(bin, 'ciadpi', _fakeCiadpi);
    platform = make();
  });
  tearDown(() async {
    await platform.stopWarp();
    await platform.stopAntiDpi();
    bin.deleteSync(recursive: true);
    data.deleteSync(recursive: true);
  });

  List<String> calls() => File('${bin.path}/usque-calls.txt').existsSync() ? File('${bin.path}/usque-calls.txt').readAsLinesSync() : [];

  test('capabilities: what is in the folder; Secure DNS is always there', () async {
    var c = await platform.capabilities();
    expect((c.warp, c.antiDpi, c.dns), (true, true, true));
    File('${bin.path}/ciadpi').deleteSync();
    File('${bin.path}/usque').writeAsStringSync('#!/bin/sh\n'); // present but not executable
    Process.runSync('chmod', ['-x', '${bin.path}/usque']);
    c = await platform.capabilities();
    expect((c.warp, c.antiDpi, c.dns), (false, false, true));
  });

  test('WARP: registers once, starts the proxy on a loopback port, checks the tunnel, and a second start reuses it', () async {
    final port = await platform.startWarp();
    expect(port, greaterThan(1024));
    expect(File('${data.path}/warp.json').existsSync(), isTrue);
    expect(verified, [port]);
    expect(calls().where((l) => l.contains('register')).length, 1);
    expect(calls().any((l) => l.contains('http-proxy') && l.contains('-b 127.0.0.1') && l.contains('-p $port')), isTrue);
    expect(await platform.startWarp(), port); // already running
    expect(calls().where((l) => l.contains('register')).length, 1);
    await platform.stopWarp();
    final again = await platform.startWarp(); // the saved configuration is reused: no new registration
    expect(again, isNot(0));
    expect(calls().where((l) => l.contains('register')).length, 1);
  });

  test('WARP: HTTP/3 not passing traffic falls back to HTTP/2; both failing says why for each', () async {
    verdicts = ['no answer through the tunnel (timeout)', null];
    final port = await platform.startWarp();
    expect(port, isNonZero);
    expect(calls().last, contains('--http2'));
    await platform.stopWarp();

    verified.clear();
    verdicts = ['no answer through the tunnel (timeout)', 'Cloudflare answered but the traffic did not go through WARP'];
    await expectLater(
      platform.startWarp(),
      throwsA(isA<NetworkError>().having((e) => e.message, 'message', allOf(contains('HTTP/3: no answer'), contains('HTTP/2: Cloudflare answered')))),
    );
  });

  test('WARP: a program that stops at once, and a registration that fails, are errors with its own words', () async {
    _write(bin, 'usque', _crashing);
    await expectLater(platform.startWarp(), throwsA(isA<NetworkError>().having((e) => e.message, 'message', contains('Could not register'))));
    expect(File('${data.path}/warp.json').existsSync(), isFalse); // nothing half-written is kept
    File('${data.path}/warp.json').writeAsStringSync('{"k":1}');
    await expectLater(
      platform.startWarp(),
      throwsA(isA<NetworkError>().having((e) => e.message, 'message', allOf(contains('stopped at once'), contains('could not open the tunnel')))),
    );
  });

  test('WARP: the program dying by itself is reported; a stop is not', () async {
    final exits = <ModeExit>[];
    platform.exits.listen(exits.add);
    final port = await platform.startWarp();
    // (the fake program wrote its own pid: nothing is looked up by name)
    Process.killPid(int.parse(File('${bin.path}/usque-pid.txt').readAsStringSync().trim()));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(exits.map((e) => e.mode), ['warp']);
    expect(exits.single.reason, contains('stopped'));
    expect(port, isNonZero);
    exits.clear();
    await platform.startWarp();
    await platform.stopWarp();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(exits, isEmpty);
  });

  test('Anti-DPI: refuses address and port arguments; starts on a loopback port; restarts on new arguments; stops', () async {
    await expectLater(platform.startAntiDpi('-p 80'), throwsA(isA<NetworkError>()));
    final port = await platform.startAntiDpi('--split 1 --disorder 1');
    expect(await _accepts(port), isTrue);
    expect(await platform.startAntiDpi('--split 1 --disorder 1'), port); // same arguments: same program
    final port2 = await platform.startAntiDpi('--split 2');
    expect(port2, isNot(port));
    expect(await _accepts(port2), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await _accepts(port), isFalse); // the first one was stopped
    final lines = File('${bin.path}/ciadpi-calls.txt').readAsLinesSync();
    expect(lines.last, '-i 127.0.0.1 -p $port2 --split 2');
    await platform.stopAntiDpi();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await _accepts(port2), isFalse);
  });

  test('Anti-DPI: a program that cannot start is an error with its words', () async {
    _write(bin, 'ciadpi', '#!/bin/sh\necho "bad option" >&2\nexit 2\n');
    await expectLater(platform.startAntiDpi('--split 1'), throwsA(isA<NetworkError>().having((e) => e.message, 'message', contains('bad option'))));
  });

  test('a program left by a crashed run is stopped at the next start', () async {
    final stale = await Process.start('sh', ['-c', 'exec -a usque-stale sleep 60']);
    File('${data.path}/usque.pid').writeAsStringSync('${stale.pid}');
    final p2 = make(); // its constructor looks for leftovers
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final gone = await stale.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
    expect(gone, isNot(-1));
    expect(File('${data.path}/usque.pid').existsSync(), isFalse);
    await p2.stopWarp();
  }, skip: Platform.isLinux ? false : 'needs /proc');
}

Future<bool> _accepts(int port) async {
  try {
    (await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 300))).destroy();
    return true;
  } catch (_) {
    return false;
  }
}
