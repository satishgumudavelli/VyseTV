// The playback report (lib/data/playback/playback_report.dart): what the player's Stream info
// and the report card say, from what the engines and the TV report. The values are the ones a
// tester photographed in another app on a TCL TV (2026-11-19, docs/dpad/PLAN.md note 95):
// Dolby Vision profile 5 and 8 at about 12 Mbps with E-AC-3 5.1, from a workers.dev host.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/data/playback/playback_report.dart';

/// What the device channel says of that TV.
const tcl = <String, Object?>{
  'device': 'TCL Smart TV Pro',
  'android': '12',
  'sdk': 31,
  'displayHdr': ['Dolby Vision', 'HDR10', 'HDR10+', 'HLG'],
  'dvDecoders': ['c2.mtk.dvhe.stn.decoder (P5)', 'c2.mtk.dvhe.st.decoder (P8)'],
  'dvProfile5': true,
  'dvProfile7': false,
  'dvProfile8': true,
  'dvBridgeReady': true,
  'dvAutoMode': 'DV81',
  'dvAutoReason': 'active display supports Dolby Vision and decoder advertises Profile 8; converting to Profile 8.1',
};

/// What Media3 says of a profile 5 film it is playing.
const playing = <String, Object?>{
  'videoCodec': 'dvhe.05.06',
  'videoMimeType': 'video/dolby-vision',
  'videoWidth': 3840,
  'videoHeight': 2160,
  'videoFps': 23.976,
  'videoBitrate': 11800000,
  'videoDecoderName': 'c2.mtk.dvhe.stn.decoder',
  'colorTransfer': 6,
  'audioMimeType': 'audio/eac3',
  'audioSampleRate': 48000,
  'audioChannels': 6,
  'firstFrameMs': 4452,
  'rebuffers': 0,
  'dvConversionActive': false,
  'dvConversionMode': 'DV81',
  'dvConversionDebugMode': 'AUTO',
  'dvSourceProfile': 5,
  'dvPlaybackPath': 'Native DV P5',
  'dvPlaybackReason': 'Dolby Vision profile 5 is being sent to the native decoder path',
};

PlaybackReport begin({String engine = 'media3'}) => PlaybackReport.begin(
  title: 'The Body · S1 E1',
  source: '111477',
  link: 'Link 1 · 4K · MKV',
  url: 'https://cdn-7f3a.example.net/files/the.body.s01e01.mkv?token=SECRET123&sig=abc',
  engine: engine,
  when: DateTime(2026, 11, 19, 8, 0, 36),
);

