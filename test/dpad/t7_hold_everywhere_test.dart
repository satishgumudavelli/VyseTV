// T7 everywhere (phase 10): on every section, each arrow held down at a keyboard's pace,
// checking after every repeat that focus is on a control (R1) and nothing threw, and at the
// end of each hold that the control is in view (R4). Then Back pressed ten times fast, which
// must end at rest on Home (R5: one thing per press).
//
// It also times every held step: the key, and the frame after it, as the bed draws it. The bed
// is a debug build drawing without a screen, so the numbers are for comparing pages with each
// other and runs with each other, not frame times on a real machine (see the plan's
// by-hand list for those).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';
import 'package:vyse_tv/screens/home/home_page.dart';

import 'bed/phase9_pages.dart' show signIn, signOut;
import 'harness.dart';

const _sections = ['home', 'discover', 'search', 'movies', 'tv', 'top', 'list', 'history', 'anime', 'live', 'downloads', 'servers', 'manga', 'music', 'audiobooks', 'party'];

/// Every held step's time, in milliseconds, by section.
final _times = <String, List<double>>{};

Future<void> _hold(WidgetTester t, String section, LogicalKeyboardKey key, int repeats) async {
  final times = _times.putIfAbsent(section, () => []);
  void look(String when) {
    final node = FocusManager.instance.primaryFocus;
    expect(node != null && Dpad.isStop(node), isTrue, reason: '$section: focus on nothing $when (on ${node?.debugLabel})');
    expect(t.takeException(), isNull, reason: '$section: threw $when');
  }

  await t.sendKeyDownEvent(key);
  await t.pump(const Duration(milliseconds: 33));
  look('after pressing ${key.debugName}');
  final clock = Stopwatch();
  for (var i = 0; i < repeats; i++) {
    clock
      ..reset()
      ..start();
    await t.sendKeyRepeatEvent(key);
    await t.pump(const Duration(milliseconds: 33));
    clock.stop();
    times.add(clock.elapsedMicroseconds / 1000);
    look('at repeat $i of ${key.debugName}');
  }
  await t.sendKeyUpEvent(key);
  await Bed.settle(t, rounds: 4);
  look('after letting ${key.debugName} go');
  expect(Bed.focusInView(), isTrue, reason: '$section: held ${key.debugName}, it ended on ${Bed.focused()}, not fully in view');
}

String _summary(List<double> times) {
  final sorted = [...times]..sort();
  double at(double q) => sorted[((sorted.length - 1) * q).round()];
  return '${sorted.length} steps: median ${at(.5).toStringAsFixed(1)} ms, p95 ${at(.95).toStringAsFixed(1)} ms, max ${sorted.last.toStringAsFixed(1)} ms';
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.windows);
    await Bed.withContent();
  });
  tearDownAll(() {
    for (final e in _times.entries) {
      debugPrint('T7 held steps on ${e.key}: ${_summary(e.value)}');
    }
    debugPrint('T7 held steps everywhere: ${_summary([for (final v in _times.values) ...v])}');
  });

  for (final section in _sections) {
    testWidgets('$section: every arrow held, then Back pressed ten times fast', (t) async {
      if (section == 'party') {
        signIn();
        addTearDown(signOut);
      }
      await Bed.pumpShell(t);
      if (section != 'home') await Bed.openSection(t, section);
      await Bed.settle(t, rounds: 4);
      await Bed.dpadMode(t);
      await Bed.down(t);
      // along, off the left into the navbar, back, then down the page and up again (on Home
      // Up ends in the spotlight, which is where Up from the top goes)
      await _hold(t, section, LogicalKeyboardKey.arrowRight, 40);
      // (long enough to come back along the longest row there is, Manga's tags, and off its end)
      await _hold(t, section, LogicalKeyboardKey.arrowLeft, 100);
      expect(Bed.focused(), anyOf(contains('SideRail'), contains('_RailItem'), contains('_RailProfile')), reason: '$section: Left held ends on the navbar');
      await Bed.right(t);
      expect(Bed.focused(), isNot(contains('SideRail')), reason: '$section: Right from the navbar is back on the page');
      await _hold(t, section, LogicalKeyboardKey.arrowDown, 120);
      await _hold(t, section, LogicalKeyboardKey.arrowUp, 120);
      for (var i = 0; i < 10; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump(const Duration(milliseconds: 50));
        expect(t.takeException(), isNull, reason: '$section: Back threw');
      }
      await Bed.settle(t, rounds: 5);
      expect(find.byType(HomePage), findsOneWidget, reason: '$section: ten fast Backs end on Home');
      expect(Bed.focused(), contains("_RailItem in SideRail 'Home'"), reason: '$section: with the ring on Home in the navbar');
      await t.pumpWidget(const SizedBox());
      await Bed.settle(t, rounds: 2);
    }, variant: OnScreens([Screens.laptop]));
  }
}
