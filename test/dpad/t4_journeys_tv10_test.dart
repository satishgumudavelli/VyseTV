// The tenth round from testers' TVs (2026-11-21). docs/dpad/PLAN.md note 99 has the round.
//
// 1. "on party... You know how you look at members? There's no option to navigate the page after
//    tapping on "library" can't select music watchlist or shows through the remote nor does it
//    highlight them"
// 2. "Audiobooks section, long pressing doesn't remove or clear the continue listening section,
//    nor does X'ing them out one at a time."
// 3. "The anime section, people are having issues scrolling down on their remote to get to
//    episodes."
// 5. "On skip buttons on playback in profile, whether Credits is ( ✅ or X'd ) an onscreen pop up
//    to the bottom right will display asking to play next episode. [While X'd that popup
//    shouldn't be showing up at all.] Auto next episode (when toggled on) Will play the next
//    episode, but it skips early before the entire episode finishes"
//
// (4, Media3 listing fewer subtitles than mpv, was not reproduced: see the note.)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/anime/anilist.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/audiobooks/audiobook_player.dart';
import 'package:vyse_tv/data/party/party_library.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/mpv/mpv.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/party/dm_page.dart';
import 'package:vyse_tv/screens/party/party_widgets.dart';
import 'package:vyse_tv/screens/party/profile_library.dart';
import 'package:vyse_tv/screens/player/player_episodes.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/widgets/common.dart' show Pressable;

