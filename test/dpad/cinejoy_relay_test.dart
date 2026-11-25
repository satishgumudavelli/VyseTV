// The relay (VyseTV's own little proxy on 127.0.0.1, inside the app) and pieces of video dressed
// up as PNG pictures (2026-11-23): Cinejoy's Polaris server keeps each MPEG-TS piece in a chunk
// of a 1x1 PNG on TikTok's picture CDN, and mpv opens such a piece as a picture. The relay hands
// over the video alone; every other piece passes as before. A made-up host on this machine
// stands in for the CDN. Played and seeked against the real Polaris outside the tests.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/playback/stream_proxy.dart';

/// [n] MPEG-TS packets; packet k is 0x47 then bytes of value k.
Uint8List _ts(int n) => Uint8List.fromList([
  for (var k = 0; k < n; k++) ...[0x47, ...List.filled(187, k)],
]);

List<int> _chunk(String type, List<int> data) => [
  ...[24, 16, 8, 0].map((s) => (data.length >> s) & 0xFF),
  ...ascii.encode(type),
  ...data,
  0, 0, 0, 0, // the CRC (not checked by anyone here)
];

const _sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
final _ihdr = _chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]);
final _idat = _chunk('IDAT', [0x78, 0x9C, 0x63, 0x60, 0, 2, 0, 0, 5, 0, 1]);

/// Polaris's way: the video in a chunk of its own, between the picture and its end.
Uint8List _inChunk(Uint8List ts) => Uint8List.fromList([..._sig, ..._ihdr, ..._idat, ..._chunk('tsDa', ts), ..._chunk('IEND', const [])]);

/// The other way seen on such hosts: the video after the picture's end.
Uint8List _afterEnd(Uint8List ts) => Uint8List.fromList([..._sig, ..._ihdr, ..._idat, ..._chunk('IEND', const []), ...ts]);

