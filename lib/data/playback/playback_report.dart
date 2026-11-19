import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform/device_channel.dart';

/// One line of a report: what it is, and what it says.
typedef ReportFact = ({String label, String value});

/// A titled group of lines ("VIDEO": codec, resolution, bitrate).
typedef ReportSection = ({String title, List<ReportFact> facts});

/// What one playback was and how it went: the player's Stream info, and the report card a
/// tester photographs when something won't play.
///
/// It is made when a video is opened and filled in as things become known: what the player
/// says about the picture and the sound, what the TV can do with HDR and Dolby Vision, how long
/// the first frame took, and how it ended (played, handed from Media3 to mpv and what for, or
/// did not play). The newest one is kept after the player closes ([last]), so a film that never
/// started can still be reported from Settings.
///
/// It never holds an address. A link carries tokens, and an IPTV link its portal's sign-in:
/// only the host is kept ([hostOf]), and anything the engines say is cleaned of addresses
/// before it is stored ([scrub]).
class PlaybackReport {
  PlaybackReport._(this._f);

  /// A report for a video being opened now.
  factory PlaybackReport.begin({
    required String title,
    required String source,
    String link = '',
    required String url,
    required String engine,
    DateTime? when,
  }) => PlaybackReport._({
    'when': (when ?? DateTime.now()).toIso8601String(),
    'title': title,
    'source': source,
    'link': link,
    'host': hostOf(url),
    'engine': engine,
  });

  factory PlaybackReport.fromJson(Map<String, Object?> json) => PlaybackReport._(Map<String, Object?>.of(json));

  final Map<String, Object?> _f;

  Map<String, Object?> toJson() => _f;

  // ── Filling it in ──

  /// A copy with [changes] laid over it (a null value takes that fact away).
  PlaybackReport _with(Map<String, Object?> changes) {
    final next = Map<String, Object?>.of(_f);
    changes.forEach((k, v) => v == null ? next.remove(k) : next[k] = v);
    return PlaybackReport._(next);
  }

  /// What the device can do (the device channel's `getPlaybackCapabilities`: its model, what its
  /// display takes, its Dolby Vision decoders, the profile 7 conversion). Android only.
  PlaybackReport withDevice(Map<String, Object?> caps) => caps.isEmpty ? this : _with({'caps': _clean(caps)});

  /// What Media3 says about the video (its `getStats`), live or as it gave the video up.
  PlaybackReport withMedia3(Map<String, Object?> stats) => stats.isEmpty ? this : _with({'exo': _clean(stats)});

  /// What mpv says about the video (its properties, by their own names).
  PlaybackReport withMpv(Map<String, Object?> facts) => facts.isEmpty ? this : _with({'mpv': _clean(facts)});

  /// The audio track in use, as the player's own track list has it (what mpv or Media3 say
  /// about the decoded sound comes first when they say it).
  PlaybackReport withAudio({String? language, String? codec, int? channels, int? sampleRate}) => _with({
    'audio': {'language': ?language, 'codec': ?codec, 'channels': ?channels, 'sampleRate': ?sampleRate},
  });

  /// The subtitle showing: its name, its language, and where it is from ("Inside the file",
  /// "OpenSubtitles", an addon's name). All null: subtitles are off.
  PlaybackReport withSubtitle({String? name, String? language, String? origin}) => _with({
    'subtitle': name == null && language == null ? null : {'name': ?name, 'language': ?language, 'origin': ?origin},
  });

  /// A first frame showed, [ms] after the open (the app's clock; Media3's own is used when it
  /// has one). After a hand-over it is mpv's, and says mpv played what Media3 gave up.
  PlaybackReport withFirstFrame(int ms) {
    if (handedOver) return _f['mpvFrameMs'] != null ? this : _with({'mpvFrameMs': ms, if (_f['firstFrameMs'] == null) 'firstFrameMs': ms});
    return _f['firstFrameMs'] != null ? this : _with({'firstFrameMs': ms});
  }

  /// It stopped to load again, once more.
  PlaybackReport withRebuffer() => _with({'rebuffers': ((_f['rebuffers'] as num?)?.toInt() ?? 0) + 1});

