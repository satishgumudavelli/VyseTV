// Plugins that list titles, browsed like Stremio's metadata addons: a scraper list whose plugins
// name catalogs (and give their titles' details), and a Vega repository whose providers' catalogs
// are read when it is added. Their catalogs become the repository addon's (a scraper list's on
// when it is added, a Vega provider's once picked in Settings > Addons > Catalogs to browse), their
// titles' pages come from their plugin, and they play from it, asked for their own ids. The engine
// is a stand-in; t4_journeys_plugins_engine_test.dart runs the real one.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/catalog/meta_addons.dart';
import 'package:vyse_tv/data/party/watch_party.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/sources/plugins/js_plugins.dart';
import 'package:vyse_tv/data/sources/plugins/plugin_catalogs.dart';
import 'package:vyse_tv/screens/home/addon_home.dart';
import 'package:vyse_tv/widgets/common.dart';
import 'package:vyse_tv/widgets/media_rows.dart';

import 'bed/phase6_pages.dart' show pressOn;
import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

const _list = 'https://plugins.test/tr/manifest.json';
const _vega = 'https://plugins.test/vega/manifest.json';

final _listFile = jsonEncode({
  'name': 'Turkish plugins',
  'scrapers': [
    {
      'id': 'turk',
      'name': '!Turk',
      'filename': 'turk.js',
      'version': '1',
      'supportedTypes': ['movie', 'tv'],
      'enabled': true,
      'resources': ['catalog', 'meta', 'stream'],
      'catalogs': [
        {'id': 'new', 'name': 'Yeni Filmler', 'type': 'movie'},
        {
          'id': 'shows',
          'name': 'Diziler',
          'type': 'tv',
          'extra': [
            {'name': 'search'},
          ],
        },
      ],
    },
    {'id': 'plain', 'name': 'Plain', 'filename': 'plain.js', 'version': '1', 'enabled': true},
  ],
});

