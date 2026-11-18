// T3, T4 and T7 for the Live TV player and the portal browser's player, with the stand-in for
// the video engine (see harness.dart): the real pages, nothing plays.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/nav.dart';
import 'package:vyse_tv/data/live_tv/live_tv.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/screens/live_tv/live_tv_player_page.dart';
import 'package:vyse_tv/screens/live_tv/portal_browser_player.dart';
import 'package:vyse_tv/widgets/audiobook_widgets.dart' show SeekBar;
import 'package:vyse_tv/widgets/common.dart';

import 'bed/walker.dart';
import 'harness.dart';

List<LiveItem> _channels({bool live = true}) => [
  for (var i = 1; i <= 6; i++) LiveItem(title: live ? 'Channel $i' : 'Recording $i', url: 'http://tv.example/$i.m3u8', subtitle: 'Made-up portal', live: live),
];

Future<void> _open(WidgetTester t, {bool live = true}) async {
  await Bed.pumpShell(t);
  rootNavigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => LiveTvPlayerPage(items: _channels(live: live), index: 1)));
  await Bed.settle(t, rounds: 5);
  expect(find.byType(LiveTvPlayerPage), findsOneWidget);
}

Future<void> _close(WidgetTester t) async {
  for (var i = 0; i < 5 && find.byType(LiveTvPlayerPage).evaluate().isNotEmpty; i++) {
    await Bed.back(t);
  }
  expect(find.byType(LiveTvPlayerPage), findsNothing);
  await Bed.settle(t, rounds: 4);
}

/// The seeks asked of the video engine so far.
Iterable<String> _seeks() => Bed.videoCalls.where((c) => c.startsWith('command') && c.contains('seek'));

String _label() => FocusManager.instance.primaryFocus?.debugLabel ?? '';
String _scope() => FocusManager.instance.primaryFocus?.nearestScope?.debugLabel ?? '';
bool _controlsUp(WidgetTester t) => !t.widget<ExcludeFocus>(find.ancestor(of: find.byTooltip('Mute (M)'), matching: find.byType(ExcludeFocus)).last).excluding;
bool _hasTooltip(String tip) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  var found = false;
  context.visitAncestorElements((e) {
    final w = e.widget;
    if (w is Tooltip && w.message == tip) found = true;
    return !found && w is! LiveTvPlayerPage;
  });
  return found;
}

/// A page with a list on the left and the browser's player in a pane on the right, the way
/// the portal browser lays it out, including its full screen (the same player, moved).
class _Browser extends StatefulWidget {
  const _Browser();
  @override
  State<_Browser> createState() => _BrowserState();
}

class _BrowserState extends State<_Browser> {
  final _player = GlobalKey();
  bool expanded = false;
  int steps = 0;

