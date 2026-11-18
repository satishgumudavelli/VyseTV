// T4 for the update box on a TV (2026-11-17). The box comes up by itself a little after start-up
// when there is a newer version, over whatever page is open; if a remote can't use it, a TV never
// updates. So, on a TV: it takes focus the moment it comes up, on Update, wherever focus was;
// Left and Right reach each of its buttons and nothing outside it; Up and Down scroll long
// release notes; Back is Later; nothing behind it moves or hears a key; it keeps focus as it
// changes (Update gives way to Cancel, then to nothing while the download is checked, then to
// Done); a held OK presses once; and when it closes focus is where it was. The bed is told it is
// a TV, as in phase 11. (Pressing Update for real needs a release to download: what the app does
// after OK on Update is the updater's own, and is set here by hand, stage by stage.)
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/nav.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/updates/updater.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/screens/shell/shell.dart' show AppShell, SideRail;
import 'package:vyse_tv/widgets/dialogs/update_dialog.dart';

import 'harness.dart';

/// Tells the app a newer version exists, as the automatic check does a little after start-up.
/// The box comes up by itself once a run of the app ([byItself], the first test here); after that
/// it is brought up the way Settings' "Check for updates" does: the same box on the same route.
Future<void> _offer(WidgetTester t, {String notes = 'Fixes for the TV.', bool byItself = false}) async {
  addTearDown(_reset);
  Updater.instance
    ..info = UpdateInfo(version: '9.0.0', notes: notes, date: '2026-11-17', files: const {}, page: null)
    ..stage = UpdateStage.available
    ..error = null
    ..shownThisRun = false;
  _tell();
  // a test that fails with the box up closes it, or the next one could not bring it up (there is
  // only ever one box, and one left open on a torn-down page never says it has closed)
  addTearDown(() async {
    if (find.byType(Dialog).evaluate().isEmpty) return;
    rootNavigatorKey.currentState?.pop();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  });
  if (!byItself) unawaited(showUpdateDialog(t.element(find.byType(AppShell))));
  await Bed.settle(t, rounds: 4);
  expect(find.text('VyseTV 9.0.0 is ready'), findsOneWidget, reason: byItself ? 'the box came up by itself' : 'the box came up');
}

/// What the updater does when its state changes.
void _tell() {
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  Updater.instance.notifyListeners();
}

/// Moves the updater on by hand (see the top of this file).
Future<void> _stage(WidgetTester t, UpdateStage stage, {double? progress}) async {
  Updater.instance
    ..stage = stage
    ..progress = progress
    ..received = ((progress ?? 0) * 70e6).round();
  _tell();
  await Bed.settle(t, rounds: 2);
}

void _reset() {
  Updater.instance
    ..stage = UpdateStage.idle
    ..info = null
    ..error = null
    ..progress = null
    ..received = 0
    ..shownThisRun = false;
  AppSettings.updateSkipped.value = '';
}

/// The words on the focused control (the first text inside it), or '' with focus on nothing.
String _label() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context is! Element) return '';
  String? found;
  void down(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is Text) {
      found = w.data ?? w.textSpan?.toPlainText();
      return;
    }
    e.visitChildren(down);
  }

  context.visitChildren(down);
  return found ?? '';
}

FocusNode? get _focus => FocusManager.instance.primaryFocus;

/// Whether focus is in the update box (on one of its buttons, or on the box itself while it has
/// none to offer).
bool _inBox() {
  final context = _focus?.context;
  return context != null && context.mounted && ModalRoute.of(context) is DialogRoute;
}

/// The list that runs down Home.
ScrollPosition _home(WidgetTester t) => t
    .state<ScrollableState>(find.descendant(of: find.byType(HomePage), matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)).first)
    .position;

/// Holds [key] for [held], the way a remote sends it (one press, then repeats), and lets go.
Future<void> _hold(WidgetTester t, LogicalKeyboardKey key, Duration held) async {
  await t.sendKeyDownEvent(key, platform: 'android');
  var gone = Duration.zero;
  await t.pump(const Duration(milliseconds: 400));
  gone += const Duration(milliseconds: 400);
  while (gone < held) {
    await t.sendKeyRepeatEvent(key, platform: 'android');
    await t.pump(const Duration(milliseconds: 50));
    gone += const Duration(milliseconds: 50);
  }
  await t.sendKeyUpEvent(key, platform: 'android');
  await Bed.settle(t, rounds: 3);
}

/// The app from its start: the box comes up by itself once a run, so each test starts one.
Future<void> _start(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await Bed.pumpShell(t);
}

