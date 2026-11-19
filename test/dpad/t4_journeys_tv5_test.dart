// The fifth round of feedback from testers' TVs (2026-11-18), item by item. docs/dpad/PLAN.md
// note 90 has the round; the ring round a text link is in t1_ring_room_test.dart and the
// number that dropped back by itself in test/account_sync_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/core/layout.dart';
import 'package:vyse_tv/core/nav.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/live_tv/iptv_playback.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/mpv/mpv.dart' show Player;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:vyse_tv/screens/live_tv/live_tv_widgets.dart';
import 'package:vyse_tv/screens/player/player_menus.dart';
import 'package:vyse_tv/widgets/common.dart' show Pressable;
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/widgets/section_chrome.dart';

import 'harness.dart';

const film = IptvVideo(title: 'The Long Night', url: 'http://portal.test:8080/movie/user/pass/501.mkv', image: 'http://portal.test/501.jpg');

List<IptvVideo> episodes() => [
  for (final (season, number) in const [(2, 1), (1, 2), (1, 1), (0, 1), (1, 3), (1, 2)])
    IptvVideo(title: 'S$season E$number', url: 'http://portal.test:8080/series/user/pass/$season$number.mp4', season: season, number: number),
];

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  setUp(() {
    PlayerEngine.debugOffered = true;
    Player.debugExoOnAnyPlatform = true;
    AppSettings.playerEngine.set('');
  });
  tearDown(() {
    PlayerEngine.debugOffered = null;
    Player.debugExoOnAnyPlatform = false;
    AppSettings.playerEngine.set('');
  });
  final tv = OnScreens([Screens.tv]);

  // "The arrow down is for like picture and picture right? The black square plays the film but
  // a portion of the bottom is cutoff, is that needed or was just for android mobile?" It was
  // the small window, which is for a pointer; nothing floats over a TV's pages.
  testWidgets('a TV: the player has no Minimize, and M does nothing', (t) async {
    expect(playersCanMinimize, isFalse);
    await Bed.openPlayer(t);
    await Bed.dpadMode(t);
    await Bed.ok(t); // the controls come up
    await Bed.settle(t, rounds: 2);
    expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Minimize')), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    expect(find.byIcon(Icons.arrow_back_rounded), findsWidgets, reason: 'Back is still there');
    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    await Bed.settle(t, rounds: 4);
    expect(MiniPlayer.session.value, isNull);
    expect(find.byType(PlayerPage), findsOneWidget, reason: 'the player is still on its page');
    await Bed.closePlayer(t);
  }, variant: tv);

  // "a new player UI for iptv (movies/series) vod section where you can customize and change
  // audio and put subtitles if the vods come equipped with them, right now there's no option
  // in the player UI". A portal's films and episodes open in the film player.
  testWidgets('a portal\'s film plays in the film player: asked for as the channel player asks, with the Audio and Subtitles menus', (t) async {
    Bed.exoCalls.clear();
    await Bed.pumpShell(t);
    final playback = IptvPlayback.film(film, portal: 'My portal');
    rootNavigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => PlayerPage(media: playback.media, episode: playback.episode, server: playback)));
    await Bed.settle(t, rounds: 6);
    expect(find.byType(PlayerPage), findsOneWidget);
    final opened = Bed.exoCalls.where((c) => c.startsWith('open ')).toList();
    expect(opened, isNotEmpty, reason: 'the film was handed to the player');
    expect(opened.last, contains(film.url));
    expect(opened.last, contains('User-Agent: libmpv'), reason: 'a portal is told what the channel player tells it');

    PlayerPanel panel() => t.widget<PlayerPanel>(find.byType(PlayerPanel));
    await Bed.down(t); // the controls: the film player's, with a key each for sound and subtitles
    expect(find.byWidgetPredicate((w) => w is Pressable && w.tooltip == 'Audio'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Pressable && w.tooltip == 'Subtitles (C)'), findsOneWidget);
    expect(find.textContaining('IPTV · My portal'), findsWidgets, reason: 'and it says where it plays from');
    // the address has the portal's sign-in in it: Copy link (in Settings, under More) says so
    await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    await Bed.settle(t, rounds: 3);
    expect(panel().open, isTrue);
    await t.scrollUntilVisible(find.text('Copy link'), 120, scrollable: find.descendant(of: find.byType(PlayerPanel), matching: find.byType(Scrollable)).last);
    expect(find.textContaining("holds your portal's sign-in"), findsOneWidget);
    expect(find.text('Download'), findsNothing, reason: 'a portal allows one connection: nothing is downloaded beside the film');
    await Bed.closePlayer(t);
  }, variant: tv);

  // "when you go from Live - Movies - Series it takes longer to load on the movies/series
  // section". Channels are rows with a small logo; films and series are a wall of posters, and
  // each was decoded as large as its file (a portal's can be 2000 by 3000).
  testWidgets("a portal's posters are decoded as wide as their card, not as large as their file", (t) async {
    await t.pumpWidget(Bed.app(Scaffold(
      body: Center(
        child: SizedBox(width: 150, height: 225, child: StreamCard(name: 'The Long Night', image: 'http://portal.test/501.jpg', poster: true, onTap: () {})),
      ),
    )));
    await t.pump();
    final picture = t.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    final real = 150 * t.view.devicePixelRatio;
    expect(picture.memCacheWidth, isNotNull);
    expect(picture.memCacheWidth!, greaterThanOrEqualTo(real.floor()), reason: 'no softer than the screen can show');
    expect(picture.memCacheWidth!, lessThan(real + 97), reason: 'and no larger than a step above it');
    expect(NetImage.decodeWidthFor(t.element(find.byType(StreamCard)), double.infinity), isNull, reason: 'a width not known yet asks for nothing');
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  test('a series: every episode the portal lists, in order, for the episode list and Next', () async {
    final playback = IptvPlayback.series(show: 'Harbour', all: episodes(), start: episodes()[2], portal: 'My portal');
    expect(playback.media.isTv, isTrue);
    expect((playback.episode!.season, playback.episode!.number), (1, 1));
    final store = playback.episodes!;
    expect((await store.seasons).map((s) => (s.number, s.episodes)), [(1, 3), (2, 1), (0, 1)], reason: 'specials last; an episode listed twice counts once');
    expect((await store.season(1)).map((e) => e.number), [1, 2, 3]);
    final after = await store.after(playback.episode!);
    expect((after!.season, after.number), (1, 2));
    final across = await store.after((await store.season(1)).last.toPlayer());
    expect((across!.season, across.number), (2, 1), reason: 'the last of a season goes on to the next season');

    final stream = await playback.open(after.toPlayer());
    expect(stream.source.url, 'http://portal.test:8080/series/user/pass/12.mp4');
    expect(stream.source.hls, isFalse);
    expect(stream.source.headers['User-Agent'], 'libmpv');
    expect(() => playback.open(const PlayerEpisode(season: 9, number: 9)), throwsStateError);
  });

  test('where you stopped is remembered: not the first half minute, not the credits', () async {
    SharedPreferences.setMockInitialValues({});
    IptvPlaces.debugForget();
    final playback = IptvPlayback.film(film, portal: 'My portal');
    expect((await playback.open(null)).resumeAt, isNull);
    const length = Duration(minutes: 100);

    playback.progress(const Duration(seconds: 20), length, paused: false);
    await playback.close();
    IptvPlaces.debugForget();
    expect((await playback.open(null)).resumeAt, isNull, reason: 'twenty seconds in is not a place to come back to');

    playback.progress(const Duration(minutes: 42), length, paused: true);
    await playback.close();
    IptvPlaces.debugForget(); // as after the app was closed
    expect((await playback.open(null)).resumeAt, const Duration(minutes: 42));
    expect((await SharedPreferences.getInstance()).getString('iptv.vod.places'), isNot(contains('pass')), reason: "the portal's sign-in is not written down a second time");

    playback.progress(const Duration(minutes: 98), length, paused: false);
    await playback.close();
    IptvPlaces.debugForget();
    expect((await playback.open(null)).resumeAt, isNull, reason: 'the credits: next time it starts again');
  });
}
