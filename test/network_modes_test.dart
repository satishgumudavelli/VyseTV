import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/network/anti_dpi_presets.dart';
import 'package:vyse_tv/data/network/local_gateway.dart';
import 'package:vyse_tv/data/network/network_channel.dart';
import 'package:vyse_tv/data/network/net_state.dart';
import 'package:vyse_tv/data/network/network_modes.dart';
import 'package:vyse_tv/data/network/network_route.dart';

class _FakePlatform implements NetworkPlatform {
  NetworkCapabilities caps = const NetworkCapabilities(warp: true, antiDpi: true, dns: true);
  Object? capsError;
  Object? warpError, dpiError;
  Duration warpDelay = Duration.zero;
  Completer<int>? warpHang;
  int warpPort = 4101, dpiPort = 4202;
  final calls = <String>[];
  final proxies = <int?>[];
  final exitsC = StreamController<ModeExit>.broadcast();

  @override
  Future<NetworkCapabilities> capabilities() async {
    if (capsError != null) throw capsError!;
    return caps;
  }

  @override
  Future<int> startWarp() async {
    calls.add('startWarp');
    if (warpHang != null) return warpHang!.future;
    await Future<void>.delayed(warpDelay);
    if (warpError != null) throw warpError!;
    return warpPort;
  }

  @override
  Future<void> stopWarp() async => calls.add('stopWarp');
  @override
  Future<int> startAntiDpi(String args) async {
    calls.add('startAntiDpi $args');
    if (dpiError != null) throw dpiError!;
    return dpiPort;
  }

  @override
  Future<void> stopAntiDpi() async => calls.add('stopAntiDpi');
  @override
  Future<void> setProxy(int? port) async => proxies.add(port);
  @override
  Stream<ModeExit> get exits => exitsC.stream;
}

class _FakeGateway implements GatewayHandle {
  _FakeGateway(this.port, this.route, this.doh);
  @override
  final int port;
  final NetworkRoute route;
  final List<String> doh;
  bool stopped = false;
  @override
  Future<void> stop() async => stopped = true;
}

