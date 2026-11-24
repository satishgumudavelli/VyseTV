import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'network/dns_providers.dart';
import 'network/net_state.dart';
import 'network/network_route.dart';

/// HTTP client for hosts the local network may block. It uses the system resolver first; when
/// that answers with a sinkhole (0.0.0.0, 127.x) or the address can't be reached, it looks the
/// host up over Cloudflare DNS-over-HTTPS and connects to that address instead (TLS still
/// verifies the real hostname). Names that spell out their address (sslip.io and nip.io
/// names) go straight to it before asking anyone.
///
/// Network modes (data/network/network_modes.dart) steer it: with a route active (WARP or Anti-DPI) the client talks to the local
/// gateway as an ordinary proxy (except for this device and its local network); with Secure DNS chosen, names are looked up over
/// that provider first and the system resolver is the fallback.
final http.Client netClient = IOClient(
  HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 20)
    ..findProxy = _findProxy
    ..connectionFactory = _connect,
);

/// The proxy for [uri]: the local gateway while a network mode has a route, otherwise a direct connection; this device and its local
/// network always go direct.
String _findProxy(Uri uri) {
  final port = NetState.proxyPort ?? (uri.host == NetState.serverHost ? NetState.serverPort : null);
  return port == null || isLocalHost(uri.host) ? 'DIRECT' : 'PROXY 127.0.0.1:$port';
}

/// A fresh client that gets through the same way (for code that closes its clients, like the
/// account server's live connection).
http.Client resilientClient() => IOClient(resilientHttpClient());

HttpClient resilientHttpClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 12)
  ..findProxy = _findProxy
  ..connectionFactory = _connect;

/// Makes every `HttpClient` the app creates (images, the `http` package, the updater…) follow the network modes. Installed in main().
class NetworkOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context)
    ..findProxy = _findProxy
    ..connectionFactory = _connect;
}

/// Runs [body] with every HttpClient it makes (WebSockets included) getting through this way.
Future<T> withResilientHttp<T>(Future<T> Function() body) => HttpOverrides.runWithHttpOverrides(body, _Resilient());

class _Resilient extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context)
    ..connectionTimeout = const Duration(seconds: 12)
    ..findProxy = _findProxy
    ..connectionFactory = _connect;
}

class _Plain extends HttpOverrides {}

final _viaDoh = <String>{}; // hosts whose system answer didn't work this session

/// Names that spell out their own address (1-2-3-4.sslip.io, 1.2.3.4.nip.io): no DNS
/// needed at all, for networks whose DNS won't answer for them.
InternetAddress? _spelledOut(String host) {
  final m = RegExp(r'^(?:.*[.-])?(\d{1,3})[.-](\d{1,3})[.-](\d{1,3})[.-](\d{1,3})\.(?:sslip|nip)\.io$').firstMatch(host);
  return m == null ? null : InternetAddress.tryParse('${m[1]}.${m[2]}.${m[3]}.${m[4]}');
}

Future<ConnectionTask<Socket>> _connect(Uri uri, String? proxyHost, int? proxyPort) async {
  // a proxy (the local gateway): connect to it as it is; the client does the CONNECT and the TLS itself
  if (proxyHost != null && proxyPort != null) return Socket.startConnect(proxyHost, proxyPort);
  final host = uri.host;
  final secure = uri.scheme == 'https' || uri.scheme == 'wss';
  // WebSockets come through with port 0 when the address doesn't name one
  final port = uri.hasPort && uri.port != 0 ? uri.port : (secure ? 443 : 80);

  Future<Socket> open() async {
    // an address given as numbers (a self-hosted addon on your network), or this machine: just
    // dial it; the sinkhole filter below is only for names a DNS server answered
    final literal = InternetAddress.tryParse(host) ?? (host == 'localhost' ? InternetAddress.loopbackIPv4 : null);
    if (literal != null) return _dial(literal, host, port, secure, const Duration(seconds: 8));
    Object? error;
    final tried = <InternetAddress>{};
    // Secure DNS chosen: its answer first, the system resolver after it
    if (NetState.doh.isNotEmpty) {
      for (final a in await _dohAddresses(host)) {
        if (!tried.add(a)) continue;
        try {
          return await _dial(a, host, port, secure, const Duration(seconds: 8));
        } catch (e) {
          error = e;
        }
      }
    }
    if (!_viaDoh.contains(host)) {
      for (final a in await systemLookup(host)) {
        if (!tried.add(a)) continue;
        try {
          return await _dial(a, host, port, secure, const Duration(seconds: 5));
        } catch (e) {
          error = e;
        }
      }
      _viaDoh.add(host);
    }
    final spelled = _spelledOut(host);
    if (spelled != null && tried.add(spelled)) {
      try {
        return await _dial(spelled, host, port, secure, const Duration(seconds: 8));
      } catch (e) {
        error = e;
      }
    }
    for (final a in await _dohAddresses(host)) {
      if (!tried.add(a)) continue;
      try {
        return await _dial(a, host, port, secure, const Duration(seconds: 8));
      } catch (e) {
        error = e;
      }
    }
    throw error ?? SocketException('Could not reach $host');
  }

  return ConnectionTask.fromSocket(open(), () {});
}

Future<Socket> _dial(InternetAddress a, String host, int port, bool secure, Duration timeout) async {
  final s = await Socket.connect(a, port, timeout: timeout);
  if (!secure) return s;
  try {
    return await SecureSocket.secure(s, host: host).timeout(timeout);
  } catch (_) {
    s.destroy();
    rethrow;
  }
}

// The lookups themselves use a plain client even inside the overrides: they must not come back here for their own query.
final _dohResolver = DohResolver(newClient: () => HttpOverrides.runWithHttpOverrides(HttpClient.new, _Plain()));

/// Addresses for [host] over Secure DNS: the chosen provider, or Cloudflare as the fallback when none is chosen.
Future<List<InternetAddress>> _dohAddresses(String host) {
  final chosen = NetState.doh;
  return _dohResolver.resolve(host, chosen.isNotEmpty ? chosen : dnsProviderById('cloudflare').urls);
}
