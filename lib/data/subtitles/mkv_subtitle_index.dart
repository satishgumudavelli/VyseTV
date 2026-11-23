// The subtitle tracks inside a Matroska file (MKV, WebM), with when each of their lines shows,
// read from the file's index (its Cues) without reading the film itself: a few small range
// requests at its start and end. Muxers index every subtitle line (MKVToolNix by default, and
// FFmpeg), so the timing of the video's own subtitles for the whole film is known before it
// plays, whichever engine plays it: the reference for automatic subtitle sync (auto_sync.dart).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../net.dart';

class MkvSubtitleTrack {
  const MkvSubtitleTrack({
    required this.number,
    required this.codec,
    required this.lang,
    required this.name,
    required this.forced,
    required this.hearingImpaired,
    required this.lines,
    required this.timed,
  });

  /// The track's number in the file.
  final int number;

  /// Matroska's codec id: S_TEXT/UTF8 (SRT), S_TEXT/ASS, S_TEXT/WEBVTT, S_HDMV/PGS, S_VOBSUB…
  final String codec;

  /// The language as the file has it ('eng', 'en-US'…).
  final String lang;
  final String name;
  final bool forced;
  final bool hearingImpaired;

  /// Each line's start and end, in seconds of the film, in order. [timed] false: the index
  /// gave no durations, so each end is a guess (until the next line, at most 4 s).
  final List<(double, double)> lines;
  final bool timed;

  /// Text, not pictures.
  bool get text => codec.startsWith('S_TEXT');

  @override
  String toString() => 'track $number $codec $lang${name.isEmpty ? '' : ' "$name"'}${forced ? ' forced' : ''}: ${lines.length} lines';
}

