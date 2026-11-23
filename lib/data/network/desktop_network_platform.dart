import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'anti_dpi_presets.dart';
import 'network_channel.dart';

/// WARP and Anti-DPI on Linux: the same two programs as on Android (usque and ByeDPI, built for this machine by
/// `scripts/build_usque.sh` and `scripts/build_byedpi.sh`, shipped in the bundle's `lib` folder), run as child processes that listen on
/// 127.0.0.1 only. Mirrors `NetworkModesPlugin.kt`. Nothing here changes the machine's routes or other programs (no system-wide VPN).
class DesktopNetworkPlatform implements NetworkPlatform {
  DesktopNetworkPlatform({
    Directory? binDir,
    Directory? dataDir,
    Future<String?> Function(int port)? verifyWarp,
    this.warpListenWait = const Duration(seconds: 3),
    this.antiDpiWait = const Duration(seconds: 4),
  }) : _bin = (binDir ?? File(Platform.resolvedExecutable).parent.uri.resolve('lib/').toFilePath().asDir()).absolute,
       _data = (dataDir ?? _defaultDataDir()).absolute,
       _verify = verifyWarp ?? _traceThroughWarp {
    unawaited(_killStale());
  }

  final Directory _bin, _data;
  final Future<String?> Function(int port) _verify;
  final Duration warpListenWait, antiDpiWait;
  final _exits = StreamController<ModeExit>.broadcast();

  _Running? _warp, _dpi;
  bool _stopping = false;
  Future<void> _busy = Future.value(); // one start or stop at a time

  static Directory _defaultDataDir() {
    final base = Platform.environment['XDG_DATA_HOME'] ?? '${Platform.environment['HOME'] ?? '.'}/.local/share';
    return Directory('$base/vysetv/network');
  }

  File _program(String name) => File('${_bin.path}${_bin.path.endsWith('/') ? '' : '/'}$name');
  bool _runnable(File f) => f.existsSync() && (f.statSync().mode & 0x49) != 0; // any execute bit

  @override
  Stream<ModeExit> get exits => _exits.stream;

  @override
  Future<NetworkCapabilities> capabilities() async =>
      NetworkCapabilities(warp: _runnable(_program('usque')), antiDpi: _runnable(_program('ciadpi')), dns: true);

  @override
  Future<void> setProxy(int? port) async {} // mpv is pointed at the gateway by the player page; there is no platform HTTP stack to steer

