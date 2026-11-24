import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_settings.dart';
import '../server_config.dart';
import 'anti_dpi_presets.dart';
import 'dns_providers.dart';
import 'local_gateway.dart';
import 'net_state.dart';
import 'network_channel.dart';
import 'network_route.dart';

enum ModePhase { off, starting, active, failed }

/// The live condition of WARP or of Anti-DPI (specs/001-warp-doh-anti-dpi/data-model.md). Not saved.
@immutable
class ModeState {
  const ModeState(this.phase, {this.reason});
  final ModePhase phase;
  final String? reason;
  static const off = ModeState(ModePhase.off);
  static const starting = ModeState(ModePhase.starting);
  static const active = ModeState(ModePhase.active);
  const ModeState.failed(String this.reason) : phase = ModePhase.failed;
  @override
  bool operator ==(Object other) => other is ModeState && other.phase == phase && other.reason == reason;
  @override
  int get hashCode => Object.hash(phase, reason);
}

/// Starts the local gateway; replaced in tests.
Future<GatewayHandle> _realGateway({required NetworkRoute route, List<String> dohEndpoints = const []}) =>
    LocalGateway.start(route: route, dohEndpoints: dohEndpoints);

typedef GatewayStarter = Future<GatewayHandle> Function({required NetworkRoute route, List<String> dohEndpoints});

/// WARP, Secure DNS and Anti-DPI: the saved choices, the live state of each program, and the route and DNS the rest of the app follows.
/// WARP and Anti-DPI exclude each other; a failure always returns the setting to off and the route to direct; the last choice wins.
class NetworkModes {
  NetworkModes({
    NetworkPlatform? platform,
    GatewayStarter? startGateway,
    this.warpTimeout = const Duration(seconds: 30),
    this.antiDpiTimeout = const Duration(seconds: 5),
  }) : _platform = platform ?? defaultNetworkPlatform(),
       _startGateway = startGateway ?? _realGateway {
    _exitSub = _platform.exits.listen(_onExit);
  }

  /// The one the app uses.
  static NetworkModes instance = NetworkModes();

  final NetworkPlatform _platform;
  final GatewayStarter _startGateway;
  final Duration warpTimeout, antiDpiTimeout;
  StreamSubscription<ModeExit>? _exitSub;

  final warp = ValueNotifier<ModeState>(ModeState.off);
  final antiDpi = ValueNotifier<ModeState>(ModeState.off);

  /// Where the app's traffic goes now.
  final route = ValueNotifier<NetworkRoute>(NetworkRoute.direct);

  /// What this device can run; null until asked.
  final capabilities = ValueNotifier<NetworkCapabilities?>(null);

  /// Sentences for the viewer: what just happened (connecting, failed, turned off…).
  final _messages = StreamController<String>.broadcast(sync: true);
  Stream<String> get messages => _messages.stream;

  GatewayHandle? _gateway;
  NetworkRoute? _gatewayRoute;
  List<String>? _gatewayDoh;
  int _warpGen = 0, _dpiGen = 0, _gatewayGen = 0;

  void _say(String m) {
    if (!_messages.isClosed) _messages.add(m);
  }

  /// Finds out what the device can run (Settings asks when it opens, in case the start-up check has not finished).
  Future<void> refreshCapabilities() async {
    try {
      capabilities.value = await _platform.capabilities();
    } catch (_) {}
  }

  // ── what the rest of the app reads ──

  /// The Secure DNS endpoints in use: none when Off, when the choice is incomplete, or while WARP resolves names itself.
  List<String> get dohEndpoints => route.value is HttpProxyRoute ? const [] : dnsEndpointsFor(AppSettings.netDoh.value, AppSettings.netDohUrl.value);

  /// The gateway's port when the app's own HTTP clients must go through it (a route is active); null otherwise.
  int? get dartProxyPort => route.value is DirectRoute || _serverOnly ? null : _gateway?.port;

