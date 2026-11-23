// How the metadata addon pages look on desktop windows (the TV and the phone are pictured by
// t4_journeys_meta_addons_test.dart): Home with TMDB on and off, Discover on an addon's catalog,
// an addon title's details, search across TMDB and the addons, and Settings > Addons. Each is
// pictured (docs/dpad/pictures/meta_addons) and must lay out without an overflow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/catalog/meta_addons.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/discover/discover_page.dart';
import 'package:vyse_tv/screens/profile/profile_page.dart';
import 'package:vyse_tv/screens/search/search_page.dart';

import 'bed/fake_addons.dart';
import 'harness.dart';

void main() {
  late FakeRoute route;
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.windows);
    route = Bed.http.route;
    Bed.http.route = (method, uri) => fakeAddons(method, uri) ?? route(method, uri);
  });
  tearDownAll(() => Bed.http.route = route);
  final screen = OnScreens(Screens.windows);

  final lantern = Addon.fromManifest(lanternUrl, lanternManifest);
  final kite = Addon.fromManifest(kiteUrl, kiteManifest);

  void install({bool tmdb = true}) {
    MetaAddons.debugReset();
    Addons.list.value = Addons.withBuiltIns([lantern, kite]);
    if (!tmdb) Addons.setEnabled(Addon.tmdb, false);
    addTearDown(() => Addons.list.value = const []);
  }

  testWidgets('Home, TMDB on and off', (t) async {
    final problems = await Bed.overflows(() async {
      install();
      await Bed.pumpShell(t);
      await Bed.picture(t, 'meta_addons/look_home_tmdb_on');
      final list = find.byType(Scrollable).first;
      await t.drag(list, const Offset(0, -1400));
      await Bed.settle(t, rounds: 4);
      await Bed.picture(t, 'meta_addons/look_home_tmdb_on_rows');

      await t.pumpWidget(const SizedBox());
      Addons.setEnabled(Addon.tmdb, false);
      await Bed.pumpShell(t);
      await Bed.picture(t, 'meta_addons/look_home_tmdb_off');
      await t.drag(find.byType(Scrollable).first, const Offset(0, -1600));
      await Bed.settle(t, rounds: 4);
      await Bed.picture(t, 'meta_addons/look_home_tmdb_off_cards');
      await t.drag(find.byType(Scrollable).first, const Offset(0, -2400));
      await Bed.settle(t, rounds: 4);
      await Bed.picture(t, 'meta_addons/look_home_tmdb_off_genres');
    });
    expect(problems, isEmpty);
  }, variant: screen);

  testWidgets('Discover on an addon catalog, details of an addon show, search, Settings > Addons', (t) async {
    final problems = await Bed.overflows(() async {
      install();
      await Bed.pumpShell(t);
      await Bed.push(t, const DiscoverPage());
      await Bed.picture(t, 'meta_addons/look_discover_tmdb_on');
      await t.tap(find.text('Popular · Series'));
      await Bed.settle(t);
      await Bed.picture(t, 'meta_addons/look_discover_catalog');
      await Bed.back(t);

      final show = MetaAddons.media(lanternShow(2), type: 'series', from: lantern)!;
      await Bed.push(t, DetailsPage(media: show));
      await Bed.picture(t, 'meta_addons/look_details_show');
      await Bed.back(t);

      await Bed.push(t, const SearchPage());
      await t.enterText(find.byType(TextField).first, 'long night');
      await Bed.settle(t);
      await Bed.picture(t, 'meta_addons/look_search');
      await Bed.back(t);

      await Bed.push(t, const ProfilePage(addons: true));
      await Bed.picture(t, 'meta_addons/look_settings');
      await Bed.back(t);
      await t.pump(const Duration(seconds: 4));
    });
    expect(problems, isEmpty);
  }, variant: screen);
}