import 'bed/fake_anilist.dart' show fakeAniList;
import 'bed/phase7_pages.dart';
import 'bed/phase9_pages.dart';
import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await Bed.withContent();
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);

  /// Holds OK down for a moment, as on a remote.
  Future<void> holdOk(WidgetTester t) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await t.pump(const Duration(milliseconds: 600));
    await t.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await Bed.settle(t, rounds: 2);
  }

  // ── 3. an anime's episodes ──

  testWidgets('an anime: Down from Play reaches the Episodes tab, the episode\'s Play and its mark, and Up comes back', (t) async {
    final was = Bed.http.route;
    Bed.http.route = (method, uri) {
      if (uri.host != 'graphql.anilist.co') return was(method, uri);
      final data = fakeAniList();
      final inner = data['data']! as Map<String, Object?>;
      inner['Media'] = {...inner['Media']! as Map<String, Object?>, 'format': 'TV', 'episodes': 13, 'status': 'FINISHED'};
      return FakeReply.json(data);
    };
    addTearDown(() => Bed.http.route = was);
    await Bed.pumpShell(t);
    await Bed.push(t, AnimeDetailsPage(anime: Anime.fromMedia(Bed.catalogue[81])));
    await Bed.settle(t, rounds: 4);
    if (!Bed.focused().contains("'Play'")) await Bed.focus(t, find.ancestor(of: find.text('Play'), matching: find.byType(Pressable)).first);

    await Bed.down(t);
    expect(Bed.focused(), contains("_SectionTab in _MeasureSize 'Episodes'"));
    await Bed.down(t);
    expect(Bed.focused(), contains("'Play E1'"), reason: 'the episode lies under the tabs, although its buttons are at its right');
    expect(Bed.focusInView(), isTrue);
    await Bed.picture(t, 'tv10/anime_episode');
    await Bed.down(t);
    expect(Bed.focused(), contains('_MarkEpisode'));
    await Bed.down(t);
    expect(Bed.focused(), contains('_SeasonMarks'));
    expect(Bed.focusInView(), isTrue);

    await Bed.up(t);
    expect(Bed.focused(), contains('_MarkEpisode'));
    await Bed.up(t);
    expect(Bed.focused(), contains("'Play E1'"));
    await Bed.right(t);
    await Bed.settle(t, rounds: 2);
    expect(Bed.focused(), contains("'Play E2'"), reason: 'Left and Right on it still change the episode');
    await Bed.up(t);
    expect(Bed.focused(), contains("'Episodes'"), reason: 'and Up goes back to the tabs');
  }, variant: tv);

  // ── 1. a Party member's library ──

  Map<String, Object?> saved(int n, {bool tv = false, bool anime = false}) => {
    'm': {
      'id': 9000 + n,
      'title': 'Saved title $n',
      'tv': tv,
      'overview': 'Made up.',
      'poster_path': '/p$n.jpg',
      'backdrop_path': '/b$n.jpg',
      'vote_average': 7.1,
      'genre_ids': [18],
      'popularity': 10.0,
      'vote_count': 100,
      'date': '2024-01-0${n % 9 + 1}',
      if (anime) 'anime': true,
    },
    'a': 1700000000000 + n,
  };

  testWidgets('a member\'s Library opened from their profile: the remote is on the page, and reaches Watchlist, Music and the kinds', (t) async {
    final was = ProfileLibrary.send;
    ProfileLibrary.send = (path) async => {
      'titles': [saved(1), saved(2), saved(3, tv: true), saved(4, tv: true), saved(5, tv: true, anime: true)],
      'likes': [],
      'playlists': [],
      'albums': [{'id': 'al1', 'title': 'Understory', 'thumb': '', 'subtitle': 'Album', 'a': 1700000000000}],
    };
    addTearDown(() => ProfileLibrary.send = was);
    await phase9Pages['Party, a profile']!(t);
    await Bed.focus(t, find.ancestor(of: find.text('Library'), matching: find.byType(PartyChipButton)).first);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 6);
    expect(find.byType(ProfileLibraryPage), findsOneWidget);
    // it was left on the Party page under it, where nothing could take it: no ring, no keys
    expect(Bed.focused(), isNot('nothing'), reason: 'the ring is on the library, not lost under it');
    expect(find.ancestor(of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget), matching: find.byType(ProfileLibraryPage)), findsOneWidget);

    await Bed.down(t);
    expect(Bed.focused(), contains("'Watchlist 5'"));
    await Bed.right(t);
    expect(Bed.focused(), contains("'Music 1'"));
    await Bed.left(t);
    await Bed.down(t);
    expect(Bed.focused(), contains("'All 5'"));
    await Bed.right(t);
    await Bed.right(t);
    expect(Bed.focused(), contains("'Shows 2'"));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(find.text('Saved title 3'), findsWidgets, reason: 'OK picks the kind: the shows');
    expect(find.text('Saved title 1'), findsNothing);
    expect(Bed.focused(), contains("'Shows 2'"), reason: 'the ring stays on the chip');
    await Bed.picture(t, 'tv10/library_shows');
    await Bed.down(t);
    expect(Bed.focused(), contains('_Poster'));
    expect(Bed.focusInView(), isTrue);

    for (var i = 0; i < 3 && !Bed.focused().contains("'Music 1'"); i++) {
      await Bed.up(t);
    }
    await Bed.right(t);
    expect(Bed.focused(), contains("'Music 1'"));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(find.text('Saved albums'), findsOneWidget, reason: 'OK on Music shows their music');
    await Bed.back(t);
    expect(find.byType(ProfileLibraryPage), findsNothing);
    await t.pump(const Duration(seconds: 3));
  }, variant: tv);

  testWidgets('Message on a member\'s profile: the remote is in the conversation', (t) async {
    await phase9Pages['Party']!(t);
    showPartyProfile(Bed.sectionNavigator(t).context, 'u1', initial: person(1, relation: 'friends')).ignore();
    await Bed.settle(t, rounds: 5);
    await Bed.focus(t, find.ancestor(of: find.text('Message'), matching: find.byType(PartyChipButton)).first);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 6);
    expect(find.byType(DmPage), findsOneWidget);
    expect(Bed.focused(), isNot('nothing'));
    expect(find.ancestor(of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget), matching: find.byType(DmPage)), findsOneWidget);
    await Bed.back(t);
    await t.pump(const Duration(seconds: 3));
  }, variant: tv);

  // ── 2. Audiobooks: Continue listening ──

  testWidgets('Continue listening: holding OK on a book takes it off the row, and the ring goes to the one beside it', (t) async {
    final books = AudiobookPlayer.instance.recents.value;
    addTearDown(() => AudiobookPlayer.instance.recents.value = books);
    await phase7Pages['Audiobooks']!(t);
    for (var i = 0; i < 6 && !Bed.focused().contains('BookCard'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('Continue listening'));
    final held = AudiobookPlayer.instance.recents.value.firstWhere((r) => Bed.focused().contains(r.book.title));
    await holdOk(t);
    final left = AudiobookPlayer.instance.recents.value;
    expect(left, hasLength(books.length - 1));
    expect(left.where((r) => r.book.uuid == held.book.uuid), isEmpty, reason: 'the book held, and only it');
    expect(find.byType(DetailsPage), findsNothing);
    expect(Bed.focused(), allOf(contains('Continue listening'), contains(left.single.book.title)), reason: 'on to the book beside it');
    await Bed.picture(t, 'tv10/books_removed');
    await holdOk(t);
    expect(AudiobookPlayer.instance.recents.value, isEmpty);
    expect(find.text('Continue listening'), findsNothing, reason: 'the row goes with its last book');
    expect(Bed.focused(), isNot('nothing'));
    await t.pump(const Duration(seconds: 3));
  }, variant: tv);

  testWidgets('a book taken off Continue listening while it is open stays off when paused or closed, and comes back when played', (t) async {
    final player = AudiobookPlayer.instance;
    final books = player.recents.value;
    addTearDown(() {
      player.book = null;
      player.recents.value = books;
    });
    final open = books.first.book;
    player.book = open; // (as if it were playing: the bed has no audio engine)
    await player.forget(open);
    expect(player.recents.value.where((r) => r.book.uuid == open.uuid), isEmpty);
    player.pause();
    expect(player.recents.value.where((r) => r.book.uuid == open.uuid), isEmpty, reason: 'pausing it saved it straight back');
    await player.toggle();
    expect(player.recents.value.first.book.uuid, open.uuid, reason: 'played again: it is being listened to');
    await player.stop();
  });

  // ── 5. the next episode, over the credits and at the end ──

  group('the next episode', () {
    late FakeRoute route;
    setUp(() {
      PlayerEngine.debugOffered = true;
      Player.debugExoOnAnyPlatform = true;
      AppSettings.playerEngine.set('');
      debugFilmSources = [
        FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/episode.mkv', type: 'mkv')]),
      ];
      route = Bed.http.route;
      Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
    });
    tearDown(() {
      PlayerEngine.debugOffered = null;
      Player.debugExoOnAnyPlatform = false;
      AppSettings.playerEngine.set('');
      AppSettings.skipButtonsOff.set('');
      AppSettings.autoNext.set(true);
      debugFilmSources = null;
      Bed.http.route = route;
    });

    int opens() => Bed.exoCalls.where((c) => c.startsWith('open ')).length;
    UpNextCard? card() => find.byType(UpNextCard).evaluate().isEmpty ? null : find.byType(UpNextCard).evaluate().single.widget as UpNextCard;

    /// The video says where it is. (The engine passes that on at most four times a second, by
    /// a real clock: so a real quarter of a second goes by first.)
    Future<void> reach(WidgetTester t, double seconds) async {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 260)));
      await Bed.exoProperty(t, 'time-pos', seconds);
      await t.pump(const Duration(milliseconds: 100));
    }

    /// Episode 1 open, 24 minutes long, playing at [at] seconds (no credits from TheIntroDB: the
    /// last 4%, from 23:02, counts as them).
    Future<void> playAt(WidgetTester t, double seconds) async {
      Bed.exoCalls.clear();
      await Bed.openPlayer(t, series: true);
      expect(opens(), 1);
      await Bed.exoProperty(t, 'duration', 1440.0);
      // the next episode is looked up as the episode starts (its season, from TMDB)
      final show = t.widget<PlayerPage>(find.byType(PlayerPage)).media.id;
      for (var i = 0; i < 20 && !Bed.http.seen.any((u) => u.contains('/tv/$show/season/1')); i++) {
        await Bed.settle(t, rounds: 1);
      }
      expect(Bed.http.seen.where((u) => u.contains('/tv/$show/season/1')), isNotEmpty);
      // (a playing video reports where it is many times a second; the card is looked for each time)
      await Bed.settle(t, rounds: 2);
      await reach(t, seconds);
    }

    /// Its Dismiss (×), as a pointer would press it.
    Future<void> dismiss(WidgetTester t) async {
      card()!.onDismiss();
      await t.pump();
      await t.pump(const Duration(milliseconds: 400)); // (it slides away)
    }

    Future<void> theEnd(WidgetTester t) async {
      await reach(t, 1439.9);
      await Bed.exoProperty(t, 'eof-reached', true);
      await t.pump(const Duration(milliseconds: 300));
    }

    testWidgets('Credits on, Auto next on: over the credits it is offered, not played; it plays once the episode has ended', (t) async {
      await playAt(t, 1400);
      expect(card(), isNotNull, reason: 'over the credits, as their skip button');
      expect(card()!.auto, isFalse);
      expect(find.text('Play next'), findsOneWidget);
      await t.pump(const Duration(seconds: 8));
      expect(opens(), 1, reason: 'nothing plays by itself before the end: the credits are the episode\'s too');
      await theEnd(t);
      expect(card()!.auto, isTrue, reason: 'the end: the countdown starts');
      expect(find.textContaining('Playing in'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      await Bed.settle(t, rounds: 4);
      expect(opens(), 2, reason: 'and the next episode plays');
      await Bed.closePlayer(t);
    }, variant: tv);

    testWidgets('Credits off: nothing over the credits; Auto next still plays the next one at the end', (t) async {
      AppSettings.skipButtonsOff.set('credits');
      await playAt(t, 1400);
      expect(card(), isNull, reason: 'Credits off: the credits play with nothing over them');
      await t.pump(const Duration(seconds: 5));
      expect(card(), isNull);
      await theEnd(t);
      expect(card()?.auto, isTrue);
      await t.pump(const Duration(seconds: 4));
      await Bed.settle(t, rounds: 4);
      expect(opens(), 2);
      await Bed.closePlayer(t);
    }, variant: tv);

    testWidgets('Credits off and Auto next off: nothing over the credits and nothing at the end', (t) async {
      AppSettings.skipButtonsOff.set('credits');
      AppSettings.autoNext.set(false);
      await playAt(t, 1400);
      expect(card(), isNull);
      await theEnd(t);
      expect(card(), isNull, reason: 'no popup at all');
      await t.pump(const Duration(seconds: 6));
      expect(opens(), 1);
      await Bed.closePlayer(t);
    }, variant: tv);

    testWidgets('Credits on and Auto next off: offered over the credits, and it waits for you at the end', (t) async {
      AppSettings.autoNext.set(false);
      await playAt(t, 1400);
      expect(card()?.auto, isFalse);
      await theEnd(t);
      expect(card()?.auto, isFalse, reason: 'no countdown without Auto next');
      await t.pump(const Duration(seconds: 6));
      expect(opens(), 1);
      await Bed.ok(t); // OK on the picture takes what it offers
      await Bed.settle(t, rounds: 4);
      expect(opens(), 2);
      await Bed.closePlayer(t);
    }, variant: tv);

    testWidgets('put away over the credits, it still comes at the end with Auto next on; seeking back before the credits offers it again', (t) async {
      await playAt(t, 1400);
      expect(card(), isNotNull);
      await dismiss(t);
      expect(card(), isNull);
      await reach(t, 1410);
      expect(card(), isNull, reason: 'put away: it stays away over the credits');
      await reach(t, 600);
      expect(card(), isNull);
      await reach(t, 1400);
      expect(card()?.auto, isFalse, reason: 'back before the credits, and there again: offered again');
      await dismiss(t);
      await theEnd(t);
      expect(card()?.auto, isTrue, reason: 'Auto next is for the end, whatever was put away over the credits');
      await dismiss(t);
      await t.pump(const Duration(seconds: 5));
      expect(card(), isNull);
      expect(opens(), 1, reason: 'put away at the end too: nothing plays');
      await Bed.closePlayer(t);
    }, variant: tv);
  });
}