  @override
  Widget build(BuildContext context) {
    final player = BrowserLivePlayer(
      key: _player,
      item: const LiveItem(title: 'Channel 1', url: 'http://tv.example/1.m3u8'),
      expanded: expanded,
      onExpand: () => setState(() => expanded = !expanded),
      onStep: (d) => setState(() => steps += d),
    );
    if (expanded) return Scaffold(body: player);
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 300,
            child: Column(
              children: [
                for (var i = 1; i <= 4; i++)
                  Pressable(onTap: () {}, builder: (_, _, _) => SizedBox(height: 60, child: Center(child: Text('Row $i')))),
              ],
            ),
          ),
          Expanded(child: Center(child: SizedBox(width: 640, height: 360, child: player))),
        ],
      ),
    );
  }
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screen = OnScreens([Screens.laptop]);

  testWidgets('Live TV: Up and Down change channel and start no D-pad mode; OK or Right brings the controls up on Play', (t) async {
    await _open(t);
    expect(_label(), 'live player', reason: 'the player opens with focus on the picture');
    expect(find.text('Channel 2'), findsWidgets);
    await Bed.down(t);
    expect(find.text('Channel 3'), findsWidgets, reason: 'Down is the next channel, as always');
    await Bed.up(t, times: 2);
    expect(find.text('Channel 1'), findsWidgets);
    expect(InputModeTracker.currentMode, InputMode.pointer, reason: 'changing channel is not navigating: no ring');
    expect(_label(), 'live player');

    await Bed.right(t);
    expect(InputModeTracker.currentMode, InputMode.keyboard);
    expect(_hasTooltip('Play') || _hasTooltip('Pause'), isTrue, reason: 'the controls come up with focus on Play');
    final calls = Bed.videoCalls.length;
    await Bed.ok(t);
    expect(Bed.videoCalls.length, greaterThan(calls), reason: 'OK on Play reached the video engine');
    await Bed.down(t);
    await Bed.up(t);
    expect(find.text('Channel 1'), findsWidgets, reason: 'on the controls Up and Down move focus; the channel stays');
    await Bed.up(t, times: 8);
    expect(Bed.focused(), isNot(contains('_WinButton')), reason: 'a held Up ends on the top bar, not on the window’s Close');

    await Bed.back(t);
    expect(find.byType(LiveTvPlayerPage), findsOneWidget, reason: 'the first Back hides the controls');
    expect(_controlsUp(t), isFalse);
    expect(_label(), 'live player');
    await Bed.down(t);
    expect(find.text('Channel 2'), findsWidgets, reason: 'and Up and Down change channel again');
    await Bed.back(t);
    expect(find.byType(LiveTvPlayerPage), findsNothing, reason: 'the second Back leaves');
    expect(find.byType(HomePage), findsOneWidget);
    expect(Bed.focused(), isNot('nothing'));
  }, variant: screen);

  testWidgets('Live TV: the channel list opens in place on the channel that is on, keeps the arrows, and Back closes it', (t) async {
    await _open(t);
    await Bed.right(t);
    final opener = FocusManager.instance.primaryFocus!;
    expect(_hasTooltip('Play') || _hasTooltip('Pause'), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await Bed.settle(t, rounds: 3);
    expect(_scope(), 'channels');
    expect(Bed.focused(), contains('Channel 2'), reason: 'the list opens on the channel that is on');
    await Bed.down(t, times: 2);
    expect(Bed.focused(), contains('Channel 4'));
    expect(find.text('Channel 2'), findsWidgets, reason: 'moving in the list does not change channel');
    await Bed.left(t, times: 3);
    await Bed.right(t, times: 3);
    await Bed.down(t, times: 9);
    expect(_scope(), 'channels', reason: 'arrows stay in the list');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 2);
    expect(find.descendant(of: find.byType(GlassIconButton), matching: find.text('Channel 6')), findsNothing);
    expect(find.text('Channel 6'), findsNWidgets(2), reason: 'OK on a row puts that channel on (its name is now in the top bar too)');
    await Bed.back(t);
    expect(find.byType(LiveTvPlayerPage), findsOneWidget, reason: 'Back closes the list and only the list');
    expect(opener.hasPrimaryFocus, isTrue, reason: 'and focus is back on the control it was opened from');
    await _close(t);
  }, variant: screen);

  testWidgets('Live TV, T3: every control can be reached with arrows and nothing loses focus', (t) async {
    await _open(t);
    await Bed.right(t);
    final walk = await Walker(t, settle: () async {}, isNavbar: (_) => true).run(maxPresses: 800);
    for (final p in walk.problems) {
      debugPrint('PROBLEM $p', wrapWidth: 2000);
    }
    walk.expectClean();
    expect(walk.places.length, greaterThanOrEqualTo(9), reason: 'Back, Channels, previous, Play, next, Mute, full screen and the window’s three');
    await _close(t);
  }, variant: screen);

  testWidgets('a recording: Left and Right seek on the picture, and its seek bar is a stop that seeks too', (t) async {
    await _open(t, live: false);
    expect(find.byType(SeekBar), findsOneWidget);
    await Bed.right(t);
    expect(_seeks(), isNotEmpty, reason: 'Right on the picture seeks');
    expect(InputModeTracker.currentMode, InputMode.pointer);
    await Bed.ok(t);
    await Bed.dpadMode(t);
    await Bed.ok(t);
    for (var i = 0; i < 4 && !Bed.focused().contains('SeekBar'); i++) {
      await Bed.up(t);
    }
    expect(Bed.focused(), contains('SeekBar'), reason: 'Up from the buttons reaches the seek bar');
    final seeks = _seeks().length;
    await Bed.right(t, times: 3);
    expect(Bed.focused(), contains('SeekBar'), reason: 'Left and Right on the bar seek; focus stays');
    await Bed.down(t);
    expect(Bed.focused(), isNot(contains('SeekBar')), reason: 'Down leaves the bar (a plain slider would have kept it)');
    expect(_seeks().length, seeks, reason: 'nothing was playing, so there was nowhere to seek to: no call was made');
    await _close(t);
  }, variant: screen);

  testWidgets('T7: Back hammered and held in the Live TV player ends on the page underneath, at rest', (t) async {
    await _open(t);
    await Bed.right(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await Bed.settle(t, rounds: 3);
    expect(_scope(), 'channels');
    await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 12; i++) {
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await t.pump(const Duration(milliseconds: 33));
    }
    await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await Bed.settle(t, rounds: 3);
    expect(find.byType(LiveTvPlayerPage), findsOneWidget, reason: 'a held Back closed the list and stopped there');
    for (var i = 0; i < 6; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump(const Duration(milliseconds: 60));
      expect(t.takeException(), isNull);
    }
    await Bed.settle(t, rounds: 5);
    expect(find.byType(LiveTvPlayerPage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
    expect(Bed.focused(), isNot('nothing'));
  }, variant: screen);

  group('the portal browser’s player', () {
    double controls(WidgetTester t) => t.widget<AnimatedOpacity>(find.ancestor(of: find.byTooltip('Mute (M)'), matching: find.byType(AnimatedOpacity)).first).opacity;
    _BrowserState page(WidgetTester t) => t.state<_BrowserState>(find.byType(_Browser));

    // the player lets go of the video engine before the test ends (see Bed.closePlayer)
    Future<void> leave(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await Bed.settle(t, rounds: 4);
    }

    testWidgets('in its pane the buttons are stops on the page; full screen it has the two states', (t) async {
      await t.pumpWidget(Bed.app(const _Browser()));
      await Bed.settle(t, rounds: 4);
      await Bed.dpadMode(t);
      await Bed.focus(t, find.widgetWithText(Pressable, 'Row 1'));
      expect(Bed.focused(), contains('Row 1'), reason: 'the page starts on its list, not on the pane');
      await Bed.down(t, times: 3);
      expect(Bed.focused(), contains('Row 4'), reason: 'a row beside the pane');
      await Bed.right(t);
      final pane = FocusManager.instance.primaryFocus!;
      expect(Bed.focused(), contains('BrowserLivePlayer'), reason: 'Right from a row beside it lands on the pane, which is one stop');
      expect(controls(t), 1, reason: 'focus shows the buttons of the pane, as hover does');
      await t.pump(const Duration(seconds: 6));
      expect(controls(t), 1, reason: 'and they stay while focus is there');
      await Bed.right(t);
      expect(pane.hasPrimaryFocus, isFalse, reason: 'Right steps onto its first button');
      expect(pane.hasFocus, isTrue);
      await Bed.right(t, times: 2);
      await Bed.up(t);
      await Bed.down(t);
      expect(page(t).steps, 0, reason: 'with a D-pad Up and Down move focus; the channel stays');
      await Bed.left(t, times: 8);
      expect(Bed.focused(), contains('Row'), reason: 'Left steps back out, then back to the list');
      await t.pump(const Duration(milliseconds: 400));

      // full screen from its own button
      await Bed.right(t);
      expect(pane.hasPrimaryFocus, isTrue);
      final full = Bed.nodeOf(t, find.byWidgetPredicate((w) => w is Pressable && w.tooltip == 'Full screen (F)'));
      for (var i = 0; i < 8 && !full.hasPrimaryFocus; i++) {
        await Bed.right(t);
      }
      expect(full.hasPrimaryFocus, isTrue);
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      expect(page(t).expanded, isTrue);
      expect(Bed.focused(), contains('BrowserLivePlayer'), reason: 'focus stays on a control of the player');

      await Bed.back(t);
      expect(page(t).expanded, isTrue, reason: 'the first Back hides the controls');
      expect(_label(), 'browser player');
      await Bed.down(t);
      await Bed.down(t);
      expect(page(t).steps, 2, reason: 'on the picture Up and Down change channel');
      await Bed.ok(t);
      final play = Bed.nodeOf(t, find.byWidgetPredicate((w) => w is Pressable && (w.tooltip == 'Play (Space)' || w.tooltip == 'Pause (Space)')));
      expect(play.hasPrimaryFocus, isTrue, reason: 'OK brings the controls up with focus on Play');
      final walk = await Walker(t, settle: () async {}, isNavbar: (_) => true).run(maxPresses: 400);
      for (final p in walk.problems) {
        debugPrint('PROBLEM $p', wrapWidth: 2000);
      }
      walk.expectClean();
      await Bed.back(t);
      await Bed.back(t);
      expect(page(t).expanded, isFalse, reason: 'Back, then Back again, returns to the list');
      await leave(t);
    }, variant: screen);

    testWidgets('with a mouse the pane behaves as before: nothing takes focus, and its keys work once clicked', (t) async {
      await t.pumpWidget(Bed.app(const _Browser()));
      await Bed.settle(t, rounds: 4);
      expect(Bed.focused(), 'nothing');
      await t.tapAt(t.getCenter(find.byType(BrowserLivePlayer)));
      await t.pump(const Duration(milliseconds: 400));
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump(const Duration(milliseconds: 100));
      expect(page(t).steps, 1, reason: 'clicked, the pane takes Up and Down for channels');
      expect(InputModeTracker.currentMode, InputMode.pointer);
      await t.sendKeyEvent(LogicalKeyboardKey.keyF);
      await Bed.settle(t, rounds: 2);
      expect(page(t).expanded, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await Bed.settle(t, rounds: 2);
      expect(page(t).expanded, isFalse, reason: 'Escape returns to the list, as before');
      await leave(t);
    }, variant: screen);
  });
}