String? fact(List<ReportSection> sections, String section, String label) {
  for (final s in sections) {
    if (s.title != section) continue;
    for (final f in s.facts) {
      if (f.label == label) return f.value;
    }
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Stream info names the source, the engine, the picture, the sound and the subtitle', () {
    final r = begin().withDevice(tcl).withMedia3(playing).withAudio(language: 'English').withSubtitle(name: 'en', language: 'English', origin: 'Inside the file');
    final s = r.stream;
    expect([for (final x in s) x.title], ['Source', 'Player engine', 'Video', 'Audio', 'Subtitle']);
    expect(fact(s, 'Source', 'Source'), '111477');
    expect(fact(s, 'Source', 'Link'), 'Link 1 · 4K · MKV');
    expect(fact(s, 'Source', 'Server'), 'cdn-7f3a.example.net');
    expect(fact(s, 'Player engine', 'Engine'), 'Media3');
    expect(fact(s, 'Player engine', 'Video decoder'), 'c2.mtk.dvhe.stn.decoder');
    expect(fact(s, 'Video', 'Codec'), 'Dolby Vision, profile 5');
    expect(fact(s, 'Video', 'Resolution'), '3840 × 2160 (4K)');
    expect(fact(s, 'Video', 'Bitrate'), '11.8 Mbps');
    expect(fact(s, 'Video', 'Frame rate'), '23.976 fps');
    expect(fact(s, 'Audio', 'Codec'), 'E-AC-3');
    expect(fact(s, 'Audio', 'Channels'), '5.1');
    expect(fact(s, 'Audio', 'Sample rate'), '48 kHz');
    expect(fact(s, 'Audio', 'Language'), 'English');
    expect(fact(s, 'Subtitle', 'From'), 'Inside the file');
    expect(fact(begin().stream, 'Subtitle', 'Showing'), 'Off', reason: 'no subtitle: said, not left out');
  });

  test('the report card: the hardware, the decision and the outcome of a film Media3 plays', () {
    final r = begin().withDevice(tcl).withMedia3(playing);
    final c = r.card;
    expect([for (final x in c) x.title], ['Source and hardware', 'Decision', 'Outcome']);
    expect(fact(c, 'Source and hardware', 'Server'), 'cdn-7f3a.example.net');
    expect(fact(c, 'Source and hardware', 'When'), '2026-11-19 08:00:36');
    expect(fact(c, 'Source and hardware', 'Device'), 'TCL Smart TV Pro · Android 12');
    expect(fact(c, 'Source and hardware', 'Display'), 'Dolby Vision, HDR10, HDR10+, HLG');
    expect(fact(c, 'Source and hardware', 'Dolby Vision decoders'), 'c2.mtk.dvhe.stn.decoder (P5)\nc2.mtk.dvhe.st.decoder (P8)');
    expect(fact(c, 'Decision', 'Why'), isNull, reason: 'played as it is: nothing to explain');
    expect(fact(c, 'Decision', 'Source profile'), 'Dolby Vision 5');
    expect(fact(c, 'Decision', 'This video'), 'Played as it is, by the Dolby Vision decoder');
    expect(fact(c, 'Decision', 'Profile 7 videos'), 'Auto: converted to profile 8.1');
    expect(fact(c, 'Decision', 'Conversion bridge'), 'Ready, not in use');
    expect(fact(c, 'Outcome', 'HDR format'), 'Dolby Vision');
    expect(fact(c, 'Outcome', 'First frame'), '4452 ms');
    expect(fact(c, 'Outcome', 'Rebuffers'), '0');
    expect(fact(c, 'Outcome', 'Result'), 'Played on Media3');
    expect(fact(c, 'Outcome', 'What Media3 said'), isNull);
    expect(r.summary, 'The Body · S1 E1 · played on Media3');
  });

  test('a hand-over: what Media3 gave the film up for, how long in, and whether mpv then played it', () {
    final gaveUp = Map<String, Object?>.of(playing)..remove('firstFrameMs');
    var r = begin().withDevice(tcl).withMedia3(gaveUp).withHandOver(
      kind: 'video',
      reason: 'Decoder hang: c2.mtk.dvhe.stn.decoder accepted input but produced no output',
      detail: 'Decoder hang: c2.mtk.dvhe.stn.decoder took 3 frames and showed none in 5012ms, with 8200ms of the video waiting',
      afterMs: 6210,
    );
    expect(r.engineLine, 'mpv, after Media3 could not play the picture');
    expect(r.result, 'Media3 could not play the picture after 6.2 s and handed it to mpv, which has not shown a picture');
    expect(fact(r.card, 'Outcome', 'What Media3 said'), contains('took 3 frames and showed none in 5012ms'));
    expect(fact(r.card, 'Outcome', 'First frame'), isNull);
    expect(fact(r.card, 'Decision', 'Video decoder'), 'c2.mtk.dvhe.stn.decoder', reason: 'what Media3 knew stays on the card');
    expect(r.summary, endsWith('handed to mpv'));

    r = r.withFirstFrame(9800).withMpv(const {'video-codec': 'hevc', 'video-params/w': 3840, 'video-params/h': 2160, 'video-params/gamma': 'pq', 'hwdec-current': 'mediacodec', 'audio-codec-name': 'eac3', 'current-tracks/audio/demux-channel-count': 6});
    expect(r.result, 'Media3 could not play the picture after 6.2 s and handed it to mpv, which played it');
    expect(fact(r.card, 'Outcome', 'First frame'), '9800 ms');
    // (now mpv describes the stream)
    expect(fact(r.stream, 'Player engine', 'Video decoder'), 'mediacodec');
    expect(fact(r.stream, 'Audio', 'Codec'), 'E-AC-3');

    final stream = begin().withHandOver(kind: 'stream', reason: 'Source error', detail: 'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT (2002) · java.net.SocketTimeoutException: timeout', afterMs: 43000);
    expect(stream.result, 'Media3 lost the stream after 43 s and handed it to mpv, which has not shown a picture');
    expect(begin().withHandOver(kind: 'audio').engineLine, 'mpv, after Media3 could not play the sound');
    expect(begin(engine: 'mpv-kept').engineLine, 'mpv, since Media3 gave an earlier video up');
  });

  test('a film that never started, and one that failed, say so', () {
    expect(begin().result, 'Has not shown a picture yet');
    expect(begin().closed(26000).result, 'Closed after 26 s with no picture');
    expect(begin().closed(26000).summary, 'The Body · S1 E1 · closed before it started');
    final failed = begin().withFailure('HTTP 404');
    expect(failed.result, 'Did not play: HTTP 404');
    expect(failed.summary, endsWith('did not play'));
    final later = begin(engine: 'mpv').withFirstFrame(2100).withFailure('Connection reset');
    expect(later.result, 'Stopped: Connection reset', reason: 'an error after the picture has shown ended it');
    expect(later.summary, endsWith('stopped with an error'));
    expect(fact(begin(engine: 'mpv').withFirstFrame(2100).card, 'Outcome', 'Result'), 'Played on mpv');
  });

  test('mpv on a desktop: its own names for the same facts', () {
    final r = begin(engine: 'mpv').withMpv(const {
      'video-codec': 'h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)',
      'video-params/w': '1920',
      'video-params/h': '1080',
      'video-params/gamma': 'bt.1886',
      'video-bitrate': '5200000',
      'container-fps': '25.000000',
      'hwdec-current': 'd3d11va',
      'audio-codec-name': 'aac',
      'audio-params/samplerate': '44100',
      'audio-params/hr-channels': 'stereo',
    }).withFirstFrame(1800);
    expect(fact(r.stream, 'Player engine', 'Engine'), 'mpv');
    expect(fact(r.stream, 'Video', 'Codec'), 'H.264 · SDR');
    expect(fact(r.stream, 'Video', 'Resolution'), '1920 × 1080 (1080p)');
    expect(fact(r.stream, 'Video', 'Bitrate'), '5.2 Mbps');
    expect(fact(r.stream, 'Video', 'Frame rate'), '25 fps');
    expect(fact(r.stream, 'Audio', 'Codec'), 'AAC');
    expect(fact(r.stream, 'Audio', 'Channels'), 'stereo');
    expect(fact(r.stream, 'Audio', 'Sample rate'), '44.1 kHz');
    expect(fact(r.card, 'Source and hardware', 'Device'), isNull, reason: 'what is not known is left out, not guessed');
    expect(fact(r.card, 'Outcome', 'HDR format'), 'SDR');
  });

  test('no address is ever kept: only the host, also in what the engines say', () {
    final r = begin()
        .withHandOver(kind: 'stream', detail: 'Unable to connect to https://cdn-7f3a.example.net/files/x.mkv?token=SECRET123 (timeout)')
        .withFailure('Failed to open http://portal.example:8080/movie/user/pass123/55.mkv')
        .withMedia3(const {'audioLastSinkError': 'see https://host.example/a?key=K1'});
    final everything = '${r.text}\n${r.toJson()}';
    expect(everything, isNot(contains('SECRET123')));
    expect(everything, isNot(contains('pass123')));
    expect(everything, isNot(contains('K1')));
    expect(everything, isNot(contains('the.body.s01e01')));
    expect(everything, contains('cdn-7f3a.example.net'));
    expect(fact(r.card, 'Outcome', 'What Media3 said'), 'Unable to connect to cdn-7f3a.example.net (timeout)');
    expect(PlaybackReport.hostOf('file:///storage/emulated/0/Movies/a.mkv'), '');
    expect(PlaybackReport.hostOf('magnet:?xt=urn:btih:abc'), '');
  });

  test('the newest report is kept, and read back after a restart', () async {
    SharedPreferences.setMockInitialValues({});
    PlaybackReport.debugReset();
    await PlaybackReport.load();
    expect(PlaybackReport.last.value, isNull);
    await PlaybackReport.keep(begin().withDevice(tcl).withMedia3(playing));
    expect(PlaybackReport.last.value?.result, 'Played on Media3');

    PlaybackReport.debugReset(); // the app starts again
    expect(PlaybackReport.last.value, isNull);
    await PlaybackReport.load();
    final back = PlaybackReport.last.value!;
    expect(back.title, 'The Body · S1 E1');
    expect(back.when, DateTime(2026, 11, 19, 8, 0, 36));
    expect(fact(back.card, 'Source and hardware', 'Dolby Vision decoders'), 'c2.mtk.dvhe.stn.decoder (P5)\nc2.mtk.dvhe.st.decoder (P8)');
    expect(back.text, contains('First frame: 4452 ms'));
  });
}