  Future<T> _serial<T>(Future<T> Function() job) {
    final next = _busy.then((_) => job());
    _busy = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  // ── WARP ──

  @override
  Future<int> startWarp() => _serial(_startWarp);

  Future<int> _startWarp() async {
    final running = _warp;
    if (running != null && running.alive) return running.port;
    final bin = _program('usque');
    if (!_runnable(bin)) throw NetworkError('WARP is not available on this machine (no usque in ${_bin.path})');
    await _data.create(recursive: true);
    final config = File('${_data.path}/warp.json');
    if (!config.existsSync() || config.lengthSync() == 0) {
      // usque registers an anonymous WARP client itself and writes the configuration. Some networks reset connections to Cloudflare's
      // registration host at random, so a failed attempt is tried again (up to 4 times).
      String? last;
      for (var attempt = 1; attempt <= 4; attempt++) {
        try {
          final r = await Process.run(bin.path, [
            '-c',
            config.path,
            'register',
            '--accept-tos',
          ], workingDirectory: _data.path).timeout(const Duration(seconds: 25));
          if (r.exitCode == 0 && config.existsSync() && config.lengthSync() > 0) {
            last = null;
            break;
          }
          last = _tail('${r.stderr}\n${r.stdout}');
        } catch (e) {
          last = '$e';
        }
        if (config.existsSync() && config.lengthSync() == 0) config.deleteSync();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (last != null) throw NetworkError('Could not register with Cloudflare WARP: $last');
    }
    final why = <String>[];
    for (final (label, extra) in const [
      ('HTTP/3', <String>[]),
      ('HTTP/2', <String>['--http2']),
    ]) {
      final port = await _freePort();
      final args = ['-c', config.path, 'http-proxy', '-b', '127.0.0.1', '-p', '$port', '-d', '1.1.1.1', '-d', '8.8.8.8', ...extra];
      final p = await Process.start(bin.path, args, workingDirectory: _data.path);
      final out = _Output(p);
      final up = await out.waitFor((l) => l.toLowerCase().contains('listening on'), warpListenWait, p);
      if (!up) {
        why.add('$label: the program ${await _exited(p) ? 'stopped at once (${await out.tailOfEnded(2)})' : 'did not start listening'}');
        p.kill(ProcessSignal.sigkill);
        continue;
      }
      final bad = await _verify(port);
      if (bad != null) {
        why.add('$label: $bad; the program said: ${out.tail(2)}');
        p.kill(ProcessSignal.sigkill);
        continue;
      }
      final r = _Running(p, port, extra.join(' '));
      _warp = r;
      _remember('usque', p.pid);
      unawaited(_watch('warp', r));
      return port;
    }
    throw NetworkError('WARP did not connect: ${why.join('; ')}');
  }

  @override
  Future<void> stopWarp() => _serial(() async {
    final r = _warp;
    _warp = null;
    await _kill(r, 'usque');
  });

  /// null when a request through the local proxy really leaves through WARP (Cloudflare's trace says `warp=on`); else why not.
  static Future<String?> _traceThroughWarp(int port) async {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..connectionFactory =
          null // not the app's resolving factory: this is a plain request to the proxy
      ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      final rq = await c.getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace')).timeout(const Duration(seconds: 8));
      final res = await rq.close().timeout(const Duration(seconds: 8));
      final body = await utf8.decodeStream(res).timeout(const Duration(seconds: 8));
      return body.contains('warp=on') || body.contains('warp=plus') ? null : 'Cloudflare answered but the traffic did not go through WARP';
    } catch (e) {
      return 'no answer through the tunnel (${e.toString().split('\n').first})';
    } finally {
      c.close(force: true);
    }
  }

  // ── Anti-DPI ──

  @override
  Future<int> startAntiDpi(String args) => _serial(() => _startAntiDpi(args));

  Future<int> _startAntiDpi(String args) async {
    final bad = validateAntiDpiArgs(args);
    if (bad != null) throw NetworkError(bad);
    final tokens = args.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final canonical = tokens.join(' ');
    final running = _dpi;
    if (running != null && running.alive) {
      if (running.args == canonical) return running.port;
      _dpi = null;
      await _kill(running, 'ciadpi');
    }
    final bin = _program('ciadpi');
    if (!_runnable(bin)) throw NetworkError('Anti-DPI is not available on this machine (no ciadpi in ${_bin.path})');
    await _data.create(recursive: true);
    final port = await _freePort();
    final p = await Process.start(bin.path, ['-i', '127.0.0.1', '-p', '$port', ...tokens]);
    final out = _Output(p);
    final deadline = DateTime.now().add(antiDpiWait);
    var up = false;
    while (DateTime.now().isBefore(deadline)) {
      if (await _exited(p)) break;
      if (await _accepts(port)) {
        up = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    if (!up) {
      final died = await _exited(p);
      p.kill(ProcessSignal.sigkill);
      throw NetworkError('Anti-DPI did not start${died ? ': ${await out.tailOfEnded(3)}' : ' in time'}');
    }
    final r = _Running(p, port, canonical);
    _dpi = r;
    _remember('ciadpi', p.pid);
    unawaited(_watch('antiDpi', r));
    return port;
  }

  @override
  Future<void> stopAntiDpi() => _serial(() async {
    final r = _dpi;
    _dpi = null;
    await _kill(r, 'ciadpi');
  });

  // ── process helpers ──

  Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  Future<bool> _accepts(int port) async {
    try {
      (await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 200))).destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether [p] has ended (checked without waiting for it).
  Future<bool> _exited(Process p) async => await p.exitCode.timeout(const Duration(milliseconds: 30), onTimeout: () => -999) != -999;

  Future<void> _watch(String mode, _Running r) async {
    final code = await r.process.exitCode;
    r.markDead();
    final current = mode == 'warp' ? _warp : _dpi;
    if (identical(current, r) && !_stopping) {
      if (mode == 'warp') {
        _warp = null;
      } else {
        _dpi = null;
      }
      _exits.add(ModeExit(mode, 'the program stopped (exit code $code)'));
    }
  }

  Future<void> _kill(_Running? r, String name) async {
    if (r == null) return;
    _stopping = true;
    try {
      r.process.kill();
      await r.process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          r.process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } finally {
      _stopping = false;
      _forget(name);
    }
  }

  String _tail(String text) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return lines.isEmpty ? 'no output' : lines.skip(lines.length > 2 ? lines.length - 2 : 0).join(' | ');
  }

  // A program left by a crashed earlier run would hold a port and a tunnel: its pid is written down and checked at the next start.
  File _pidFile(String name) => File('${_data.path}/$name.pid');

  void _remember(String name, int pid) {
    try {
      _data.createSync(recursive: true);
      _pidFile(name).writeAsStringSync('$pid');
    } catch (_) {}
  }

  void _forget(String name) {
    try {
      final f = _pidFile(name);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Future<void> _killStale() async {
    for (final name in const ['usque', 'ciadpi']) {
      try {
        final f = _pidFile(name);
        if (!f.existsSync()) continue;
        final pid = int.tryParse(f.readAsStringSync().trim());
        if (pid != null) {
          final cmd = File('/proc/$pid/cmdline');
          if (cmd.existsSync() && utf8.decode(cmd.readAsBytesSync(), allowMalformed: true).contains(name)) Process.killPid(pid, ProcessSignal.sigkill);
        }
        f.deleteSync();
      } catch (_) {}
    }
  }
}

extension on String {
  Directory asDir() => Directory(this);
}

class _Running {
  _Running(this.process, this.port, this.args);
  final Process process;
  final int port;
  final String args;
  bool get alive => !_dead;
  bool _dead = false;
  void markDead() => _dead = true;
}

/// A started program's output: the last lines, and a wait for one that matches.
class _Output {
  _Output(Process p) {
    final done = <Future<void>>[];
    for (final s in [p.stdout, p.stderr]) {
      final sub = s.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        _lines.add(l.length > 200 ? l.substring(0, 200) : l);
        if (_lines.length > 8) _lines.removeAt(0);
        for (final w in List.of(_waiters)) {
          if (w.$1(l)) w.$2.complete(true);
        }
      }, onError: (_) {});
      done.add(sub.asFuture<void>().catchError((Object _) {}));
    }
    _done = Future.wait(done);
  }

  final _lines = <String>[];
  final _waiters = <(bool Function(String), Completer<bool>)>[];
  late final Future<List<void>> _done;

  /// The last [n] lines, once a program that has ended has delivered what it said (a moment at most).
  Future<String> tailOfEnded(int n) async {
    await _done.timeout(const Duration(milliseconds: 500), onTimeout: () => const []);
    return tail(n);
  }

  String tail(int n) => _lines.isEmpty ? 'no output' : _lines.skip(_lines.length > n ? _lines.length - n : 0).join(' | ');

  /// True when a line matching [test] shows up within [wait] (also if it already did); false when the time runs out or [p] ends first.
  Future<bool> waitFor(bool Function(String) test, Duration wait, Process p) async {
    if (_lines.any(test)) return true;
    final c = Completer<bool>();
    _waiters.add((test, c));
    unawaited(
      p.exitCode.then((_) {
        if (!c.isCompleted) c.complete(_lines.any(test));
      }),
    );
    return c.future.timeout(wait, onTimeout: () => false);
  }
}