  /// WARP carries VyseTV's own server only (the "VyseTV server only" switch): the rest of the app goes straight out.
  bool get _serverOnly => route.value is HttpProxyRoute && AppSettings.netWarpServerOnly.value;

  /// The gateway's port for native players (a route is active or Secure DNS is on); null when they can go straight out.
  int? get gatewayPort => _serverOnly ? null : _gateway?.port;

  // ── WARP ──

  Future<void> setWarp(bool on) async {
    final gen = ++_warpGen;
    if (!on) {
      AppSettings.netWarp.set(false);
      if (warp.value.phase == ModePhase.active || warp.value.phase == ModePhase.starting) _say('WARP disconnected');
      warp.value = ModeState.off;
      await _stopWarp();
      if (gen == _warpGen) await _applyRouteSaying();
      return;
    }
    AppSettings.netWarp.set(true);
    if (antiDpi.value.phase != ModePhase.off || AppSettings.netAntiDpi.value) {
      await _turnAntiDpiOff();
      _say("Anti-DPI turned off: it can't run together with WARP");
    }
    if (gen != _warpGen) return;
    warp.value = ModeState.starting;
    _say('Connecting to Cloudflare WARP…');
    try {
      final port = await _platform.startWarp().timeout(warpTimeout, onTimeout: () => throw NetworkError('timed out'));
      if (gen != _warpGen) {
        // switched again while starting: the later choice wins
        if (!AppSettings.netWarp.value) await _stopWarp();
        return;
      }
      route.value = HttpProxyRoute(port);
      warp.value = ModeState.active;
      final bad = await _applyRoute();
      if (gen != _warpGen) return;
      if (bad != null) return await _fail(warp, AppSettings.netWarp, 'WARP error: $bad', bad, _stopWarp);
      _say('WARP connected');
    } catch (e) {
      if (gen != _warpGen) return;
      await _fail(warp, AppSettings.netWarp, 'WARP error: ${_why(e)}', _why(e), _stopWarp);
    }
  }

  /// Switches WARP between carrying everything and carrying only VyseTV's own server.
  Future<void> setWarpServerOnly(bool on) async {
    AppSettings.netWarpServerOnly.set(on);
    await _applyRouteSaying();
  }

  Future<void> _stopWarp() async {
    try {
      await _platform.stopWarp();
    } catch (_) {}
    if (route.value is HttpProxyRoute) route.value = NetworkRoute.direct;
  }

  // ── Anti-DPI ──

  Future<void> setAntiDpi(bool on) async {
    final gen = ++_dpiGen;
    if (!on) {
      AppSettings.netAntiDpi.set(false);
      if (antiDpi.value.phase == ModePhase.active || antiDpi.value.phase == ModePhase.starting) _say('Anti-DPI stopped');
      antiDpi.value = ModeState.off;
      await _stopAntiDpi();
      if (gen == _dpiGen) await _applyRouteSaying();
      return;
    }
    final bad = validateAntiDpiArgs(AppSettings.netAntiDpiArgs.value);
    if (bad != null) {
      AppSettings.netAntiDpi.set(false);
      antiDpi.value = ModeState.failed(bad);
      _say('Anti-DPI error: $bad');
      return;
    }
    AppSettings.netAntiDpi.set(true);
    if (warp.value.phase != ModePhase.off || AppSettings.netWarp.value) {
      await _turnWarpOff();
      _say("WARP turned off: it can't run together with Anti-DPI");
    }
    if (gen != _dpiGen) return;
    antiDpi.value = ModeState.starting;
    _say('Starting Anti-DPI…');
    try {
      final port = await _platform
          .startAntiDpi(antiDpiArgsFor(AppSettings.netAntiDpiPreset.value, AppSettings.netAntiDpiArgs.value))
          .timeout(antiDpiTimeout, onTimeout: () => throw NetworkError('timed out'));
      if (gen != _dpiGen) {
        if (!AppSettings.netAntiDpi.value) await _stopAntiDpi();
        return;
      }
      route.value = SocksRoute(port);
      antiDpi.value = ModeState.active;
      final bad = await _applyRoute();
      if (gen != _dpiGen) return;
      if (bad != null) return await _fail(antiDpi, AppSettings.netAntiDpi, 'Anti-DPI error: $bad', bad, _stopAntiDpi);
      _say('Anti-DPI active');
    } catch (e) {
      if (gen != _dpiGen) return;
      await _fail(antiDpi, AppSettings.netAntiDpi, 'Anti-DPI error: ${_why(e)}', _why(e), _stopAntiDpi);
    }
  }

