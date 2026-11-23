// Continue watching's Up next, with a remote (arrows, OK, Back): a show whose episode was watched
// to the end stays on the row with the episode after it, once that one is out ("S1:E4 · Up
// next"); OK plays that episode from the start, and holding OK offers Mark as watched (the card
// moves on to the episode after) and Remove from Continue watching. Films are left as they were.
// On the TV screen the app runs as a TV, on the phone as a phone.
//
// The shows are the bed's made-up TMDB ones (three seasons of eight, all out); the anime is a
// made-up AniList series of twelve (bed/fake_anilist.dart, turned into a series here); the addon
// title is a show from the made-up Lantern addon (bed/fake_addons.dart: seasons of three and two).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/anime/anilist.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/catalog/meta_addons.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/screens/home/up_next.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/screens/player/sources_page.dart';

import 'bed/fake_addons.dart';
import 'bed/fake_anilist.dart';
import 'bed/fake_net.dart';
import 'harness.dart';

/// AniList's answer for every question: the bed's made-up one, its anime a series of twelve
/// episodes, all out.
FakeReply? _aniList(String method, Uri uri) {
  if (uri.host != 'graphql.anilist.co') return null;
  final all = fakeAniList();
  final data = all['data']! as Map<String, Object?>;
  final media = data['Media']! as Map<String, Object?>;
  return FakeReply.json({
    ...all,
    'data': {
      ...data,
      'Media': {...media, 'format': 'TV', 'status': 'FINISHED', 'episodes': 12},
    },
  });
}

