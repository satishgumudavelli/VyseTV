import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'desktop_network_platform.dart';

/// What this device can run (a binary for its CPU is in the app).
class NetworkCapabilities {
  const NetworkCapabilities({this.warp = false, this.antiDpi = false, this.dns = false});

  /// WARP and Anti-DPI need their program for this CPU; Secure DNS only needs the platform to carry the gateway (Android).
  final bool warp, antiDpi, dns;
  static const none = NetworkCapabilities();
}

/// A mode failed with a sentence fit to show.
class NetworkError implements Exception {
  NetworkError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A running mode's program died by itself.
class ModeExit {
  const ModeExit(this.mode, this.reason);
  final String mode; // 'warp' or 'antiDpi'
  final String reason;
}

/// What the controller needs from the platform (specs/001-warp-doh-anti-dpi/contracts/native-channel.md); fakeable in tests.
abstract class NetworkPlatform {
  Future<NetworkCapabilities> capabilities();
  Future<int> startWarp();
  Future<void> stopWarp();
  Future<int> startAntiDpi(String args);
  Future<void> stopAntiDpi();

  /// Point the platform's HTTP stack (ExoPlayer) at the local gateway, or clear it with null.
  Future<void> setProxy(int? port);
  Stream<ModeExit> get exits;
}

/// No programs here (Linux, Windows, Apple, tests): every mode is unavailable.
class NoNetworkPlatform implements NetworkPlatform {
  const NoNetworkPlatform();
  @override
  Future<NetworkCapabilities> capabilities() async => NetworkCapabilities.none;
  @override
  Future<int> startWarp() => Future.error(NetworkError('Not available on this device'));
  @override
  Future<void> stopWarp() async {}
  @override
  Future<int> startAntiDpi(String args) => Future.error(NetworkError('Not available on this device'));
  @override
  Future<void> stopAntiDpi() async {}
  @override
  Future<void> setProxy(int? port) async {}
  @override
  Stream<ModeExit> get exits => const Stream.empty();
}

/// The Android implementation: channel `vyse/network` (NetworkModesPlugin.kt).
class AndroidNetworkPlatform implements NetworkPlatform {
  AndroidNetworkPlatform() {
    try {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'onModeEvent' && call.arguments is Map) {
          final a = call.arguments as Map;
          _exits.add(ModeExit('${a['mode']}', '${a['reason'] ?? 'stopped'}'));
        }
        return null;
      });
    } catch (_) {
      // a background isolate has no channels: it only reads NetState, and never needs this
    }
  }
  static const _ch = MethodChannel('vyse/network');
  final _exits = StreamController<ModeExit>.broadcast();

  Future<T?> _call<T>(String m, [Object? args]) async {
    try {
      return await _ch.invokeMethod<T>(m, args);
    } on PlatformException catch (e) {
      throw NetworkError(e.message ?? 'Failed (${e.code})');
    } on MissingPluginException {
      throw NetworkError('Not available on this device');
    }
  }

  @override
  Future<NetworkCapabilities> capabilities() async {
    try {
      final r = await _call<Map>('capabilities');
      return NetworkCapabilities(warp: r?['warp'] == true, antiDpi: r?['antiDpi'] == true, dns: r != null);
    } catch (_) {
      return NetworkCapabilities.none;
    }
  }

  @override
  Future<int> startWarp() async => ((await _call<Map>('startWarp'))?['port'] as num?)?.toInt() ?? (throw NetworkError('WARP gave no port'));
  @override
  Future<void> stopWarp() async => _call<Object>('stopWarp');
  @override
  Future<int> startAntiDpi(String args) async =>
      ((await _call<Map>('startAntiDpi', {'args': args}))?['port'] as num?)?.toInt() ?? (throw NetworkError('Anti-DPI gave no port'));
  @override
  Future<void> stopAntiDpi() async => _call<Object>('stopAntiDpi');
  @override
  Future<void> setProxy(int? port) async =>
      _call<Object>('setProxy', {'host': port == null ? null : '127.0.0.1', 'port': port, 'kind': port == null ? null : 'http'});
  @override
  Stream<ModeExit> get exits => _exits.stream;
}

/// The platform for this device: Android's plugin on Android, the programs run directly on Linux, none elsewhere.
NetworkPlatform defaultNetworkPlatform() => Platform.isAndroid
    ? AndroidNetworkPlatform()
    : Platform.isLinux
    ? DesktopNetworkPlatform()
    : const NoNetworkPlatform();