void main() {
  late _FakePlatform platform;
  late List<_FakeGateway> gateways;
  late NetworkModes modes;
  late List<String> said;
  Object? gatewayError;

  setUp(() {
    for (final s in [AppSettings.netWarp, AppSettings.netAntiDpi]) {
      s.value = false;
    }
    AppSettings.netDoh.value = 'off';
    AppSettings.netDohUrl.value = '';
    AppSettings.netAntiDpiPreset.value = 'split_disorder';
    AppSettings.netAntiDpiArgs.value = '';
    platform = _FakePlatform();
    gateways = [];
    gatewayError = null;
    modes = NetworkModes(
      platform: platform,
      warpTimeout: const Duration(milliseconds: 300),
      antiDpiTimeout: const Duration(milliseconds: 300),
      startGateway: ({required route, dohEndpoints = const []}) async {
        if (gatewayError != null) throw gatewayError!;
        final g = _FakeGateway(9000 + gateways.length, route, dohEndpoints);
        gateways.add(g);
        return g;
      },
    );
    said = [];
    modes.messages.listen(said.add);
  });
  tearDown(() => modes.dispose());

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  group('WARP', () {
    test('on: starting, then active with the route and the gateway; off: back to direct', () async {
      final states = <ModePhase>[];
      modes.warp.addListener(() => states.add(modes.warp.value.phase));
      await modes.setWarp(true);
      await settle();
      expect(states, [ModePhase.starting, ModePhase.active]);
      expect(modes.route.value, const HttpProxyRoute(4101));
      expect(AppSettings.netWarp.value, isTrue);
      expect(gateways.single.route, const HttpProxyRoute(4101));
      expect(modes.gatewayPort, 9000);
      expect(modes.dartProxyPort, 9000);
      expect(platform.proxies.last, 9000);
      expect(NetState.proxyPort, 9000); // what the HTTP clients read (also handed to background isolates)
      expect(said, ['Connecting to Cloudflare WARP…', 'WARP connected']);

      await modes.setWarp(false);
      expect(modes.warp.value, ModeState.off);
      expect(AppSettings.netWarp.value, isFalse);
      expect(modes.route.value, isA<DirectRoute>());
      expect(modes.dartProxyPort, isNull);
      expect(platform.proxies.last, isNull);
      expect(NetState.proxyPort, isNull);
      expect(gateways.single.stopped, isTrue);
      expect(said.last, 'WARP disconnected');
    });

    test('server only: the gateway runs, but only VyseTV\'s own server uses it; players and the rest go direct', () async {
      await modes.setWarp(true);
      await modes.setWarpServerOnly(true);
      expect(modes.dartProxyPort, isNull);
      expect(modes.gatewayPort, isNull);
      expect(platform.proxies.last, isNull);
      expect(NetState.proxyPort, isNull);
      expect(NetState.serverPort, 9000);
      await modes.setWarpServerOnly(false);
      expect(NetState.serverPort, isNull);
      expect(NetState.proxyPort, 9000);
      expect(platform.proxies.last, 9000);
      await modes.setWarp(false);
    });

    test('a failure returns the switch to off and the route to direct, with a sentence', () async {
      platform.warpError = NetworkError('Cloudflare did not answer');
      await modes.setWarp(true);
      expect(modes.warp.value, const ModeState.failed('Cloudflare did not answer'));
      expect(AppSettings.netWarp.value, isFalse);
      expect(modes.route.value, isA<DirectRoute>());
      expect(gateways, isEmpty);
      expect(said.last, 'WARP error: Cloudflare did not answer');
    });

    test('no answer in time is a failure too', () async {
      platform.warpHang = Completer<int>();
      await modes.setWarp(true);
      expect(modes.warp.value, const ModeState.failed('timed out'));
      expect(AppSettings.netWarp.value, isFalse);
    });

    test('the last choice wins when switched quickly', () async {
      platform.warpDelay = const Duration(milliseconds: 80);
      final on = modes.setWarp(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final off = modes.setWarp(false);
      await Future.wait([on, off]);
      await settle();
      expect(modes.warp.value, ModeState.off);
      expect(AppSettings.netWarp.value, isFalse);
      expect(modes.route.value, isA<DirectRoute>());
      expect(platform.calls.last, 'stopWarp');
      expect(gateways.where((g) => !g.stopped), isEmpty);
    });

    test('the program dying by itself is a failure: switch off, route direct', () async {
      await modes.setWarp(true);
      platform.exitsC.add(const ModeExit('warp', 'the tunnel closed'));
      await settle();
      expect(modes.warp.value, const ModeState.failed('the tunnel closed'));
      expect(AppSettings.netWarp.value, isFalse);
      expect(modes.route.value, isA<DirectRoute>());
      expect(said.last, 'WARP stopped: the tunnel closed');
    });

    test('a gateway that cannot start leaves the app on its normal route', () async {
      gatewayError = StateError('no port');
      await modes.setWarp(true);
      expect(modes.route.value, isA<DirectRoute>());
      expect(modes.dartProxyPort, isNull);
      expect(modes.warp.value.phase, ModePhase.failed); // not "active" while the app is really on its normal route
      expect(AppSettings.netWarp.value, isFalse);
      expect(platform.calls.last, 'stopWarp');
      expect(said.last, startsWith('WARP error: the local proxy could not start'));
      expect(said, isNot(contains('WARP connected')));
    });
  });

  group('Anti-DPI', () {
    test('on: starts with the recommended parameters; the route is SOCKS; off stops it', () async {
      await modes.setAntiDpi(true);
      expect(platform.calls, ['startAntiDpi $defaultAntiDpiArgs']);
      expect(modes.antiDpi.value, ModeState.active);
      expect(modes.route.value, const SocksRoute(4202));
      expect(said, ['Starting Anti-DPI…', 'Anti-DPI active']);
      await modes.setAntiDpi(false);
      expect(modes.route.value, isA<DirectRoute>());
      expect(said.last, 'Anti-DPI stopped');
    });

    test('a preset or new parameters restart it while it runs; refused parameters change nothing', () async {
      await modes.setAntiDpi(true);
      await modes.setAntiDpiPreset('split');
      expect(platform.calls.last, 'startAntiDpi --split 1');
      expect(said.last, 'Anti-DPI restarted with the new settings');
      expect(await modes.setAntiDpiArgs('-p 80'), isNotNull);
      expect(AppSettings.netAntiDpiArgs.value, '');
      expect(await modes.setAntiDpiArgs('--split 2'), isNull);
      expect(platform.calls.last, 'startAntiDpi --split 2');
      expect(AppSettings.netAntiDpiPreset.value, 'custom');
      await modes.resetAntiDpiArgs();
      expect(platform.calls.last, 'startAntiDpi $defaultAntiDpiArgs');
      expect(AppSettings.netAntiDpiArgs.value, '');
      expect(AppSettings.netAntiDpiPreset.value, 'split_disorder');
    });

    test('a start failure leaves it off and the app on its normal route', () async {
      platform.dpiError = NetworkError('could not start');
      await modes.setAntiDpi(true);
      expect(modes.antiDpi.value, const ModeState.failed('could not start'));
      expect(AppSettings.netAntiDpi.value, isFalse);
      expect(modes.route.value, isA<DirectRoute>());
      expect(said.last, 'Anti-DPI error: could not start');
    });

    test('parameters that cannot run are refused before anything starts', () async {
      AppSettings.netAntiDpiArgs.value = '--port 1';
      await modes.setAntiDpi(true);
      expect(platform.calls, isEmpty);
      expect(modes.antiDpi.value.phase, ModePhase.failed);
      expect(AppSettings.netAntiDpi.value, isFalse);
    });
  });

  group('WARP and Anti-DPI exclude each other', () {
    test('turning one on turns the other off and says so', () async {
      await modes.setAntiDpi(true);
      await modes.setWarp(true);
      expect(modes.antiDpi.value, ModeState.off);
      expect(AppSettings.netAntiDpi.value, isFalse);
      expect(modes.warp.value, ModeState.active);
      expect(modes.route.value, isA<HttpProxyRoute>());
      expect(said, contains("Anti-DPI turned off: it can't run together with WARP"));
      await modes.setAntiDpi(true);
      expect(modes.warp.value, ModeState.off);
      expect(AppSettings.netWarp.value, isFalse);
      expect(modes.route.value, isA<SocksRoute>());
      expect(said, contains("WARP turned off: it can't run together with Anti-DPI"));
    });
  });

  group('Secure DNS', () {
    test('a provider applies at once: the gateway carries it for the players; Off releases them', () async {
      await modes.setDoh('cloudflare');
      expect(modes.dohEndpoints.first, 'https://cloudflare-dns.com/dns-query');
      expect(NetState.doh, modes.dohEndpoints);
      expect(gateways.single.doh, modes.dohEndpoints);
      expect(modes.gatewayPort, 9000);
      expect(modes.dartProxyPort, isNull); // Dart's own clients resolve in process while the route is direct
      expect(platform.proxies.last, 9000);
      await modes.setDoh('off');
      expect(modes.dohEndpoints, isEmpty);
      expect(modes.gatewayPort, isNull);
      expect(platform.proxies.last, isNull);
    });

    test('custom: refused when invalid (previous kept), applied when valid', () async {
      await modes.setDoh('google');
      expect(await modes.setCustomDoh('abc'), 'Enter a full https:// address');
      expect(AppSettings.netDoh.value, 'google');
      expect(await modes.setCustomDoh('https://dns.example/dns-query'), isNull);
      expect(AppSettings.netDoh.value, 'custom');
      expect(modes.dohEndpoints, ['https://dns.example/dns-query']);
      expect(said.last, 'Custom DNS applied');
    });

    test('while WARP is on the choice is kept but not applied; it applies again after WARP', () async {
      await modes.setDoh('cloudflare');
      await modes.setWarp(true);
      expect(AppSettings.netDoh.value, 'cloudflare');
      expect(modes.dohEndpoints, isEmpty);
      expect(gateways.last.doh, isEmpty);
      await modes.setWarp(false);
      expect(modes.dohEndpoints, isNotEmpty);
      expect(gateways.last.doh, modes.dohEndpoints);
    });
  });

  group('restore at start', () {
    test('a saved WARP comes back', () async {
      AppSettings.netWarp.value = true;
      await modes.restore();
      expect(modes.warp.value, ModeState.active);
      expect(modes.route.value, const HttpProxyRoute(4101));
      expect(modes.capabilities.value!.warp, isTrue);
    });

    test('a saved mode this device cannot run is shown as unavailable, never throws, keeps the saved choice', () async {
      platform.caps = NetworkCapabilities.none;
      AppSettings.netWarp.value = true;
      await modes.restore();
      expect(modes.warp.value, const ModeState.failed('Not available on this device'));
      expect(AppSettings.netWarp.value, isTrue);
      expect(modes.route.value, isA<DirectRoute>());
      expect(platform.calls, isEmpty);
    });

    test('both saved (a restored copy): WARP wins, Anti-DPI is stored off', () async {
      AppSettings.netWarp.value = true;
      AppSettings.netAntiDpi.value = true;
      await modes.restore();
      expect(AppSettings.netAntiDpi.value, isFalse);
      expect(modes.warp.value, ModeState.active);
      expect(platform.calls.where((c) => c.startsWith('startAntiDpi')), isEmpty);
    });

    test('a start that fails is reported, not thrown; Secure DNS comes back too', () async {
      platform.warpError = NetworkError('offline');
      AppSettings.netWarp.value = true;
      AppSettings.netDoh.value = 'google';
      await modes.restore();
      expect(modes.warp.value.phase, ModePhase.failed);
      expect(modes.route.value, isA<DirectRoute>());
      expect(modes.dohEndpoints, isNotEmpty);
      expect(modes.gatewayPort, isNotNull);
    });

    test('a platform that cannot even answer does not break the start', () async {
      platform.capsError = StateError('channel gone');
      await modes.restore();
      expect(said.last, startsWith('Network modes:'));
    });
  });
}