final _vegaFile = jsonEncode([
  {'value': 'alpha', 'display_name': 'Alpha', 'version': '1'},
]);

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final desktop = OnScreens([Screens.desktop]);
  late FakeRoute route;
  late Directory dir;
  final calls = <String>[];
  final asked = <Map<String, Object?>>[];

  Future<Map<String, Object?>> call(String code, String entry, Map<String, Object?> args) async {
    calls.add('$entry ${jsonEncode(args)}');
    Map<String, Object?> value(Object? v) => {'value': v, 'log': const []};
    switch (entry) {
      case '__vyseDescribe':
        return value({
          'catalogs': [
            {'title': 'New', 'filter': ''},
            {'title': 'Netflix Series', 'filter': 'web-series/netflix'},
          ],
          'genres': [
            {'title': 'Action', 'filter': 'g/action'},
          ],
          'search': true,
          'meta': true,
        });
      case '__scraperCatalog' when args['catalogId'] == 'new':
        return value(
          args['pageToken'] == null
              ? {
                  'metas': [
                    {'id': 'turk:film1', 'name': 'Film Bir', 'type': 'movie', 'poster': 'https://img.test/f1.jpg', 'releaseInfo': '2024'},
                  ],
                  'next': '2',
                }
              : {
                  'metas': [
                    {'id': 'turk:film2', 'name': 'Film Iki', 'type': 'movie'},
                  ],
                },
        );
      case '__scraperCatalog':
        return value({
          'metas': [
            {'id': 'turk:show1', 'name': 'Dizi Bir', 'type': 'tv', 'poster': 'https://img.test/s1.jpg'},
          ],
        });
      case '__scraperMeta':
        return value({
          'meta': {
            'id': 'turk:show1',
            'type': 'tv',
            'name': 'Dizi Bir',
            'description': 'Bir dizi.',
            'videos': [
              {'id': 'turk:show1:1:1', 'season': 1, 'episode': 1, 'title': 'Bolum 1'},
              {'id': 'turk:show1:1:2', 'season': 1, 'episode': 2, 'title': 'Bolum 2'},
            ],
          },
        });
      case '__vegaCatalog':
        return value({
          'metas': [
            {'id': '/dark-s1/', 'name': 'Dark', 'type': 'series', 'poster': 'https://img.test/d.jpg'},
          ],
        });
      case '__vegaMeta':
        return value({
          'meta': {
            'id': args['link'],
            'type': 'series',
            'name': 'Dark',
            'imdb_id': 'tt5753856',
            'videos': [
              {'id': '${args['link']}|1|1', 'season': 1, 'episode': 1, 'title': 'Episode 1'},
            ],
          },
        });
    }
    return {'log': const [], 'error': 'no $entry'};
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vyse_plugin_catalogs_');
    PluginRepos.debugDir = dir;
    PluginRepos.debugReset();
    PluginCatalogs.debugReset();
    MetaAddons.debugReset();
    calls.clear();
    asked.clear();
    Addons.list.value = Addons.withBuiltIns(const []);
    debugPluginCall = call;
    debugPluginEngine = (code, query) async {
      asked.add({...query, 'plugin': code.contains('PLAIN') ? 'plain' : (code.contains('TURK') ? 'turk' : 'alpha')});
      final own = query['ownId'];
      return {
        'streams': own == null
            ? const []
            : [
                {'url': 'https://cdn.test/own/${Uri.encodeComponent('$own')}.mp4', 'type': 'mp4', 'quality': '1080p', 'server': 'Own'},
              ],
        'log': const [],
      };
    };
    route = Bed.http.route;
    Bed.http.route = (method, uri) {
      if (uri.host != 'plugins.test') return route(method, uri);
      return switch (uri.path) {
        '/tr/manifest.json' => FakeReply(200, utf8.encode(_listFile), type: 'application/json'),
        '/tr/turk.js' => FakeReply(200, utf8.encode('// TURK\nmodule.exports = {};'), type: 'text/javascript'),
        '/tr/plain.js' => FakeReply(200, utf8.encode('// PLAIN\nmodule.exports = {};'), type: 'text/javascript'),
        '/vega/manifest.json' => FakeReply(200, utf8.encode(_vegaFile), type: 'application/json'),
        final p when p.startsWith('/vega/dist/alpha/') && !p.endsWith('episodes.js') => FakeReply(200, utf8.encode('/* ${p.split('/').last} */'), type: 'text/javascript'),
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

  Addon addon(String url) => Addons.list.value.firstWhere((a) => a.manifestUrl == url);

  /// TMDB on or off, saved the way Settings saves it.
  void tmdb(bool on) {
    final l = [for (final a in Addons.list.value) a.manifestUrl == Addon.tmdb.manifestUrl ? a.copyWith(enabled: on) : a];
    AppSettings.addons.set(jsonEncode([for (final a in l) a.toJson()]));
    Addons.list.value = l;
  }

  group('a scraper list whose plugins list titles', () {
    testWidgets('its catalogs are its addon\'s, on when it is added (just above TMDB); pages go by the token the last one handed over', (t) async {
      await t.runAsync(() => Addons.install(_list));
      final a = addon(_list);
      expect(a.browse, ['turk'], reason: "a scraper list's plugins that list titles are on from the start");
      expect([for (final c in a.catalogs) '${c.id} ${c.type} ${c.name}'], ['turk/new movie Turk · Yeni Filmler', 'turk/shows series Turk · Diziler'],
          reason: 'led by the plugin\'s name; "tv" is shows');
      expect('${(a.catalogs[1].search, a.meta, a.metaPrefixes)}', '${(true, true, [PluginCatalogs.prefix(_list)])}');
      final list = Addons.list.value;
      expect(list.indexOf(a), lessThan(list.indexWhere((x) => x.manifestUrl == Addon.tmdb.manifestUrl)), reason: 'its rows lead on Home');

      final films = (await t.runAsync(() => MetaAddons.page(a, a.catalogs.first)))!;
      expect([for (final m in films) '${m.title} ${m.year} ${m.addonId}'], ['Film Bir 2024 ${PluginCatalogs.prefix(_list)}turk:turk:film1']);
      final more = (await t.runAsync(() => MetaAddons.page(a, a.catalogs.first, skip: 1)))!;
      expect(more.single.title, 'Film Iki');
      expect(calls.last, contains('"pageToken":"2"'), reason: 'the token the first page handed over');
      expect(await t.runAsync(() => MetaAddons.page(a, a.catalogs.first, skip: 2)), isEmpty, reason: 'no token after the last page: nothing more');
      expect(calls.where((c) => c.startsWith('__scraperCatalog')), hasLength(2));
    }, variant: desktop);

    testWidgets("a show's page comes from its plugin, episodes and all; an episode plays from that plugin alone, asked for it by its own id", (t) async {
      await t.runAsync(() => Addons.install(_list));
      final a = addon(_list);
      final show = (await t.runAsync(() => MetaAddons.page(a, a.catalogs[1])))!.single;
      expect(show.isTv, isTrue);
      final x = (await t.runAsync(() => MetaAddons.meta(show)))!;
      expect([for (final v in x.videos) '${v.season}x${v.episode} ${v.name}'], ['1x1 Bolum 1', '1x2 Bolum 2']);
      expect(x.details.media.overview, 'Bir dizi.');
      final target = (await t.runAsync(() => MetaAddons.target(show, season: 1, episode: 2)))!;
      final got = (await t.runAsync(() => Addons.streams(a, target)))!;
      expect([for (final s in got.streams) s.url], ['https://cdn.test/own/turk%3Ashow1%3A1%3A2.mp4']);
      expect([for (final q in asked) '${q['plugin']} ${q['ownId']} ${q['season']}x${q['episode']}'], ['turk turk:show1:1:2 1x2'], reason: 'Turk alone, not Plain');

      // in a watch party, a guest's run asks the host's plugin for the same title, by its own id
      final sent = WatchParty.sourceJson(AddonPick(got.streams.single, target));
      final copy = WatchParty.sourcePick(WatchState(media: show, season: 1, episode: 2, by: 'u0', source: sent))!;
      PluginRepos.debugReset(); // (another device: nothing found here yet)
      asked.clear();
      final again = (await t.runAsync(() => Addons.pluginAgain(copy)))!;
      expect(again.first.stream.url, 'https://cdn.test/own/turk%3Ashow1%3A1%3A2.mp4');
      expect([for (final q in asked) '${q['plugin']} ${q['ownId']}'], ['turk turk:show1:1:2'], reason: "the host's plugin alone, for the same episode");
    }, variant: desktop);

    testWidgets('one added before catalogs were read gets them on its next update: its plugins read again once, its catalogs on', (t) async {
      // as an older version kept it: its plugins without their catalogs, and no choice saved
      final key = PluginRepos.repoKey(_list);
      final kept = Directory('${dir.path}${Platform.pathSeparator}$key')..createSync(recursive: true);
      File('${kept.path}${Platform.pathSeparator}turk.js').writeAsStringSync('// TURK, kept');
      File('${kept.path}${Platform.pathSeparator}plain.js').writeAsStringSync('// PLAIN, kept');
      File('${kept.path}${Platform.pathSeparator}index.json').writeAsStringSync(jsonEncode({
        'url': _list,
        'name': 'Turkish plugins',
        'plugins': [
          {'id': 'turk', 'name': '!Turk', 'url': 'https://plugins.test/tr/turk.js', 'version': '1', 'types': ['movie', 'tv'], 'scraper': true},
          {'id': 'plain', 'name': 'Plain', 'url': 'https://plugins.test/tr/plain.js', 'version': '1', 'types': ['movie', 'tv'], 'scraper': true},
        ],
      }));
      Addons.list.value = [
        Addon.fromJson({'url': _list, 'id': 'plugins.$key', 'name': 'Turkish plugins', 'streams': true, 'pl': true, 'cat': []})!,
        ...Addons.withBuiltIns(const []),
      ];
      expect((await t.runAsync(() => PluginRepos.local(_list)))!.plugins.every((p) => p.stale), isTrue);
      await t.runAsync(() => Addons.refresh(force: true));
      final a = addon(_list);
      expect(a.browse, ['turk'], reason: "a scraper list's plugins that list titles: on");
      expect([for (final c in a.catalogs) c.id], ['turk/new', 'turk/shows']);
      expect((await t.runAsync(() => PluginRepos.local(_list)))!.plugins.any((p) => p.stale), isFalse);
      expect(File('${kept.path}${Platform.pathSeparator}turk.js').readAsStringSync(), startsWith('${scraperMarker}turk'), reason: 'its script came down again, once');
    }, variant: desktop);

    testWidgets('Home with TMDB off: its catalogs are rows, their titles from the plugin', (t) async {
      await t.runAsync(() => Addons.install(_list));
      tmdb(false);
      addTearDown(() => tmdb(true));
      await Bed.pumpShell(t);
      final row = find.byKey(ValueKey('catalog/$_list|movie|turk/new'));
      for (var i = 0; i < 30 && find.descendant(of: row, matching: find.byType(PosterCard)).evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await Bed.settle(t, rounds: 1);
      }
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Turk · Yeni Filmler · Movies')), findsOneWidget);
      expect(t.widgetList<PosterCard>(find.descendant(of: row, matching: find.byType(PosterCard))).map((c) => c.media.title), ['Film Bir']);
      expect(find.byType(CatalogShelf), findsNWidgets(2), reason: 'both of its catalogs');
      await Bed.picture(t, 'plugin_catalogs_home');
    }, variant: desktop);
  });

  group('a Vega repository', () {
    testWidgets("its providers' catalogs are read when it is added, and show once picked in Settings > Addons > Catalogs to browse, with a remote", (t) async {
      await t.runAsync(() => Addons.install(_vega));
      var a = addon(_vega);
      expect(a.catalogs, isEmpty, reason: "a Vega provider's are off until picked (a repository can list hundreds)");
      expect(a.browse, isEmpty);
      expect(calls.where((c) => c.startsWith('__vyseDescribe')), hasLength(1), reason: 'its catalog module read once, as it came down');

      await openSettings(t, 'Addons');
      await pressOn(t, find.byTooltip('Catalogs to browse'));
      for (var i = 0; i < 20 && find.text('Alpha').evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await Bed.settle(t, rounds: 1);
      }
      expect(find.textContaining('3 catalogs: New, Netflix Series, Genres · search'), findsOneWidget);
      final row = find.widgetWithText(Pressable, 'Alpha');
      expect(Bed.nodeOf(t, row).hasPrimaryFocus, isTrue, reason: 'the first plugin has the focus (on ${Bed.focused()})');
      await Bed.ok(t);
      for (var i = 0; i < 10 && addon(_vega).catalogs.isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await Bed.settle(t, rounds: 1);
      }
      a = addon(_vega);
      expect(a.browse, ['vega-alpha']);
      expect([for (final c in a.catalogs) '${c.id} ${c.type}${c.genreRequired ? ' genre' : ''}${c.searchOnly ? ' search' : ''}'], [
        'vega-alpha/c0 movie',
        'vega-alpha/c1 series',
        'vega-alpha/genre movie genre',
        'vega-alpha/search movie search',
      ]);
      expect(Bed.nodeOf(t, row).hasPrimaryFocus, isTrue, reason: 'the focus stays on the row');
      await Bed.picture(t, 'plugin_catalogs_pick');
      await Bed.back(t);
      expect(find.text('Catalogs to browse'), findsNothing, reason: 'Back closes it');
    }, variant: OnScreens([Screens.desktop, Screens.tv]));

    testWidgets("a provider's titles: a row, a genre, a search; a show's page from it; an episode plays from it by its own id", (t) async {
      await t.runAsync(() => Addons.install(_vega));
      await t.runAsync(() => Addons.setBrowse(addon(_vega), ['vega-alpha']));
      final a = addon(_vega);
      final row = (await t.runAsync(() => MetaAddons.page(a, a.catalogs[0])))!;
      expect(row.single.title, 'Dark');
      expect(row.single.backdropPath, 'https://img.test/d.jpg', reason: "its one picture is its page's backdrop too");
      expect(calls.last, contains('"filter":""'));
      await t.runAsync(() => MetaAddons.page(a, a.catalogs[2], genre: 'Action'));
      expect(calls.last, contains('"genre":"Action"'));
      final found = (await t.runAsync(() => MetaAddons.search('dark')))!;
      expect([for (final (_, m) in found) m.title], ['Dark']);
      expect(calls.last, contains('"search":"dark"'));
      final x = (await t.runAsync(() => MetaAddons.meta(row.single)))!;
      expect([for (final v in x.videos) '${v.season}x${v.episode}'], ['1x1']);
      final target = (await t.runAsync(() => MetaAddons.target(row.single, season: 1, episode: 1)))!;
      final got = (await t.runAsync(() => Addons.streams(a, target)))!;
      expect([for (final s in got.streams) s.url], ['https://cdn.test/own/${Uri.encodeComponent('/dark-s1/|1|1')}.mp4']);
      expect([for (final q in asked) q['ownId']], ['/dark-s1/|1|1']);
    }, variant: desktop);
  });
}
