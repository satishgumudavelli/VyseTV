// T3 for phase 6 at a TV's size and on a phone: Anime, Live TV (every tab), Downloads and
// Servers, with their boxes and sub-pages, each walked with arrows only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/phase6_pages.dart';
import 'bed/walker.dart';
import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await Bed.withContent();
  });

  for (final page in phase6Pages.entries) {
    testWidgets(page.key, (t) async {
      await page.value(t);
      final box = FocusManager.instance.primaryFocus?.nearestScope?.debugLabel?.contains('Modal') ?? false;
      final report = await Walker(t, settle: () => Bed.settle(t, rounds: 1), isNavbar: box ? (_) => true : null).run(maxPresses: 3000);
      debugPrint('${page.key}: walked ${report.places.length} places in ${report.presses} presses, ${report.problems.length} problem(s)');
      for (final p in report.problems) {
        debugPrint('PROBLEM $p', wrapWidth: 2000);
      }
      for (final o in report.overflows) {
        debugPrint('OVERFLOW $o', wrapWidth: 600);
      }
      report.expectClean();
    }, variant: OnScreens(Screens.android));
  }
}
