// T3 for the path to a title, on a Windows size: each page walked with arrows only.
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
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screen = OnScreens([Screens.laptop]);

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
      (await _walk(t)).expectClean();
    }, variant: screen);
  }

  testWidgets('Search', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'search');
    (await _walk(t)).expectClean();
  }, variant: screen);
}
