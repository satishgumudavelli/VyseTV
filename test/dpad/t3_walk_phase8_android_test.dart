// T3 for phase 8 at a TV's size and on a phone: every group of Profile and settings walked
// with arrows only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/phase8_pages.dart';
import 'bed/walker.dart';
import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await Bed.withContent();
  });

  for (final page in phase8Pages.entries) {
    testWidgets(page.key, (t) async {
      await page.value(t);
      final report = await Walker(t, settle: () => Bed.settle(t, rounds: 1)).run(maxPresses: 4000);
      debugPrint('${page.key}: walked ${report.places.length} places in ${report.presses} presses, ${report.problems.length} problem(s)');
      final kinds = <String, int>{};
      for (final p in report.places.values) {
        if (p.label.contains('SideRail') || p.label.contains('WindowBar')) continue;
        final k = p.label.replaceAll(RegExp(r"'.*'"), "'…'");
        kinds[k] = (kinds[k] ?? 0) + 1;
      }
      debugPrint('   ${kinds.entries.map((e) => '${e.value} x ${e.key}').join('  |  ')}', wrapWidth: 4000);
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
