// T4 for the fourth round of TV feedback (2026-11-17): "for some TVs it's still starting and auto
// scrolling to the bottom". A TV that has just been switched on, a fresh install (nothing in
// progress, so no Continue watching row), and TMDB slow to answer: every answer takes four
// seconds, which a weak TV box on a slow network easily takes. Home shows its placeholders
// meanwhile, and its only control that is there at once is the Discord link in its footer, at
// the foot of the page. The bed is told it is a TV, as in phase 11.
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

  testWidgets('a TV starting on a slow network stays at the top of Home, and the ring lands on Play when the hero comes', (t) async {
    await t.pumpWidget(Bed.app(const AppShell()));
    var furthest = 0.0;
    final seen = <String>[];
    // seven seconds, a tenth of a second at a time, with no key pressed
    for (var i = 0; i < 70; i++) {
      await Bed.settle(t, rounds: 1, step: const Duration(milliseconds: 100));
      final at = _homeOffset(t);
      if (at > furthest) furthest = at;
      final now = Bed.focused();
      if (seen.isEmpty || seen.last != now) seen.add('${(i + 1) * 100} ms: $now (Home scrolled to ${at.round()})');
    }
    debugPrint('focus as Home loaded:\n  ${seen.join('\n  ')}');
    expect(furthest, lessThan(1), reason: 'Home never moved off its top while it loaded (it went as far as ${furthest.round()})');
    expect(Bed.focused(), contains("'Play'"), reason: 'the ring is on the hero’s Play once the hero is there');
    expect(Bed.focusInView(), isTrue);
    expect(_homeOffset(t), lessThan(1));
    // the hero's logos were asked for when it came, and take as long: let them come back
    await Bed.settle(t, rounds: 10, step: const Duration(seconds: 2));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  }, variant: OnScreens([Screens.tv]));
}
