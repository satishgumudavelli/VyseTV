// The test bed's network: every HTTP request the app makes in a test is answered from here, and
// every poster and backdrop is a small picture made on the spot. Nothing leaves the machine.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file/memory.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// What a fake answer is made of.
class FakeReply {
  const FakeReply(this.status, this.body, {this.type = 'application/json; charset=utf-8'});
  FakeReply.json(Object data, {int status = 200}) : this(status, utf8.encode(jsonEncode(data)));
  static const notFound = FakeReply(404, <int>[]);

  final int status;
  final List<int> body;
  final String type;
}

/// Decides the answer for one request. Return null for "no such page" (a 404).
typedef FakeRoute = FakeReply? Function(String method, Uri uri);

/// Installed as [HttpOverrides.global]: every `HttpClient` the app makes is a [_Client].
class FakeHttp extends HttpOverrides {
  FakeHttp(this.route);

  FakeRoute route;

  /// How long an answer takes to come back (a slow TV, a slow network). Measured on the test's
  /// own clock, so the test decides when it arrives. Null or zero: at once.
  Duration Function(Uri uri)? delay;

  /// Every request seen, oldest first ("GET https://…").
  final seen = <String>[];

  /// Requests nothing answered.
  final missed = <String>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(this);

  FakeReply answer(String method, Uri uri) {
    seen.add('$method $uri');
    final reply = route(method, uri);
    if (reply == null) missed.add('$method $uri');
    return reply ?? FakeReply.notFound;
  }
}

class _Client implements HttpClient {
  _Client(this.net);
  final FakeHttp net;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => _Request(net, method, url);
  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) =>
      openUrl(method, Uri(scheme: port == 443 ? 'https' : 'http', host: host, port: port, path: path));
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  void close({bool force = false}) {}

  // timeouts, proxies, the connection factory: accepted and ignored
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Headers implements HttpHeaders {
  final _values = <String, List<String>>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) => _values[name.toLowerCase()] = ['$value'];
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) => (_values[name.toLowerCase()] ??= []).add('$value');
  @override
  void forEach(void Function(String name, List<String> values) action) => _values.forEach(action);
  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];
  @override
  String? value(String name) => _values[name.toLowerCase()]?.firstOrNull;
  @override
  ContentType? get contentType {
    final v = value('content-type');
    return v == null ? null : ContentType.parse(v);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.net, this.method, this.uri);
  final FakeHttp net;
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _Headers();
  @override
  Encoding encoding = utf8;
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;
  @override
  bool bufferOutput = true;

  final _done = Completer<HttpClientResponse>();

  @override
  void add(List<int> data) {}
  @override
  void write(Object? object) {}
  @override
  void writeln([Object? object = '']) {}
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  Future<void> flush() async {}
  @override
  Future<HttpClientResponse> get done => _done.future;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  Future<HttpClientResponse> close() async {
    final wait = net.delay?.call(uri) ?? Duration.zero;
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    if (!_done.isCompleted) _done.complete(_Response(net.answer(method, uri)));
    return _done.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.reply) {
    headers.set('content-type', reply.type);
    headers.set('content-length', reply.body.length);
  }
  final FakeReply reply;

  @override
  final HttpHeaders headers = _Headers();
  @override
  int get statusCode => reply.status;
  @override
  int get contentLength => reply.body.length;
  @override
  String get reasonPhrase => reply.status == 200 ? 'OK' : 'Not Found';
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  HttpClientResponseCompressionState get compressionState => HttpClientResponseCompressionState.notCompressed;
  @override
  List<Cookie> get cookies => const [];

  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream<List<int>>.fromIterable([if (reply.body.isNotEmpty) reply.body]).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ───────────────────────── Pictures ─────────────────────────

/// A small PNG that fades from one colour to another, both picked from [seed]: a stand-in for a
/// poster or a backdrop. Stretched over a card it reads as a soft gradient, different per title.
Uint8List fakePicture(String seed, {int width = 12, int height = 12}) {
  var h = 0x811c9dc5;
  for (final c in seed.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  List<int> colour(int hue, double light) {
    // hue 0..359 on a muted wheel
    double ch(int n) {
      final k = (n + hue / 30) % 12;
      final a = .45 * (light < .5 ? light : 1 - light);
      return light - a * [k - 3, 9 - k, 1.0].reduce((x, y) => x < y ? x : y).clamp(-1.0, 1.0);
    }

    return [for (final n in const [0, 8, 4]) (ch(n) * 255).round().clamp(0, 255)];
  }

  final a = colour(h % 360, .42), b = colour((h ~/ 360 + 40) % 360, .2);
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // no filter on this row
    for (var x = 0; x < width; x++) {
      final t = (x / (width - 1) + y / (height - 1)) / 2;
      for (var i = 0; i < 3; i++) {
        raw.addByte((a[i] + (b[i] - a[i]) * t).round());
      }
    }
  }
  final out = BytesBuilder()..add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  void chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    out
      ..add(_u32(data.length))
      ..add(body)
      ..add(_u32(_crc(body)));
  }

  chunk('IHDR', [..._u32(width), ..._u32(height), 8, 2, 0, 0, 0]);
  chunk('IDAT', zlib.encode(raw.toBytes()));
  chunk('IEND', const []);
  return out.toBytes();
}

List<int> _u32(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];

final _crcTable = [
  for (var n = 0; n < 256; n++)
    () {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = c & 1 == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1;
      }
      return c;
    }(),
];

int _crc(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 255] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}

/// Stands in for cached_network_image's cache: each address gets a [fakePicture], held in
/// memory. No disk, no network, no timers, and nothing that waits: a picture made during one
/// test is handed to the next as a finished value, never as a Future from the earlier test.
class FakeImages implements BaseCacheManager {
  final _files = MemoryFileSystem();
  final _made = <String, FileInfo>{};

  /// Every picture asked for.
  final seen = <String>{};

  FileInfo _picture(String url) {
    seen.add(url);
    return _made[url] ??= () {
      final wide = url.contains('/w1280') || url.contains('/w780') || url.contains('/original') || url.contains('ytimg');
      final file = _files.file('/${_made.length}.png')..writeAsBytesSync(fakePicture(url, width: wide ? 16 : 10, height: wide ? 9 : 15));
      return FileInfo(file, FileSource.Cache, DateTime(2100), url);
    }();
  }

  @override
  Stream<FileResponse> getFileStream(String url, {String? key, Map<String, String>? headers, bool withProgress = false}) => Stream.value(_picture(url));

  @override
  Future<FileInfo> downloadFile(String url, {String? key, Map<String, String>? authHeaders, bool force = false}) async => _picture(url);

  @override
  Future<FileInfo?> getFileFromCache(String key, {bool ignoreMemCache = false}) async => _made[key];

  @override
  Future<FileInfo?> getFileFromMemory(String key) async => _made[key];

  @override
  Future<void> removeFile(String key) async {}

  @override
  Future<void> emptyCache() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('FakeImages: ${invocation.memberName}');
}
