// Watched and unwatched by hand, with a remote (arrows, OK, Back): a film's page, a show's
// episode list, Continue watching, and the player's list of episodes. On the TV screen the app
// runs as a TV (the player's episodes are a full-screen menu there); on the phone, as a phone.
//
// What a mark does to History and to the copies on the account and on Trakt and Simkl is held
// by test/watch_marks_test.dart; here, only that a remote reaches it and sees it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/player/player_episodes.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/screens/player/tv_menus.dart';
import 'package:vyse_tv/widgets/common.dart';
import 'package:vyse_tv/widgets/watched_marks.dart';

import 'harness.dart';

/// The text on the control that has the ring, for Material buttons (a dialog's).
String? _materialFocus() {
  final node = DpadRoot.debugRinged;
  if (node?.context == null) return null;
  String? text;
  void visit(Element e) {
    if (text != null) return;
    if (e.widget is Text) text = (e.widget as Text).data;
    e.visitChildren(visit);
  }

  (node!.context! as Element).visitChildren(visit);
  return text;
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.android));
  final screen = OnScreens(Screens.android);

  /// The TV screen runs as a TV, the phone as a phone; History is put back after each test.
  Future<void> start(WidgetTester t) async {
    TvDetectionService.debugReset();
    await t.runAsync(() => TvDetectionService.getInstance(forceTv: OnScreens.current == Screens.tv));
    addTearDown(TvDetectionService.debugReset);
    final saved = WatchProgress.entries.value;
    addTearDown(() => WatchProgress.entries.value = saved);
  }

  /// Holds OK down for a moment, as on a remote.
  Future<void> holdOk(WidgetTester t) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await t.pump(const Duration(milliseconds: 600));
    await t.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await Bed.settle(t, rounds: 2);
  }

  /// Moves Right (then down a line and along it) until [what] has the ring.
  Future<void> seek(WidgetTester t, String what) async {
    for (var i = 0; i < 5 && !Bed.focused().contains(what); i++) {
      await Bed.right(t);
    }
    if (!Bed.focused().contains(what)) {
      await Bed.down(t);
      for (var i = 0; i < 5 && !Bed.focused().contains(what); i++) {
        await Bed.left(t);
      }
      for (var i = 0; i < 5 && !Bed.focused().contains(what); i++) {
        await Bed.right(t);
      }
    }
    expect(Bed.focused(), contains(what));
  }

  /// Toasts run out before the test ends.
  Future<void> done(WidgetTester t) => t.pump(const Duration(seconds: 4));

  testWidgets('a film: Mark watched is beside Save; OK marks it (finished, off Continue watching), OK again takes it back', (t) async {
    await start(t);
    await Bed.pumpShell(t);
    final film = Bed.freshTitle();
    expect(WatchProgress.find(film), isNull);
    await Bed.push(t, DetailsPage(media: film));
    if (!Bed.focused().contains("'Play'")) await Bed.down(t); // (a TV starts on it; a phone's first press finds it)
    expect(Bed.focused(), contains("'Play'"));
    await seek(t, 'WatchedButton');
    expect(Bed.focused(), contains('Mark watched'));
    expect(Bed.focusInView(), isTrue);

    await Bed.ok(t);
    expect(WatchProgress.isSeen(film), isTrue);
    expect(WatchProgress.find(film)!.finished, isTrue, reason: 'the "finished" playing to the end gives');
    expect(WatchProgress.continueWatching.where((e) => e.media.key == film.key), isEmpty);
    expect(Bed.focused(), allOf(contains('WatchedButton'), contains('Watched')), reason: 'the ring stays on it, and it says so');
    await Bed.picture(t, 'watched/film_watched');

    await Bed.ok(t);
    expect(WatchProgress.isSeen(film), isFalse);
    expect(WatchProgress.find(film)!.blank, isTrue, reason: 'nothing watched: not in History');
    expect(Bed.focused(), contains('Mark watched'));
    await Bed.back(t);
    expect(find.byType(DetailsPage), findsNothing);
    await done(t);
  }, variant: screen);

  testWidgets('a series: Down from Play E1 to its mark; Left and Right still change the episode; under the timeline, the whole season', (t) async {
    await start(t);
    await Bed.pumpShell(t);
    final show = Bed.freshTitle(series: true);
    await Bed.push(t, DetailsPage(media: show));
    if (!Bed.focused().contains("'Play'")) await Bed.down(t);
    expect(Bed.focused(), contains("'Play'"));
    for (var i = 0; i < 12 && !Bed.focused().contains('_SeasonNumber'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('_SeasonNumber'));
    // the seasons are beside the episode on a wide screen, above it on a phone
    if (OnScreens.current == Screens.phone) {
      await Bed.down(t);
    } else {
      await Bed.right(t);
    }
    expect(Bed.focused(), contains("'Play E1'"));

    await Bed.down(t);
    expect(Bed.focused(), contains('_MarkEpisode'), reason: 'the mark is under Play');
    expect(Bed.focusInView(), isTrue);
    await Bed.ok(t);
    expect(WatchProgress.isSeen(show, season: 1, episode: 1), isTrue);
    expect(Bed.focused(), allOf(contains('_MarkEpisode'), contains('Watched')));
    await Bed.picture(t, 'watched/episode_watched');

    await Bed.right(t);
    await Bed.settle(t, rounds: 2);
    expect(find.textContaining('Chapter 2:'), findsWidgets, reason: 'Right from the mark moves to the next episode, as from Play');
    expect(Bed.focused(), allOf(contains('_MarkEpisode'), contains('Mark watched')), reason: 'and episode 2 is not watched');
    await Bed.left(t);
    await Bed.settle(t, rounds: 2);
    expect(Bed.focused(), contains('Watched'));

    await Bed.down(t);
    expect(Bed.focused(), contains('_SeasonMarks'), reason: 'the season, under the timeline');
    expect(Bed.focused(), contains('Mark season watched'));
    expect(Bed.focusInView(), isTrue);
    await Bed.ok(t);
    final count = RegExp(r'^(\d+) of (\d+) watched$');
    final line = t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').firstWhere(count.hasMatch);
    final m = count.firstMatch(line)!;
    expect(m[1], m[2], reason: 'every episode out is watched: $line');
    expect(int.parse(m[1]!), greaterThan(1));
    expect(WatchProgress.find(show)!.episodesFinished, int.parse(m[1]!));
    expect(Bed.focused(), contains('Mark season unwatched'));
    await Bed.picture(t, 'watched/season_watched');

    await Bed.ok(t);
    expect(WatchProgress.find(show)!.episodesFinished, 0, reason: 'and back again');
    expect(find.text('0 of ${m[2]} watched'), findsOneWidget);
    await done(t);
  }, variant: screen);

  // Testers (2026-11-23): "how do you mark a series watched?"
  testWidgets('a series: Mark all watched beside Save marks every episode of every season; it says All watched after; pressed again, it asks first', (t) async {
    await start(t);
    await Bed.pumpShell(t);
    final show = Bed.freshTitle(series: true); // 3 seasons of 8, all out
    await Bed.push(t, DetailsPage(media: show));
    if (!Bed.focused().contains("'Play'")) await Bed.down(t);
    expect(Bed.focused(), contains("'Play'"));
    await seek(t, 'SeriesWatchedButton');
    expect(Bed.focused(), contains('Mark all watched'));
    expect(Bed.focusInView(), isTrue);

    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(WatchProgress.find(show)!.episodesFinished, 24, reason: 'every episode of the 3 seasons');
    expect(WatchProgress.isSeen(show, season: 3, episode: 8), isTrue);
    expect(WatchProgress.isSeen(show, season: 0, episode: 1), isFalse, reason: 'specials are not marked');
    expect(Bed.focused(), allOf(contains('SeriesWatchedButton'), contains('All watched')), reason: 'the ring stays on it, and it says so');
    await Bed.picture(t, 'watched/series_watched');

    // the page opened again knows it, without a press
    await Bed.back(t);
    expect(find.byType(DetailsPage), findsNothing);
    await Bed.push(t, DetailsPage(media: show));
    await Bed.settle(t, rounds: 3);
    expect(find.text('All watched'), findsOneWidget);
    if (!Bed.focused().contains("'Play'")) await Bed.down(t);
    await seek(t, 'SeriesWatchedButton');

    // pressed now, it asks; Back (or Cancel) leaves everything watched
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    expect(find.text('Mark all unwatched?'), findsOneWidget);
    expect(_materialFocus(), 'Cancel', reason: 'the safe answer has the ring');
    await Bed.back(t);
    expect(find.byType(AlertDialog), findsNothing, reason: 'Back closes it');
    expect(WatchProgress.find(show)!.episodesFinished, 24, reason: 'and changes nothing');
    expect(Bed.focused(), contains('SeriesWatchedButton'), reason: 'the ring is back on the button');

    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    await Bed.right(t);
    expect(_materialFocus(), 'Mark unwatched');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(find.byType(AlertDialog), findsNothing);
    expect(WatchProgress.find(show)!.episodesFinished, 0, reason: 'every episode back to unwatched');
    expect(Bed.focused(), allOf(contains('SeriesWatchedButton'), contains('Mark all watched')));
    await done(t);
  }, variant: screen);

  testWidgets('Continue watching: holding OK on a card offers Mark as watched; it leaves the row', (t) async {
    await start(t);
    await Bed.pumpShell(t);
    for (var i = 0; i < 8 && !Bed.focused().contains('Continue watching'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('Continue watching'));
    final before = WatchProgress.continueWatching.map((e) => e.media.key).toSet();

    await holdOk(t);
    expect(find.text('Mark as watched'), findsOneWidget, reason: 'holding OK opens the card\'s menu');
    expect(find.text('Remove from Continue watching'), findsOneWidget);
    await Bed.picture(t, 'watched/continue_menu');
    await Bed.ok(t);
    expect(find.text('Mark as watched'), findsNothing, reason: 'the menu closed');

    final after = WatchProgress.continueWatching.map((e) => e.media.key).toSet();
    final gone = before.difference(after);
    expect(gone, hasLength(1), reason: 'the card held, and only it');
    final e = WatchProgress.entries.value.firstWhere((e) => e.media.key == gone.single);
    expect(e.finished, isTrue);
    expect(e.hidden, isFalse, reason: 'watched, not removed by hand');
    // (the card is gone: the kit puts the ring back on the page, as when a card is removed)
    expect(Bed.focused(), isNot('nothing'));
    expect(Bed.focusInView(), isTrue);
    await done(t);
  }, variant: screen);

  testWidgets('the player\'s episodes: holding OK on an episode marks it watched and the row says so; again, unwatched', (t) async {
    await start(t);
    await Bed.openPlayer(t, series: true);
    final show = t.widget<PlayerPage>(find.byType(PlayerPage)).media;
    await Bed.down(t);
    // (a phone's key has no keyboard letter)
    final tool = Bed.nodeOf(t, find.byWidgetPredicate((w) => w is Pressable && (w.tooltip == 'Episodes (E)' || w.tooltip == 'Episodes')));
    // along each row of controls, then down to the next (a phone keeps it in a capsule of its own)
    for (var row = 0; row < 5 && !tool.hasPrimaryFocus; row++) {
      for (var i = 0; i < 8 && !tool.hasPrimaryFocus; i++) {
        await Bed.left(t);
      }
      for (var i = 0; i < 14 && !tool.hasPrimaryFocus; i++) {
        await Bed.right(t);
      }
      if (!tool.hasPrimaryFocus) await Bed.down(t);
    }
    expect(tool.hasPrimaryFocus, isTrue, reason: 'the arrows reach the Episodes key');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    expect(Bed.focused(), allOf(contains('_EpisodeRow'), contains('Chapter 2')), reason: 'it opens on the episode after the one playing');
    if (OnScreens.current == Screens.tv) {
      expect(find.descendant(of: find.byType(TvMenuFrame), matching: find.textContaining('Hold OK to mark watched')), findsOneWidget, reason: 'a TV says how');
    }
    Finder inList(Finder what) => find.descendant(of: find.byType(EpisodesPanel), matching: what);
    expect(inList(find.textContaining('Watched')), findsNothing);

    await holdOk(t);
    expect(WatchProgress.isSeen(show, season: 1, episode: 2), isTrue);
    expect(find.byType(PlayerPage), findsOneWidget, reason: 'holding OK played nothing');
    expect(t.widget<EpisodesPanel>(find.byType(EpisodesPanel)).current.number, 1, reason: 'still on episode 1');
    expect(Bed.focused(), allOf(contains('_EpisodeRow'), contains('Chapter 2')), reason: 'the ring stays on the row');
    expect(inList(find.textContaining('Watched')), findsOneWidget, reason: 'the row says so');
    expect(
      t.widgetList<WatchedTick>(inList(find.byType(WatchedTick))).where((w) => w.seen),
      hasLength(1),
      reason: 'and its tick is green',
    );
    await Bed.picture(t, 'watched/player_episodes');

    await holdOk(t);
    expect(WatchProgress.isSeen(show, season: 1, episode: 2), isFalse);
    await Bed.back(t);
    expect(tool.hasPrimaryFocus, isTrue, reason: 'Back closes the list onto its button');
    await done(t);
    await Bed.closePlayer(t);
  }, variant: screen);
}
