// T4 for the third round of TV feedback (2026-11-17): Home's "If you like" title picker opened on
// OK, but its menu never had the remote's arrows. Focus stayed on the title, Down went on down
// the page, the page scrolled, and a menu closes when its page scrolls: "it just scrolls back in
// the home screen". My List's sort menu was the same. Menus that open in place (MenuAnchor) now
// take focus as they open, on the choice in use; keep the arrows; let the page behind them be;
// and give focus back to what opened them when they close. Also here: a held OK presses once,
// on what it went down on. The bed is told it is a TV, as in phase 11.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/screens/library/my_list_page.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'harness.dart';

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

/// The list that runs down [page].
ScrollPosition _list(WidgetTester t, Type page) => t
    .state<ScrollableState>(find.descendant(of: find.byType(page), matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)).first)
    .position;

/// The button a menu hangs from (the "If you like" title, My List's sort).
Finder get _button => find.descendant(of: find.byType(MenuAnchor), matching: find.byType(Pressable)).first;

FocusNode? get _focus => FocusManager.instance.primaryFocus;
bool _inMenu() => _focus != null && Dpad.menuOf(_focus!) != null;
bool _menuShown() => find.byType(MenuItemButton).evaluate().isNotEmpty;

/// Whether focus is on the menu's choice in use (the item marked as where it starts).
bool _onChoiceInUse() => _focus?.context?.findAncestorWidgetOfExactType<DpadStart>()?.start ?? false;

/// The title the "If you like" row is built on (the words on its button).
String _seed(WidgetTester t) => t.widget<Text>(find.descendant(of: _button, matching: find.byType(Text)).first).data!;

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

/// Home, with focus brought down the page to the "If you like" title the way a remote does.
Future<void> _toPicker(WidgetTester t) async {
  await Bed.pumpShell(t);
  await Bed.down(t, times: 2);
  await Bed.focus(t, _button);
  expect(identical(_focus, Bed.nodeOf(t, _button)), isTrue);
  expect(Bed.focusInView(), isTrue);
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);

  testWidgets('Home\'s "If you like" title: OK opens its menu with focus in it, on the title in use', (t) async {
    expect(PlatformDetector.isTV(), isTrue);
    await _toPicker(t);
    final page = _list(t, HomePage).pixels;
    final seed = _seed(t);
    await Bed.ok(t);
    expect(_menuShown(), isTrue, reason: 'OK opens the menu');
    expect(_inMenu(), isTrue, reason: 'focus goes into the menu as it opens (it stayed on the title, and Down went on down the page)');
    expect(_onChoiceInUse(), isTrue, reason: 'on the title the row is built on');
    expect(_label(), seed);
    expect(DpadRoot.debugRinged, same(_focus), reason: 'the ring is on it');
    expect(_list(t, HomePage).pixels, page, reason: 'the page behind the menu did not move');
    await Bed.back(t);
  }, variant: tv);

  testWidgets('in the menu, Down goes down the titles and the page behind stays where it is; the menu stays open', (t) async {
    await _toPicker(t);
    final page = _list(t, HomePage).pixels;
    await Bed.ok(t);
    final seen = <String>[_label()];
    for (var i = 0; i < 10; i++) {
      await Bed.down(t);
      expect(_menuShown(), isTrue, reason: 'the menu stays open (it closed as soon as the page scrolled)');
      expect(_inMenu(), isTrue, reason: 'Down ${i + 1} kept focus in the menu');
      expect(Bed.focusInView(), isTrue, reason: 'the menu scrolls itself to show title ${i + 2}');
      seen.add(_label());
    }
    expect(seen.toSet().length, greaterThan(8), reason: 'each Down is the next title: $seen');
    expect(_list(t, HomePage).pixels, page, reason: 'the page behind the menu never moved');
    // the edges: Left, Right, and Up past the first title do not leave the menu
    for (final key in [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight]) {
      await Bed.press(t, key);
      expect(_inMenu(), isTrue, reason: '$key stays in the menu');
    }
    await Bed.up(t, times: 14);
    expect(_inMenu(), isTrue, reason: 'Up past the first title stays in the menu');
    expect(_label(), seen.first);
    expect(_list(t, HomePage).pixels, page);
    await Bed.back(t);
  }, variant: tv);

  testWidgets('OK on another title changes the row to it, closes the menu and leaves focus on the title, where it was', (t) async {
    await _toPicker(t);
    final page = _list(t, HomePage).pixels;
    final was = _seed(t);
    await Bed.ok(t);
    await Bed.down(t, times: 3);
    final pick = _label();
    expect(pick, isNot(was));
    await Bed.ok(t);
    expect(_menuShown(), isFalse, reason: 'the menu closed');
    expect(_seed(t), pick, reason: 'the row is now "If you like $pick"');
    expect(identical(_focus, Bed.nodeOf(t, _button)), isTrue, reason: 'focus is back on the title (the row was rebuilt for the new title: on its new button)');
    expect(_list(t, HomePage).pixels, closeTo(page, 1), reason: 'the page is where it was');
    // and the menu opens on the new choice
    await Bed.ok(t);
    expect(_inMenu(), isTrue);
    expect(_label(), pick);
    expect(_onChoiceInUse(), isTrue);
    await Bed.back(t);
  }, variant: tv);

  testWidgets('Back closes the menu without changing anything, and focus is back on the title', (t) async {
    await _toPicker(t);
    final page = _list(t, HomePage).pixels;
    final was = _seed(t);
    await Bed.ok(t);
    await Bed.down(t, times: 4);
    await Bed.back(t);
    expect(_menuShown(), isFalse);
    expect(_seed(t), was, reason: 'nothing was chosen');
    expect(identical(_focus, Bed.nodeOf(t, _button)), isTrue, reason: 'focus is back on the title');
    expect(_list(t, HomePage).pixels, closeTo(page, 1));
    // a second Back is the page's own again (not the menu's)
    expect(find.byType(HomePage), findsOneWidget);
  }, variant: tv);

  testWidgets('holding OK on the title opens the menu once: the held press does not choose a title in it', (t) async {
    await _toPicker(t);
    final was = _seed(t);
    await _hold(t, LogicalKeyboardKey.select, const Duration(milliseconds: 1500));
    expect(_menuShown(), isTrue, reason: "the press's repeats did not press the title focus landed on in the menu (which would choose it and close the menu)");
    expect(_inMenu(), isTrue);
    expect(_seed(t), was);
    await Bed.back(t);
    expect(_menuShown(), isFalse);
  }, variant: tv);

  testWidgets('My List\'s sort menu: OK opens it on the order in use, arrows stay in it, OK on another order sorts, focus back on the button', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'list');
    await Bed.focus(t, _button);
    final page = _list(t, MyListPage).pixels;
    final order = _label();
    await Bed.ok(t);
    expect(_menuShown(), isTrue);
    expect(_inMenu(), isTrue, reason: 'focus goes into the menu as it opens');
    expect(_onChoiceInUse(), isTrue, reason: 'on the order in use');
    expect(_label(), order);
    await Bed.press(t, LogicalKeyboardKey.arrowLeft);
    expect(_inMenu(), isTrue, reason: 'Left does not leave the menu for the navbar');
    await Bed.down(t);
    final other = _label();
    expect(other, isNot(order));
    await Bed.ok(t);
    expect(_menuShown(), isFalse);
    expect(identical(_focus, Bed.nodeOf(t, _button)), isTrue, reason: 'focus is back on the sort button');
    expect(_label(), other, reason: 'the list is sorted by "$other" now');
    expect(_list(t, MyListPage).pixels, closeTo(page, 1));
  }, variant: tv);
}
