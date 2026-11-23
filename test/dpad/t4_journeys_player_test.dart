// T2, T3, T4 and T7 for the video player, on the real player page with a stand-in for the
// video engine (the native side answers "started" and then does nothing; see harness.dart).
// The page is as it is while a title's sources are still being looked for: every control and
// menu is there, nothing plays. Real playback is on the by-hand list.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/screens/shell/floating.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/screens/player/player_chrome.dart';
import 'package:vyse_tv/screens/player/player_menus.dart';
import 'package:vyse_tv/screens/player/player_episodes.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/screens/player/subtitle_sync_panel.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'bed/walker.dart';
import 'harness.dart';

Future<void> _open(WidgetTester t, {bool series = false}) => Bed.openPlayer(t, series: series);
Future<void> _close(WidgetTester t) => Bed.closePlayer(t);

/// Whether the player's controls are up (they take taps and focus only then).
bool _controlsUp(WidgetTester t) => !t.widget<ExcludeFocus>(find.ancestor(of: find.byType(PlayerDock), matching: find.byType(ExcludeFocus)).first).excluding;
bool _onPicture() => FocusManager.instance.primaryFocus?.debugLabel == 'player';
bool _panelOpen(WidgetTester t) => t.widget<PlayerPanel>(find.byType(PlayerPanel)).open;

/// The focus node of the dock's tool with this tooltip, and a walk along the dock to it.
FocusNode _tool(WidgetTester t, String tip) => Bed.nodeOf(t, find.byWidgetPredicate((w) => w is Pressable && w.tooltip == tip));

Future<FocusNode> _goToTool(WidgetTester t, String tip) async {
  final tool = _tool(t, tip);
  for (var i = 0; i < 14 && !tool.hasPrimaryFocus; i++) {
    await Bed.right(t);
  }
  expect(tool.hasPrimaryFocus, isTrue, reason: 'Right along the dock reaches "$tip"');
  return tool;
}

String _scope() => FocusManager.instance.primaryFocus?.nearestScope?.debugLabel ?? '';