abstract final class MkvSubtitleIndex {
  /// The subtitle tracks of the file at [url] (http, https, file, or a path), with their
  /// lines; null when it isn't a Matroska file, can't be read, or keeps no index of them.
  static Future<List<MkvSubtitleTrack>?> read(String url, {Map<String, String> headers = const {}, http.Client? client}) async {
    final uri = Uri.tryParse(url);
    final _Reader reader;
    if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
      reader = _HttpReader(uri, headers, client ?? netClient);
    } else {
      final path = uri != null && uri.isScheme('file') ? uri.toFilePath() : url;
      if (!File(path).existsSync()) return null;
      reader = _FileReader(File(path));
    }
    try {
      return await _read(reader).timeout(const Duration(seconds: 30));
    } catch (_) {
      return null;
    } finally {
      await reader.close();
    }
  }

  static Future<List<MkvSubtitleTrack>?> _read(_Reader r) async {
    // (the seek table, the tracks and their settings sit in the first few KB; past that, the
    // seek table says where)
    final head = await r.read(0, 64 * 1024);
    if (head.length < 64) return null;
    final ebml = _Element.at(head, 0);
    if (ebml == null || ebml.id != 0x1A45DFA3) return null;
    var docType = 'matroska';
    for (final e in _children(head, ebml)) {
      if (e.id == 0x4282) docType = e.text(head);
    }
    if (docType != 'matroska' && docType != 'webm') return null;
    final segment = _Element.at(head, ebml.end);
    if (segment == null || segment.id != 0x18538067) return null;
    final base = segment.data; // positions in the file's seek tables count from here

    var scale = 1000000; // nanoseconds a timestamp counts (Matroska's default)
    Uint8List? tracks;
    Uint8List? cues;
    final seeks = <int, int>{}; // element id -> its position
    Future<void> seekHead(Uint8List b, _Element e) async {
      for (final s in _children(b, e)) {
        if (s.id != 0x4DBB) continue;
        int? id, pos;
        for (final f in _children(b, s)) {
          if (f.id == 0x53AB) id = f.uint(b);
          if (f.id == 0x53AC) pos = f.uint(b);
        }
        if (id != null && pos != null) seeks.putIfAbsent(id, () => pos!);
      }
    }

    // what is in the first part of the file, up to the film itself
    var at = segment.data;
    while (at < head.length) {
      final e = _Element.at(head, at);
      if (e == null || e.id == 0x1F43B675) break; // a Cluster: the film starts
      if (e.end > head.length) {
        if (e.id == 0x1654AE6B || e.id == 0x1C53BB6B) seeks.putIfAbsent(e.id, () => at - base);
        if (e.size == null) break;
        at = e.end;
        continue;
      }
      if (e.id == 0x114D9B74) await seekHead(head, e);
      if (e.id == 0x1549A966) {
        for (final f in _children(head, e)) {
          if (f.id == 0x2AD7B1) scale = f.uint(head);
        }
      }
      if (e.id == 0x1654AE6B) tracks = Uint8List.sublistView(head, e.data, e.end);
      if (e.id == 0x1C53BB6B) cues = Uint8List.sublistView(head, e.data, e.end);
      if (e.size == null) break;
      at = e.end;
    }
    // a second seek table, kept at the end of the file
    final more = seeks[0x114D9B74];
    if (more != null && base + more >= head.length) {
      final b = await _element(r, base + more, 64 * 1024);
      if (b != null) await seekHead(b.$1, b.$2);
    }
    if (tracks == null) {
      final pos = seeks[0x1654AE6B];
      if (pos == null) return null;
      final b = await _element(r, base + pos, 1024 * 1024);
      if (b == null) return null;
      tracks = Uint8List.sublistView(b.$1, b.$2.data, b.$2.end);
    }
    if (cues == null) {
      final pos = seeks[0x1C53BB6B];
      if (pos == null) return null;
      final b = await _element(r, base + pos, 16 * 1024 * 1024);
      if (b == null) return null;
      cues = Uint8List.sublistView(b.$1, b.$2.data, b.$2.end);
    }

    // the subtitle tracks
    final subs = <int, Map<String, Object>>{};
    for (final t in _all(tracks)) {
      if (t.id != 0xAE) continue;
      int? number, type;
      var codec = '', lang = 'eng', bcp = '', name = '';
      var forced = false, hi = false;
      for (final f in _children(tracks, t)) {
        switch (f.id) {
          case 0xD7:
            number = f.uint(tracks);
          case 0x83:
            type = f.uint(tracks);
          case 0x86:
            codec = f.text(tracks);
          case 0x22B59C:
            lang = f.text(tracks);
          case 0x22B59D:
            bcp = f.text(tracks);
          case 0x536E:
            name = f.text(tracks);
          case 0x55AA:
            forced = f.uint(tracks) == 1;
          case 0x55AB:
            hi = f.uint(tracks) == 1;
        }
      }
      if (number == null || type != 0x11) continue;
      subs[number] = {'codec': codec, 'lang': bcp.isNotEmpty ? bcp : lang, 'name': name, 'forced': forced, 'hi': hi};
    }
    if (subs.isEmpty) return const [];

    // every index entry: when, which track, and for how long
    final times = <int, Map<int, int?>>{}; // track -> time -> duration
    var first = -1;
    for (final p in _all(cues)) {
      if (p.id != 0xBB) continue;
      int? time;
      final where = <(int, int?)>[];
      for (final f in _children(cues, p)) {
        if (f.id == 0xB3) time = f.uint(cues);
        if (f.id == 0xB7) {
          int? track, duration;
          for (final g in _children(cues, f)) {
            if (g.id == 0xF7) track = g.uint(cues);
            if (g.id == 0xB2) duration = g.uint(cues);
          }
          if (track != null) where.add((track, duration));
        }
      }
      if (time == null) continue;
      if (first < 0 || time < first) first = time;
      for (final (track, duration) in where) {
        if (subs.containsKey(track)) (times[track] ??= {})[time] = duration ?? times[track]?[time];
      }
    }
    // (mpv counts the film from its first moment, like the downloaded file does)
    final start = math.max(0, first);
    double secs(int t) => t * scale / 1e9;
    return [
      for (final MapEntry(key: number, value: m) in subs.entries)
        () {
          final entries = (times[number] ?? const <int, int?>{}).entries.toList()..sort((a, b) => a.key.compareTo(b.key));
          final timed = entries.isNotEmpty && entries.every((e) => e.value != null && e.value! > 0);
          return MkvSubtitleTrack(
            number: number,
            codec: m['codec']! as String,
            lang: m['lang']! as String,
            name: m['name']! as String,
            forced: m['forced']! as bool,
            hearingImpaired: m['hi']! as bool,
            timed: timed,
            lines: [
              for (var i = 0; i < entries.length; i++)
                (
                  secs(entries[i].key - start),
                  timed
                      ? secs(entries[i].key - start + entries[i].value!)
                      : math.min(secs(entries[i].key - start) + 4, i + 1 < entries.length ? secs(entries[i + 1].key - start) - .05 : secs(entries[i].key - start) + 4),
                ),
            ],
          );
        }(),
    ];
  }

  /// The element at [pos] of the file, whole (up to [max] bytes): the bytes read, and where it
  /// is in them.
  static Future<(Uint8List, _Element)?> _element(_Reader r, int pos, int max) async {
    final top = await r.read(pos, 16);
    final e = _Element.at(top, 0);
    if (e == null || e.size == null || e.end > max) return null;
    final b = await r.read(pos, e.end);
    if (b.length < e.end) return null;
    return (b, e);
  }

  static Iterable<_Element> _children(Uint8List b, _Element parent) sync* {
    var at = parent.data;
    while (at < parent.end && at < b.length) {
      final e = _Element.at(b, at);
      if (e == null || e.size == null || e.end > parent.end) return;
      yield e;
      at = e.end;
    }
  }

  static Iterable<_Element> _all(Uint8List b) => _children(b, _Element(0, 0, b.length));
}

