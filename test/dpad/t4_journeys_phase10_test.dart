// T4 for phase 10: the two sweeps of the hardening phase. A row of tabs on a title's page is
// entered on the tab that is showing (as every other row of tabs is), and every place with a
// Back of its own takes a remote's Back and a controller's B as it takes Escape.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/anime/anilist.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/details/person_page.dart';
import 'package:vyse_tv/screens/search/search_page.dart';

import 'harness.dart';

/// A Back key as the device it comes from sends it (the simulator needs that platform's codes).
Future<void> _back(WidgetTester t, LogicalKeyboardKey key, {int repeats = 0}) async {
  final (physical, platform) = switch (key) {
    LogicalKeyboardKey.goBack => (PhysicalKeyboardKey.escape, 'android'), // a remote's Back
    LogicalKeyboardKey.gameButtonB => (PhysicalKeyboardKey.gameButtonB, 'android'),
    LogicalKeyboardKey.browserBack => (PhysicalKeyboardKey.browserBack, 'windows'),
    _ => (PhysicalKeyboardKey.escape, 'windows'),
  };
  await t.sendKeyDownEvent(key, physicalKey: physical, platform: platform);
  for (var i = 0; i < repeats; i++) {
    await t.pump(const Duration(milliseconds: 33));
    await t.sendKeyRepeatEvent(key, physicalKey: physical, platform: platform);
  }
  await t.sendKeyUpEvent(key, physicalKey: physical, platform: platform);
  await Bed.settle(t, rounds: 4);
}

bool _typing() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
Finder _tabs() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SectionTab');
String _tabLabel(WidgetTester t, int i) => (t.widget(_tabs().at(i)) as dynamic).label as String;

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.windows);
    await Bed.withContent(); // (an anime's page needs AniList's answers)
  });
  final screen = OnScreens([Screens.laptop]);

  final titles = <String, Widget Function()>{
    'a series’ page': () => DetailsPage(media: Bed.catalogue[81]),
    'an anime’s page': () => AnimeDetailsPage(anime: Anime.fromMedia(Bed.catalogue[81])),
  };
  for (final page in titles.entries) {
    testWidgets('${page.key}: Up from what a tab shows lands on that tab, wherever focus passed along the tabs', (t) async {
      await Bed.pumpShell(t);
      await Bed.push(t, page.value());
      await Bed.dpadMode(t);
      final start = Bed.focused();
      expect(_tabs().evaluate().length, greaterThanOrEqualTo(3), reason: 'a page with tabs');
      // down to the tabs, then OK on the second
      for (var i = 0; i < 12 && !Bed.focused().contains('_SectionTab'); i++) {
        await Bed.down(t);
      }
      expect(Bed.focused(), contains('_SectionTab'));
      final second = _tabLabel(t, 1);
      await Bed.focus(t, _tabs().at(1));
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      // along to the third without OK, then down into what the second shows
      await Bed.right(t);
      expect(Bed.focused(), contains(_tabLabel(t, 2)));
      await Bed.down(t);
      expect(Bed.focused(), isNot(contains('_SectionTab')), reason: 'Down goes into what the tab shows');
      await Bed.up(t);
      expect(Bed.focused(), allOf(contains('_SectionTab'), contains(second)), reason: 'back up on the tab that is showing ($second), not the one passed over');
      // and the page still starts where it did
      await Bed.back(t);
      await Bed.push(t, page.value());
      await Bed.dpadMode(t);
      expect(Bed.focused(), start, reason: 'a mark on a tab is not where the page starts');
    }, variant: screen);
  }

  testWidgets('a search box: a remote’s Back and a controller’s B do what Escape does; held, Back is one press', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'search');
    await Bed.dpadMode(t);
    final box = find.descendant(of: find.byType(SearchPage), matching: find.byType(EditableText)).first;
    String text() => t.widget<EditableText>(box).controller.text;
    for (final key in [LogicalKeyboardKey.goBack, LogicalKeyboardKey.gameButtonB, LogicalKeyboardKey.browserBack, LogicalKeyboardKey.escape]) {
      t.widget<EditableText>(box).focusNode.requestFocus();
      await Bed.settle(t, rounds: 2);
      t.testTextInput.enterText('kite');
      await Bed.settle(t, rounds: 2);
      expect(_typing(), isTrue);
      // held for a second: still one press, so the text goes and the caret stays
      await _back(t, key, repeats: 30);
      expect(text(), isEmpty, reason: '${key.debugName}: the first Back clears the text');
      expect(_typing(), isTrue, reason: '${key.debugName}: held, it did nothing more');
      await _back(t, key);
      expect(_typing(), isFalse, reason: '${key.debugName}: the next Back leaves the box');
      expect(find.byType(SearchPage), findsOneWidget, reason: 'and the page stays');
      expect(Bed.focused(), isNot('nothing'));
    }
  }, variant: screen);

  testWidgets('a person’s photos: a remote’s Back closes the photo viewer, onto the photo it opened from', (t) async {
    await Bed.pumpShell(t);
    await Bed.push(t, const PersonPage(id: 500, name: 'Mara Ellison', profilePath: '/f500.jpg'));
    await Bed.dpadMode(t);
    final photos = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_PhotoTile');
    expect(photos, findsWidgets);
    for (final key in [LogicalKeyboardKey.goBack, LogicalKeyboardKey.gameButtonB]) {
      await Bed.focus(t, photos.at(1));
      final from = FocusManager.instance.primaryFocus!;
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Lightbox'), findsOneWidget);
      await Bed.right(t);
      expect(find.text('3 / 6'), findsOneWidget, reason: 'Right turns to the next photo');
      await _back(t, key);
      expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Lightbox'), findsNothing, reason: '${key.debugName} closes it');
      expect(find.byType(PersonPage), findsOneWidget, reason: 'and only it');
      expect(from.hasPrimaryFocus, isTrue, reason: 'R6: back on the photo it was opened from');
    }
  }, variant: screen);
}
