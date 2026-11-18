// T4 for the fourth round of TV feedback (2026-11-17), with t4_tv4_start_fresh_test.dart: the
// same slow start (a fresh install, TMDB taking four seconds), and someone pressing the remote
// while Home is still loading. An arrow with nothing in view to go to must not carry the page
// down to the first control that happens to be there already (the genres near its foot); an
// arrow out of the page still leaves it. The bed is told it is a TV.
//
// One test per file: Home's answers are asked for once a run, by the first test that opens it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/screens/shell/shell.dart';

import 'harness.dart';

double _homeOffset(WidgetTester t) {
  final lists = find.descendant(of: find.byType(HomePage), matching: find.byType(Scrollable));
  if (lists.evaluate().isEmpty) return 0;
  return t.state<ScrollableState>(lists.first).position.pixels;
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android, warm: false, returning: false);
    await TvDetectionService.getInstance(forceTv: true);
    Bed.http.delay = (uri) => uri.host == 'api.themoviedb.org' ? const Duration(seconds: 4) : Duration.zero;
  });

  testWidgets('arrows pressed while Home is still loading on a TV keep it at its top; Left still reaches the navbar', (t) async {
    await t.pumpWidget(Bed.app(const AppShell()));
    await Bed.settle(t, rounds: 15, step: const Duration(milliseconds: 100));
    expect(find.byType(HomePage), findsOneWidget);
    expect(_homeOffset(t), lessThan(1));
    // Down and Right: nothing in view yet to go to
    await Bed.down(t);
    await Bed.right(t);
    expect(_homeOffset(t), lessThan(1), reason: 'an arrow did not carry the page down to the genres');
    expect(Bed.focused(), isNot(contains('Explore genres')));
    // Left: out of the page, onto the navbar
    await Bed.left(t);
    expect(Bed.focused(), contains('SideRail'), reason: 'Left leaves a page that is still loading');
    expect(Bed.focusInView(), isTrue);
    expect(_homeOffset(t), lessThan(1));
    // let everything Home asked for come back, then put it all away
    await Bed.settle(t, rounds: 10, step: const Duration(seconds: 2));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  }, variant: OnScreens([Screens.tv]));
}