/// The anime [_aniList] answers about, as Continue watching keeps it.
const _anime = Media(
  id: 9000,
  title: 'Paper Lanterns',
  isTv: true,
  anime: true,
  posterPath: 'https://img.anilist.example/cover0.jpg',
  backdropPath: 'https://img.anilist.example/banner0.jpg',
);

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android, route: (method, uri) => _aniList(method, uri) ?? fakeAddons(method, uri));
    Addons.start(); // as the app's main does
    // asked here, outside any test, the anime's details are there for every test (see Bed._warm)
    await AniList.details(_anime.id);
    await AnimeExtras.of(_anime.id);
  });
  final screen = OnScreens(Screens.android);
  final lantern = Addon.fromManifest(lanternUrl, lanternManifest);

  /// The TV screen runs as a TV, the phone as a phone; History is put back after each test, and
  /// nothing Up next found is kept from one test to the next.
  Future<void> start(WidgetTester t) async {
    TvDetectionService.debugReset();
    await t.runAsync(() => TvDetectionService.getInstance(forceTv: OnScreens.current == Screens.tv));
    addTearDown(TvDetectionService.debugReset);
    final saved = WatchProgress.entries.value;
    addTearDown(() => WatchProgress.entries.value = saved);
    UpNext.debugReset();
    addTearDown(UpNext.debugReset);
    MetaAddons.debugReset();
  }

  /// [show] played to the end of episode [episode] of season [season], a moment ago.
  void finished(Media show, int season, int episode) => WatchProgress.record(
    show,
    position: const Duration(minutes: 47),
    duration: const Duration(minutes: 47),
    season: season,
    episode: episode,
    episodeName: 'Chapter $episode',
  );

  /// Holds OK down for a moment, as on a remote.
  Future<void> holdOk(WidgetTester t) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await t.pump(const Duration(milliseconds: 600));
    await t.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await Bed.settle(t, rounds: 2);
  }

  /// Down from the top of Home onto Continue watching, then along it to [title]'s card.
  Future<void> toCard(WidgetTester t, String title) async {
    for (var i = 0; i < 8 && !Bed.focused().contains('Continue watching'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('Continue watching'));
    for (var i = 0; i < 8 && !Bed.focused().contains(title); i++) {
      await Bed.left(t);
    }
    for (var i = 0; i < 8 && !Bed.focused().contains(title); i++) {
      await Bed.right(t);
    }
    expect(Bed.focused(), contains(title));
    expect(Bed.focusInView(), isTrue);
  }

  /// The Continue watching cards, first to last.
  Finder cards() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ResumeCard');

  /// [title]'s card.
  Finder card(String title) => find.ancestor(of: find.text(title), matching: cards());

  /// What [title]'s card says under its name ("S1:E4  Chapter 4: …") and beside it ("Up next").
  List<String> says(WidgetTester t, String title) =>
      [for (final w in t.widgetList<Text>(find.descendant(of: card(title), matching: find.byType(Text)))) w.data ?? ''];

  /// The requests for [show]'s seasons so far.
  int seasonAsks(Media show) => Bed.http.seen.where((r) => r.contains('/tv/${show.id}/season/')).length;

  /// Toasts run out before the test ends.
  Future<void> done(WidgetTester t) => t.pump(const Duration(seconds: 4));

  testWidgets('a show watched to the end stays, with the next episode at the start (S1:E4, Up next); OK plays that one; a film and a show at its last episode leave', (t) async {
    await start(t);
    final show = Bed.freshTitle(series: true);
    final ended = Bed.freshTitle(series: true);
    final film = Bed.freshTitle();
    final watching = WatchProgress.entries.value.where((e) => e.inContinue).map((e) => e.media).toList();
    finished(ended, 3, 8); // the last of its three seasons
    WatchProgress.record(film, position: const Duration(minutes: 100), duration: const Duration(minutes: 100));
    finished(show, 1, 3);
    await Bed.pumpShell(t);

    // (each card's first words are its title: the made-up titles have no logo)
    String titleOf(Widget c) => t.widget<Text>(find.descendant(of: find.byWidget(c), matching: find.byType(Text)).first).data!;
    final row = t.widgetList(cards()).map(titleOf).toList();
    expect(row.first, show.title, reason: 'watched last: first on the row');
    expect(row[1], watching.first.title, reason: 'then what is part-way through: not the film watched to the end, nor the show at its last episode');
    expect(card(ended.title), findsNothing);
    expect(card(film.title), findsNothing);
    final line = says(t, show.title);
    expect(line, contains(startsWith('S1:E4')), reason: 'the episode after the one finished: $line');
    expect(line, contains('Up next'));
    expect(line.where((s) => s.contains('left')), isEmpty, reason: 'nothing of it played: no time left to tell');
    final rings = t.widgetList<CircularProgressIndicator>(find.descendant(of: card(show.title), matching: find.byType(CircularProgressIndicator)));
    expect(rings.map((r) => r.value), everyElement(0), reason: 'at the start');

    // asked once, and only about the two shows that could have a next episode
    expect(seasonAsks(show), 1);
    expect(seasonAsks(ended), 1);
    for (final m in watching) {
      expect(Bed.http.seen.where((r) => r.contains('/${m.isTv ? 'tv' : 'movie'}/${m.id}/season')), isEmpty, reason: '${m.title} is part-way through');
    }
    final kept = (await SharedPreferences.getInstance()).getString('watch.upNext');
    expect((jsonDecode(kept!) as Map).keys, containsAll([show.key, ended.key]), reason: 'kept on the device');

    await toCard(t, show.title);
    await Bed.picture(t, 'up_next/row');

    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    final player = t.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.media.key, show.key);
    expect((player.episode?.season, player.episode?.number), (1, 4), reason: 'OK plays the episode the card shows');
    expect(WatchProgress.resumeSeconds(show, season: 1, episode: 4), 0, reason: 'from its start: there is no place to carry on from');
    await Bed.closePlayer(t);

    // Home again: the answers are kept, nothing is asked twice (the player asks for its own list)
    final asked = (seasonAsks(show), seasonAsks(ended));
    await Bed.pumpShell(t);
    expect(says(t, show.title), contains('Up next'));
    expect((seasonAsks(show), seasonAsks(ended)), asked);
    await done(t);
  }, variant: screen);

  testWidgets('holding OK on an Up next card: Mark as watched moves the card on (into the next season) with the ring on it; Remove takes the show off', (t) async {
    await start(t);
    final show = Bed.freshTitle(series: true);
    finished(show, 1, 7);
    await Bed.pumpShell(t);
    expect(says(t, show.title), allOf(contains(startsWith('S1:E8')), contains('Up next')));
    await toCard(t, show.title);

    await holdOk(t);
    expect(find.text('Mark as watched'), findsOneWidget, reason: 'holding OK opens the card\'s menu');
    expect(find.text('Remove from Continue watching'), findsOneWidget);
    await Bed.picture(t, 'up_next/menu');
    await Bed.ok(t);
    expect(find.text('Remove from Continue watching'), findsNothing, reason: 'the menu closed');
    expect(WatchProgress.isSeen(show, season: 1, episode: 8), isTrue, reason: 'the episode the card showed');
    expect(find.byType(PlayerPage), findsNothing, reason: 'and nothing played');
    await Bed.settle(t, rounds: 2);
    expect(says(t, show.title), allOf(contains(startsWith('S2:E1')), contains('Up next')), reason: 'the first of the next season');
    expect(Bed.focused(), contains(show.title), reason: 'the ring stays on the card');
    expect(Bed.focusInView(), isTrue);
    await Bed.picture(t, 'up_next/moved_on');

    await holdOk(t);
    await Bed.down(t);
    await Bed.ok(t);
    expect(WatchProgress.find(show)!.hidden, isTrue, reason: 'Remove from Continue watching');
    expect(card(show.title), findsNothing);
    expect(WatchProgress.isSeen(show, season: 2, episode: 1), isFalse, reason: 'removing marks nothing');
    expect(Bed.focused(), isNot('nothing'));
    expect(Bed.focusInView(), isTrue);

    // played again, it's back, as any show is
    finished(show, 2, 1);
    await Bed.settle(t, rounds: 2);
    expect(says(t, show.title), allOf(contains(startsWith('S2:E2')), contains('Up next')));
    await done(t);
  }, variant: screen);

  testWidgets('an anime watched to the end of an episode: the next of its run (E6, Up next); OK plays it', (t) async {
    await start(t);
    finished(_anime, 0, 5);
    await Bed.pumpShell(t);
    expect(says(t, _anime.title), allOf(contains(startsWith('E6')), contains('Up next')), reason: 'anime are numbered straight through');
    await toCard(t, _anime.title);
    await Bed.picture(t, 'up_next/anime');

    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    final player = t.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.media.key, _anime.key);
    expect((player.episode?.season, player.episode?.number), (0, 6));
    await Bed.closePlayer(t);
    await done(t);
  }, variant: screen);

  testWidgets('a title from a metadata addon: the next episode from its addon, into its next season (S2:E1, Up next); OK opens it', (t) async {
    await start(t);
    final streaming = AppSettings.streamingMode.value;
    addTearDown(() {
      Addons.list.value = const [];
      AppSettings.addons.value = '[]';
      AppSettings.streamingMode.value = streaming;
    });
    Addons.list.value = Addons.withBuiltIns([lantern]);
    // (Streaming mode off: its sources are picked first, as for any title, with no TMDB match in the way)
    AppSettings.streamingMode.value = false;
    final show = MetaAddons.media(lanternShow(3), type: 'series', from: lantern)!;
    finished(show, 1, 3); // the last of its first season
    await Bed.pumpShell(t);
    expect(says(t, show.title), allOf(contains(startsWith('S2:E1')), contains('Up next')));
    expect(Bed.http.seen, contains('GET https://lantern.test/meta/series/${show.addonId}.json'), reason: 'its episodes come from its addon');
    await toCard(t, show.title);
    await Bed.picture(t, 'up_next/addon');

    // (the sources page is a little too wide for a TV: a known one, see the TV notes)
    final wide = await Bed.overflows(() async {
      await Bed.ok(t);
      final sources = t.widget<SourcesPage>(find.byType(SourcesPage));
      expect(sources.media.key, show.key);
      expect((sources.episode?.season, sources.episode?.number), (2, 1), reason: 'OK opens the episode the card shows');
      await Bed.back(t);
    });
    expect(wide.where((o) => !o.contains('sources_page.dart')), isEmpty);
    expect(find.byType(SourcesPage), findsNothing);
    await done(t);
  }, variant: screen);
}
