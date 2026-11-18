// T3 for phase 9 at a TV's size and on a phone: Party and the pages and boxes that open from
// it, walked with arrows only. What Party's server would have sent is put in by hand.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/layout.dart';

import 'bed/phase9_pages.dart';
import 'bed/walker.dart';
import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.android));

  for (final page in phase9Pages.entries) {
    testWidgets(page.key, (t) async {
      addTearDown(signOut);
      await page.value(t);
      await Bed.dpadMode(t);
      await Bed.settle(t, rounds: 2);
      // a box has no navbar to reach; nor has a conversation or a room on a phone, which
      // take the whole screen (the bottom bar is hidden while they are open)
      final box = FocusManager.instance.primaryFocus?.nearestScope?.debugLabel?.contains('Modal') ?? false;
      final whole = hideBottomBar.value > 0 && OnScreens.current.size.width < 640;
      final report = await Walker(t, settle: () => Bed.settle(t, rounds: 1), isNavbar: box || whole ? (_) => true : null).run(maxPresses: 3000);
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
