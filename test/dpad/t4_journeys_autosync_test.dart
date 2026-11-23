// Automatic subtitle sync (lib/data/subtitles/auto_sync.dart): a downloaded subtitle file lined
// up with the video's own subtitle track, which mpv keeps on hidden as its second subtitle.
// Testers asked for it; mpv has no command of its own for it.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/data/subtitles/auto_sync.dart';
import 'package:vyse_tv/data/subtitles/sound_sync.dart';
import 'package:vyse_tv/data/subtitles/voice_activity.dart';
import 'package:vyse_tv/mpv/mpv.dart' show Player;
import 'package:vyse_tv/screens/player/player_menus.dart' show MenuRow;
import 'package:vyse_tv/widgets/common.dart' show Pressable;

import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

/// A made-up film's own subtitle lines, from 4 s to [until]: a line of 1 to 3.5 s, then a pause
/// that may be short or long, as people talk.
List<Span> filmLines(int seed, {double until = 400}) {
  final rnd = math.Random(seed);
  final out = <Span>[];
  var t = 4.0;
  while (t < until) {
    final d = 1 + rnd.nextDouble() * 2.5;
    out.add((t, t + d));
    t += d + const [.1, .2, .4, .8, 1.5, 3, 6][rnd.nextInt(7)];
  }
  return out;
}

/// The same speech as someone else timed it, for another release and in another language:
/// [shift] seconds early (late when negative), one line in eight joined to the next or cut in
/// two, every time a little off. [scale]: made for another frame rate.
List<Span> retimed(List<Span> film, double shift, int seed, {double scale = 1}) {
  final rnd = math.Random(seed);
  double j() => (rnd.nextDouble() - .5) * .3;
  Span at(double a, double b) => (a / scale - shift, b / scale - shift);
  final out = <Span>[];
  for (var i = 0; i < film.length; i++) {
    var (a, b) = film[i];
    final roll = rnd.nextDouble();
    if (roll < .12 && i + 1 < film.length && film[i + 1].$1 - b < .5) b = film[++i].$2;
    if (roll > .9 && b - a > 2.4) {
      final m = (a + b) / 2;
      out..add(at(a + j(), m))..add(at(m + .05, b + j()));
    } else {
      out.add(at(a + j(), b + j()));
    }
  }
  return out;
}

/// Plays [film] from [from] to [to] as the player would tell [a]: the clock every half second,
/// each line as it starts (and, right after a jump, the line already showing), with a look at
/// the verdict every 8 lines once there are enough. Returns the first verdict that isn't "wait".
AutoSyncVerdict? play(AutoSync a, List<Span> film, double from, double to) {
  var looked = a.lineCount;
  for (var t = from; t <= to; t += .5) {
    a.position(t);
    for (final l in film) {
      if ((l.$1 > t - .5 && l.$1 <= t) || (t == from && l.$1 <= t && t < l.$2)) a.line(l.$1, l.$2);
    }
    if (a.lineCount >= minLines && a.lineCount - looked >= 8) {
      looked = a.lineCount;
      final v = a.verdict();
      if (v.kind != AutoSyncKind.wait) return v;
    }
  }
  return null;
}

/// The share of [film]'s lines that [m] puts within 0.35 s of where they are, the file having
/// each at [toFile] of its film time.
double placed(SyncMap m, List<Span> film, double Function(double) toFile) {
  var ok = 0;
  for (final l in film) {
    if ((toFile(l.$1) + m.delayAt(l.$1) - l.$1).abs() <= .35) ok++;
  }
  return ok / film.length;
}

/// The subtitle delays in [calls] (mpv's "setProperty {name: sub-delay, value: 2.400}", or
/// Media3's "setMpvProperty …"), oldest first; [method] '' takes either.
List<double> delays(List<String> calls, String method) => [
  for (final c in calls)
    if (c.startsWith(method) && c.contains('name: sub-delay,')) double.parse(RegExp(r'value: (-?[\d.]+)').firstMatch(c)![1]!),
];

