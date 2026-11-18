// T3 for phase 7 at a TV's size and on a phone: Music (the plain page: its own frame is for
// wide windows), Manga and Audiobooks, with their players and the reader, walked with arrows only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/phase7_pages.dart';
import 'bed/walker.dart';
import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await Bed.withContent();
  });

  for (final page in phase7Pages.entries) {
    testWidgets(page.key, (t) async {
      if (cannotBeBuiltHere(page.key)) return;
      await page.value(t);
      await Bed.dpadMode(t);
      await Bed.settle(t, rounds: 2);
      // the reader opens for reading (arrows turn pages): holding OK brings its bar up to walk
      if (page.key.contains('reader')) await readerBar(t);
      // a page over the whole app (a player, the reader) has no navbar to reach
      final over = page.key.contains('player') || page.key.contains('reader');
      final report = await Walker(t, settle: () => Bed.settle(t, rounds: 1), isNavbar: over ? (_) => true : null).run(maxPresses: 3000);
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
      await quiet(t);
      report.expectClean();
    }, variant: OnScreens(Screens.android));
  }
}