  Future<void> _stopAntiDpi() async {
    try {
      await _platform.stopAntiDpi();
    } catch (_) {}
    if (route.value is SocksRoute) route.value = NetworkRoute.direct;
  }

  /// Picks a preset; restarts Anti-DPI with it when it is running. Clears hand-edited parameters.
  Future<void> setAntiDpiPreset(String id) async {
    AppSettings.netAntiDpiPreset.set(antiDpiPresetById(id).id);
    AppSettings.netAntiDpiArgs.set('');
    await _restartAntiDpi('Anti-DPI restarted with the new settings');
  }

  /// Saves hand-edited parameters ('' = the preset's); returns why they were refused, or null. Restarts Anti-DPI when running.
  Future<String?> setAntiDpiArgs(String args) async {
    final bad = validateAntiDpiArgs(args);
    if (bad != null) return bad;
    AppSettings.netAntiDpiArgs.set(args.trim());
    if (args.trim().isNotEmpty) AppSettings.netAntiDpiPreset.set('custom');
    if (args.trim().isEmpty && AppSettings.netAntiDpiPreset.value == 'custom') AppSettings.netAntiDpiPreset.set(defaultAntiDpiPresetId);
    _say('Parameters saved');
    await _restartAntiDpi('Anti-DPI restarted with the new settings');
    return null;
  }

  Future<void> resetAntiDpiArgs() async {
    AppSettings.netAntiDpiArgs.set('');
    AppSettings.netAntiDpiPreset.set(defaultAntiDpiPresetId);
    await _restartAntiDpi('Anti-DPI restarted with the recommended settings');
  }

  Future<void> _restartAntiDpi(String doneMessage) async {
    if (antiDpi.value.phase != ModePhase.active) return;
    await setAntiDpi(true);
    if (antiDpi.value.phase == ModePhase.active) _say(doneMessage);
  }

  Future<void> _turnAntiDpiOff() async {
    _dpiGen++;
    AppSettings.netAntiDpi.set(false);
    antiDpi.value = ModeState.off;
    await _stopAntiDpi();
  }

  Future<void> _turnWarpOff() async {
    _warpGen++;
    AppSettings.netWarp.set(false);
    warp.value = ModeState.off;
    await _stopWarp();
  }

  // ── Secure DNS ──

  /// Chooses a provider ('off', 'cloudflare', 'google', 'adguard' or 'custom'); applies at once.
  Future<void> setDoh(String id) async {
    AppSettings.netDoh.set(dnsProviderById(id).id);
    await _applyRouteSaying();
  }

  /// Saves a custom resolver address and chooses Custom; returns why it was refused (the previous setting is kept), or null.
  Future<String?> setCustomDoh(String url) async {
    final bad = validateCustomDohUrl(url);
    if (bad != null) return bad;
    AppSettings.netDohUrl.set(url.trim());
    AppSettings.netDoh.set('custom');
    _say('Custom DNS applied');
    await _applyRouteSaying();
    return null;
  }

  // ── failure, exit, restore ──

  Future<void> _fail(ValueNotifier<ModeState> state, Setting<bool> setting, String message, String reason, Future<void> Function() stop) async {
    setting.set(false);
    state.value = ModeState.failed(reason);
    _say(message);
    await stop();
    await _applyRouteSaying();
  }

