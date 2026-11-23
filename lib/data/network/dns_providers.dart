import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A secure DNS (DNS over HTTPS) choice (specs/001-warp-doh-anti-dpi/data-model.md).
class DnsProvider {
  const DnsProvider(this.id, this.label, this.urls);
  final String id, label;

  /// Endpoints to try in order: the named one, then the same service by address (for a network that
  /// tampers with the lookup of the resolver's own name). Empty for Off and Custom.
  final List<String> urls;
}

const dnsProviders = <DnsProvider>[
  DnsProvider('cloudflare', 'Cloudflare (1.1.1.1)', ['https://cloudflare-dns.com/dns-query', 'https://1.1.1.1/dns-query']),
  DnsProvider('google', 'Google (8.8.8.8)', ['https://dns.google/dns-query', 'https://8.8.8.8/dns-query']),
  DnsProvider('adguard', 'AdGuard', ['https://dns.adguard-dns.com/dns-query', 'https://94.140.14.14/dns-query']),
  DnsProvider('custom', 'Custom', []),
  DnsProvider('off', 'Off', []),
];

DnsProvider dnsProviderById(String id) => dnsProviders.firstWhere((p) => p.id == id, orElse: () => dnsProviders.last);

/// Why [input] can't be a custom resolver address, or null when it can: an https address with a host, no user info and no fragment.
String? validateCustomDohUrl(String input) {
  final s = input.trim();
  if (s.isEmpty || s.length > 2048) return 'Enter a full https:// address';
  final u = Uri.tryParse(s);
  if (u == null || u.scheme != 'https' || u.host.isEmpty || u.userInfo.isNotEmpty || u.hasFragment) return 'Enter a full https:// address';
  return null;
}

/// The endpoints for the choice [id] ('off' → none; 'custom' → [customUrl] when it is valid).
List<String> dnsEndpointsFor(String id, String customUrl) {
  if (id == 'custom') return validateCustomDohUrl(customUrl) == null ? [customUrl.trim()] : const [];
  return dnsProviderById(id).urls;
}

// ── the lookup ──

bool isSinkhole(InternetAddress a) => a.isLoopback || a.address == '0.0.0.0' || a.address == '::';

/// The system resolver's answer without addresses that mean "blocked" (0.0.0.0, loopback); IPv4 first.
Future<List<InternetAddress>> systemLookup(String host) async {
  try {
    final all = await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
    return [
      ...all.where((a) => a.type == InternetAddressType.IPv4 && !isSinkhole(a)),
      ...all.where((a) => a.type == InternetAddressType.IPv6 && !isSinkhole(a)),
    ];
  } catch (_) {
    return const [];
  }
}

/// A DNS-over-HTTPS client (RFC 8484 wire format, so any resolver works). It uses a plain [HttpClient] made by [newClient]
/// (never the app's overridden one: it must not come back here for its own lookup) and remembers answers for this session;
/// a failed lookup is not remembered.
class DohResolver {
  DohResolver({HttpClient Function()? newClient}) : _newClient = newClient ?? HttpClient.new;
  final HttpClient Function() _newClient;
  final _cache = <String, Future<List<InternetAddress>>>{};

  Future<List<InternetAddress>> resolve(String host, List<String> endpoints) {
    final key = '${endpoints.join('|')}#$host';
    return _cache[key] ??= () async {
      final client = _newClient()..connectionTimeout = const Duration(seconds: 6);
      try {
        for (final url in endpoints) {
          try {
            final ips = <InternetAddress>[];
            for (final type in const [1, 28]) {
              ips.addAll(await _query(client, url, host, type));
            }
            final usable = ips.where((a) => !isSinkhole(a)).toList()..sort((a, b) => a.type == b.type ? 0 : (a.type == InternetAddressType.IPv4 ? -1 : 1));
            if (usable.isNotEmpty) return usable;
          } catch (_) {}
        }
        _cache.remove(key);
        return const <InternetAddress>[];
      } finally {
        client.close(force: true);
      }
    }();
  }

  Future<List<InternetAddress>> _query(HttpClient client, String endpoint, String host, int type) async {
    final dns = base64Url.encode(buildDnsQuery(host, type)).replaceAll('=', '');
    final base = Uri.parse(endpoint);
    final rq = await client.getUrl(base.replace(queryParameters: {...base.queryParameters, 'dns': dns}));
    rq.headers.set(HttpHeaders.acceptHeader, 'application/dns-message');
    final res = await rq.close().timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('DoH ${res.statusCode}');
    }
    final body = BytesBuilder();
    await for (final c in res.timeout(const Duration(seconds: 6))) {
      body.add(c);
      if (body.length > 64 * 1024) throw const FormatException('DoH answer too long');
    }
    return parseDnsAnswer(body.toBytes());
  }
}

/// A DNS query for [host]'s A (1) or AAAA (28) records (RFC 1035 wire format, recursion desired).
Uint8List buildDnsQuery(String host, int type) {
  final b = BytesBuilder()..add(const [0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]); // id 0 (RFC 8484), flags RD, 1 question
  for (final label in host.split('.')) {
    if (label.isEmpty) continue;
    final l = ascii.encode(label);
    if (l.length > 63) throw ArgumentError('label too long: $host');
    b
      ..addByte(l.length)
      ..add(l);
  }
  b
    ..addByte(0)
    ..add([0, type, 0, 1]); // type, class IN
  return b.toBytes();
}

/// The addresses in a DNS answer (A and AAAA records; CNAMEs and the rest are skipped). Throws on a malformed or error answer.
List<InternetAddress> parseDnsAnswer(Uint8List m) {
  if (m.length < 12) throw const FormatException('short DNS answer');
  final d = ByteData.sublistView(m);
  final rcode = d.getUint8(3) & 15;
  if (rcode != 0) throw FormatException('DNS error $rcode');
  var qd = d.getUint16(4), an = d.getUint16(6);
  var p = 12;
  int skipName(int at) {
    var i = at;
    while (true) {
      if (i >= m.length) throw const FormatException('bad DNS name');
      final len = m[i];
      if (len == 0) return i + 1;
      if (len & 0xC0 == 0xC0) return i + 2; // a pointer ends the name
      i += len + 1;
    }
  }

  for (; qd > 0; qd--) {
    p = skipName(p) + 4;
  }
  final out = <InternetAddress>[];
  for (; an > 0; an--) {
    p = skipName(p);
    if (p + 10 > m.length) throw const FormatException('short DNS answer');
    final type = d.getUint16(p), len = d.getUint16(p + 8);
    p += 10;
    if (p + len > m.length) throw const FormatException('short DNS answer');
    if (type == 1 && len == 4 || type == 28 && len == 16) out.add(InternetAddress.fromRawAddress(Uint8List.fromList(m.sublist(p, p + len))));
    p += len;
  }
  return out;
}