/// Home with focus some way down it, on a card: where a viewer is when the box comes up.
Future<(FocusNode, double)> _onHome(WidgetTester t) async {
  await _start(t);
  await Bed.down(t, times: 3);
  final card = _focus!;
  final page = _home(t).pixels;
  expect(page, greaterThan(0), reason: '(the page has scrolled, so "it did not move" means something)');
  return (card, page);
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);

  testWidgets('the box takes focus the moment it comes up, on Update, with the ring; the page behind did not move', (t) async {
    expect(PlatformDetector.isTV(), isTrue);
    final (card, page) = await _onHome(t);
    await _offer(t, byItself: true);
    expect(_inBox(), isTrue, reason: 'focus left the page for the box');
    expect(_label(), 'Update', reason: 'on Update (the first button on the left is "Skip this version": OK there would have skipped the release)');
    expect(DpadRoot.debugRinged, same(_focus), reason: 'the ring is on Update');
    expect(card.hasFocus, isFalse);
    expect(_home(t).pixels, page);
    await Bed.picture(t, 'tv3/update_box');
    await Bed.back(t);
    expect(find.text('VyseTV 9.0.0 is ready'), findsNothing, reason: 'Back closed it (Later)');
  }, variant: tv);

  testWidgets('Left and Right reach every button and never leave the box; Up, Down and held arrows go nowhere; nothing behind moves', (t) async {
    final (_, page) = await _onHome(t);
    await _offer(t);
    await Bed.left(t);
    expect(_label(), 'Later');
    await Bed.left(t);
    expect(_label(), 'Skip this version');
    await Bed.left(t);
    expect(_label(), 'Skip this version', reason: 'Left at the first button stays in the box (it does not reach the navbar behind it)');
    await Bed.right(t, times: 2);
    expect(_label(), 'Update');
    await Bed.right(t);
    expect(_label(), 'Update');
    for (final key in [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown]) {
      await Bed.press(t, key, times: 3);
      expect(_label(), 'Update', reason: '$key has nowhere to go in the box');
    }
    for (final key in [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowUp]) {
      await _hold(t, key, const Duration(seconds: 2));
      expect(_inBox(), isTrue, reason: 'a held $key stays in the box');
    }
    expect(find.text('VyseTV 9.0.0 is ready'), findsOneWidget);
    expect(_home(t).pixels, page, reason: 'no key reached the page behind the box');
    await Bed.back(t);
  }, variant: tv);

  testWidgets('Back is Later: the box closes, focus is back on the card it was on, the page where it was', (t) async {
    final (card, page) = await _onHome(t);
    await _offer(t);
    await Bed.back(t);
    expect(find.text('VyseTV 9.0.0 is ready'), findsNothing);
    expect(identical(_focus, card), isTrue, reason: 'focus is back where it was: ${Bed.focused()}');
    expect(_home(t).pixels, closeTo(page, 1));
    expect(Updater.instance.shownThisRun, isTrue, reason: 'it does not come up again by itself until the next start');
    expect(AppSettings.updateSkipped.value, '', reason: 'Later is not Skip');
  }, variant: tv);

  testWidgets('OK on Later closes it the same way; OK on "Skip this version" skips that version', (t) async {
    final (card, page) = await _onHome(t);
    await _offer(t);
    await Bed.left(t);
    await Bed.ok(t);
    expect(find.text('VyseTV 9.0.0 is ready'), findsNothing);
    expect(identical(_focus, card), isTrue);
    expect(AppSettings.updateSkipped.value, '');
    // again, as from Settings, and skipped this time
    await _offer(t);
    await Bed.left(t, times: 2);
    expect(_label(), 'Skip this version');
    await Bed.ok(t);
    expect(find.text('VyseTV 9.0.0 is ready'), findsNothing);
    expect(AppSettings.updateSkipped.value, '9.0.0');
    expect(identical(_focus, card), isTrue);
    expect(_home(t).pixels, closeTo(page, 1));
  }, variant: tv);

  testWidgets('the box takes focus from the navbar too, and gives it back there', (t) async {
    await _start(t);
    await Bed.left(t);
    final entry = _focus!;
    expect(find.ancestor(of: find.byWidgetPredicate((w) => w is Focus && identical(w.focusNode, entry)), matching: find.byType(SideRail)), findsOneWidget,
        reason: '(focus is on the navbar)');
    await _offer(t);
    expect(_label(), 'Update');
    await Bed.back(t);
    expect(identical(_focus, entry), isTrue);
  }, variant: tv);

  testWidgets('long release notes: Up and Down scroll them, focus stays on Update, and a scrollbar shows there is more', (t) async {
    final (_, page) = await _onHome(t);
    await _offer(t, notes: [for (var i = 1; i <= 40; i++) 'Line $i of what changed in this release.'].join('\n'));
    final notes = t.state<ScrollableState>(find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first).position;
    expect(notes.maxScrollExtent, greaterThan(0), reason: '(more notes than fit)');
    expect(find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollbar)), findsOneWidget);
    await Bed.down(t);
    expect(notes.pixels, greaterThan(0), reason: 'Down scrolled the notes');
    expect(_label(), 'Update');
    await Bed.down(t, times: 30);
    expect(notes.pixels, notes.maxScrollExtent, reason: 'to their end');
    expect(_label(), 'Update');
    await Bed.up(t, times: 30);
    expect(notes.pixels, 0, reason: 'and back to their start');
    expect(_label(), 'Update');
    expect(_home(t).pixels, page);
    await Bed.back(t);
  }, variant: tv);

  testWidgets('OK on Update: when it can\'t go through the box says so with focus on Try again; a held OK pressed Update once', (t) async {
    final (card, _) = await _onHome(t);
    await _offer(t);
    var told = 0;
    void count() => told++;
    Updater.instance.addListener(count);
    addTearDown(() => Updater.instance.removeListener(count));
    // (the bed has no release to download, so Update fails at once: "no download for this device")
    await _hold(t, LogicalKeyboardKey.select, const Duration(milliseconds: 1500));
    expect(find.text("The update didn't go through"), findsOneWidget);
    expect(_label(), 'Try again', reason: 'focus moved to the button that moves things on');
    expect(told, 1, reason: 'the press acted once: its repeats did not press Try again, which focus landed on');
    await Bed.left(t);
    expect(_label(), 'Close');
    await Bed.ok(t);
    expect(find.text("The update didn't go through"), findsNothing);
    expect(identical(_focus, card), isTrue);
  }, variant: tv);

  testWidgets('the box keeps focus as it changes: Cancel while downloading, nothing to press while checking (no key gets out, Back waits), then Done', (t) async {
    final (card, page) = await _onHome(t);
    await _offer(t);
    await _stage(t, UpdateStage.downloading, progress: .1);
    expect(find.text('Downloading VyseTV 9.0.0'), findsOneWidget);
    expect(_label(), 'Cancel', reason: 'Update gave way to Cancel, and focus with it');
    expect(DpadRoot.debugRinged, same(_focus));
    for (var p = .2; p < .9; p += .1) {
      Updater.instance
        ..progress = p
        ..received = (p * 70e6).round();
      _tell();
      await t.pump(const Duration(milliseconds: 150));
    }
    await Bed.settle(t, rounds: 1);
    expect(_label(), 'Cancel', reason: 'the progress redraws the box; focus stays put');
    await _stage(t, UpdateStage.verifying, progress: 1);
    expect(find.text('Checking the download'), findsOneWidget);
    expect(_inBox(), isTrue, reason: 'with no button to offer, the box still holds focus (the page behind does not get it)');
    for (final key in [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.select]) {
      await Bed.press(t, key);
      expect(_inBox(), isTrue, reason: '$key reached nothing behind the box');
    }
    await Bed.back(t);
    expect(find.text('Checking the download'), findsOneWidget, reason: 'Back does not close the box while the download is checked');
    expect(_home(t).pixels, page);
    await _stage(t, UpdateStage.handedOver);
    await Bed.settle(t, rounds: 2);
    expect(find.text('Almost there'), findsOneWidget);
    expect(_label(), 'Done');
    await Bed.ok(t);
    expect(find.text('Almost there'), findsNothing);
    expect(identical(_focus, card), isTrue, reason: 'focus is back where it was before the box came up');
    expect(_home(t).pixels, closeTo(page, 1));
  }, variant: tv);

  testWidgets('Cancel: the download stops and the box is back to its offer, with focus on Update (not on the button that took Cancel\'s place)', (t) async {
    await _onHome(t);
    await _offer(t);
    await _stage(t, UpdateStage.downloading, progress: .4);
    expect(_label(), 'Cancel');
    // what Cancel ends in (the updater stops the download and offers the release again)
    await _stage(t, UpdateStage.available);
    expect(find.text('VyseTV 9.0.0 is ready'), findsOneWidget);
    expect(_label(), 'Update');
    await Bed.back(t);
  }, variant: tv);
}