/// An EBML element: its id, where its data starts, and how long it is (null: not said).
class _Element {
  const _Element(this.id, this.data, this.size);
  final int id;
  final int data;
  final int? size;

  int get end => data + (size ?? 0);

  static _Element? at(Uint8List b, int pos) {
    if (pos >= b.length) return null;
    final idLen = _length(b[pos]);
    if (idLen == 0 || idLen > 4 || pos + idLen >= b.length) return null;
    var id = 0;
    for (var k = 0; k < idLen; k++) {
      id = (id << 8) | b[pos + k];
    }
    final sp = pos + idLen;
    final sizeLen = _length(b[sp]);
    if (sizeLen == 0 || sp + sizeLen > b.length) return null;
    var size = b[sp] & (0xFF >> sizeLen);
    var unknown = size == (0xFF >> sizeLen);
    for (var k = 1; k < sizeLen; k++) {
      size = (size << 8) | b[sp + k];
      if (b[sp + k] != 0xFF) unknown = false;
    }
    return _Element(id, sp + sizeLen, unknown ? null : size);
  }

  /// How many bytes a variable-length number starting with [first] takes (0: not one).
  static int _length(int first) {
    for (var n = 1; n <= 8; n++) {
      if (first & (0x80 >> (n - 1)) != 0) return n;
    }
    return 0;
  }

  int uint(Uint8List b) {
    var v = 0;
    for (var k = data; k < end && k < b.length; k++) {
      v = (v << 8) | b[k];
    }
    return v;
  }

  String text(Uint8List b) => String.fromCharCodes(b.sublist(data, math.min(end, b.length)).where((c) => c != 0));
}

abstract class _Reader {
  /// Up to [length] bytes from [start] (fewer at the end of the file).
  Future<Uint8List> read(int start, int length);
  Future<void> close();
}

class _HttpReader implements _Reader {
  _HttpReader(this.uri, this.headers, this.client);
  final Uri uri;
  final Map<String, String> headers;
  final http.Client client;

  @override
  Future<Uint8List> read(int start, int length) async {
    final q = http.Request('GET', uri)
      ..headers.addAll(headers)
      ..headers['Range'] = 'bytes=$start-${start + length - 1}';
    final r = await client.send(q).timeout(const Duration(seconds: 15));
    // a host that ignores the range sends the whole file: only its start is any use
    if (r.statusCode == 200 && start > 0) throw const HttpException('no ranges');
    if (r.statusCode != 206 && r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
    final out = BytesBuilder(copy: false);
    final done = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = r.stream.listen(
      (chunk) {
        out.add(chunk);
        if (out.length >= length && !done.isCompleted) {
          done.complete();
          unawaited(sub.cancel());
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    await done.future.timeout(const Duration(seconds: 20));
    final bytes = out.takeBytes();
    return bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
  }

  @override
  Future<void> close() async {}
}

class _FileReader implements _Reader {
  _FileReader(this.file);
  final File file;
  RandomAccessFile? _f;

  @override
  Future<Uint8List> read(int start, int length) async {
    final f = _f ??= await file.open();
    await f.setPosition(start);
    return f.read(length);
  }

  @override
  Future<void> close() async => _f?.close();
}
