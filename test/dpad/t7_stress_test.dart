// T7: holding keys down. An arrow held for 200 repeats moves steadily, never leaves focus on
// nothing, never ends out of view, and never throws (R1, R9). Back pressed fast does one thing
// per press (R5).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/home/home_page.dart';

import 'bed/walker.dart';
import 'harness.dart';

/// Holds [key] down for [repeats] repeats at a keyboard's pace (about 30 a second), checking
/// after every one that focus is on a control. Returns how many different controls it visited.
Future<int> _hold(WidgetTester t, LogicalKeyboardKey key, {int repeats = 200}) async {
  final seen = <String>{};
  void look(String when) {
    final node = FocusManager.instance.primaryFocus;
    expect(node != null && Dpad.isStop(node), isTrue, reason: 'focus on nothing $when (on ${node?.debugLabel})');
    expect(t.takeException(), isNull, reason: 'threw $when');
    // by what it is and where it sits (posters carry no words to tell them apart by)
    seen.add(describeStop(node!).$1);
  }

  await t.sendKeyDownEvent(key);
  await t.pump(const Duration(milliseconds: 33));
  look('after the press');
  for (var i = 0; i < repeats; i++) {
    await t.sendKeyRepeatEvent(key);
    await t.pump(const Duration(milliseconds: 33));
    look('at repeat $i of ${key.keyLabel}');
  }
  await t.sendKeyUpEvent(key);
  await Bed.settle(t, rounds: 4);
  look('after the release');
  expect(Bed.focusInView(), isTrue, reason: 'held ${key.keyLabel}: ended on ${Bed.focused()}, which is not fully in view');
  return seen.length;
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screen = OnScreens([Screens.laptop]);

  testWidgets('Home: each arrow held for 200 repeats', (t) async {
    await Bed.pumpShell(t);
    await Bed.down(t);
    final down = await _hold(t, LogicalKeyboardKey.arrowDown);
    expect(down, greaterThan(10), reason: 'it travelled down the page');
    expect(Bed.focused(), contains('Discord'), reason: 'and stopped at the bottom, not somewhere odd');
    await Bed.up(t, times: 2);
    expect(Bed.focused(), contains('All-time greats'));
    final right = await _hold(t, LogicalKeyboardKey.arrowRight);
    expect(right, greaterThan(10), reason: 'it travelled along the row');
    final row = RegExp(r'under "([^"]+)"').firstMatch(Bed.focused())?.group(1);
    final left = await _hold(t, LogicalKeyboardKey.arrowLeft);
    expect(left, greaterThan(10));
    expect(Bed.focused(), contains('SideRail'), reason: 'all the way left ends on the navbar');
    await Bed.right(t);
    expect(Bed.focused(), contains('under "$row"'), reason: 'and Right from there is back in the row');
    await _hold(t, LogicalKeyboardKey.arrowUp);
    expect(find.byType(HomePage), findsOneWidget);
  }, variant: screen);

  testWidgets('a held arrow moves at a steady pace, not at the keyboard\'s', (t) async {
    await Bed.pumpShell(t);
    await Bed.down(t, times: 3);
    final before = Bed.focused();
    // thirty repeats in one second: about twelve steps, not thirty
    await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    final seen = <String>{before};
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 33));
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      seen.add(Bed.focused());
    }
    await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await Bed.settle(t, rounds: 3);
    expect(seen.length, inInclusiveRange(10, 15), reason: 'steps taken in a second of holding Right');
  }, variant: screen);

  testWidgets('Discover: Down and Up held for 200 repeats, through pages loading', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'discover');
    await Bed.down(t, times: 2);
    final down = await _hold(t, LogicalKeyboardKey.arrowDown);
    expect(down, greaterThan(6));
    expect(Bed.focused(), contains('_DiscoverCard'));
    await _hold(t, LogicalKeyboardKey.arrowUp);
  }, variant: screen);

  testWidgets('Back pressed ten times fast does one thing per press and ends at rest', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'discover');
    await Bed.down(t, times: 3);
    await Bed.ok(t);
    expect(find.byType(DetailsPage), findsOneWidget);
    for (var i = 0; i < 10; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump(const Duration(milliseconds: 50));
      expect(t.takeException(), isNull);
    }
    await Bed.settle(t, rounds: 5);
    // page, navbar, Home: three presses did something, the other seven nothing
    expect(find.byType(DetailsPage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
    expect(Bed.focused(), contains("_RailItem in SideRail 'Home'"));
  }, variant: screen);
}
