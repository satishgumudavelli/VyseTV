/// What the app's HTTP clients need to know about the network modes, with no platform code behind it, so that a background isolate
/// can read it (a plugin runs in one: the Android channel behind `NetworkModes` cannot be created there).
///
/// Each isolate has its own copy: the main one is kept current by `NetworkModes`; code that starts an isolate takes a [snapshot] first
/// and calls [apply] inside it.
class NetState {
  /// The local gateway's port while a route (WARP, Anti-DPI) is active: HTTP clients use it as their proxy. Null: go straight out.
  static int? proxyPort;

  /// The gateway's port when only VyseTV's own server ([serverHost]) goes through it (WARP's "VyseTV server only"): everything else is
  /// direct. Only read by the main isolate's clients.
  static int? serverPort;
  static String serverHost = '';

  /// Secure DNS endpoints to look names up with first (empty: the system resolver, with Cloudflare as the fallback).
  static List<String> doh = const [];

  static ({int? proxyPort, List<String> doh}) snapshot() => (proxyPort: proxyPort, doh: doh);

  static void apply(({int? proxyPort, List<String> doh}) s) {
    proxyPort = s.proxyPort;
    doh = s.doh;
  }
}
