// The pages photographed for the pointer-mode baseline, shared by the Windows and the Android
// baseline files. Each entry gets the shell on Home and leaves the page to photograph on screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/screens/details/person_page.dart';
import 'package:vyse_tv/screens/shell/shell.dart';

import '../harness.dart';

typedef PageOpener = Future<void> Function(WidgetTester t);

Future<void> _scrollHome(WidgetTester t, double to) async {
  final list = t.state<ScrollableState>(find.descendant(of: find.byType(HomePage), matching: find.byType(Scrollable)).first);
  list.position.jumpTo(to);
  await Bed.settle(t);
}

Future<void> _openProfile(WidgetTester t) async {
  final phone = OnScreens.current.size.width < 640;
  if (phone) {
    final item = find.descendant(of: find.byType(BottomBar), matching: find.text('Profile'));
    await t.scrollUntilVisible(item, 200, scrollable: find.descendant(of: find.byType(BottomBar), matching: find.byType(Scrollable)));
    await t.tap(item);
  } else {
    await t.tap(find.descendant(of: find.byType(SideRail), matching: find.byType(Avatar)));
  }
  await Bed.settle(t);
}

final Map<String, PageOpener> baselinePages = {
  'home': (t) async {},
  'home_rows': (t) => _scrollHome(t, 760),
  'home_lower': (t) => _scrollHome(t, 2400),
  'discover': (t) => Bed.openSection(t, 'discover'),
  'search': (t) => Bed.openSection(t, 'search'),
  'movies': (t) => Bed.openSection(t, 'movies'),
  'tv': (t) => Bed.openSection(t, 'tv'),
  'top': (t) => Bed.openSection(t, 'top'),
  'list': (t) => Bed.openSection(t, 'list'),
  'history': (t) => Bed.openSection(t, 'history'),
  'details_movie': (t) => Bed.push(t, DetailsPage(media: Bed.catalogue[0])),
  'details_tv': (t) => Bed.push(t, DetailsPage(media: Bed.catalogue[81])),
  'person': (t) => Bed.push(t, const PersonPage(id: 500, name: 'Mara Ellison', profilePath: '/f500.jpg')),
  'profile': _openProfile,
  'party': (t) => Bed.openSection(t, 'party'),
  'downloads': (t) => Bed.openSection(t, 'downloads'),
  'anime': (t) => Bed.openSection(t, 'anime'),
  'servers': (t) => Bed.openSection(t, 'servers'),
  'manga': (t) => Bed.openSection(t, 'manga'),
  'music': (t) => Bed.openSection(t, 'music'),
  'audiobooks': (t) => Bed.openSection(t, 'audiobooks'),
  'live': (t) => Bed.openSection(t, 'live'),
};