  /// Media3 handed the video to mpv: what for ([kind]: audio, video, stream, format, stuck,
  /// error), in the plugin's words, and how long after the open.
  PlaybackReport withHandOver({required String kind, String reason = '', String detail = '', int? afterMs}) => _with({
    'handOver': {'kind': kind, 'reason': scrub(reason), 'detail': scrub(detail), 'afterMs': ?afterMs},
  });

  /// It did not play, and why (the player's error, or the app's own words for it).
  PlaybackReport withFailure(String why) => _with({'failure': scrub(why)});

  /// The player closed, [afterMs] after the open.
  PlaybackReport closed(int afterMs) => _with({'closedAfterMs': afterMs});

  // ── Reading it ──

  String _s(String key) => (_f[key] as String?) ?? '';
  Map<String, Object?> _m(String key) => switch (_f[key]) {
    final Map<Object?, Object?> m => m.cast<String, Object?>(),
    _ => const {},
  };

  DateTime get when => DateTime.tryParse(_s('when')) ?? DateTime.fromMillisecondsSinceEpoch(0);
  String get title => _s('title');
  String get source => _s('source');
  String get host => _s('host');
  bool get onMedia3 => _s('engine') == 'media3';
  bool get handedOver => _m('handOver').isNotEmpty;
  int? get firstFrameMs => (_m('exo')['firstFrameMs'] as num?)?.toInt() ?? (_f['firstFrameMs'] as num?)?.toInt();
  bool get started => firstFrameMs != null;
  bool get failed => _s('failure').isNotEmpty;

  /// One line for a list: what it was and how it went ("The Body · handed to mpv").
  String get summary => [if (title.isNotEmpty) title, _outcomeShort].join(' · ');

  String get _outcomeShort {
    if (failed) return started ? 'stopped with an error' : 'did not play';
    if (handedOver) return _f['mpvFrameMs'] != null ? 'played on mpv, after Media3' : 'handed to mpv';
    if (started) return 'played on ${onMedia3 ? 'Media3' : 'mpv'}';
    return _f['closedAfterMs'] == null ? 'starting' : 'closed before it started';
  }

  /// The engine line: Media3, mpv, or mpv after a hand-over and what that was for.
  String get engineLine {
    // (a Media3 player that has given one video to mpv plays the ones after it on mpv too)
    if (_s('engine') == 'mpv-kept') return 'mpv, since Media3 gave an earlier video up';
    if (!onMedia3) return 'mpv';
    if (!handedOver) return 'Media3';
    return 'mpv, after Media3 ${_handOverWords(_m('handOver')['kind'] as String? ?? '')}';
  }

  static String _handOverWords(String kind) => switch (kind) {
    'audio' => 'could not play the sound',
    'video' => 'could not play the picture',
    'stream' => 'lost the stream',
    'format' => 'could not read the file',
    'stuck' => 'got stuck',
    _ => 'could not play it',
  };

  /// Whether mpv has said anything about the video yet (it says nothing until it has it open).
  bool get _mpvKnows => _m('mpv')['video-params/w'] != null || _m('mpv')['audio-codec-name'] != null;

  /// Stream info: the source, the engine, the picture, the sound and the subtitle.
  List<ReportSection> get stream {
    // (after a hand-over the video is mpv's to describe, once it has it open)
    final exo = handedOver && _mpvKnows ? const <String, Object?>{} : _m('exo'), mpv = _m('mpv');
    final link = _s('link');
    final subtitle = _m('subtitle');
    // (after a hand-over, until mpv has the video open, the decoder Media3 used is not what plays it)
    final decoder = handedOver && !_mpvKnows ? null : _str(exo['videoDecoderName']) ?? _mpvDecoder(mpv);
    return [
      (title: 'Source', facts: _facts([
        ('Source', source),
        ('Link', link),
        ('Server', host),
      ])),
      (title: 'Player engine', facts: _facts([
        ('Engine', engineLine),
        ('Video decoder', decoder ?? ''),
      ])),
      (title: 'Video', facts: _facts([
        ('Codec', _videoCodec(exo, mpv)),
        ('Resolution', _resolution(exo, mpv)),
        ('Bitrate', _bitrate(exo['videoBitrate'] ?? mpv['video-bitrate'])),
        ('Frame rate', _fps(exo['videoFps'] ?? mpv['container-fps'])),
      ])),
      (title: 'Audio', facts: _facts([
        ('Codec', _audioCodec(exo, mpv)),
        ('Channels', _channels(exo, mpv)),
        ('Sample rate', _sampleRate(exo['audioSampleRate'] ?? mpv['current-tracks/audio/demux-samplerate'] ?? mpv['audio-params/samplerate'] ?? _m('audio')['sampleRate'])),
        ('Language', _str(_m('audio')['language']) ?? ''),
      ])),
      (title: 'Subtitle', facts: subtitle.isEmpty
          ? const [(label: 'Showing', value: 'Off')]
          : _facts([
              ('Name', _str(subtitle['name']) ?? ''),
              ('Language', _str(subtitle['language']) ?? ''),
              ('From', _str(subtitle['origin']) ?? ''),
            ])),
    ];
  }