/// A Matroska file as a muxer writes one, with no picture or sound in it: a seek table, its
/// tracks (a video track and an English SRT track), a cluster where the film would begin, and
/// at the end the index, where every subtitle line has its time and duration (as MKVToolNix
/// and FFmpeg write them).
Uint8List mkv(List<Span> subs) {
  List<int> id(int v) => [for (var k = 3; k >= 0; k--) if (v >> (8 * k) != 0) (v >> (8 * k)) & 0xFF];
  List<int> el(int i, List<int> body) => [...id(i), 0x01, for (var k = 6; k >= 0; k--) (body.length >> (8 * k)) & 0xFF, ...body];
  List<int> uint(int i, int v) => el(i, [for (var k = 7; k >= 0; k--) (v >> (8 * k)) & 0xFF]);
  List<int> str(int i, String s) => el(i, s.codeUnits);
  final ebml = el(0x1A45DFA3, [...str(0x4282, 'matroska'), ...uint(0x4287, 4)]);
  final info = el(0x1549A966, uint(0x2AD7B1, 1000000));
  final tracks = el(0x1654AE6B, [
    ...el(0xAE, [...uint(0xD7, 1), ...uint(0x83, 1), ...str(0x86, 'V_MPEG4/ISO/AVC')]),
    ...el(0xAE, [...uint(0xD7, 2), ...uint(0x83, 0x11), ...str(0x86, 'S_TEXT/UTF8'), ...str(0x22B59C, 'eng')]),
  ]);
  final cluster = el(0x1F43B675, uint(0xE7, 0));
  final cues = el(0x1C53BB6B, [
    ...el(0xBB, [...uint(0xB3, 0), ...el(0xB7, [...uint(0xF7, 1), ...uint(0xF1, 0)])]),
    for (final s in subs)
      ...el(0xBB, [...uint(0xB3, (s.$1 * 1000).round()), ...el(0xB7, [...uint(0xF7, 2), ...uint(0xF1, 0), ...uint(0xB2, ((s.$2 - s.$1) * 1000).round())])]),
  ]);
  List<int> seek(int info, int tracks, int cues) => el(0x114D9B74, [
    for (final (i, at) in [(0x1549A966, info), (0x1654AE6B, tracks), (0x1C53BB6B, cues)]) ...el(0x4DBB, [...el(0x53AB, id(i)), ...uint(0x53AC, at)]),
  ]);
  final infoAt = seek(0, 0, 0).length, tracksAt = infoAt + info.length, cuesAt = tracksAt + tracks.length + cluster.length;
  return Uint8List.fromList([...ebml, ...el(0x18538067, [...seek(infoAt, tracksAt, cuesAt), ...info, ...tracks, ...cluster, ...cues])]);
}

