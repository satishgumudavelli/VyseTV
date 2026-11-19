// The seventh round from testers' TVs (2026-11-19), on the APK of note 91: "When 111477 is
// selected it says media3 can't play this one - using mpv. And then it skips to another source."
// docs/dpad/PLAN.md note 93 has the round.
//
// As the engine tests are: on a PC, with the bed standing in for the Media3 plugin
// (Bed.exoCalls for what the app asks of it, Bed.exoEvent and Bed.exoProperty for what it tells
// the app), and two made-up film sources in place of the real ones.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/mpv/mpv.dart';

import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  late FakeRoute route;
  setUp(() {
    PlayerEngine.debugOffered = true;
    Player.debugExoOnAnyPlatform = true;
    AppSettings.playerEngine.set('');
    // Two sources with a link each, in this order. Both links answer when they are checked.
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/first.mkv', type: 'mkv')]),
      FilmSource(id: 'second', name: 'Second', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/second.mkv', type: 'mkv')]),
    ];
    route = Bed.http.route;
    Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
  });
  tearDown(() {
    PlayerEngine.debugOffered = null;
    Player.debugExoOnAnyPlatform = false;
    AppSettings.playerEngine.set('');
    debugFilmSources = null;
    Bed.http.route = route;
  });
  final tv = OnScreens([Screens.tv]);

  /// The links the player was asked to open, oldest first.
  List<String> opened() => [
    for (final c in Bed.exoCalls)
      if (c.startsWith('open ')) RegExp(r'files\.test/(\w+)\.mkv').firstMatch(c)?[1] ?? c,
  ];

  // The start-up watch gives a link picked for you 25 seconds to get going, then tries the next.
  // Its clock ran on from when Media3 opened the link, through the hand-over: on a host that is
  // slow to answer, mpv had a few seconds left, and the link was dropped while mpv was opening it.
  testWidgets('Media3 hands a film to mpv 20 seconds in: mpv gets its own 25 seconds, and the note says what Media3 could not play', (t) async {
    Bed.exoCalls.clear();
    await Bed.openPlayer(t);
    expect(opened(), ['first'], reason: 'the first source that answers plays, on Media3');

    await t.pump(const Duration(seconds: 18)); // (20 seconds since the open, with the bed's own settling)
    await Bed.exoEvent(t, 'backend-switched', {'kind': 'audio', 'reason': 'Audio track present but no decoder available (audio/true-hd)'});
    expect(find.text("Media3 can't play this sound (TrueHD) · using mpv"), findsOneWidget);

    await t.pump(const Duration(seconds: 10)); // 30 seconds since the open: the old clock ran out at 25
    expect(opened(), ['first'], reason: 'mpv is still opening it: the link is not given up on');
    expect(find.textContaining("didn't play"), findsNothing);

    await t.pump(const Duration(seconds: 16)); // 26 seconds since the hand-over, and mpv never opened it
    await Bed.settle(t, rounds: 4);
    expect(opened(), ['first', 'second'], reason: 'a link mpv cannot start either is still moved on from');
    await Bed.closePlayer(t);
  }, variant: tv);

  testWidgets('once mpv has the film open after a hand-over, nothing moves on from it', (t) async {
    Bed.exoCalls.clear();
    await Bed.openPlayer(t);
    expect(opened(), ['first']);
    await t.pump(const Duration(seconds: 10));
    await Bed.exoEvent(t, 'backend-switched', {'kind': 'stream', 'reason': 'Source error'});
    expect(find.text('The stream stalled on Media3 · trying mpv'), findsOneWidget);
    await t.pump(const Duration(seconds: 12));
    await Bed.exoProperty(t, 'duration', 7260.0); // mpv read the file: it has a length
    await t.pump(const Duration(seconds: 40));
    await Bed.settle(t, rounds: 2);
    expect(opened(), ['first']);
    await Bed.closePlayer(t);
  }, variant: tv);

  // Nothing changed for a link that just never starts: 25 seconds, then the next.
  testWidgets('a link that never gets going on Media3 is still moved on from after 25 seconds', (t) async {
    Bed.exoCalls.clear();
    await Bed.openPlayer(t);
    expect(opened(), ['first']);
    await t.pump(const Duration(seconds: 22));
    expect(opened(), ['first']);
    await t.pump(const Duration(seconds: 3));
    await Bed.settle(t, rounds: 4);
    expect(opened(), ['first', 'second']);
    await Bed.closePlayer(t);
  }, variant: tv);

  test('the hand-over note names the part Media3 could not play', () {
    String note(String kind, [String reason = '']) => PlayerEngine.handOverNote((kind: kind, reason: reason));
    expect(note('audio', 'Audio track present but no decoder available (audio/true-hd, audio/ac3)'), "Media3 can't play this sound (TrueHD, Dolby Digital) · using mpv");
    expect(note('audio', 'Audio track present but no decoder available (audio/vnd.dts.hd)'), "Media3 can't play this sound (DTS-HD) · using mpv");
    expect(note('audio', 'AudioTrack init failed 0 Config(48000, 6396, 44100)'), "Media3 can't play this sound · using mpv");
    expect(note('video', 'Video track present but no decoder available (video/dolby-vision)'), "Media3 can't play this picture (Dolby Vision) · using mpv");
    expect(note('video', 'Decoder hang: c2.mtk.hevc.decoder accepted input but produced no output'), "Media3 can't play this picture · using mpv");
    expect(note('stream', 'Source error'), 'The stream stalled on Media3 · trying mpv');
    expect(note('format'), "Media3 can't read this file · using mpv");
    expect(note('stuck', 'Playback stalled while buffering for 12000ms'), 'Media3 got stuck · using mpv');
    expect(note('error'), "Media3 can't play this one · using mpv");
    expect(PlayerEngine.handOverNote(null), "Media3 can't play this one · using mpv", reason: 'an older plugin says nothing more');
    // a codec with no plain name is not shown as its technical one
    expect(note('audio', 'Audio track present but no decoder available (audio/x-unknown)'), "Media3 can't play this sound · using mpv");
  });
}
