import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/network/dns_providers.dart';

/// A DNS answer for `a.test` with one CNAME and the given records (type, rdata).
Uint8List _answer(List<(int, List<int>)> records, {int rcode = 0}) {
  final b = BytesBuilder()
    ..add([0, 0, 0x81, 0x80 | rcode, 0, 1, 0, records.length, 0, 0, 0, 0])
    ..add([1, 97, 4, 116, 101, 115, 116, 0, 0, 1, 0, 1]); // question: a.test A IN
  for (final (type, data) in records) {
    b
      ..add([0xC0, 12, 0, type, 0, 1, 0, 0, 0, 60, 0, data.length]) // name pointer, type, IN, ttl 60, rdlength
      ..add(data);
  }
  return b.toBytes();
}

void main() {
  test('providers: the list, ids and the by-address fallbacks', () {
    expect(dnsProviders.map((p) => p.id), ['cloudflare', 'google', 'adguard', 'custom', 'off']);
    expect(dnsProviderById('google').urls.first, 'https://dns.google/dns-query');
    expect(dnsProviderById('nope').id, 'off');
    for (final p in dnsProviders.where((p) => p.urls.isNotEmpty)) {
      expect(p.urls.length, 2); // the name, then the address
      expect(InternetAddress.tryParse(Uri.parse(p.urls.last).host), isNotNull);
    }
  });

  test('custom address: https with a host only; no user info or fragment; at most 2048', () {
    expect(validateCustomDohUrl('https://dns.example/dns-query'), isNull);
    expect(validateCustomDohUrl(' https://9.9.9.9/dns-query '), isNull);
    expect(validateCustomDohUrl('https://[2606:4700::1111]/dns-query'), isNull);
    for (final bad in [
      '',
      'abc',
      'http://dns.example/q',
      'https://',
      'https://u:p@dns.example/q',
      'https://dns.example/q#x',
      'https://${'a' * 2100}.example',
    ]) {
      expect(validateCustomDohUrl(bad), 'Enter a full https:// address', reason: bad);
    }
    expect(dnsEndpointsFor('custom', 'https://dns.example/q'), ['https://dns.example/q']);
    expect(dnsEndpointsFor('custom', 'nope'), isEmpty);
    expect(dnsEndpointsFor('off', ''), isEmpty);
    expect(dnsEndpointsFor('cloudflare', ''), dnsProviderById('cloudflare').urls);
  });

  test('wire format: the query and the answer', () {
    expect(buildDnsQuery('a.test', 1), [0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 97, 4, 116, 101, 115, 116, 0, 0, 1, 0, 1]);
    final ips = parseDnsAnswer(
      _answer([
        (5, [1, 98, 0]),
        (1, [93, 184, 216, 34]),
        (28, List.filled(15, 0) + [1]),
      ]),
    );
    expect(ips.map((a) => a.address), ['93.184.216.34', '::1']); // the CNAME is skipped
    expect(() => parseDnsAnswer(_answer([], rcode: 3)), throwsFormatException); // NXDOMAIN
    expect(() => parseDnsAnswer(Uint8List(5)), throwsFormatException);
  });

  test('DoH lookup: asks every endpoint in turn, drops sinkhole answers, caches only successes', () async {
    var hits = 0;
    final good = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bad = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() {
      good.close(force: true);
      bad.close(force: true);
    });
    bad.listen((r) {
      r.response.statusCode = 500;
      r.response.close();
    });
    good.listen((r) {
      hits++;
      final q = base64Url.decode(base64Url.normalize(r.uri.queryParameters['dns']!));
      final isA = q[q.length - 3] == 1;
      expect(r.headers.value('accept'), 'application/dns-message');
      r.response.headers.contentType = ContentType('application', 'dns-message');
      r.response.add(
        _answer(
          isA
              ? [
                  (1, [0, 0, 0, 0]),
                  (1, [10, 9, 8, 7]),
                ]
              : [],
        ),
      );
      r.response.close();
    });
    final doh = DohResolver();
    final endpoints = ['http://127.0.0.1:${bad.port}/dns-query', 'http://127.0.0.1:${good.port}/dns-query'];
    expect((await doh.resolve('a.test', endpoints)).map((a) => a.address), ['10.9.8.7']); // 0.0.0.0 dropped; the broken endpoint skipped
    await doh.resolve('a.test', endpoints);
    expect(hits, 2); // an A and an AAAA query, once: the second call came from the cache
    // nothing answers: empty, and not remembered
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadUrl = 'http://127.0.0.1:${dead.port}/dns-query';
    await dead.close(force: true);
    expect(await doh.resolve('b.test', [deadUrl]), isEmpty);
    expect(await doh.resolve('b.test', [deadUrl]), isEmpty);
  });

  test('the system lookup drops addresses that mean blocked', () async {
    expect(isSinkhole(InternetAddress('0.0.0.0')), isTrue);
    expect(isSinkhole(InternetAddress('127.0.0.1')), isTrue);
    expect(isSinkhole(InternetAddress('8.8.8.8')), isFalse);
    expect((await systemLookup('localhost')).any(isSinkhole), isFalse); // localhost is loopback: all removed
  });
}