  /// The report card: where it came from and what the device has, what was decided about
  /// Dolby Vision, and how it went.
  List<ReportSection> get card {
    final caps = _m('caps');
    // (what Media3 knew stays on the card after a hand-over: it is what went wrong there)
    final exo = _m('exo'), mpv = _m('mpv');
    final display = _list(caps['displayHdr']);
    final decoders = _list(caps['dvDecoders']);
    final profile = (exo['dvSourceProfile'] as num?)?.toInt() ?? (mpv['dvSourceProfile'] as num?)?.toInt() ?? _dvProfile(_str(exo['videoCodec']));
    final asked = _str(exo['dvConversionDebugMode']) ?? (caps['dvAutoMode'] == null ? null : 'AUTO');
    final inEffect = _str(exo['dvConversionMode']) ?? _str(caps['dvAutoMode']) ?? '';
    final bridge = caps['dvBridgeReady'] as bool?;
    final converting = exo['dvConversionActive'] == true;
    final path = _str(exo['dvPlaybackPath']);
    return [
      (title: 'Source and hardware', facts: _facts([
        ('Source', [source, _s('link')].where((x) => x.isNotEmpty).join(' · ')),
        ('Server', host),
        ('When', _when),
        ('Device', [_str(caps['device']) ?? '', if (_str(caps['android']) != null) 'Android ${caps['android']}'].where((x) => x.isNotEmpty).join(' · ')),
        ('Display', caps.isEmpty ? '' : (display.isEmpty ? 'No HDR' : display.join(', '))),
        ('Dolby Vision decoders', caps.isEmpty ? '' : (decoders.isEmpty ? 'None' : decoders.join('\n'))),
      ])),
      (title: 'Decision', facts: _facts([
        ('Engine', engineLine),
        ('Video decoder', _str(exo['videoDecoderName']) ?? _mpvDecoder(mpv) ?? ''),
        ('Source profile', profile == null ? '' : 'Dolby Vision $profile'),
        ('This video', path == null ? '' : _dvPath(path)),
        // (why, where it is not played as it is: the plugin's own words)
        ('Why', path == null || path.startsWith('Native DV') || path == 'DV P8 passthrough' ? '' : _str(exo['dvPlaybackReason']) ?? ''),
        // (what this TV does with profile 7, whatever is playing: the rule other apps call the DV mode)
        ('Profile 7 videos', asked == null ? '' : (asked.toUpperCase() == 'AUTO' ? 'Auto: ${_dvMode(inEffect)}' : '${_dvMode(asked)}, set by hand')),
        ('Conversion bridge', bridge == null ? '' : (converting ? 'In use' : (bridge ? 'Ready, not in use' : 'Not there'))),
      ])),
      (title: 'Outcome', facts: _facts([
        ('HDR format', _hdr(exo, mpv)),
        ('First frame', firstFrameMs == null ? '' : '$firstFrameMs ms'),
        ('Rebuffers', started ? '${(exo['rebuffers'] as num?)?.toInt() ?? (_f['rebuffers'] as num?)?.toInt() ?? 0}' : ''),
        ('Result', result),
        ('What Media3 said', _str(_m('handOver')['detail']) ?? _str(_m('handOver')['reason']) ?? ''),
      ])),
    ];
  }

