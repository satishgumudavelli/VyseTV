// Comic plugins (a Vega provider of type "comic") go to the Manga section, never Home: their first
// list is a shelf on the Manga page (See all opens all their lists), their series open on the
// Manga details page with their chapters, and the reader shows a chapter's pages from the plugin,
// with the headers their site wants. They are never asked for a video's streams. Settings >
// Addons > Catalogs to browse lists them as In Manga, on until turned off. The engine is a
// stand-in; t4_journeys_plugins_engine_test.dart runs the real one.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/manga/plugin_comics.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/sources/plugins/js_plugins.dart';
import 'package:vyse_tv/data/sources/plugins/plugin_catalogs.dart';
import 'package:vyse_tv/screens/manga/manga_details_page.dart';
import 'package:vyse_tv/screens/manga/manga_page.dart';
import 'package:vyse_tv/screens/manga/manga_reader_page.dart';
import 'package:vyse_tv/screens/manga/manga_widgets.dart' show MangaCard;
import 'package:vyse_tv/widgets/common.dart';

import 'bed/phase6_pages.dart' show pressOn;
import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

const _repo = 'https://plugins.test/komix/manifest.json';

final _manifest = jsonEncode([
  {'value': 'inkpress', 'display_name': 'Ink Press', 'type': 'comic', 'version': '1'},
]);

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final desktop = OnScreens([Screens.desktop]);
  late FakeRoute route;
  late Directory dir;
  final calls = <String>[];
  final videoAsked = <String>[];

  Future<Map<String, Object?>> call(String code, String entry, Map<String, Object?> args) async {
    calls.add('$entry ${jsonEncode(args)}');
    Map<String, Object?> value(Object? v) => {'value': v, 'log': const []};
    return switch (entry) {
      '__vyseDescribe' => value({
        'catalogs': [
          {'title': 'Popular', 'filter': ''},
          {'title': 'Latest', 'filter': 'latest'},
        ],
        'genres': const [],
        'search': true,
        'meta': true,
      }),
      '__vegaCatalog' => value({
        'metas': args['search'] != null
            ? [
                {'id': '/series/9/', 'name': 'Found Moon', 'type': 'comic'},
              ]
            : [
                {'id': '/series/1/', 'name': 'Paper Moon', 'type': 'comic', 'poster': 'https://img.test/c1.jpg'},
                {'id': '/series/2/', 'name': 'Iron Ink', 'type': 'comic', 'poster': 'https://img.test/c2.jpg'},
              ],
      }),
      '__vegaComic' => value({
        'meta': {'title': 'Paper Moon', 'image': 'https://img.test/c1.jpg', 'synopsis': 'A comic about the moon.', 'tags': ['Drama'], 'author': 'Ink Artist'},
        'chapters': [
          {'link': '/c/1', 'title': 'Chapter 1', 'number': 1},
          {'link': '/c/2', 'title': 'Chapter 2', 'number': 2},
        ],
      }),
      '__vegaPages' => value({
        'pages': [
          {'url': 'https://img.test${args['link']}/1.jpg', 'headers': {'Referer': 'https://site.test/'}},
          {'url': 'https://img.test${args['link']}/2.jpg', 'headers': {'Referer': 'https://site.test/'}},
        ],
      }),
      _ => {'log': const [], 'error': 'no $entry'},
    };
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vyse_plugin_comics_');
    PluginRepos.debugDir = dir;
    PluginRepos.debugReset();
    PluginCatalogs.debugReset();
    PluginComics.debugReset();
    calls.clear();
    videoAsked.clear();
    Addons.list.value = Addons.withBuiltIns(const []);
    debugPluginCall = call;
    debugPluginEngine = (code, query) async {
      videoAsked.add(jsonEncode(query));
      return {'streams': const [], 'log': const []};
    };
    route = Bed.http.route;
    Bed.http.route = (method, uri) {
      if (uri.host != 'plugins.test') return route(method, uri);
      return switch (uri.path) {
        '/komix/manifest.json' => FakeReply(200, utf8.encode(_manifest), type: 'application/json'),
        final p when p.startsWith('/komix/dist/inkpress/') && !p.endsWith('episodes.js') => FakeReply(200, utf8.encode('/* ${p.split('/').last} */'), type: 'text/javascript'),
        _ => const FakeReply(404, []),
      };
    };
  });
  tearDown(() {
    Bed.http.route = route;
    debugPluginCall = null;
    debugPluginEngine = null;
    PluginRepos.debugDir = null;
    Addons.list.value = const [];
    AppSettings.addons.set('[]');
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Addon addon() => Addons.list.value.firstWhere((a) => a.manifestUrl == _repo);

  Future<void> waitFor(WidgetTester t, Finder f, {int rounds = 40}) async {
    for (var i = 0; i < rounds && f.evaluate().isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await Bed.settle(t, rounds: 1);
    }
  }

  testWidgets('a comic plugin is never on Home nor asked for a video; it is a Manga source, on from the start', (t) async {
    await t.runAsync(() => Addons.install(_repo));
    final a = addon();
    expect(a.catalogs, isEmpty, reason: 'not on Home, Discover or search');
    expect(a.comicsOff, isEmpty);
    final info = (await t.runAsync(() => PluginRepos.local(_repo)))!;
    expect(info.plugins.single.comic, isTrue, reason: 'its manifest says "comic"');
    expect([for (final c in info.plugins.single.catalogs) '${c.id} ${c.type}'], ['c0 comic', 'c1 comic', 'search comic']);
    final sources = (await t.runAsync(PluginComics.sources))!;
    expect([for (final s in sources) '${s.name}: ${[for (final c in s.shelves) c.name].join(', ')}'], ['Ink Press: Popular, Latest']);
    // a film's sources: the comic plugin isn't asked
    final film = Bed.freshTitle();
    await t.runAsync(() => Addons.streams(a, AddonTarget(type: 'movie', tmdb: film.id, title: film.title, year: int.tryParse(film.year ?? ''))));
    expect(videoAsked, isEmpty, reason: "a comic's pages are not a video's streams");
  }, variant: desktop);

  testWidgets("the Manga page: its first list is a shelf; a series opens with its details and chapters and reads its pages, with their site's headers; See all opens all its lists", (t) async {
    await t.runAsync(() => Addons.install(_repo));
    await Bed.pumpShell(t);
    await Bed.push(t, const MangaPage());
    final shelf = find.text('Ink Press · Popular');
    await waitFor(t, find.text('Paper Moon'));
    expect(shelf, findsOneWidget);
    expect(find.text('Paper Moon'), findsOneWidget);
    await Bed.picture(t, 'plugin_comics_manga_page');

    await pressOn(t, find.descendant(of: find.byWidgetPredicate((w) => w is MangaCard && w.manga.title == 'Paper Moon'), matching: find.byType(Pressable)).first);
    await waitFor(t, find.text('A comic about the moon.'));
    expect(find.byType(MangaDetailsPage), findsOneWidget);
    expect(find.text('A comic about the moon.'), findsOneWidget, reason: 'its details, from its plugin');
    expect(find.textContaining('Ink Artist', findRichText: true), findsWidgets, reason: 'its author, from its plugin');
    await waitFor(t, find.text('2 chapters'));
    expect(find.text('2 chapters'), findsOneWidget);
    await Bed.picture(t, 'plugin_comics_series');

    await pressOn(t, find.ancestor(of: find.text('Start reading'), matching: find.byType(Pressable)).first);
    await waitFor(t, find.byType(MangaReaderPage));
    expect(find.byType(MangaReaderPage), findsOneWidget);
    for (var i = 0; i < 20 && PluginComics.headersFor('https://img.test/c/1/1.jpg') == null; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await Bed.settle(t, rounds: 1);
    }
    expect(calls.where((c) => c.startsWith('__vegaPages')).single, contains('"link":"/c/1"'), reason: 'the first chapter, from its plugin');
    expect(PluginComics.headersFor('https://img.test/c/1/1.jpg'), {'Referer': 'https://site.test/'}, reason: 'its pages load with their headers');
    await Bed.back(t);
    await Bed.settle(t, rounds: 4);
    await Bed.back(t);
    await Bed.settle(t, rounds: 4);

    // See all: all its lists, the first picked
    final seeAll = find.ancestor(of: find.text('See all'), matching: find.byType(Pressable));
    await t.ensureVisible(seeAll.first);
    await pressOn(t, seeAll.first);
    await waitFor(t, find.text('Iron Ink'));
    expect(find.widgetWithText(Pressable, 'Popular'), findsWidgets);
    expect(find.widgetWithText(Pressable, 'Latest'), findsWidgets);
    expect(find.text('From Vega providers'), findsOneWidget);
    await Bed.back(t);
  }, variant: desktop);

  testWidgets('Settings > Addons > Catalogs to browse: it is In Manga, and OK turns it off there', (t) async {
    await t.runAsync(() => Addons.install(_repo));
    await openSettings(t, 'Addons');
    await pressOn(t, find.byTooltip('Catalogs to browse'));
    await waitFor(t, find.text('Ink Press'));
    expect(find.textContaining('In Manga · 2 catalogs: Popular, Latest · search'), findsOneWidget);
    final row = find.widgetWithText(Pressable, 'Ink Press');
    expect(Bed.nodeOf(t, row).hasPrimaryFocus, isTrue);
    await Bed.ok(t);
    for (var i = 0; i < 10 && addon().comicsOff.isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await Bed.settle(t, rounds: 1);
    }
    expect(addon().comicsOff, ['vega-inkpress']);
    expect(await t.runAsync(PluginComics.sources), isEmpty, reason: 'off: gone from Manga');
    await Bed.back(t);
  }, variant: OnScreens([Screens.desktop, Screens.tv]));
}
