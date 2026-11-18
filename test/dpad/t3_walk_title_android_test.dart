// T3 for the path to a title, at a TV's size and on a phone: each page walked with arrows only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/anime/anilist.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/details/person_page.dart';
import 'package:vyse_tv/screens/player/sources_page.dart';

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
  final screen = OnScreens(Screens.android);

  final pages = <String, Widget Function()>{
    'a film\'s page': () => DetailsPage(media: Bed.catalogue[0]),
    'a series\' page': () => DetailsPage(media: Bed.catalogue[81]),
    'a person\'s page': () => const PersonPage(id: 500, name: 'Mara Ellison', profilePath: '/f500.jpg'),
    'the sources of a film': () => SourcesPage(media: Bed.catalogue[0]),
    'an anime\'s page': () => AnimeDetailsPage(anime: Anime.fromMedia(Bed.catalogue[81])),
  };
  for (final page in pages.entries) {
    testWidgets(page.key, (t) async {
      await Bed.pumpShell(t);
      await Bed.push(t, page.value());
      // At 960 wide the sources page's own header row is 19 px too wide (sources_page.dart
      // line 471), with or without a key pressed. A layout matter for the TV-size pass
      // (phase 11), listed in the plan; one such overflow is expected here and no more.
      final sourcesOnTv = page.key.startsWith('the sources') && OnScreens.current == Screens.tv;
      (await _walk(t)).expectClean(knownOverflows: sourcesOnTv ? 1 : 0);
    }, variant: screen);
  }

  testWidgets('Search', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'search');
    (await _walk(t)).expectClean();
  }, variant: screen);
}