  void _onExit(ModeExit e) {
    if (e.mode == 'warp' && warp.value.phase == ModePhase.active) {
      unawaited(_fail(warp, AppSettings.netWarp, 'WARP stopped: ${e.reason}', e.reason, _stopWarp));
    } else if (e.mode == 'antiDpi' && antiDpi.value.phase == ModePhase.active) {
      unawaited(_fail(antiDpi, AppSettings.netAntiDpi, 'Anti-DPI stopped: ${e.reason}', e.reason, _stopAntiDpi));
    }
  }

  /// At app start: finds out what the device can run and brings back the saved modes. Never throws; a failure is reported and the
  /// app carries on on its normal route.
  Future<void> restore() async {
    try {
      final caps = capabilities.value = await _platform.capabilities();
      if (AppSettings.netWarp.value && AppSettings.netAntiDpi.value) {
        AppSettings.netAntiDpi.set(false); // both saved (a restored copy): WARP wins
        _say("Anti-DPI turned off: it can't run together with WARP");
      }
      if (AppSettings.netWarp.value) {
        if (caps.warp) {
          await setWarp(true);
        } else {
          warp.value = const ModeState.failed('Not available on this device');
        }
      } else if (AppSettings.netAntiDpi.value) {
        if (caps.antiDpi) {
          await setAntiDpi(true);
        } else {
          antiDpi.value = const ModeState.failed('Not available on this device');
        }
      }
      await _applyRouteSaying();
    } catch (e) {
      _say('Network modes: ${_why(e)}');
    }
  }

  /// Makes the gateway match the route and the DNS choice: running while a route is active or Secure DNS is on, with native players
  /// pointed at it; stopped (and the players released) otherwise.
  Future<String?> _applyRoute() async {
    final bad = await _applyRouteCore();
    _publish();
    return bad;
  }

  /// Tells the HTTP clients (this isolate's [NetState]) where to go now.
  void _publish() {
    NetState.proxyPort = dartProxyPort;
    NetState.serverHost = Uri.parse(accountServer).host;
    NetState.serverPort = _serverOnly ? _gateway?.port : null;
    NetState.doh = dohEndpoints;
  }

  Future<String?> _applyRouteCore() async {
    final gen = ++_gatewayGen;
    final r = route.value;
    final doh = dohEndpoints;
    final needed = r is! DirectRoute || doh.isNotEmpty;
    if (!needed) {
      await _dropGateway();
      return null;
    }
    if (_gateway != null && _gatewayRoute == r && listEquals(_gatewayDoh, doh)) {
      await _platform.setProxy(_serverOnly ? null : _gateway!.port); // (the scope may have changed)
      return null;
    }
    await _dropGateway();
    try {
      final g = await _startGateway(route: r, dohEndpoints: doh);
      if (gen != _gatewayGen) {
        await g.stop(); // changed again while starting
        return null;
      }
      _gateway = g;
      _gatewayRoute = r;
      _gatewayDoh = doh;
      await _platform.setProxy(_serverOnly ? null : g.port);
      return null;
    } catch (e) {
      // no gateway: the app keeps its normal route rather than a broken one
      route.value = NetworkRoute.direct;
      return 'the local proxy could not start (${_why(e)})';
    }
  }

  /// [_applyRoute] for callers that have no mode to fail: a problem is only reported.
  Future<void> _applyRouteSaying() async {
    final bad = await _applyRoute();
    if (bad != null) _say('Network modes: $bad');
  }

  Future<void> _dropGateway() async {
    final g = _gateway;
    _gateway = null;
    _gatewayRoute = null;
    _gatewayDoh = null;
    try {
      await _platform.setProxy(null);
    } catch (_) {}
    await g?.stop();
  }

  String _why(Object e) => e is NetworkError ? e.message : e.toString().replaceFirst(RegExp(r'^[A-Za-z]*(Exception|Error): '), '').split('\n').first;

  @visibleForTesting
  Future<void> dispose() async {
    await _exitSub?.cancel();
    await _dropGateway();
    await _messages.close();
  }
}