/// Lets the controls time out (they hide four seconds after the last key).
Future<void> _idle(WidgetTester t) async {
  await t.pump(const Duration(seconds: 5));
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screen = OnScreens([Screens.laptop]);

  testWidgets('controls hidden: focus rests on the picture; Left and Right are its own and start no D-pad mode', (t) async {
    await _open(t);
    expect(_onPicture(), isTrue, reason: 'the player opens with focus on the picture');
    await _idle(t);
    expect(_controlsUp(t), isFalse);
    await Bed.right(t);
    await Bed.left(t);
    expect(_onPicture(), isTrue);
    expect(InputModeTracker.currentMode, InputMode.pointer, reason: 'seeking with the arrows is not navigating: no ring, the mouse cursor stays');
    expect(_controlsUp(t), isFalse);
    // Space still pauses, with a mouse in charge as before
    final calls = Bed.videoCalls.length;
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump(const Duration(milliseconds: 100));
    expect(Bed.videoCalls.length, greaterThan(calls), reason: 'Space reached the video engine');
    expect(_onPicture(), isTrue);
    await _close(t);
  }, variant: screen);

  testWidgets('OK or Down brings the controls up with focus on Play; arrows walk the controls; Back hides them; Back again leaves', (t) async {
    await _open(t);
    await _idle(t);
    expect(_controlsUp(t), isFalse);
    await Bed.down(t);
    expect(_controlsUp(t), isTrue, reason: 'Down on the picture brings the controls up');
    expect(Bed.focused(), contains('PlayKey'), reason: 'and puts focus on Play');
    expect(InputModeTracker.currentMode, InputMode.keyboard);
    final calls = Bed.videoCalls.length;
    await Bed.ok(t);
    expect(Bed.videoCalls.length, greaterThan(calls), reason: 'OK on Play reached the video engine');

    await Bed.left(t);
    expect(Bed.focused(), contains('_Skip'));
    await Bed.right(t, times: 2);
    expect(Bed.focused(), contains('_Skip'), reason: 'the other skip button, past Play');
    await Bed.right(t);
    expect(Bed.focused(), contains('_Tool'), reason: 'on along the dock to the tools');
    await Bed.up(t);
    expect(Bed.focused(), contains('PlayerRail'), reason: 'the seek bar is a stop above the dock');
    await Bed.right(t, times: 3);
    await Bed.left(t);
    expect(Bed.focused(), contains('PlayerRail'), reason: 'on the seek bar Left and Right seek; focus stays');
    await Bed.up(t, times: 8);
    expect(Bed.focused(), contains('_IconBtn'), reason: 'Up, however long it is held, ends on the top bar (Back and Minimise), not on the Close button of the window');
    await Bed.right(t, times: 2);
    expect(Bed.focused(), contains('_WinButton'), reason: 'Right from the end of the top bar leads to the buttons of the window');
    await Bed.right(t, times: 4);
    await Bed.up(t);
    expect(Bed.focused(), contains('_WinButton'));
    await Bed.down(t);
    expect(Bed.focused(), contains('_IconBtn'), reason: 'Down (or Left off their first) leads back');
    expect(_controlsUp(t), isTrue, reason: 'pressing keys keeps the controls up');

    await Bed.back(t);
    expect(find.byType(PlayerPage), findsOneWidget, reason: 'the first Back only hides the controls');
    expect(_controlsUp(t), isFalse);
    expect(_onPicture(), isTrue);
    await Bed.back(t);
    expect(find.byType(PlayerPage), findsNothing, reason: 'the second Back leaves the player');
    expect(find.byType(HomePage), findsOneWidget);
    expect(Bed.focused(), isNot('nothing'), reason: 'and the page underneath has focus again');
  }, variant: screen);

  testWidgets('OK on the picture also brings the controls up; left alone they hide and focus goes back to the picture', (t) async {
    await _open(t);
    await _idle(t);
    // Enter with a mouse in charge: the controls show, nothing takes focus (no ring to show)
    await Bed.ok(t);
    expect(_controlsUp(t), isTrue);
    expect(_onPicture(), isTrue);
    await _idle(t);
    expect(_controlsUp(t), isFalse);
    // with a D-pad
    await Bed.up(t);
    expect(Bed.focused(), contains('PlayKey'));
    await _idle(t);
    expect(_controlsUp(t), isFalse, reason: 'four seconds without a key: the controls hide');
    expect(_onPicture(), isTrue, reason: 'and a hidden control does not keep focus (R1, R4)');
    await Bed.ok(t);
    expect(Bed.focused(), contains('PlayKey'));
    await _close(t);
  }, variant: screen);

  testWidgets('a menu opens in place, takes focus, keeps the arrows, and Back returns to the button that opened it', (t) async {
    await _open(t);
    await Bed.down(t);
    await Bed.right(t, times: 3);
    expect(Bed.focused(), contains('_Tool'));
    final tool = FocusManager.instance.primaryFocus!;
    final picture = t.getRect(find.byType(PlayerPage));
    await Bed.ok(t);
    expect(_panelOpen(t), isTrue, reason: 'OK on a tool opens its menu');
    expect(t.getRect(find.byType(PlayerPage)), picture, reason: 'the picture is not moved or shrunk for a menu');
    final menu = FocusManager.instance.primaryFocus!;
    expect(Dpad.isStop(menu), isTrue, reason: 'focus is on something in the menu');
    expect(menu.nearestScope!.debugLabel, 'player menu');
    for (final press in [Bed.down, Bed.left, Bed.up, Bed.right, Bed.down, Bed.down, Bed.right]) {
      await press(t, times: 3);
      expect(FocusManager.instance.primaryFocus!.nearestScope!.debugLabel, 'player menu', reason: 'arrows stay in the menu');
      expect(Dpad.isStop(FocusManager.instance.primaryFocus), isTrue);
    }
    await Bed.back(t);
    expect(_panelOpen(t), isFalse, reason: 'Back closes the menu');
    expect(find.byType(PlayerPage), findsOneWidget, reason: 'and only the menu');
    expect(tool.hasPrimaryFocus, isTrue, reason: 'focus is back on the tool that opened it');
    expect(_controlsUp(t), isTrue);
    await _close(t);
  }, variant: screen);

  testWidgets('the episode list opens on the episode after the one playing, keeps the arrows, and Back returns to its button', (t) async {
    await _open(t, series: true);
    await Bed.down(t);
    final tool = await _goToTool(t, 'Episodes (E)');
    final picture = t.getRect(find.byType(PlayerPage));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    expect(t.widget<EpisodesPanel>(find.byType(EpisodesPanel)).current.number, 1);
    expect(Bed.focused(), allOf(contains('_EpisodeRow'), contains('Chapter 2')), reason: 'the list was still loading when the panel opened; focus moved to the next episode when it arrived');
    expect(Bed.focusInView(), isTrue);
    expect(t.getRect(find.byType(PlayerPage)), picture, reason: 'the picture is not moved or shrunk');
    final walk = await Walker(t, settle: () async {}, isNavbar: (_) => true, ignore: (label) => !label.contains('EpisodesPanel')).run(maxPresses: 800);
    for (final p in walk.problems) {
      debugPrint('PROBLEM $p', wrapWidth: 2000);
    }
    walk.expectClean();
    expect(walk.where('_SeasonPill').length, 3);
    expect(walk.where('_EpisodeRow').length, greaterThan(5));
    expect(_scope(), 'episodes', reason: 'arrows never left the list');
    await Bed.back(t);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(tool.hasPrimaryFocus, isTrue, reason: 'Back closes the list and returns to the button that opened it');
    await _close(t);
  }, variant: screen);

  testWidgets('the subtitles menu opens on the current choice; Sync opens its panel on Play; Back closes one thing at a time', (t) async {
    await _open(t);
    await Bed.down(t);
    final tool = await _goToTool(t, 'Subtitles (C)');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(Bed.focused(), allOf(contains('MenuRow'), contains("'Off'")), reason: 'no subtitle is on: the menu opens on Off, the choice in use');
    await Bed.up(t);
    expect(Bed.focused(), contains('Sync automatically'));
    await Bed.up(t);
    expect(Bed.focused(), contains('Sync subtitles'));
    await Bed.up(t);
    expect(Bed.focused(), allOf(contains('MenuSegments'), contains('Subtitles')), reason: 'Up from the list reaches the tabs, on the tab that is showing');
    await Bed.down(t);
    expect(Bed.focused(), contains('Sync subtitles'));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    expect(_panelOpen(t), isFalse);
    expect(_scope(), 'subtitle sync');
    final play = Bed.nodeOf(t, find.descendant(of: find.byType(SubtitleSyncPanel), matching: find.byWidgetPredicate((w) => w is Pressable && w.tooltip == 'Play')));
    expect(play.hasPrimaryFocus, isTrue, reason: 'the sync panel opens on its Play button');
    final walk = await Walker(t, settle: () async {}, isNavbar: (_) => true, ignore: (label) => !label.contains('SubtitleSyncPanel')).run(maxPresses: 800);
    for (final p in walk.problems) {
      debugPrint('PROBLEM $p', wrapWidth: 2000);
    }
    walk.expectClean();
    expect(walk.where('_Nudge').length, 4);
    expect(_scope(), 'subtitle sync');
    // the panel has a text box: Back steps off it first if the walk ended there
    for (var i = 0; i < 2 && _scope() == 'subtitle sync'; i++) {
      await Bed.back(t);
    }
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(tool.hasPrimaryFocus, isTrue, reason: 'back on the Subtitles button');
    await _close(t);
  }, variant: screen);

  testWidgets('a menu a mouse opened: nothing takes focus; the first Down goes into the menu, not to Play', (t) async {
    await _open(t, series: true);
    await t.sendKeyEvent(LogicalKeyboardKey.keyE);
    await Bed.settle(t, rounds: 4);
    expect(_onPicture(), isTrue, reason: 'the list\'s start is only a mark: with a mouse in charge the picture keeps the keys');
    expect(InputModeTracker.currentMode, InputMode.pointer);
    await Bed.down(t);
    expect(_scope(), 'episodes');
    expect(Bed.focused(), contains('_EpisodeRow'));
    await Bed.back(t);
    expect(_onPicture(), isTrue, reason: 'it was opened from the picture, so that is where Back returns');
    await _close(t);
  }, variant: screen);

  testWidgets('after a menu closes the controls time out as usual and focus goes back to the picture', (t) async {
    await _open(t);
    await Bed.down(t);
    final tool = await _goToTool(t, 'Settings (S)');
    await Bed.ok(t);
    expect(_panelOpen(t), isTrue);
    await _idle(t);
    await _idle(t);
    expect(_panelOpen(t), isTrue, reason: 'an open menu does not time out');
    await Bed.back(t);
    expect(tool.hasPrimaryFocus, isTrue);
    expect(_controlsUp(t), isTrue);
    await _idle(t);
    expect(_controlsUp(t), isFalse, reason: 'the idle clock started again when the menu closed');
    expect(_onPicture(), isTrue);
    await _close(t);
  }, variant: screen);

  testWidgets('the small window: M shrinks the player; the rail\'s entry leads in, focus shows its buttons, OK brings it back', (t) async {
    await _open(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    await Bed.settle(t, rounds: 5);
    expect(find.byType(PlayerPage), findsNothing, reason: 'its page closed');
    expect(MiniPlayer.session.value, isNotNull);
    addTearDown(MiniPlayer.close);
    double buttons() => t.widget<AnimatedOpacity>(find.ancestor(of: find.byTooltip('Back to full size'), matching: find.byType(AnimatedOpacity)).first).opacity;
    expect(buttons(), 0, reason: 'its buttons show on hover only');

    await Bed.down(t);
    await Bed.left(t, times: 25);
    expect(Bed.focused(), contains('SideRail'));
    for (var i = 0; i < 20 && !Bed.focused().contains('_RailFloating'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains("'Mini player'"));
    expect(buttons(), 0);
    await Bed.ok(t);
    expect(FloatingLayer.region.hasFocus, isTrue);
    expect(Bed.focused(), contains('_MiniButton'));
    final playOrPause = find.byWidgetPredicate((w) => w is Tooltip && (w.message == 'Play' || w.message == 'Pause'));
    expect(Bed.nodeOf(t, find.descendant(of: playOrPause, matching: find.byType(Pressable))).hasPrimaryFocus, isTrue, reason: 'the small window starts on Play');
    expect(buttons(), 1, reason: 'what hover reveals, focus reveals');
    await t.pump(const Duration(seconds: 5));
    expect(buttons(), 1, reason: 'and they stay while focus is on them');
    for (final press in [Bed.up, Bed.right, Bed.down, Bed.right, Bed.up, Bed.down]) {
      await press(t, times: 2);
      expect(Bed.focused(), contains('_MiniButton'), reason: 'Up, Down and Right stay in the small window');
    }
    await Bed.left(t, times: 4);
    expect(Bed.focused(), contains('SideRail'), reason: 'Left off its edge is the rail again, as for the chat');
    await Bed.ok(t);
    expect(Bed.focused(), contains('_MiniButton'));
    await Bed.back(t);
    expect(Bed.focused(), contains('SideRail'), reason: 'Back leaves it for the rail');
    await t.pump(const Duration(milliseconds: 400));
    expect(buttons(), 0, reason: 'and its buttons go');

    // back in, to "Back to full size"
    await Bed.ok(t);
    final restore = Bed.nodeOf(t, find.descendant(of: find.byTooltip('Back to full size'), matching: find.byType(Pressable)));
    for (var i = 0; i < 6 && !restore.hasPrimaryFocus; i++) {
      await Bed.up(t);
      if (!restore.hasPrimaryFocus) await Bed.left(t);
    }
    expect(restore.hasPrimaryFocus, isTrue);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 5);
    expect(find.byType(PlayerPage), findsOneWidget, reason: 'the player is back on its page');
    expect(MiniPlayer.session.value, isNull);
    await _close(t);
  }, variant: screen);

  testWidgets('media keys work in both states and move nothing', (t) async {
    await _open(t);
    await _idle(t);
    var calls = Bed.videoCalls.length;
    await t.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause, platform: 'android');
    await t.pump(const Duration(milliseconds: 100));
    expect(Bed.videoCalls.length, greaterThan(calls), reason: 'play/pause with the controls hidden');
    expect(_onPicture(), isTrue);
    await Bed.down(t);
    await Bed.right(t, times: 3);
    expect(Bed.focused(), contains('_Tool'));
    calls = Bed.videoCalls.length;
    await t.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause, platform: 'android');
    await t.pump(const Duration(milliseconds: 100));
    expect(Bed.videoCalls.length, greaterThan(calls), reason: 'and with focus on a control');
    expect(Bed.focused(), contains('_Tool'), reason: 'focus stayed where it was');
    await _close(t);
  }, variant: screen);

  testWidgets('with a mouse in charge the letter keys open menus as before and nothing takes focus', (t) async {
    await _open(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    await Bed.settle(t, rounds: 2);
    expect(_panelOpen(t), isTrue);
    expect(_onPicture(), isTrue);
    expect(InputModeTracker.currentMode, InputMode.pointer);
    await Bed.back(t);
    expect(_panelOpen(t), isFalse);
    expect(find.byType(PlayerPage), findsOneWidget);
    await Bed.back(t);
    expect(find.byType(PlayerPage), findsNothing, reason: 'Escape leaves the player, as before');
  }, variant: screen);

  testWidgets('T3: every control, and every menu tab, can be reached with arrows; nothing is cut off', (t) async {
    await _open(t);
    final report = await Walker(t, settle: () async {}, isNavbar: (p) => p.label.contains('_IconBtn')).run(maxPresses: 1200);
    debugPrint('walked ${report.places.length} places in ${report.presses} presses, ${report.problems.length} problem(s)');
    for (final p in report.problems) {
      debugPrint('PROBLEM $p', wrapWidth: 2000);
    }
    report.expectClean();
    expect(report.where('PlayKey'), isNotEmpty);
    expect(report.where('PlayerRail'), isNotEmpty);
    expect(report.where('_Tool').length, greaterThanOrEqualTo(4));

    // into the settings menu, and the same there
    for (var i = 0; i < 12 && !Bed.focused().contains('_Tool'); i++) {
      await Bed.down(t);
      await Bed.right(t, times: 2);
    }
    await Bed.right(t, times: 6);
    await Bed.left(t);
    await Bed.ok(t);
    expect(_panelOpen(t), isTrue);
    final inMenu = await Walker(t, settle: () async {}, isNavbar: (_) => true, ignore: (label) => !label.contains('player_menus.dart')).run(maxPresses: 1500);
    debugPrint('menu: walked ${inMenu.places.length} places in ${inMenu.presses} presses, ${inMenu.problems.length} problem(s)');
    for (final p in inMenu.problems) {
      debugPrint('PROBLEM $p', wrapWidth: 2000);
    }
    inMenu.expectClean();
    expect(inMenu.places.length, greaterThan(4));
    await _close(t);
  }, variant: screen);

  testWidgets('T7: Back hammered, and held, never does two things at once and ends at rest', (t) async {
    await _open(t);
    await Bed.down(t);
    await Bed.right(t, times: 3);
    await Bed.ok(t);
    expect(_panelOpen(t), isTrue);
    // held: closes the menu, and no more
    await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 15; i++) {
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await t.pump(const Duration(milliseconds: 33));
    }
    await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await Bed.settle(t, rounds: 3);
    expect(_panelOpen(t), isFalse);
    expect(find.byType(PlayerPage), findsOneWidget, reason: 'a held Back closed the menu and stopped there');
    expect(_controlsUp(t), isTrue);
    // hammered: controls, then out, then nothing more than the shell's own steps
    for (var i = 0; i < 6; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump(const Duration(milliseconds: 60));
      expect(t.takeException(), isNull);
    }
    await Bed.settle(t, rounds: 5);
    expect(find.byType(PlayerPage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
    expect(Bed.focused(), isNot('nothing'));
  }, variant: screen);

  group('the Next episode card by itself', () {
    testWidgets('the card is one stop and its Dismiss another; OK plays, or dismisses', (t) async {
      var played = 0, dismissed = 0;
      await t.pumpWidget(Bed.app(Scaffold(
        body: Center(
          child: SizedBox(
            width: 440,
            child: UpNextCard(
              episode: const EpisodeInfo(1, 2, 'Kite Season', 'What happens next.', null, 46, null),
              auto: false,
              onPlay: () => played++,
              onDismiss: () => dismissed++,
            ),
          ),
        ),
      )));
      await t.pump(const Duration(milliseconds: 400));
      await Bed.dpadMode(t);
      await Bed.focus(t, find.byType(UpNextCard));
      expect(Bed.focused(), contains('UpNextCard'));
      await Bed.ok(t);
      expect(played, 1);
      await Bed.right(t);
      await Bed.ok(t);
      expect((played, dismissed), (1, 1), reason: 'Right steps onto the card\'s own Dismiss button');
      await Bed.left(t);
      await Bed.ok(t);
      expect(played, 2, reason: 'and Left steps back onto the card');
    }, variant: screen);
  });

  group('the seek bar by itself', () {
    testWidgets('Left and Right seek by a step; held, the steps grow; it shows where it is', (t) async {
      final position = ValueNotifier(const Duration(minutes: 30));
      final duration = ValueNotifier(const Duration(hours: 2));
      final buffered = ValueNotifier(Duration.zero);
      addTearDown(position.dispose);
      addTearDown(duration.dispose);
      addTearDown(buffered.dispose);
      final seeks = <Duration>[];
      await t.pumpWidget(Bed.app(Scaffold(
        body: Center(child: SizedBox(width: 900, child: PlayerRail(position: position, duration: duration, buffered: buffered, onSeek: seeks.add))),
      )));
      await t.pump(const Duration(milliseconds: 300));
      final node = Bed.nodeOf(t, find.byType(PlayerRail));
      await Bed.dpadMode(t);
      node.requestFocus();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('30:00'), findsOneWidget, reason: 'under focus the bar shows the time it is at');

      await Bed.right(t);
      expect(seeks.last, const Duration(minutes: 30, seconds: 10));
      await Bed.right(t);
      expect(seeks.last, const Duration(minutes: 30, seconds: 20), reason: 'each press goes on from the last, not from where the video says it still is');
      await Bed.left(t, times: 3);
      expect(seeks.last, const Duration(minutes: 29, seconds: 50));
      expect(node.hasPrimaryFocus, isTrue);

      // held: thirty repeats travel much further than thirty single steps
      seeks.clear();
      await t.pump(const Duration(seconds: 1));
      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 30; i++) {
        await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await t.pump(const Duration(milliseconds: 33));
      }
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(seconds: 1));
      expect(seeks.length, 31, reason: 'every repeat seeks: the bar does not use the page-moving pace');
      expect(seeks.last - const Duration(minutes: 30), greaterThan(const Duration(minutes: 10)));
      // never past the ends
      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      for (var i = 0; i < 200; i++) {
        await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
      }
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await t.pump(const Duration(seconds: 1));
      expect(seeks.last, Duration.zero);
      expect(node.hasPrimaryFocus, isTrue);
      await Bed.up(t);
      await Bed.down(t);
      expect(t.takeException(), isNull);
    }, variant: screen);

    testWidgets('a mouse still clicks and drags it as before', (t) async {
      final position = ValueNotifier(Duration.zero);
      final duration = ValueNotifier(const Duration(minutes: 100));
      final buffered = ValueNotifier(Duration.zero);
      addTearDown(position.dispose);
      addTearDown(duration.dispose);
      addTearDown(buffered.dispose);
      final seeks = <Duration>[];
      await t.pumpWidget(Bed.app(Scaffold(
        body: Center(child: SizedBox(width: 1000, child: PlayerRail(position: position, duration: duration, buffered: buffered, onSeek: seeks.add))),
      )));
      await t.pump(const Duration(milliseconds: 300));
      final rail = t.getRect(find.byType(PlayerRail));
      await t.tapAt(Offset(rail.left + 250, rail.center.dy));
      await t.pump(const Duration(milliseconds: 300));
      expect(seeks.single, const Duration(minutes: 25));
      expect(Bed.nodeOf(t, find.byType(PlayerRail)).hasFocus, isFalse, reason: 'a click leaves no focus behind');
    }, variant: screen);
  });
}