void main() {
  late HttpServer host;
  late HttpClient client;
  final ts = _ts(40);
  final fmp4 = Uint8List.fromList([0, 0, 0, 24, ...ascii.encode('stypmsdh'), ...List.filled(400, 9)]);
  final pieces = <String, (Uint8List, String)>{
    '/a.png': (_inChunk(ts), 'image/png'),
    '/b.png': (_inChunk(ts), 'image/png'),
    '/c.png': (_afterEnd(ts), 'image/png'),
    '/plain.ts': (ts, 'video/mp2t'),
    '/frag.png': (fmp4, 'image/png'), // Cinejoy's other servers: fragmented MP4 named as a picture
  };
  final seen = <String>[]; // what the host was asked: "path range"

  setUpAll(() async {
    client = HttpClient();
    host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host.listen((req) async {
      final res = req.response;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      seen.add('${req.uri.path} ${range ?? ''}'.trim());
      if (req.uri.path == '/list.m3u8') {
        res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        res.write('#EXTM3U\n#EXT-X-TARGETDURATION:8\n${[for (final p in pieces.keys) '#EXTINF:8.0,\n$p'].join('\n')}\n#EXT-X-ENDLIST\n');
        return res.close();
      }
      final (body, type) = pieces[req.uri.path]!;
      res.headers.contentType = ContentType.parse(type);
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range ?? '');
      if (m == null) {
        res.headers.contentLength = body.length;
        res.add(body);
      } else {
        final a = int.parse(m[1]!), b = m[2]!.isEmpty ? body.length - 1 : int.parse(m[2]!);
        res
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $a-$b/${body.length}')
          ..headers.contentLength = b - a + 1
          ..add(body.sublist(a, b + 1));
      }
      await res.close();
    });
  });
  tearDownAll(() async {
    await host.close(force: true);
    await StreamProxy.instance.close();
  });

  /// The relay's address for each piece of the playlist, in its order.
  Future<Map<String, String>> relayed() async {
    final list = await StreamProxy.instance.wrap('http://127.0.0.1:${host.port}/list.m3u8');
    final text = await (await (await client.getUrl(Uri.parse(list))).close()).transform(utf8.decoder).join();
    final urls = [for (final l in const LineSplitter().convert(text)) if (l.startsWith('http')) l];
    return Map.fromIterables(pieces.keys, urls);
  }

  Future<(HttpClientResponse, Uint8List)> get(String url, {String? range}) async {
    final rq = await client.getUrl(Uri.parse(url));
    if (range != null) rq.headers.set(HttpHeaders.rangeHeader, range);
    final res = await rq.close();
    final bytes = await res.fold(BytesBuilder(copy: false), (b, c) => b..add(c));
    return (res, bytes.toBytes());
  }

  test('where the video sits in a piece: in a chunk of its own, after the end, or nowhere', () {
    expect(StreamProxy.hiddenVideo(_inChunk(ts)), (start: 64, length: ts.length));
    expect(StreamProxy.hiddenVideo(_afterEnd(ts)), (start: 8 + _ihdr.length + _idat.length + 12, length: null));
    expect(StreamProxy.hiddenVideo(ts), isNull, reason: 'plain MPEG-TS');
    expect(StreamProxy.hiddenVideo(fmp4), isNull, reason: 'fragmented MP4');
    expect(StreamProxy.hiddenVideo([..._sig, ..._ihdr, ..._idat, ..._chunk('IEND', const [])]), isNull, reason: 'a real picture, nothing after it');
  });

  test('a piece hidden in a picture comes out as its video alone, whole or a part; other pieces pass as they came', () async {
    final at = await relayed();

    var (res, body) = await get(at['/a.png']!);
    expect((res.statusCode, res.headers.contentType?.mimeType, res.contentLength), (200, 'video/mp2t', ts.length));
    expect(body, ts, reason: 'the picture and its end are left out');

    (res, body) = await get(at['/a.png']!, range: 'bytes=188-375');
    expect((res.statusCode, res.headers.value(HttpHeaders.contentRangeHeader)), (206, 'bytes 188-375/${ts.length}'));
    expect(body, ts.sublist(188, 376), reason: 'a part of the video: its second packet');
    expect(seen.last, '/a.png bytes=252-439', reason: 'asked of the host as that part of the picture');

    // (records compare lists by identity: bytes are checked on their own)
    (res, body) = await get(at['/b.png']!, range: 'bytes=0-187');
    expect(res.statusCode, 206);
    expect(body, ts.sublist(0, 188), reason: 'a part asked for before the relay had seen the piece');

    (res, body) = await get(at['/c.png']!);
    expect((res.statusCode, res.headers.contentType?.mimeType), (200, 'video/mp2t'));
    expect(body, ts, reason: 'the video after the picture\'s end');

    (res, body) = await get(at['/plain.ts']!);
    expect((res.statusCode, res.headers.contentType?.mimeType), (200, 'video/mp2t'));
    expect(body, ts);
    (res, body) = await get(at['/frag.png']!);
    expect(res.statusCode, 200);
    expect(body, fmp4, reason: 'fragmented MP4 named as a picture is not a picture: it passes untouched');
    (res, body) = await get(at['/plain.ts']!, range: 'bytes=188-375');
    expect(res.statusCode, 206);
    expect(body, ts.sublist(188, 376), reason: 'parts of other pieces as before');
  });

  test('a downloaded piece kept as it came plays as its video too, whole or a part', () async {
    final dir = await Directory.systemTemp.createTemp('vyse_hidden_');
    addTearDown(() => dir.delete(recursive: true));
    await Directory('${dir.path}${Platform.pathSeparator}v').create();
    await File('${dir.path}${Platform.pathSeparator}v${Platform.pathSeparator}0.ts').writeAsBytes(_inChunk(ts));
    final base = await StreamProxy.instance.serveFolder(dir.path);

    var (res, body) = await get('$base/v/0.ts');
    expect((res.statusCode, res.headers.contentType?.mimeType, res.contentLength), (200, 'video/mp2t', ts.length));
    expect(body, ts);
    (res, body) = await get('$base/v/0.ts', range: 'bytes=376-563');
    expect((res.statusCode, res.headers.value(HttpHeaders.contentRangeHeader)), (206, 'bytes 376-563/${ts.length}'));
    expect(body, ts.sublist(376, 564));
  });
}
