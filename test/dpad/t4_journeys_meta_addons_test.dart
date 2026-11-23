// Stremio metadata addons, with a remote (arrows, OK, Back), on a TV and on a phone: Settings >
// Addons (TMDB built in and on; a metadata addon installed from its link), Home with TMDB on and
// off, Discover on an addon's catalog, search across TMDB and the addons, an addon title's
// details and episodes, playing it with Streaming mode off and on, and your lists.
//
// The addons are made up and answered by the bed's fake network (bed/fake_addons.dart).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/catalog/meta_addons.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/trackers/tracker_hub.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/discover/discover_page.dart';
import 'package:vyse_tv/screens/home/addon_home.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/screens/player/sources_page.dart';
import 'package:vyse_tv/screens/profile/profile_page.dart';
import 'package:vyse_tv/screens/search/search_page.dart';
import 'package:vyse_tv/core/nav.dart' show openStremioLink;
import 'package:vyse_tv/dpad/dpad_reveal.dart' show DpadRevealBlock;
import 'package:vyse_tv/widgets/common.dart';
import 'package:vyse_tv/widgets/media_rows.dart';
import 'package:vyse_tv/widgets/watched_marks.dart' show WatchedButton;

import 'bed/fake_addons.dart';
import 'harness.dart';

void main() {
  late FakeRoute route;
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    route = Bed.http.route;
    Bed.http.route = (method, uri) => fakeAddons(method, uri) ?? route(method, uri);
    Addons.start(); // as the app's main does
  });
  tearDownAll(() => Bed.http.route = route);
  final screen = OnScreens(Screens.android);

  final lantern = Addon.fromManifest(lanternUrl, lanternManifest);
  final kite = Addon.fromManifest(kiteUrl, kiteManifest);
  final brook = Addon.fromManifest(brookUrl, brookManifest);
  final hollow = Addon.fromManifest(hollowUrl, hollowManifest);
  final shelfmark = Addon.fromManifest(shelfmarkUrl, shelfmarkManifest);

  /// The TV screen runs as a TV, the phone as a phone. [addons] are installed (TMDB on unless
  /// [tmdb] is false), and everything is put back after the test.
  Future<void> start(WidgetTester t, {List<Addon> addons = const [], bool tmdb = true}) async {
    TvDetectionService.debugReset();
    await t.runAsync(() => TvDetectionService.getInstance(forceTv: OnScreens.current == Screens.tv));
    addTearDown(TvDetectionService.debugReset);
    MetaAddons.debugReset();
    Addons.list.value = Addons.withBuiltIns(addons);
    if (!tmdb) Addons.setEnabled(Addon.tmdb, false);
    final streaming = AppSettings.streamingMode.value;
    final progress = WatchProgress.entries.value;
    final list = MyList.items.value;
    addTearDown(() {
      Addons.list.value = const [];
      AppSettings.addons.value = '[]';
      AppSettings.streamingMode.value = streaming;
      WatchProgress.entries.value = progress;
      MyList.removeAll({for (final s in MyList.items.value) s.media.key});
      MyList.addAll(list);
    });
  }

  /// Requests made from here on (the bed keeps every one).
  int mark() => Bed.http.seen.length;
  List<String> since(int at) => Bed.http.seen.skip(at).toList();

  /// Presses [key] until the ring is on something whose description has [what].
  Future<void> seek(WidgetTester t, String what, {required Future<void> Function(WidgetTester t, {int times}) key, int max = 14}) async {
    for (var i = 0; i < max && !Bed.focused().contains(what); i++) {
      await key(t);
      await Bed.settle(t, rounds: 2);
    }
    expect(Bed.focused(), contains(what));
    if (!Bed.focusInView()) await Bed.picture(t, 'meta_addons/_not_in_view');
    expect(Bed.focusInView(), isTrue, reason: '${Bed.focused()} is in view');
  }

  /// The pressable control around [text].
  Finder control(String text) => find.ancestor(of: find.text(text), matching: find.byType(Pressable)).first;

  /// A widget that shows [title] (a card, a poster), found by the title it carries.
  Finder showing(String title) => find.byWidgetPredicate((w) {
    try {
      return ((w as dynamic).media as Media).title == title;
    } catch (_) {
      return false;
    }
  });

  /// Toasts run out before the test ends.
  Future<void> done(WidgetTester t) => t.pump(const Duration(seconds: 4));

  testWidgets('Settings > Addons: TMDB is built in and on; a metadata addon installs from its link above it; OK on TMDB\'s switch turns it off', (t) async {
    await start(t);
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    await Bed.push(t, const ProfilePage(addons: true));
    expect(find.text('TMDB'), findsOneWidget);
    expect(Addons.tmdbOn, isTrue);
    expect(find.text('Catalogs'), findsOneWidget, reason: "TMDB's row says what it gives");

    await t.enterText(find.byType(TextField).first, 'https://lantern.test');
    await Bed.focus(t, control('Install'));
    await Bed.ok(t);
    expect(find.textContaining('Lantern is installed (catalogs and details)'), findsOneWidget);
    expect(Addons.list.value.map((a) => a.name).toList(), ['Lantern', 'TMDB', 'Knaben'], reason: 'a metadata addon goes just above TMDB');
    expect(Addons.catalogAddons.single.catalogs.where((c) => c.board).length, 6);
    await Bed.picture(t, 'meta_addons/settings_installed');

    // TMDB's switch, from the Install button with the arrows
    bool onTmdbSwitch() {
      final node = FocusManager.instance.primaryFocus;
      if (node?.context == null) return false;
      var inTmdbRow = false, isSwitch = false;
      node!.context!.visitAncestorElements((e) {
        final name = e.widget.runtimeType.toString();
        if (name == '_Switch') isSwitch = true;
        if (name == '_AddonRow') {
          inTmdbRow = find.descendant(of: find.byWidget(e.widget), matching: find.text('TMDB')).evaluate().isNotEmpty;
          return false;
        }
        return true;
      });
      return isSwitch && inTmdbRow;
    }

    for (var i = 0; i < 24 && !onTmdbSwitch(); i++) {
      await (Bed.focused().contains('_Switch') || Bed.focused().contains("'Install'") ? Bed.down(t) : Bed.right(t));
    }
    expect(onTmdbSwitch(), isTrue, reason: "the arrows reach TMDB's switch (${Bed.focused()})");
    await Bed.ok(t);
    expect(Addons.tmdbOn, isFalse);
    expect(Addons.addonsOnly, isTrue);
    await Bed.back(t);
    await done(t);
  }, variant: screen);

  testWidgets('Home with TMDB on: the addon\'s catalogs are rows above TMDB\'s; Down reaches one, OK opens a title\'s details from the addon', (t) async {
    await start(t, addons: [lantern]);
    final at = mark();
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    expect(find.text('Popular · Movies'), findsOneWidget);
    expect(find.text('Hot right now'), findsOneWidget, reason: "TMDB's rows stay while it is on");
    expect(since(at).where((r) => r.contains('lantern.test/catalog/series/last-videos')), isEmpty, reason: 'a catalog that needs ids is never asked');
    await Bed.picture(t, 'meta_addons/home_tmdb_on');

    await seek(t, 'Popular · Movies', key: Bed.down);
    await Bed.ok(t);
    expect(find.byType(DetailsPage), findsOneWidget);
    final film = t.widget<DetailsPage>(find.byType(DetailsPage)).media;
    expect(film.isAddon, isTrue, reason: "one of Lantern's films");
    expect(find.text(film.title), findsWidgets);
    expect(since(at), contains('GET https://lantern.test/meta/movie/${film.addonId}.json'), reason: 'its details come from the addon');
    expect(find.textContaining('1h 52m'), findsWidgets, reason: "the addon's runtime");
    await Bed.picture(t, 'meta_addons/details_film');
    await Bed.back(t);
    expect(find.byType(DetailsPage), findsNothing);
    await done(t);
  }, variant: screen);

  testWidgets('Home with TMDB off: hero, rows, collection cards and genre cards come from the addon; nothing is asked of TMDB; a collection card opens on Discover', (t) async {
    await start(t, addons: [lantern], tmdb: false);
    final at = mark();
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    expect(find.text('Hot right now'), findsNothing);
    expect(find.text('Streaming services'), findsNothing);
    expect(find.text('Popular · Series'), findsOneWidget);
    expect(find.text('More from Lantern'), findsOneWidget, reason: 'the catalogs past the first five are cards');
    expect(find.text('Explore genres'), findsOneWidget);
    expect(find.text('Comedy'), findsOneWidget, reason: "the genre cards are the catalog's genres");
    final tmdb = since(at).where((r) => r.contains('api.themoviedb.org')).toList();
    expect(tmdb, isEmpty, reason: 'TMDB is off: $tmdb');
    await Bed.picture(t, 'meta_addons/home_tmdb_off');

    await seek(t, 'More from Lantern', key: Bed.down, max: 24);
    await Bed.ok(t);
    expect(find.byType(DiscoverPage), findsOneWidget);
    expect(['list3', 'year'], contains(t.widget<DiscoverPage>(find.byType(DiscoverPage)).catalog?.catalog.id), reason: 'the card\'s own catalog');
    await Bed.picture(t, 'meta_addons/collection_discover');
    await Bed.back(t);
    expect(find.byType(DiscoverPage), findsNothing);
    await done(t);
  }, variant: screen);

  testWidgets('a catalog that brings nothing back, or fails, has no row on Home (heading and all)', (t) async {
    await start(t, addons: [hollow]);
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    expect(find.text('Fine · Movies'), findsOneWidget);
    expect(find.text('Empty · Movies'), findsNothing);
    expect(find.text('Broken · Movies'), findsNothing);
    expect(find.text("Couldn't load this row."), findsNothing);
    // and a remote goes from the hero to Continue watching to the row that is there
    await seek(t, 'Fine · Movies', key: Bed.down);
    await Bed.picture(t, 'meta_addons/hollow_rows');
    await done(t);
  }, variant: screen);

  testWidgets('Discover with TMDB off: the first catalog, its genre pills; a remote picks a genre and the grid pages on', (t) async {
    await start(t, addons: [lantern], tmdb: false);
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    await Bed.push(t, const DiscoverPage());
    expect(find.text('From Lantern'), findsOneWidget);
    expect(find.text('All'), findsOneWidget, reason: "the genre pills, in place of TMDB's sort");
    expect(find.text('Filters'), findsNothing);
    await Bed.picture(t, 'meta_addons/discover_catalog');

    await seek(t, "'All'", key: Bed.down);
    expect(Bed.focused(), contains('_GenreBar'));
    await seek(t, "'Western'", key: Bed.right);
    final at = mark();
    await Bed.ok(t);
    expect(since(at), contains('GET https://lantern.test/catalog/movie/top/genre=Western.json'));
    expect(showing('Western Story 1'), findsWidgets, reason: "the grid is that genre's");

    // back to all of it, then down the grid until the next page is asked for
    await seek(t, "'All'", key: Bed.left);
    await Bed.ok(t);
    final paged = mark();
    for (var i = 0; i < 14 && !since(paged).any((r) => r.contains('skip=30')); i++) {
      await Bed.down(t);
    }
    expect(since(paged), contains('GET https://lantern.test/catalog/movie/top/skip=30.json'));
    await Bed.back(t);
    await done(t);
  }, variant: screen);

  testWidgets('Search: with TMDB off only the addons are asked; with TMDB on both are, and a title both have shows once', (t) async {
    await start(t, addons: [lantern, kite], tmdb: false);
    // (a search of its own for each screen: TMDB's answers are kept for the run)
    final q = OnScreens.current == Screens.tv ? 'long night' : 'the long night';
    final asked = Uri.encodeComponent(q);
    await Bed.pumpShell(t);
    await Bed.push(t, const SearchPage());
    var at = mark();
    await t.enterText(find.byType(TextField).first, q);
    await Bed.settle(t);
    expect(since(at), contains('GET https://lantern.test/catalog/movie/top/search=$asked.json'));
    expect(since(at), contains('GET https://kite.test/catalog/anime/kite-search/search=$asked.json'));
    expect(since(at).where((r) => r.contains('api.themoviedb.org')), isEmpty);
    expect(find.text('Lantern Only Film'), findsWidgets);
    expect(find.widgetWithText(ShelfHeader, 'Anime'), findsOneWidget, reason: "Kite's finds have a row of their own");
    await Bed.picture(t, 'meta_addons/search_addons_only');

    Addons.setEnabled(Addon.tmdb, true);
    await t.enterText(find.byType(TextField).first, '');
    await Bed.settle(t);
    at = mark();
    await t.enterText(find.byType(TextField).first, q);
    await Bed.settle(t);
    expect(since(at).any((r) => r.contains('api.themoviedb.org/3/search/movie')), isTrue);
    final longNights = find.byWidgetPredicate((w) {
      try {
        return (w as dynamic).media is Media && ((w as dynamic).media as Media).title == 'The Long Night';
      } catch (_) {
        return false;
      }
    });
    final keys = {for (final e in longNights.evaluate()) ((e.widget as dynamic).media as Media).key};
    expect(keys, {'movie/1000'}, reason: 'the film both found shows once, as TMDB\'s');
    expect(find.text('Lantern Only Film'), findsWidgets);
    await done(t);
  }, variant: screen);

  testWidgets('An addon show: episodes from its videos; with Streaming mode off, OK on an episode asks the stream addons for its own id', (t) async {
    await start(t, addons: [lantern, kite, brook]);
    AppSettings.streamingMode.value = false;
    final show = MetaAddons.media(kiteShow(7), type: 'anime', from: kite)!;
    expect(show.key, 'meta/kite:7');
    expect(show.tmdbKnown, isFalse);
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    await Bed.push(t, DetailsPage(media: show));
    expect(find.text('Starfall Academy 2'), findsWidgets);
    if (!Bed.focused().contains("'Play'")) await Bed.down(t);
    expect(Bed.focused(), contains("'Play'"));
    await seek(t, '_SeasonNumber', key: Bed.down);
    if (OnScreens.current == Screens.phone) {
      await Bed.down(t);
    } else {
      await Bed.right(t);
    }
    expect(Bed.focused(), contains("'Play E1'"));
    await Bed.right(t);
    await Bed.settle(t, rounds: 2);
    expect(find.text('Kite episode 2'), findsWidgets);
    await Bed.picture(t, 'meta_addons/details_episodes');

    final at = mark();
    // (the sources page is a little too wide for a TV: a known one, see the TV notes)
    final wide = await Bed.overflows(() async {
      await Bed.ok(t);
      expect(find.byType(SourcesPage), findsOneWidget);
      expect(since(at), contains('GET https://brook.test/stream/series/kite:7:2.json'), reason: "the episode's own video id");
      await Bed.back(t);
    });
    expect(wide.where((o) => !o.contains('sources_page.dart')), isEmpty);
    expect(find.byType(SourcesPage), findsNothing);
    await Bed.back(t);
    await done(t);
  }, variant: screen);

  testWidgets('Streaming mode on: a film matched by its IMDb id plays from VyseTV\'s sources as TMDB\'s, keeping its own key; one with no match says so and opens the addons\' sources', (t) async {
    await start(t, addons: [lantern, kite, brook]);
    AppSettings.streamingMode.value = true;
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);

    final film = MetaAddons.media(lanternFilm(3), type: 'movie', from: lantern)!;
    await Bed.push(t, DetailsPage(media: film));
    if (!Bed.focused().contains("'Play'")) await Bed.down(t);
    expect(Bed.focused(), contains("'Play'"));
    final at = mark();
    await Bed.ok(t);
    expect(since(at), contains('GET https://api.themoviedb.org/3/find/tt1000003?api_key=b3556f3b206e16f82df4d1f6fd4545e6&language=en-US&external_source=imdb_id'));
    final player = t.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.media.id, 1003, reason: "TMDB's id, for the film sources");
    expect(player.media.key, 'meta/tt1000003', reason: 'its progress stays the addon title\'s');
    await Bed.closePlayer(t);
    // (the film sources give up on a title after 30 s: their timers run out here)
    await t.pump(const Duration(seconds: 31));
    await Bed.back(t);

    final show = MetaAddons.media(kiteShow(8), type: 'anime', from: kite)!;
    await Bed.push(t, DetailsPage(media: show));
    if (!Bed.focused().contains("'Play'")) await Bed.down(t);
    expect(Bed.focused(), contains("'Play'"));
    final wide = await Bed.overflows(() async {
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 400));
      if (find.textContaining("isn't on TMDB").evaluate().isEmpty) await Bed.picture(t, 'meta_addons/_no_toast');
      expect(find.textContaining("isn't on TMDB, so it plays from your addons"), findsOneWidget, reason: 'said over the sources screen');
      await Bed.settle(t);
      expect(find.byType(SourcesPage), findsOneWidget);
      await Bed.picture(t, 'meta_addons/no_tmdb_match');
      await Bed.back(t);
    });
    expect(wide.where((o) => !o.contains('sources_page.dart')), isEmpty);
    await Bed.back(t);
    await done(t);
  }, variant: screen);

  testWidgets('Your lists: My List, progress and Continue watching keep an addon title as one, saved and read back', (t) async {
    await start(t, addons: [lantern]);
    final film = MetaAddons.media(lanternFilm(5), type: 'movie', from: lantern)!;
    TrackerHub.myListToggle(film);
    expect(MyList.has(film), isTrue);
    final saved = (await MyList.syncSnapshot())[film.key]!;
    expect((saved['m'] as Map)['sid'], 'tt1000005');
    MyList.removeAll({film.key});
    await MyList.syncApply(film.key, jsonDecode(jsonEncode(saved)) as Map<String, dynamic>);
    final back = MyList.items.value.firstWhere((s) => s.media.key == film.key).media;
    expect((back.isAddon, back.addonType, back.title, back.posterPath), (true, 'movie', 'Copperhead', 'https://img.test/lp5.jpg'));

    WatchProgress.record(film, position: const Duration(minutes: 20), duration: const Duration(minutes: 100));
    final entry = WatchProgress.find(film)!;
    final again = WatchEntry.fromJson(jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>);
    expect((again.media.key, again.media.isAddon, again.media.tmdbKnown), ('meta/tt1000005', true, false));
    expect(WatchProgress.continueWatching.first.media.key, film.key);

    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    final card = find.byWidgetPredicate((w) {
      try {
        return ((w as dynamic).entry as WatchEntry).media.key == film.key;
      } catch (_) {
        return false;
      }
    });
    expect(card, findsWidgets, reason: 'on Continue watching');
    await done(t);
  }, variant: screen);

  testWidgets('a collection: Home lists it, its page lists its films (not episodes), and OK on a film opens that film\'s own page', (t) async {
    await start(t, addons: [shelfmark]);
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    expect(find.text('Popular · Collections'), findsOneWidget);
    await seek(t, 'Popular · Collections', key: Bed.down);
    // (Down comes into the row on the card nearest the one above it: here, See all)
    await seek(t, 'PosterCard', key: Bed.left);
    await Bed.ok(t);
    expect(find.byType(DetailsPage), findsOneWidget);
    expect(find.text('Harbour Saga Collection'), findsWidgets);
    expect(find.text('Collection'), findsOneWidget);
    expect(find.text('2 films'), findsWidgets);
    expect(find.text('Films'), findsOneWidget, reason: 'its films, as a row of their own');
    expect(find.text('Episodes'), findsNothing);
    expect(find.byType(WatchedButton), findsNothing, reason: "a collection's films are marked on their own pages");
    await Bed.picture(t, 'meta_addons/collection_page');

    if (!Bed.focused().contains("'Play'")) await Bed.down(t);
    await seek(t, 'PosterCard', key: Bed.down);
    expect(Bed.focused(), contains('2 films'), reason: 'the row of its films');
    await Bed.ok(t);
    final page = t.widget<DetailsPage>(find.byType(DetailsPage).last).media;
    expect(page.key, 'meta/tt1000002', reason: 'the first film, as a title of its own');
    expect(find.text('Paper Moons'), findsWidgets);
    expect(find.text('Episodes'), findsNothing);
    await Bed.back(t);
    await Bed.back(t);
    expect(find.byType(DetailsPage), findsNothing);
    await done(t);
  }, variant: screen);

  testWidgets("a collection's Play, with Streaming mode on, plays its first film not yet watched, as TMDB's (its key its own)", (t) async {
    await start(t, addons: [shelfmark]);
    AppSettings.streamingMode.value = true;
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    final col = MetaAddons.media(shelfmarkCollection(), type: 'collections', from: shelfmark)!;
    await Bed.push(t, DetailsPage(media: col));
    if (!Bed.focused().contains("'Play'")) await Bed.down(t);
    expect(Bed.focused(), contains("'Play'"));
    await Bed.ok(t);
    final player = t.widget<PlayerPage>(find.byType(PlayerPage));
    expect((player.media.key, player.media.id, player.media.title), ('meta/tt1000002', 1002, 'Paper Moons'));
    await Bed.closePlayer(t);
    await t.pump(const Duration(seconds: 31)); // (the film sources' timers)
    await Bed.back(t);
    await done(t);
  }, variant: screen);

  testWidgets('a film TMDB knows only by name: VyseTV servers finds it; a source that is a link says where it opens, comes last, and OK on it opens it', (t) async {
    await start(t, addons: [shelfmark, brook]);
    AppSettings.streamingMode.value = false;
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    final film = MetaAddons.media({'id': 'tt1000004', 'type': 'movie', 'name': 'Harbour Lights', 'releaseInfo': '2013'})!;
    await Bed.push(t, DetailsPage(media: film));
    if (!Bed.focused().contains("'Play'")) await Bed.down(t);
    final wide = await Bed.overflows(() async {
      await Bed.ok(t);
      expect(find.byType(SourcesPage), findsOneWidget);
      expect(find.text('Opens in VyseTV'), findsOneWidget, reason: "Shelfmark's link to the collection");
      expect(find.text('Opens on YouTube'), findsOneWidget);
      expect(find.text('Opens in your browser'), findsOneWidget);
      // the file that plays comes before every link
      final rows = [for (final e in find.textContaining(RegExp('Made-up stream|Opens ')).evaluate()) (e.widget as Text).data ?? ''];
      expect(rows.first, contains('Made-up stream'));
      await Bed.picture(t, 'meta_addons/sources_links');

      // OK on the link: the collection's page, in VyseTV
      await Bed.focus(t, control('Opens in VyseTV'));
      await Bed.ok(t);
      expect(t.widget<DetailsPage>(find.byType(DetailsPage).last).media.key, 'meta/col.1');
      await Bed.back(t);

      // VyseTV servers: matched to TMDB by its name and year (a phone has it under the list)
      if (OnScreens.current == Screens.phone) {
        await t.tap(find.text('Play with VyseTV’s servers instead'));
        await Bed.settle(t);
      } else {
        await Bed.focus(t, control('VyseTV servers'));
        await Bed.ok(t);
      }
      final player = t.widget<PlayerPage>(find.byType(PlayerPage));
      expect((player.media.id, player.media.key), (1001, 'meta/tt1000004'));
      await Bed.closePlayer(t);
      await t.pump(const Duration(seconds: 31));
    });
    expect(wide.where((o) => !o.contains('sources_page.dart')), isEmpty);
    await Bed.back(t);
    await done(t);
  }, variant: screen);

  testWidgets("a film whose details carry a stream: the sources screen lists it as that addon's", (t) async {
    await start(t, addons: [lantern, brook]);
    AppSettings.streamingMode.value = false;
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    final film = MetaAddons.media(lanternFilm(7), type: 'movie', from: lantern)!;
    await Bed.push(t, DetailsPage(media: film));
    if (!Bed.focused().contains("'Play'")) await Bed.down(t);
    final wide = await Bed.overflows(() async {
      await Bed.ok(t);
      expect(find.byType(SourcesPage), findsOneWidget);
      expect(find.textContaining('Lantern own 720p'), findsOneWidget);
      expect(find.text('Lantern'), findsWidgets, reason: 'its own tab');
      await Bed.back(t);
    });
    expect(wide.where((o) => !o.contains('sources_page.dart')), isEmpty);
    await Bed.back(t);
    await done(t);
  }, variant: screen);

  testWidgets("Settings > Addons: an addon's list of addons; a remote installs one; one that needs setting up says so; no adult ones", (t) async {
    await start(t, addons: [lantern]);
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    await Bed.push(t, const ProfilePage(addons: true));
    expect(find.text('Find addons'), findsOneWidget);
    expect(find.text('Community · Lantern'), findsOneWidget, reason: 'one per list, not one per kind');
    expect(find.text('Brook'), findsOneWidget);
    expect(find.text('Needs Setup'), findsOneWidget);
    expect(find.text('Grown Ups Only'), findsNothing);
    expect(find.text('Set up'), findsOneWidget);
    final kiteRow = find.ancestor(of: find.text('Kite'), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ListedAddon'));
    await Bed.focus(t, find.ancestor(of: find.descendant(of: kiteRow, matching: find.text('Install')), matching: find.byType(Pressable)).first);
    expect(Bed.focusInView(), isTrue);
    await Bed.ok(t);
    expect(Addons.list.value.map((a) => a.name), contains('Kite'));
    expect(find.descendant(of: kiteRow, matching: find.text('Installed')), findsOneWidget);
    await Bed.picture(t, 'meta_addons/find_addons');
    await Bed.back(t);
    await done(t);
  }, variant: screen);

  testWidgets('a catalog of landscape pictures gets landscape cards on Home', (t) async {
    await start(t, addons: [hollow]);
    await Bed.pumpShell(t);
    final card = find.descendant(
      of: find.ancestor(of: find.text('Fine · Movies'), matching: find.byType(DpadRevealBlock)).first,
      matching: find.byType(PosterCard),
    ).first;
    final size = t.getSize(card);
    expect(size.width > size.height, isTrue, reason: '$size');
    await done(t);
  }, variant: screen);

  testWidgets('a Stremio search link opens Search on it, over the page, with a way back', (t) async {
    await start(t, addons: [lantern], tmdb: false);
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    final ctx = t.element(find.byType(PosterCard).first);
    expect(await openStremioLink(ctx, 'stremio:///search?search=long%20night'), isTrue);
    await Bed.settle(t);
    expect(find.byWidgetPredicate((w) => w is SearchPage && w.query == 'long night'), findsOneWidget);
    expect(find.text('Lantern Only Film'), findsWidgets);
    expect(find.text('Back'), findsWidgets);
    await Bed.back(t);
    expect(find.text('Lantern Only Film'), findsNothing);
    await done(t);
  }, variant: screen);

  test("Home's split: an addon's first five catalogs are rows; the rest, and one that lists a genre at a time, are cards", () {
    final (rows, cards) = AddonHome.split(lantern);
    expect(rows.length, AddonHome.rows);
    expect([for (final r in cards) r.catalog.id], ['list3', 'year']);
    expect(AddonHome.split(kite).$2, isEmpty, reason: 'a search-only catalog is neither');
  });
}
