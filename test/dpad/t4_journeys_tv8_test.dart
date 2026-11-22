// The player on a TV, as the user asked for it on 2026-11-19: "i want the player UI to be fully
// different for android tv, more like nuvio, and all panels to be transparent fullscreen
// menu's ... especially their subtitles ui". docs/dpad/PLAN.md note 94 has what was looked at
// and what was built.
//
// These are the real player page's journeys with a remote. What each menu holds, with made-up
// subtitles, tracks and links, is walked and drawn in look_tv_menus_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/mpv/vyse_video.dart' show VyseVideo;
import 'package:vyse_tv/screens/player/player_chrome.dart';
import 'package:vyse_tv/screens/player/player_episodes.dart';
import 'package:vyse_tv/screens/player/player_menus.dart';
import 'package:vyse_tv/screens/player/subtitle_sync_panel.dart';
import 'package:vyse_tv/screens/player/tv_menus.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);
  const screen = Rect.fromLTWH(0, 0, 960, 540);

  /// The name (tooltip) of the key the ring is on.
  String key() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<Pressable>()?.tooltip ?? '';

  /// The row the ring is on, and the column it is in.
  String row() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<MenuRow>()?.title ?? '';
  String rail() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvRail>()?.title ?? '';

  /// The controls' keys from the left, by walking Right from the first to the last.
  Future<List<String>> keys(WidgetTester t) async {
    for (var i = 0; i < 12; i++) {
      await Bed.left(t);
    }
    final out = <String>[key()];
    for (var i = 0; i < 12; i++) {
      await Bed.right(t);
      if (key() == out.last) break;
      out.add(key());
    }
    return out;
  }

  Future<void> goTo(WidgetTester t, String name) async {
    for (var i = 0; i < 12 && key() != name; i++) {
      await Bed.left(t);
    }
    for (var i = 0; i < 12 && key() != name; i++) {
      await Bed.right(t);
    }
    expect(key(), name);
  }

  PlayerPanel panel(WidgetTester t) => t.widget<PlayerPanel>(find.byType(PlayerPanel));
  Finder inMenu(Finder what) => find.descendant(of: find.byType(PlayerPanel), matching: what);
  bool controlsTakeFocus(WidgetTester t) => !t.widget<ExcludeFocus>(find.ancestor(of: find.byType(TvDock), matching: find.byType(ExcludeFocus)).first).excluding;

  testWidgets('a TV: the controls are a row of round keys from the left, and each menu fills the screen: OK on its key opens it, Back closes it onto that key', (t) async {
    await Bed.openPlayer(t);
    await Bed.down(t); // the controls come up
    expect(find.byType(TvDock), findsOneWidget);
    expect(find.byType(PlayerDock), findsNothing, reason: 'not the desktop\'s dock');
    expect(key(), 'Play / pause (Space)', reason: 'the ring starts on Play');
    expect(await keys(t), ['Play / pause (Space)', 'Subtitles (C)', 'Audio', 'Sources', 'Settings (S)', 'Stream info'], reason: 'a film: no episodes, and no volume or skip keys on a TV');
    final tops = {for (final k in find.descendant(of: find.byType(TvDock), matching: find.byType(Pressable)).evaluate()) t.getCenter(find.byWidget(k.widget)).dy};
    expect(tops.length, 1, reason: 'one row');
    expect(t.getRect(find.byType(TvDock)).left, lessThan(60), reason: 'from the left edge');
    await Bed.picture(t, 'tv8/controls_film');

    // Subtitles: the whole screen, over a picture that has not moved
    await goTo(t, 'Subtitles (C)');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 2);
    expect(panel(t).open, isTrue);
    expect(panel(t).tab, MenuTab.subtitles);
    expect(inMenu(find.byType(TvMenuFrame)), findsOneWidget);
    expect(t.getRect(inMenu(find.byType(TvMenuShade))), screen, reason: 'the menu is the whole screen');
    expect(t.getRect(find.byType(VyseVideo)), screen, reason: 'and the picture keeps it too: it shows through');
    expect(inMenu(find.widgetWithText(TvMenuFrame, 'Subtitles')), findsOneWidget);
    expect([for (final r in t.widgetList<TvRail>(inMenu(find.byType(TvRail)))) r.title], ['Languages', 'Subtitles', 'Style']);
    expect(controlsTakeFocus(t), isFalse, reason: 'the controls step aside while a menu is open');
    expect((rail(), row()), ('Languages', 'Off'), reason: 'on what is in use: nothing yet');
    await Bed.picture(t, 'tv8/subtitles_empty');
    await Bed.back(t);
    expect(panel(t).open, isFalse, reason: 'Back closes a menu: there is no list of menus to go back through');
    expect(key(), 'Subtitles (C)', reason: 'and the ring is back on its key');
    expect(controlsTakeFocus(t), isTrue);

    // Audio and Sources the same way
    for (final (name, tab) in const [('Audio', MenuTab.audio), ('Sources', MenuTab.sources)]) {
      await goTo(t, name);
      await Bed.ok(t);
      await Bed.settle(t, rounds: 2);
      expect((panel(t).open, panel(t).tab), (true, tab));
      expect(inMenu(find.widgetWithText(TvMenuFrame, tab.label)), findsOneWidget);
      await Bed.back(t);
      expect(panel(t).open, isFalse);
      expect(key(), name);
    }

    // Settings: quality, speed and the rest side by side
    await goTo(t, 'Settings (S)');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 2);
    expect(panel(t).open, isTrue);
    expect(inMenu(find.widgetWithText(TvMenuFrame, 'Settings')), findsOneWidget);
    expect([for (final r in t.widgetList<TvRail>(inMenu(find.byType(TvRail)))) r.title], ['Quality', 'Speed', 'More']);
    expect(rail(), 'Quality', reason: 'it opens in its first column');
    await Bed.right(t);
    expect((rail(), row()), ('Speed', 'Normal'), reason: 'into a column: onto the choice in use');
    await Bed.right(t);
    expect(rail(), 'More');
    await Bed.picture(t, 'tv8/settings');
    await Bed.back(t);
    expect(panel(t).open, isFalse);
    expect(key(), 'Settings (S)');
    await Bed.closePlayer(t);
  }, variant: tv);

  testWidgets('a TV: Episodes fills the screen too: the seasons, and beside them the episodes of the season the ring is on', (t) async {
    await Bed.openPlayer(t, series: true);
    await Bed.down(t);
    expect(await keys(t), ['Play / pause (Space)', 'Next episode (N)', 'Episodes (E)', 'Subtitles (C)', 'Audio', 'Sources', 'Settings (S)', 'Stream info']);
    await Bed.picture(t, 'tv8/controls_series');

    await goTo(t, 'Episodes (E)');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    Finder inEpisodes(Finder what) => find.descendant(of: find.byType(EpisodesPanel), matching: what);
    expect(t.getRect(find.byType(EpisodesPanel)), screen);
    expect(inEpisodes(find.widgetWithText(TvMenuFrame, 'Episodes')), findsOneWidget);
    final rails = [for (final r in t.widgetList<TvRail>(inEpisodes(find.byType(TvRail)))) r.title];
    expect(rails, ['Seasons', 'Season 1']);
    expect(rail(), 'Season 1', reason: 'it opens on an episode');
    expect(Bed.focusInView(), isTrue);
    await Bed.picture(t, 'tv8/episodes_1_open');

    await Bed.left(t);
    expect((rail(), row()), ('Seasons', 'Season 1'), reason: 'Left: the season showing');
    await Bed.down(t);
    await Bed.settle(t, rounds: 3);
    expect(row(), 'Season 2');
    expect([for (final r in t.widgetList<TvRail>(inEpisodes(find.byType(TvRail)))) r.title], ['Seasons', 'Season 2'], reason: 'its episodes show beside it at once');
    await Bed.picture(t, 'tv8/episodes_2_another_season');
    await Bed.ok(t); // OK on a season goes on into its episodes
    await Bed.settle(t, rounds: 2);
    expect(rail(), 'Season 2');
    await Bed.back(t);
    await Bed.settle(t, rounds: 2);
    expect(key(), 'Episodes (E)', reason: 'Back closes it onto its key');
    await Bed.closePlayer(t);
  }, variant: tv);

  testWidgets('a TV: Sync subtitles is in the Style column, and fills the screen like the menus', (t) async {
    await Bed.openPlayer(t);
    await Bed.down(t);
    await goTo(t, 'Subtitles (C)');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 2);
    await Bed.right(t); // (nothing to stop on in the middle column: no subtitles were found)
    expect(rail(), 'Style');
    final here = FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<Pressable>()!;
    expect(
      find.descendant(of: find.byWidget(here), matching: find.text('Sync subtitles')),
      findsOneWidget,
      reason: 'Right from the languages, with no subtitles in the middle column: the first thing in Style',
    );
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(panel(t).open, isFalse);
    expect(t.getRect(find.byType(SubtitleSyncPanel)), screen);
    expect(find.descendant(of: find.byType(SubtitleSyncPanel), matching: find.byType(TvMenuShade)), findsOneWidget);
    expect(find.text('Subtitle sync'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<SubtitleSyncPanel>(), isNotNull, reason: 'the ring is in it');
    await Bed.picture(t, 'tv8/sync');
    await Bed.back(t);
    await Bed.settle(t, rounds: 2);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<SubtitleSyncPanel>(), isNull);
    await Bed.closePlayer(t);
  }, variant: tv);
  // A tester (2026-11-19): "the button to go from play/pause skips the progress tracking bar".
  // Up from Play went to the source line above the bar: the bar's middle is far to the right
  // of Play, and the kit measured how far off the line a control is middle to middle.
  testWidgets('a TV: Up from Play reaches the seek bar, and Down from the bar comes back to Play', (t) async {
    await Bed.openPlayer(t);
    await Bed.down(t); // the controls come up, the ring on Play
    expect(key(), 'Play / pause (Space)');
    await Bed.up(t);
    expect(Bed.focused(), contains('PlayerRail'), reason: 'the seek bar is right above the keys');
    await Bed.down(t);
    expect(key(), 'Play / pause (Space)', reason: 'back to the key it went up from, not the one under the middle of the bar');
    await Bed.right(t, times: 3);
    final from = key();
    await Bed.up(t);
    expect(Bed.focused(), contains('PlayerRail'));
    await Bed.down(t);
    expect(key(), from, reason: 'from any key');
    await Bed.up(t, times: 2);
    expect(key(), 'Change source', reason: 'and on up past the bar');
    await Bed.closePlayer(t);
  }, variant: tv);
}