/// [lines] as an SRT file, in French.
String srt(List<Span> lines) {
  String at(double s) {
    final ms = (math.max(0, s) * 1000).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
  }

  final b = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    b.write('${i + 1}\n${at(lines[i].$1)} --> ${at(lines[i].$2)}\nUne ligne en français, ${i + 1}\n\n');
  }
  return b.toString();
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.windows);
  });
  final desktop = OnScreens([Screens.desktop]);

  group('a film on mpv with English subtitles of its own, and a French file downloaded for another release', () {
    final own = filmLines(21, until: 420); // the video's own English lines
    late FakeRoute route;
    late String file; // the downloaded file, as its host sends it
    setUp(() {
      debugFilmSources = [
        FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/film.mkv', type: 'mkv')]),
      ];
      route = Bed.http.route;
      Bed.http.route = (method, uri) => switch (uri.host) {
        'files.test' => const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska'),
        'subs.test' => FakeReply(200, utf8.encode(file), type: 'text/plain; charset=utf-8'),
        _ => route(method, uri),
      };
      // the video's tracks as mpv lists them: the picture, and English subtitles (SRT)
      Bed.videoProperties.addAll({
        'track-list/count': '2',
        'track-list/0/type': 'video',
        'track-list/1/type': 'sub',
        'track-list/1/external': 'no',
        'track-list/1/codec': 'subrip',
        'track-list/1/id': '1',
        'track-list/1/lang': 'eng',
        'track-list/1/title': 'English',
        'track-list/1/forced': 'no',
      });
    });
    tearDown(() {
      debugFilmSources = null;
      Bed.http.route = route;
      Bed.videoProperties.clear();
      AppSettings.autoSyncSubtitles.set(true);
    });

    /// Opens a film you watched a few seconds of with the French file on ([delay]: the timing
    /// you had; [mine]: the automatic sync's, not yours), and lets mpv list its tracks.
    Future<dynamic> open(WidgetTester t, {double delay = 0, bool mine = false}) async {
      final film = Bed.freshTitle();
      WatchProgress.record(
        film,
        position: const Duration(seconds: 4),
        duration: const Duration(minutes: 100),
        subtitle: {'id': 'fr-1', 'provider': 'OpenSubtitles', 'lang': 'fr', 'language': 'French', 'release': '', 'url': 'http://subs.test/film.fr.srt', 'format': 'srt', if (mine) 'autoSync': true},
        subDelay: delay,
      );
      Bed.videoCalls.clear();
      await Bed.openPlayer(t, media: film);
      bool added() => Bed.videoCalls.any((c) => c.startsWith('command') && c.contains('sub-add'));
      // (the file is written to disk first: real time, which a busy machine can make long)
      for (var i = 0; i < 40 && !added(); i++) {
        await Bed.settle(t, rounds: 2);
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      expect(added(), isTrue, reason: 'the French file is on: ${Bed.videoCalls}');
      await Bed.videoProperty(t, 'duration', 6000.0);
      await Bed.videoProperty(t, 'track-list', [
        {'id': 1, 'type': 'video', 'selected': true},
        {'id': 1, 'type': 'sub', 'lang': 'eng', 'codec': 'subrip'},
      ]);
      await t.pump(const Duration(milliseconds: 400)); // (the page reads the list 300 ms after a change)
      await Bed.settle(t, rounds: 2);
      return film;
    }

    /// Plays from [from] to [to] as mpv tells it: the clock every 2 s, and each of the video's own
    /// lines on the hidden second track as it shows and goes. (The player passes the clock on
    /// four times a second at most, by the real clock: a quarter of a second really passes
    /// before each reading.)
    Future<void> play(WidgetTester t, double from, double to) async {
      await Bed.videoProperty(t, 'pause', false);
      await Bed.videoProperty(t, 'paused-for-cache', false);
      for (var at = from; at <= to; at++) {
        if ((at - from) % 2 == 0) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 260)));
          await Bed.videoProperty(t, 'time-pos', at);
        }
        for (final l in own) {
          if (l.$2 > at - 1 && l.$2 <= at) {
            await Bed.videoProperty(t, 'secondary-sub-start', null);
            await Bed.videoProperty(t, 'secondary-sub-end', null);
          }
          if (l.$1 > at - 1 && l.$1 <= at) {
            await Bed.videoProperty(t, 'secondary-sub-start', l.$1);
            await Bed.videoProperty(t, 'secondary-sub-end', l.$2);
          }
        }
      }
    }

    /// Leaves the player. Leaving saves your progress, and Home's Continue watching hears of it
    /// while Flutter is still taking the player down, which a debug build's check reports. That
    /// is how the app was before this feature; it is taken here so the test sees past it.
    Future<void> close(WidgetTester t) async {
      await Bed.closePlayer(t);
      final e = t.takeException();
      expect(e == null || '$e'.contains('locked') || '$e'.contains('Multiple exceptions'), isTrue, reason: '$e');
      await t.pump(const Duration(seconds: 31)); // (the film sources' timers)
    }

    String set(String name) => 'setProperty {name: $name, ';
    List<String> sets(String name) => [for (final c in Bed.videoCalls) if (c.startsWith(set(name))) c];
    final none = {'setProperty {name: sub-delay, value: 0.000}'};

    testWidgets("the French file timed 2.4 s early: the video's English track goes on hidden, and after two minutes or so the file is moved 2.4 s, said once", (t) async {
      file = srt(retimed(own, 2.4, 22));
      final film = await open(t);
      final hide = Bed.videoCalls.indexWhere((c) => c.startsWith(set('secondary-sub-visibility')) && c.contains('value: no}'));
      final on = Bed.videoCalls.indexWhere((c) => c.startsWith(set('secondary-sid')) && c.contains('value: 1}'));
      expect(on, greaterThan(-1), reason: 'the English track is on as the second subtitle: ${Bed.videoCalls}');
      expect(hide, inInclusiveRange(0, on), reason: 'hidden before it is on: it never shows');
      expect(sets('sub-delay').toSet(), none, reason: 'nothing moved yet');

      await play(t, 0, 100);
      expect(sets('sub-delay').toSet(), none, reason: 'not before two minutes of it');
      await play(t, 101, 260);
      expect(delays(Bed.videoCalls, 'setProperty').last, closeTo(2.4, .1), reason: '${sets('sub-delay')}');
      expect(find.textContaining('Subtitles synced to the video (+2.'), findsOneWidget);
      expect(sets('secondary-sid').last, contains('value: 1}'), reason: 'the English track stays on, to follow what comes');
      await t.pump(const Duration(seconds: 10)); // (the note goes)
      await play(t, 261, 300);
      expect(delays(Bed.videoCalls, 'setProperty').skip(1), everyElement(closeTo(2.4, .1)), reason: 'it stays put');
      expect(find.textContaining('Subtitles synced'), findsNothing, reason: 'said once');
      expect(Bed.audioCalls.where((c) => c.startsWith('mpv_audio_listener')), isEmpty, reason: 'nothing heard by ear: it has subtitles of its own');

      await close(t);
      final saved = WatchProgress.find(film)!;
      expect(saved.subDelay, closeTo(2.4, .1), reason: 'kept with your progress, like a sync by hand');
      expect(saved.subtitle?['autoSync'], isTrue, reason: "as the automatic sync's: it may time it again next time");
    }, variant: desktop);

    testWidgets('a file for something else: nothing is moved', (t) async {
      file = srt(retimed(filmLines(23, until: 420), 0, 24));
      await open(t);
      expect(sets('secondary-sid'), isNotEmpty);
      await play(t, 0, 300);
      expect(sets('sub-delay').toSet(), none);
      expect(find.textContaining('Subtitles synced'), findsNothing);
      await close(t);
    }, variant: desktop);

    testWidgets("your own timing comes first: a delay you set stays, and the video's track is never put on", (t) async {
      file = srt(retimed(own, 2.4, 25));
      await open(t, delay: 1.5);
      expect(sets('secondary-sid').where((c) => !c.contains('value: no}')), isEmpty);
      expect(sets('sub-delay').toSet(), {'setProperty {name: sub-delay, value: 1.500}'});
      await close(t);
    }, variant: desktop);

    testWidgets('a delay the automatic sync set last time may be timed again', (t) async {
      file = srt(retimed(own, 2.4, 26));
      await open(t, delay: 1.5, mine: true);
      expect(sets('secondary-sid').where((c) => c.contains('value: 1}')), isNotEmpty);
      await play(t, 0, 260);
      expect(delays(Bed.videoCalls, 'setProperty').last, closeTo(2.4, .1), reason: '${sets('sub-delay')}');
      await close(t);
    }, variant: desktop);

    testWidgets("off in Settings: the video's track is never put on", (t) async {
      AppSettings.autoSyncSubtitles.set(false);
      file = srt(retimed(own, 2.4, 27));
      await open(t);
      expect(sets('secondary-sid').where((c) => !c.contains('value: no}')), isEmpty);
      await close(t);
    }, variant: desktop);

    testWidgets('"Sync automatically" in the subtitle menu: with a remote, off puts back the timing it set and stops listening; a click turns it on again', (t) async {
      file = srt(retimed(own, 2.4, 28));
      await open(t);
      await play(t, 0, 260);
      expect(delays(Bed.videoCalls, 'setProperty').last, closeTo(2.4, .1));
      await t.pump(const Duration(seconds: 10)); // (the note goes)
      MenuRow row() => t.widget<MenuRow>(find.byWidgetPredicate((w) => w is MenuRow && w.title == 'Sync automatically'));

      // the dock's Subtitles, then along the list (from its tabs: the file in use, restored with
      // your progress, is in no language's list here) to under Sync subtitles
      await Bed.down(t);
      final tool = Bed.nodeOf(t, find.byWidgetPredicate((w) => w is Pressable && w.tooltip == 'Subtitles (C)'));
      for (var i = 0; i < 14 && !tool.hasPrimaryFocus; i++) {
        await Bed.right(t);
      }
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      final from = Bed.focused();
      for (var i = 0; i < 6 && !Bed.focused().contains('Sync automatically'); i++) {
        await (from.contains('MenuSegments') ? Bed.down(t) : Bed.up(t));
      }
      expect(Bed.focused(), contains('Sync automatically'), reason: 'right under Sync subtitles (the menu opened on $from)');
      expect((row().value, row().detail), ('On', 'Synced to the video'));

      await Bed.ok(t);
      await Bed.settle(t, rounds: 2);
      expect(AppSettings.autoSyncSubtitles.value, isFalse, reason: 'the same setting as in Settings');
      expect((row().value, row().detail), ('Off', 'Lines them up with the video'));
      expect(delays(Bed.videoCalls, 'setProperty').last, 0, reason: 'the timing it set is put back');
      expect(sets('secondary-sid').last, contains('value: no}'), reason: "the video's track is taken off");
      expect(Bed.focused(), contains('Sync automatically'), reason: 'the ring stays on it');

      await t.tap(find.text('Sync automatically'));
      await Bed.settle(t, rounds: 3);
      expect(AppSettings.autoSyncSubtitles.value, isTrue);
      expect(row().value, 'On');
      expect(sets('secondary-sid').last, contains('value: 1}'), reason: 'listening again, to time the file afresh');
      await Bed.back(t);
      await close(t);
    }, variant: desktop);
  });

  group("a film whose MKV indexes its own English subtitles, and a French file for another release", () {
    final own = filmLines(41, until: 3000); // the video's own English lines, in its index
    late FakeRoute route;
    late String file;
    final video = mkv(own);
    setUp(() {
      debugFilmSources = [
        FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/indexed.mkv', type: 'mkv')]),
      ];
      route = Bed.http.route;
      Bed.http.route = (method, uri) => switch (uri.host) {
        'files.test' => FakeReply(200, video, type: 'video/x-matroska', ranged: true),
        'subs.test' => FakeReply(200, utf8.encode(file), type: 'text/plain; charset=utf-8'),
        _ => route(method, uri),
      };
    });
    tearDown(() {
      debugFilmSources = null;
      Bed.http.route = route;
      PlayerEngine.debugOffered = null;
      Player.debugExoOnAnyPlatform = false;
      AppSettings.playerEngine.set('');
    });

    /// Opens a film you watched a few seconds of with the French file on, on [engine]'s calls
    /// (mpv's, or Media3's), and waits for the first delay that isn't nothing.
    Future<void> open(WidgetTester t, List<String> engine) async {
      final film = Bed.freshTitle();
      WatchProgress.record(
        film,
        position: const Duration(seconds: 4),
        duration: const Duration(minutes: 100),
        subtitle: const {'id': 'fr-2', 'provider': 'OpenSubtitles', 'lang': 'fr', 'language': 'French', 'release': '', 'url': 'http://subs.test/other.fr.srt', 'format': 'srt'},
      );
      engine.clear();
      await Bed.openPlayer(t, media: film);
      // (the file is written to disk, the index read, the film fitted away from the screen's
      // thread: real time)
      for (var i = 0; i < 60 && delays(engine, '').every((d) => d == 0); i++) {
        await Bed.settle(t, rounds: 1);
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
    }

    Future<void> clock(WidgetTester t, String channel, double at) async {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 260)));
      if (channel == 'exo') {
        await Bed.exoProperty(t, 'time-pos', at);
      } else {
        await Bed.videoProperty(t, 'time-pos', at);
      }
    }

    testWidgets('on mpv: fitted from the index as it opens, before a second of it plays', (t) async {
      file = srt(retimed(own, 2.4, 42));
      await open(t, Bed.videoCalls);
      expect(delays(Bed.videoCalls, 'setProperty').last, closeTo(2.4, .1), reason: '${Bed.videoCalls.where((c) => c.contains('sub-delay'))}');
      expect(find.textContaining('Subtitles synced to the video (+2.'), findsOneWidget);
      await Bed.closePlayer(t);
      t.takeException(); // (see close() above)
      await t.pump(const Duration(seconds: 31));
    }, variant: desktop);

    testWidgets("on Media3 (an Android TV's player): the same, through Media3", (t) async {
      PlayerEngine.debugOffered = true;
      Player.debugExoOnAnyPlatform = true;
      AppSettings.playerEngine.set('');
      file = srt(retimed(own, -3.1, 44));
      await open(t, Bed.exoCalls);
      expect(delays(Bed.exoCalls, 'setMpvProperty').last, closeTo(-3.1, .1), reason: '${Bed.exoCalls.where((c) => c.contains('sub-delay'))}');
      expect(find.textContaining('Subtitles synced to the video (−3.'), findsOneWidget);
      await Bed.closePlayer(t);
      t.takeException();
      await t.pump(const Duration(seconds: 31));
    }, variant: desktop);

    testWidgets('a file made for 25 fps slides further off as the film goes on: the delay follows it, said once', (t) async {
      const speed = 25 / 23.976;
      file = srt(retimed(own, 1, 45, scale: speed));
      await open(t, Bed.videoCalls);
      expect(find.textContaining('Subtitles synced to the video'), findsOneWidget);
      await t.pump(const Duration(seconds: 10)); // (the note goes)
      for (final at in [600.0, 1800.0, 2700.0]) {
        await clock(t, 'mpv', at);
        // a line of the file at c belongs at c × speed + 1 × speed: at film time t, the delay is
        // t − (t − 1 × speed) / speed
        expect(delays(Bed.videoCalls, 'setProperty').last, closeTo(at - (at - speed) / speed, .3), reason: 'at ${at}s');
      }
      expect(find.textContaining('Subtitles synced'), findsNothing, reason: 'quiet after the first');
      await Bed.closePlayer(t);
      t.takeException();
      await t.pump(const Duration(seconds: 31));
    }, variant: desktop);
  });

  testWidgets('Settings > Subtitles has "Sync automatically", with mpv and with Media3 (the file index works on both)', (t) async {
    addTearDown(() {
      PlayerEngine.debugOffered = null;
      AppSettings.playerEngine.set('');
    });
    PlayerEngine.debugOffered = true;
    AppSettings.playerEngine.set('mpv');
    await openSettings(t, 'Subtitles');
    await Bed.settle(t, rounds: 2);
    expect(find.text('Sync automatically'), findsOneWidget);
    AppSettings.playerEngine.set(''); // Media3
    await Bed.settle(t, rounds: 2);
    expect(find.text('Sync automatically'), findsOneWidget);
  }, variant: desktop);

  group('the matcher', () {
    test('timed 2.4 s early for another release, in another language, lines joined and cut differently: +2.4 s, once two minutes are heard', () {
      final film = filmLines(1);
      final a = AutoSync(retimed(film, 2.4, 2));
      expect(play(a, film, 0, 70), isNull);
      expect(a.verdict().kind, AutoSyncKind.wait, reason: 'a minute is not enough');
      final v = play(a, film, 70, 300)!;
      expect(v.kind, AutoSyncKind.fits, reason: v.why);
      expect(v.map!.simple, isTrue, reason: v.why);
      expect(v.map!.delayAt(100), closeTo(2.4, .1), reason: v.why);
      expect(a.playedSeconds, lessThan(200), reason: 'it answers within a few minutes: ${v.why}');
    });

    test('7.5 s late, heard in two stretches with a seek between: −7.5 s', () {
      final film = filmLines(3, until: 600);
      final a = AutoSync(retimed(film, -7.5, 4));
      expect(play(a, film, 30, 100), isNull);
      final v = play(a, film, 380, 560)!;
      expect(v.kind, AutoSyncKind.fits, reason: v.why);
      expect(v.map!.delayAt(400), closeTo(-7.5, .1), reason: v.why);
    });

    test("the video's own track also has lines for sounds ([door shuts]) that the file hasn't: +2.4 s still", () {
      final film = filmLines(5);
      final rnd = math.Random(6);
      final own = [
        ...film,
        for (var i = 0; i + 1 < film.length; i++)
          if (film[i + 1].$1 - film[i].$2 > 2.5 && rnd.nextDouble() < .6) (film[i].$2 + .4, film[i].$2 + 1.6),
      ]..sort((x, y) => x.$1.compareTo(y.$1));
      final a = AutoSync(retimed(film, 2.4, 7));
      final v = play(a, own, 0, 400)!;
      expect(v.kind, AutoSyncKind.fits, reason: v.why);
      expect(v.map!.delayAt(200), closeTo(2.4, .1), reason: v.why);
    });

    test('a file for something else: never fits, and it gives up', () {
      final film = filmLines(8, until: 1200);
      final a = AutoSync(retimed(filmLines(9, until: 1200), 0, 10));
      final v = play(a, film, 0, 1200);
      expect(v?.kind, AutoSyncKind.unclear, reason: v?.why ?? 'never answered: ${a.verdict().why}');
    });

    test('made for 25 frames a second (it slides further off as the film goes on): its speed is found, and every line lands', () {
      final film = filmLines(11, until: 900);
      const speed = 25 / 23.976;
      final a = AutoSync(retimed(film, 1, 12, scale: speed));
      final v = play(a, film, 0, 900)!;
      expect(v.kind, AutoSyncKind.fits, reason: v.why);
      expect(v.map!.parts.single.$2, closeTo(speed, .0005), reason: v.why);
      expect(placed(v.map!, film, (t) => t / speed - 1), greaterThan(.95), reason: v.why);
    });

    test('a scene the file does not have: the start has one shift, the rest another, and both are followed', () {
      final film = filmLines(13, until: 600);
      final file = [
        ...retimed([for (final l in film) if (l.$1 < 60) l], 2.4, 14),
        ...retimed([for (final l in film) if (l.$1 >= 60) l], 8, 15),
      ];
      final a = AutoSync(file);
      final v = play(a, film, 0, 600)!;
      expect(v.kind, AutoSyncKind.fits, reason: v.why);
      expect(v.map!.parts, hasLength(2), reason: v.why);
      expect(placed(v.map!, film, (t) => t < 60 ? t - 2.4 : t - 8), greaterThan(.9), reason: v.why);
    });

    test("a whole film's index against a file 1.5 s late that slides another 0.6 s by the end: fitted at once, part by part", () {
      final film = filmLines(31, until: 7200);
      const speed = 1 + .6 / 7200;
      final v = fitSubtitles(film, retimed(film, -1.5, 32, scale: speed), const [(0, 7200)], whole: true);
      expect(v.kind, AutoSyncKind.fits, reason: v.why);
      expect(placed(v.map!, film, (t) => t / speed + 1.5), greaterThan(.95), reason: v.why);
    });

    test("a whole film's index against a 25 fps file with a 50 s scene missing at 40 minutes: two parts, every line lands", () {
      final film = filmLines(33, until: 7200);
      const speed = 25 / 23.976;
      final file = [
        ...retimed([for (final l in film) if (l.$1 < 2400) l], 1, 34, scale: speed),
        ...retimed([for (final l in film) if (l.$1 >= 2450) l], 1 + 50 / speed, 35, scale: speed),
      ];
      final v = fitSubtitles(film, file, const [(0, 7200)], whole: true);
      expect(v.kind, AutoSyncKind.fits, reason: v.why);
      expect(v.map!.parts, hasLength(2), reason: v.why);
      final kept = [for (final l in film) if (l.$1 < 2400 || l.$1 >= 2450) l];
      expect(placed(v.map!, kept, (t) => t < 2400 ? t / speed - 1 : (t - 50) / speed - 1), greaterThan(.95), reason: v.why);
    });

    test("a whole film's index against a file for something else: unclear", () {
      final v = fitSubtitles(filmLines(36, until: 7200), retimed(filmLines(37, until: 7200), 0, 38), const [(0, 7200)], whole: true);
      expect(v.kind, AutoSyncKind.unclear, reason: v.why);
    });
  });

  group('by ear', () {
    test('the voice detector hears a made-up voice, and not the quiet before it', () {
      final speech = detectSpeech(sound(const [(1.0, 5.0)], 0, 5));
      expect(speech.sublist(0, 100).where((s) => s == 1), isEmpty, reason: 'the quiet second');
      expect(speech.sublist(110).where((s) => s == 1).length, greaterThan(300), reason: 'the voice');
    });

    test('a file 2.4 s early is moved 2.4 s by two stretches of speech, heard with misses and music taken for speech', () {
      final own = filmLines(61, until: 1800);
      final file = retimed(own, 2.4, 62);
      final v = fitToSpeech([heardOf(own, 300, seed: 1), heardOf(own, 1100, seed: 2)], file);
      expect(v.kind, AutoSyncKind.fits, reason: v.why);
      expect(v.map!.delayAt(500), closeTo(2.4, .1), reason: v.why);
    });

    test('a file made for 25 fps: its speed is found by ear', () {
      const speed = 25 / 23.976;
      final own = filmLines(63, until: 1800);
      final v = fitToSpeech([heardOf(own, 400, seed: 3), heardOf(own, 1300, seed: 4)], retimed(own, 1, 64, scale: speed));
      expect(v.kind, AutoSyncKind.fits, reason: v.why);
      expect(v.map!.parts.single.$2, closeTo(speed, .0005), reason: v.why);
    });

    test("another film's file, or one stretch only: nothing", () {
      final own = filmLines(65, until: 1800);
      final heard = [heardOf(own, 300, seed: 5), heardOf(own, 1100, seed: 6)];
      expect(fitToSpeech(heard, retimed(filmLines(66, until: 1800), 0, 67)).kind, AutoSyncKind.unclear);
      expect(fitToSpeech(heard.take(1).toList(), retimed(own, 2.4, 68)).kind, AutoSyncKind.wait);
    });

    test('what is spoken: not a sound described or a song', () {
      final lines = spokenLines(const [(1, 2, 'Where were you?'), (3, 4, '[door shuts]'), (5, 6, '(laughs)'), (7, 8, '♪ la la ♪'), (9, 10, '<i>Not now.</i>')]);
      expect(lines, const [(1, 2), (9, 10)]);
    });

    test('where to listen: where the file has dialogue, spread over the film, the first soon', () {
      final lines = [
        for (var t = 0.0; t < 3600; t += 4)
          if (t < 1200 || t > 1500) (t, t + (t > 2000 && t < 2200 ? 3.5 : 1.5)),
      ];
      final at = listenAt(lines, 3600, 600);
      expect(at.first, inInclusiveRange(615, 1215), reason: 'soon after where you are: $at');
      expect(at.where((a) => a >= 2000 - 45 && a <= 2200), isNotEmpty, reason: 'where the dialogue is thickest: $at');
      expect(at.every((a) => a + 45 <= 3600 - 288), isTrue, reason: 'not the closing credits: $at');
      for (var i = 0; i < at.length; i++) {
        for (var j = i + 1; j < at.length; j++) {
          expect((at[i] - at[j]).abs(), greaterThanOrEqualTo(45), reason: 'spread: $at');
        }
      }
    });
  });

  group('a film with no subtitles of its own (an MP4), and a French file for another release', () {
    final own = filmLines(51, until: 1800); // when people speak in it
    late FakeRoute route;
    late String file;
    setUp(() {
      debugFilmSources = [
        FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/film.mp4', type: 'mp4')]),
      ];
      route = Bed.http.route;
      Bed.http.route = (method, uri) => switch (uri.host) {
        'files.test' => const FakeReply(206, [0, 0, 0, 0], type: 'video/mp4'),
        'subs.test' => FakeReply(200, utf8.encode(file), type: 'text/plain; charset=utf-8'),
        _ => route(method, uri),
      };
    });
    tearDown(() {
      debugFilmSources = null;
      Bed.http.route = route;
    });

    testWidgets("by ear: the listener decodes two stretches of the film's sound ahead, the speech is heard, and the French file is moved 2.4 s", (t) async {
      file = srt(retimed(own, 2.4, 52));
      final film = Bed.freshTitle();
      WatchProgress.record(
        film,
        position: const Duration(seconds: 4),
        duration: const Duration(minutes: 100),
        subtitle: const {'id': 'fr-3', 'provider': 'OpenSubtitles', 'lang': 'fr', 'language': 'French', 'release': '', 'url': 'http://subs.test/ear.fr.srt', 'format': 'srt'},
      );
      Bed.videoCalls.clear();
      Bed.audioCalls.clear();
      await Bed.openPlayer(t, media: film);
      bool added() => Bed.videoCalls.any((c) => c.startsWith('command') && c.contains('sub-add'));
      for (var i = 0; i < 40 && !added(); i++) {
        await Bed.settle(t, rounds: 2);
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      expect(added(), isTrue);
      await Bed.videoProperty(t, 'duration', 1800.0);
      await Bed.videoProperty(t, 'pause', false);
      await Bed.videoProperty(t, 'paused-for-cache', false);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 260)));
      await Bed.videoProperty(t, 'time-pos', 30.0);

      // each stretch the listener is asked for: its sound written where it was told to write
      // it, then "done", as mpv would
      final answered = <String>[];
      for (var i = 0; i < 150 && delays(Bed.videoCalls, 'setProperty').every((d) => d == 0); i++) {
        await t.pump(const Duration(seconds: 1));
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        final calls = Bed.audioCalls;
        final asked = calls.lastIndexWhere((c) => c.startsWith('mpv_audio_listener setProperty {name: ao-pcm-file,'));
        if (asked < 0) continue;
        final path = RegExp(r'value: (.*)\}$').firstMatch(calls[asked])![1]!;
        final opened = calls.skip(asked).any((c) => c.startsWith('mpv_audio_listener command') && c.contains('loadfile'));
        if (answered.contains(path) || !opened) continue;
        final end = double.parse(RegExp(r'value: ([\d.]+)').firstMatch(calls.lastWhere((c) => c.startsWith('mpv_audio_listener setProperty {name: end,')))![1]!);
        answered.add(path);
        await t.runAsync(() => File(path).writeAsBytes(sound(own, end - 45, 45).buffer.asUint8List()));
        await Bed.audioProperty(t, 'mpv_audio_listener', 'eof-reached', true);
        await Bed.audioProperty(t, 'mpv_audio_listener', 'eof-reached', false);
      }
      expect(answered, hasLength(2),
          reason: 'two stretches were enough: ${Bed.audioCalls.where((c) => c.contains('setProperty {name: end'))}; '
              'delays ${delays(Bed.videoCalls, 'setProperty')}; the listener: ${Bed.audioCalls.take(12)}');
      expect(Bed.audioCalls.where((c) => c.startsWith('mpv_audio_listener setProperty {name: ao,')).every((c) => c.contains('value: pcm}')), isTrue,
          reason: 'to a file, never the speakers');
      expect(delays(Bed.videoCalls, 'setProperty').last, closeTo(2.4, .15), reason: '${Bed.videoCalls.where((c) => c.contains('sub-delay'))}');
      expect(find.textContaining('Subtitles synced to the video (+2.'), findsOneWidget);
      await Bed.settle(t, rounds: 2);
      expect(Bed.audioCalls.where((c) => c.startsWith('mpv_audio_listener dispose')), hasLength(1), reason: 'nothing more to hear: the listener goes');
      await Bed.closePlayer(t);
      t.takeException(); // (Continue watching hears the progress saved as the player closes)
      await t.pump(const Duration(seconds: 31));
    }, variant: desktop);
  });
}