  /// How it went, in a line: played and on what, handed to mpv and what for, or why not.
  String get result {
    final over = _m('handOver');
    final after = (over['afterMs'] as num?)?.toInt();
    final handed = over.isEmpty
        ? ''
        : 'Media3 ${_handOverWords(over['kind'] as String? ?? '')}${after == null ? '' : ' after ${_seconds(after)}'} and handed it to mpv';
    // (an error after the picture has shown ended it; one before means it never played)
    if (failed) return ['${started ? 'Stopped' : 'Did not play'}: ${_s('failure')}', handed].where((x) => x.isNotEmpty).join('. ');
    if (over.isNotEmpty) return _f['mpvFrameMs'] != null ? '$handed, which played it' : '$handed, which has not shown a picture';
    if (started) return 'Played on ${onMedia3 ? 'Media3' : 'mpv'}';
    final closed = (_f['closedAfterMs'] as num?)?.toInt();
    return closed == null ? 'Has not shown a picture yet' : 'Closed after ${_seconds(closed)} with no picture';
  }

  /// The whole report as text, to paste into a message.
  String get text => [
    'VyseTV playback report',
    if (title.isNotEmpty) title,
    for (final s in [...stream, ...card]) ...['', s.title.toUpperCase(), for (final f in s.facts) '${f.label}: ${f.value}'],
  ].join('\n');

  // ── Plain words for what the engines say ──

  static List<ReportFact> _facts(List<(String, String)> all) => [
    for (final (label, value) in all)
      if (value.trim().isNotEmpty) (label: label, value: value.trim()),
  ];

  static String? _str(Object? v) => switch (v) {
    final String s when s.trim().isNotEmpty => s.trim(),
    _ => null,
  };

  static List<String> _list(Object? v) => v is List ? [for (final x in v) '$x'] : const [];

