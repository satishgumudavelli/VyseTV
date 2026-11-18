// T3 at a TV's size and on a phone (booted as Android): every phase 3 page walked with arrows only (see bed/walker.dart).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/walker.dart';
import 'harness.dart';

Future<WalkReport> _walk(WidgetTester t, {bool Function(String label)? ignore, int maxPresses = 3000}) async {
  final report = await Walker(t, settle: () => Bed.settle(t, rounds: 1), ignore: ignore).run(maxPresses: maxPresses);
  debugPrint('walked ${report.places.length} places in ${report.presses} presses, ${report.problems.length} problem(s)');
  for (final p in report.problems) {
    debugPrint('PROBLEM $p', wrapWidth: 2000);
  }
  return report;
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.android));

  testWidgets('Home', (t) async {
    await Bed.pumpShell(t);
    (await _walk(t)).expectClean();
  }, variant: OnScreens(Screens.android));

  for (final section in const ['discover', 'movies', 'tv', 'top', 'list', 'history']) {
    testWidgets('section: $section', (t) async {
      await Bed.pumpShell(t);
      await Bed.openSection(t, section);
      (await _walk(t)).expectClean();
    }, variant: OnScreens(Screens.android));
  }
}