/// The speech heard in [seconds] of a film from [start]: where [own] has a line, speech, missed
/// a sixth of the time; elsewhere, a third of the time taken for speech (music, a crowd).
Heard heardOf(List<Span> own, double start, {double seconds = 45, int seed = 1}) {
  final rnd = math.Random(seed);
  final out = Uint8List((seconds * 100).round());
  var k = 0;
  for (var i = 0; i < out.length; i++) {
    final t = start + i / 100;
    while (k < own.length && own[k].$2 <= t) {
      k++;
    }
    final speaking = k < own.length && own[k].$1 <= t;
    out[i] = speaking ? (rnd.nextDouble() < .16 ? 0 : 1) : (rnd.nextDouble() < .33 ? 1 : 0);
  }
  return Heard(start, out);
}

/// [seconds] of a film's sound from [start], 16 kHz mono 16-bit: a made-up voice (a buzz shaped
/// like an "ah", four syllables a second) wherever [own] has a line, a faint hiss elsewhere.
Int16List sound(List<Span> own, double start, double seconds) {
  final rnd = math.Random(start.round());
  final out = Int16List((seconds * 16000).round());
  var k = 0;
  for (var i = 0; i < out.length; i++) {
    final t = start + i / 16000;
    while (k < own.length && own[k].$2 <= t) {
      k++;
    }
    var x = (rnd.nextDouble() - .5) * 40;
    if (k < own.length && own[k].$1 <= t) {
      final f0 = 140 + 15 * math.sin(2 * math.pi * 1.3 * t);
      final syllable = math.pow(math.sin(math.pi * ((t - own[k].$1) * 4 % 1)), 2).toDouble();
      var v = 0.0;
      for (var h = 1; h <= 20; h++) {
        final f = f0 * h;
        final g = math.exp(-math.pow((f - 700) / 150, 2)) + .7 * math.exp(-math.pow((f - 1200) / 200, 2)) + .3 * math.exp(-math.pow((f - 2600) / 300, 2)) + .05;
        v += g * math.sin(2 * math.pi * f * t + h);
      }
      x += v * syllable * 3000;
    }
    out[i] = x.round().clamp(-32768, 32767);
  }
  return out;
}