  static double? _num(Object? v) => switch (v) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s),
    _ => null,
  };

  String get _when {
    final t = when;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static String _seconds(int ms) => ms < 10000 ? '${(ms / 1000).toStringAsFixed(1)} s' : '${(ms / 1000).round()} s';

  static String _dvMode(String mode) => switch (mode.toUpperCase()) {
    'AUTO' => 'Auto',
    'DISABLED' => 'played as they are',
    'DV81' => 'converted to profile 8.1',
    'HEVC_STRIP' => 'played as HDR10',
    '' => 'not known',
    _ => mode,
  };

  /// The plugin's name for how this video's Dolby Vision is played, in plain words.
  static String _dvPath(String path) => switch (path) {
    'P7 -> P8.1' => 'Converted to profile 8.1',
    'P7 -> HEVC' => 'Dolby Vision taken out, played as HDR10',
    'HDR fallback' => 'Played as HDR10, by the HEVC decoder',
    'DV P8 passthrough' => 'Played as it is, by the Dolby Vision decoder',
    _ when path.startsWith('Native DV') => 'Played as it is, by the Dolby Vision decoder',
    _ => path,
  };

  static int? _dvProfile(String? codecs) {
    final m = RegExp(r'dv(?:he|h1|av|a1)\.(\d{2})').firstMatch(codecs?.toLowerCase() ?? '');
    return m == null ? null : int.tryParse(m[1]!);
  }

  static const _videoMimes = {
    'video/hevc': 'HEVC',
    'video/avc': 'H.264',
    'video/av01': 'AV1',
    'video/x-vnd.on2.vp9': 'VP9',
    'video/x-vnd.on2.vp8': 'VP8',
    'video/mpeg2': 'MPEG-2',
    'video/mp4v-es': 'MPEG-4',
    'video/wvc1': 'VC-1',
  };

  static String _mpvVideoCodec(String name) {
    final n = name.toLowerCase();
    for (final (has, label) in const [('hevc', 'HEVC'), ('h.265', 'HEVC'), ('h264', 'H.264'), ('h.264', 'H.264'), ('av1', 'AV1'), ('vp9', 'VP9'), ('vp8', 'VP8'), ('mpeg2', 'MPEG-2'), ('mpeg-2', 'MPEG-2'), ('vc1', 'VC-1'), ('vc-1', 'VC-1'), ('mpeg4', 'MPEG-4')]) {
      if (n.contains(has)) return label;
    }
    return name.split(RegExp(r' [(/]')).first;
  }

  /// HDR as the stream carries it: Dolby Vision with its profile, HDR10, HLG, or SDR.
  String _hdr(Map<String, Object?> exo, Map<String, Object?> mpv) {
    final profile = (exo['dvSourceProfile'] as num?)?.toInt() ?? (mpv['dvSourceProfile'] as num?)?.toInt() ?? _dvProfile(_str(exo['videoCodec']));
    if (exo['videoMimeType'] == 'video/dolby-vision' || profile != null) {
      // (profile 8 through the HEVC decoder: its HDR10 layer is what shows)
      final asHdr10 = _str(exo['dvPlaybackPath']) == 'HDR fallback' || _str(exo['dvConversionMode']) == 'HEVC_STRIP' && exo['dvConversionActive'] == true;
      return asHdr10 ? 'Dolby Vision, shown as HDR10' : 'Dolby Vision';
    }
    final transfer = (exo['colorTransfer'] as num?)?.toInt();
    final gamma = _str(mpv['video-params/gamma']);
    if (transfer == 6 || gamma == 'pq') return 'HDR10';
    if (transfer == 7 || gamma == 'hlg') return 'HLG';
    return exo.isEmpty && mpv.isEmpty ? '' : 'SDR';
  }

  String _videoCodec(Map<String, Object?> exo, Map<String, Object?> mpv) {
    final mime = _str(exo['videoMimeType']), name = _str(mpv['video-codec']);
    if (mime == null && name == null) return '';
    final profile = (exo['dvSourceProfile'] as num?)?.toInt() ?? (mpv['dvSourceProfile'] as num?)?.toInt() ?? _dvProfile(_str(exo['videoCodec']));
    final base = mime == 'video/dolby-vision' ? '' : (mime != null ? (_videoMimes[mime] ?? mime.replaceFirst('video/', '')) : _mpvVideoCodec(name!));
    final hdr = _hdr(exo, mpv);
    if (hdr.startsWith('Dolby Vision')) return [if (profile == null) 'Dolby Vision' else 'Dolby Vision, profile $profile', if (base.isNotEmpty) base].join(' · ');
    return [base, hdr].where((x) => x.isNotEmpty).join(' · ');
  }

  String _resolution(Map<String, Object?> exo, Map<String, Object?> mpv) {
    final w = _num(exo['videoWidth'] ?? mpv['video-params/w'] ?? mpv['videoWidth'])?.round() ?? 0;
    final h = _num(exo['videoHeight'] ?? mpv['video-params/h'] ?? mpv['videoHeight'])?.round() ?? 0;
    if (w <= 0 || h <= 0) return '';
    final name = w >= 3000 ? '4K' : (w >= 1800 ? '1080p' : (w >= 1200 ? '720p' : (w >= 800 ? '480p' : '')));
    return '$w × $h${name.isEmpty ? '' : ' ($name)'}';
  }

  static String _bitrate(Object? bps) {
    final b = _num(bps) ?? 0;
    if (b <= 0) return '';
    return b >= 1e6 ? '${(b / 1e6).toStringAsFixed(1)} Mbps' : '${(b / 1e3).round()} kbps';
  }

  static String _fps(Object? fps) {
    final f = _num(fps) ?? 0;
    if (f <= 1) return '';
    return '${f == f.roundToDouble() ? f.round() : f.toStringAsFixed(3)} fps';
  }

  static const _audioNames = {
    'audio/eac3': 'E-AC-3',
    'audio/eac3-joc': 'E-AC-3, Atmos',
    'audio/ac3': 'AC-3',
    'audio/ac4': 'AC-4',
    'audio/true-hd': 'TrueHD',
    'audio/vnd.dts': 'DTS',
    'audio/vnd.dts.hd': 'DTS-HD',
    'audio/vnd.dts.hd;profile=lbr': 'DTS Express',
    'audio/vnd.dts.uhd;profile=p2': 'DTS:X',
    'audio/mp4a-latm': 'AAC',
    'audio/mpeg': 'MP3',
    'audio/mpeg-l2': 'MP2',
    'audio/flac': 'FLAC',
    'audio/opus': 'Opus',
    'audio/vorbis': 'Vorbis',
    'audio/alac': 'ALAC',
    'audio/raw': 'PCM',
    // mpv's names for the same
    'eac3': 'E-AC-3',
    'ac3': 'AC-3',
    'ac4': 'AC-4',
    'truehd': 'TrueHD',
    'dts': 'DTS',
    'aac': 'AAC',
    'mp3': 'MP3',
    'mp2': 'MP2',
    'flac': 'FLAC',
    'opus': 'Opus',
    'vorbis': 'Vorbis',
    'alac': 'ALAC',
  };

  String _audioCodec(Map<String, Object?> exo, Map<String, Object?> mpv) {
    final said = _str(exo['audioMimeType']) ?? _str(mpv['audio-codec-name']) ?? _str(_m('audio')['codec']);
    if (said == null) return '';
    final key = said.toLowerCase();
    return _audioNames[key] ?? (key.startsWith('pcm') ? 'PCM' : said.replaceFirst('audio/', '').toUpperCase());
  }

  String _channels(Map<String, Object?> exo, Map<String, Object?> mpv) {
    final n = _num(exo['audioChannels'] ?? mpv['current-tracks/audio/demux-channel-count'] ?? _m('audio')['channels'])?.round();
    return switch (n) {
      null || 0 => _str(mpv['audio-params/hr-channels']) ?? '',
      1 => 'Mono',
      2 => 'Stereo',
      6 => '5.1',
      8 => '7.1',
      _ => '$n channels',
    };
  }

  static String _sampleRate(Object? hz) {
    final r = _num(hz) ?? 0;
    if (r <= 0) return '';
    final k = r / 1000;
    return '${k == k.roundToDouble() ? k.round() : k.toStringAsFixed(1)} kHz';
  }

  static String? _mpvDecoder(Map<String, Object?> mpv) => switch (_str(mpv['hwdec-current'])) {
    null => null,
    'no' => 'Software',
    final String d => d,
  };

  // ── Keeping addresses out ──

  static final _address = RegExp(r'''[a-zA-Z][a-zA-Z0-9+.-]*://[^\s,;)\]}"']+''');

  /// The host of [url] alone ("files.example.com"), or '' when it has none (a file on this
  /// device, a torrent).
  static String hostOf(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasScheme || u.scheme == 'file' || u.scheme == 'content' || u.scheme == 'magnet') return '';
    return u.host;
  }

  /// [text] with every address in it cut down to its host.
  static String scrub(String text) => text.replaceAllMapped(_address, (m) {
    final host = hostOf(m[0]!);
    return host.isEmpty ? '(address)' : host;
  });

  /// Only what JSON can hold, and no addresses in any text.
  static Map<String, Object?> _clean(Map<Object?, Object?> raw) => {
    for (final e in raw.entries)
      if (e.key is String)
        e.key as String: switch (e.value) {
          final String s => scrub(s),
          final num n => n,
          final bool b => b,
          final List<Object?> l => [for (final x in l) x is String ? scrub(x) : (x is num || x is bool ? x : '$x')],
          final Map<Object?, Object?> m => _clean(m),
          _ => null,
        },
  }..removeWhere((_, v) => v == null);

  // ── The newest one, kept ──

  static const _key = 'device.lastPlayback';

  /// The newest report, also after the player has closed and the app has been started again.
  /// Null until [load] has read it, or when nothing has been played yet.
  static final last = ValueNotifier<PlaybackReport?>(null);
  static bool _loaded = false;

  /// Reads the kept report (once).
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null && last.value == null) last.value = PlaybackReport.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (_) {
      // nothing kept, or kept by a build that wrote it differently
    }
  }

  /// Makes [report] the newest one and keeps it.
  static Future<void> keep(PlaybackReport report) async {
    _loaded = true;
    last.value = report;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(report.toJson()));
    } catch (_) {
      // (a report that can't be written is still shown while the app runs)
    }
  }

  /// What this device can do with HDR and Dolby Vision, asked of Android once and remembered.
  /// Empty anywhere else.
  static Future<Map<String, Object?>> device() => _device ??= () async {
    try {
      final caps = await deviceChannel.invokeMethod<Map<Object?, Object?>>('getPlaybackCapabilities');
      return caps?.cast<String, Object?>() ?? const <String, Object?>{};
    } catch (_) {
      return const <String, Object?>{};
    }
  }();
  static Future<Map<String, Object?>>? _device;

  @visibleForTesting
  static void debugReset() {
    _device = null;
    _loaded = false;
    last.value = null;
  }
}
