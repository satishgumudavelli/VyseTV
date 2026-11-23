// Scraper plugins as addons: a repository of JavaScript plugins (a repo.json, or a Vega provider
// manifest) is installed from Settings > Addons like a Stremio addon, its scripts kept in files on
// the device; its plugins' streams show on the sources screen with the other addons', and never
// among VyseTV's own sources. The engine itself is stood in for (its library isn't in a test);
// t4_journeys_plugins_engine_test.dart runs the real one where it is.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/data/sources/plugins/js_plugins.dart';
import 'package:vyse_tv/screens/player/sources_page.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'bed/phase6_pages.dart' show pressOn;
import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

const _repo = 'https://plugins.test/repo.json';

final _repoFile = jsonEncode({
  'name': 'Test plugins',
  'plugins': [
    {'id': 'alpha', 'name': 'Alpha', 'version': '1', 'url': 'alpha.js'},
    {'id': 'beta', 'name': 'Beta', 'version': '1', 'url': 'https://plugins.test/beta.js', 'types': ['movie']},
  ],
});

/// The stand-in engine: Alpha finds a 1080p HLS link (its link doesn't say .m3u8) and logs a line;
/// Beta's site is down.
Future<Map<String, Object?>> _engine(String code, Map<String, Object?> query) async => code.contains('ALPHA')
    ? {
        'streams': [
          {'url': 'https://cdn.test/alpha/master', 'type': 'hls', 'quality': '1080p', 'server': 'Alpha Fast', 'audio': 'English', 'headers': {'Referer': 'https://alpha.test/'}},
          {'url': 'ftp://nope.test/x.mp4'},
        ],
        'log': ['looked for ${query['title']} (${query['year']})'],
      }
    : {'streams': const [], 'log': const [], 'error': 'site down'};

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final desktop = OnScreens([Screens.desktop]);
  late FakeRoute route;
  late Directory dir;
  final served = <String>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vyse_plugins_');
    PluginRepos.debugDir = dir;
    PluginRepos.debugReset();
    debugPluginEngine = _engine;
    served.clear();
    route = Bed.http.route;
    Bed.http.route = (method, uri) {
      if (uri.host != 'plugins.test') return route(method, uri);
      served.add(uri.path);
      return switch (uri.path) {
        '/repo.json' => FakeReply(200, utf8.encode(_repoFile), type: 'application/json'),
        '/alpha.js' => FakeReply(200, utf8.encode('// ALPHA\nasync function getStreams(q) { return []; }'), type: 'text/javascript'),
        '/beta.js' => FakeReply(200, utf8.encode('// BETA\nasync function getStreams(q) { return []; }'), type: 'text/javascript'),
        _ => const FakeReply(404, []),
      };
    };
  });
  tearDown(() {
    Bed.http.route = route;
    debugPluginEngine = null;
    PluginRepos.debugDir = null;
    Addons.list.value = const [];
    AppSettings.addons.set('[]');
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('reading repositories', () {
    test('GitHub links become raw links', () {
      expect(normalizeRepoUrl('https://github.com/a/b/blob/main/repo.json'), 'https://raw.githubusercontent.com/a/b/main/repo.json');
      expect(normalizeRepoUrl('https://github.com/a/b'), 'https://raw.githubusercontent.com/a/b/HEAD/repo.json');
      expect(normalizeRepoUrl(' https://x.test/r.json '), 'https://x.test/r.json');
    });

    test('a repo.json: relative links, ids, kinds; bad entries left out', () {
      final r = parseRepoFile(
        jsonEncode({
          'name': 'Mine',
          'plugins': [
            {'id': 'one', 'name': 'One', 'url': 'p/one.js', 'types': ['tv']},
            {'url': 'https://h.test/two.js'},
            {'id': 'bad id!', 'url': 'x.js'},
            {'id': 'ftp', 'url': 'ftp://h.test/f.js'},
            {'id': 'one', 'url': 'again.js'},
          ],
        }),
        'https://h.test/repo/repo.json',
      );
      expect(r.name, 'Mine');
      expect([for (final p in r.plugins) '${p.id} ${p.url} ${p.types.join(',')}'], [
        'one https://h.test/repo/p/one.js tv',
        'two https://h.test/two.js movie,tv',
      ]);
    });

    test('a Vega manifest: each provider a plugin, not the turned-off, torrent or oddly named ones', () {
      final r = parseRepoFile(
        jsonEncode([
          {'display_name': 'Alpha', 'value': 'alpha', 'version': '1.5'},
          {'display_name': 'Off', 'value': 'off', 'disabled': true},
          {'display_name': 'Torrents', 'value': 'torrentio'},
          {'display_name': 'Bad', 'value': 'bad value!'},
        ]),
        'https://h.test/v/manifest.json?x=1',
      );
      expect([for (final p in r.plugins) (p.id, p.name, p.url, p.vega)], [('vega-alpha', 'Alpha', 'https://h.test/v/dist/alpha', true)]);
    });

    test('a scraper list: each scraper a plugin (its file next to the manifest), not the ones turned off; series means shows', () {
      final r = parseRepoFile(
        jsonEncode({
          'name': 'Their scrapers',
          'version': '1.0.0',
          'scrapers': [
            {'id': 'one', 'name': 'One', 'version': '2', 'filename': 'providers/one.js', 'supportedTypes': ['movie', 'series'], 'enabled': true, 'contentLanguage': ['tr', 'en']},
            {'id': 'off', 'name': 'Off', 'filename': 'providers/off.js', 'enabled': false},
            {'id': 'bad id', 'filename': 'x.js'},
            {'id': 'nofile'},
          ],
        }),
        'https://h.test/me/repo/refs/heads/main/manifest.json',
      );
      expect(r.name, 'Their scrapers');
      expect([for (final p in r.plugins) '${p.id} ${p.url} ${p.types.join(',')} ${p.note} ${p.scraper}'], [
        'one https://h.test/me/repo/refs/heads/main/providers/one.js movie,tv TR · EN true',
      ]);
      expect(composeScraperPlugin('one', '2', 'module.exports = {};'), startsWith('${scraperMarker}one\n'));
    });

    test('a plugin repository is told from a Stremio manifest', () {
      expect(isPluginRepo({'name': 'x', 'scrapers': []}), isTrue, reason: 'a scraper list');
      expect(isPluginRepo({'plugins': []}), isTrue);
      expect(isPluginRepo([{'value': 'a'}]), isTrue);
      expect(isPluginRepo({'id': 'org.addon', 'resources': ['stream']}), isFalse);
      expect(isPluginRepo(const []), isFalse);
    });

    test('an update downloads only what changed, and drops what the repository no longer lists', () {
      const keep = PluginEntry(id: 'a', name: 'A', url: 'u/a', version: '1');
      final plan = PluginRepos.planUpdate(
        [keep, const PluginEntry(id: 'b', name: 'B', url: 'u/b', version: '1'), const PluginEntry(id: 'c', name: 'C', url: 'u/c')],
        [keep, const PluginEntry(id: 'b', name: 'B', url: 'u/b', version: '2'), const PluginEntry(id: 'c', name: 'C', url: 'u/c'), const PluginEntry(id: 'd', name: 'D', url: 'u/d')],
      );
      expect(plan.keep, ['a']);
      expect(plan.fetch, ['b', 'c', 'd'], reason: 'a newer version, one with no version (always), a new one');
      expect(plan.drop, isEmpty);
      expect(PluginRepos.planUpdate([keep], const []).drop, ['a']);
    });

    test("a script can't reach this device or its network", () {
      for (final a in ['127.0.0.1', '10.1.2.3', '172.20.0.1', '192.168.1.1', '100.64.0.1', '169.254.1.1', '::1', 'fd00::1', '::ffff:10.0.0.1']) {
        expect(isPrivateAddress(InternetAddress(a)), isTrue, reason: a);
      }
      for (final a in ['8.8.8.8', '172.32.0.1', '2606:4700::1111']) {
        expect(isPrivateAddress(InternetAddress(a)), isFalse, reason: a);
      }
    });

    test("a plugin's answer: only http(s) links, its fields as given", () {
      final s = parseStreams([
        {'url': 'https://v.test/a.m3u8', 'quality': 720, 'server': 'S', 'headers': {'Referer': 'r'}},
        {'url': 'magnet:?xt=urn:btih:abc'},
        'nonsense',
      ]);
      expect(s, hasLength(1));
      expect((s.single.type, s.single.quality, s.single.server), ('hls', '720', 'S'));
      expect(s.single.headers, {'Referer': 'r'});
    });
  });

  group('as an addon', () {
    testWidgets('Settings > Addons: a repo.json link installs it as one addon (Plugins), its scripts in files, none in your settings, none among VyseTV sources', (t) async {
      final ours = [for (final s in activeFilmSources()) s.id];
      await openSettings(t, 'Addons');
      await Bed.settle(t, rounds: 2);
      await t.enterText(find.byType(TextField).first, _repo);
      await pressOn(t, find.widgetWithText(Pressable, 'Install'));
      for (var i = 0; i < 20 && Addons.list.value.every((a) => !a.plugins); i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await Bed.settle(t, rounds: 1);
      }
      final a = Addons.list.value.firstWhere((a) => a.plugins);
      expect((a.name, a.manifestUrl, a.streams, a.description), ('Test plugins', _repo, true, '2 plugins: Alpha, Beta'));
      expect(find.textContaining('Test plugins is installed'), findsOneWidget);
      expect(find.text('Plugins'), findsOneWidget, reason: 'the row says what it is');
      final kept = Directory('${dir.path}${Platform.pathSeparator}${PluginRepos.repoKey(_repo)}');
      expect([for (final f in kept.listSync()) f.uri.pathSegments.last]..sort(), ['alpha.js', 'beta.js', 'index.json']);
      expect(AppSettings.addons.value, isNot(contains('ALPHA')), reason: 'your addons (synced) hold the link, not the scripts');
      expect([for (final s in activeFilmSources()) s.id], ours, reason: "VyseTV's own sources are untouched");
    }, variant: desktop);

    testWidgets("a scraper list's link installs the same way: its scrapers kept as plugins, each wrapped to run as one", (t) async {
      Bed.http.route = (method, uri) => uri.host != 'scrapers.test'
          ? route(method, uri)
          : switch (uri.path) {
              '/list/manifest.json' => FakeReply(
                200,
                utf8.encode(jsonEncode({
                  'name': 'Their scrapers',
                  'scrapers': [
                    {'id': 'site', 'name': 'Site', 'version': '1', 'filename': 'providers/site.js', 'supportedTypes': ['movie', 'tv'], 'enabled': true},
                  ],
                })),
                type: 'application/json',
              ),
              '/list/providers/site.js' => FakeReply(200, utf8.encode('async function getStreams(id, type) { return []; }\nmodule.exports = { getStreams };'), type: 'text/javascript'),
              _ => const FakeReply(404, []),
            };
      final ran = <String>[];
      debugPluginEngine = (code, query) async {
        ran.add(code.split('\n').first);
        return {'streams': const [], 'log': const []};
      };
      final a = await t.runAsync(() => Addons.install('https://scrapers.test/list/manifest.json'));
      expect((a!.plugins, a.name, a.description), (true, 'Their scrapers', '1 plugin: Site'));
      final kept = File('${dir.path}${Platform.pathSeparator}${PluginRepos.repoKey('https://scrapers.test/list/manifest.json')}${Platform.pathSeparator}site.js');
      expect(kept.readAsStringSync(), allOf(startsWith('${scraperMarker}site\n'), contains('async function getStreams(id, type)')));
      await t.runAsync(() => PluginRepos.find(a.manifestUrl, {'tmdbId': 1, 'isTv': false, 'title': 'X'}));
      expect(ran, ['${scraperMarker}site'], reason: 'run as its wrapped script');
    }, variant: desktop);

    testWidgets("the sources screen: the repository's plugins answer as its addon; the log says what each did", (t) async {
      await t.runAsync(() => Addons.install(_repo)); // (files are written in real time)
      final film = Bed.catalogue[0];
      await Bed.pumpShell(t);
      await Bed.push(t, SourcesPage(media: film));
      for (var i = 0; i < 30 && find.textContaining('Alpha Fast').evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await Bed.settle(t, rounds: 1);
      }
      expect(find.textContaining('Alpha Fast'), findsWidgets, reason: "Alpha's link, with its server");
      expect(find.textContaining('ftp://'), findsNothing);
      expect(PluginLog.lines.value.join('\n'), allOf(contains('[Alpha] looked for'), contains('[Alpha] done: 1 stream'), contains('[Beta] ERROR: site down')));
      await Bed.back(t);
    }, variant: desktop);

    testWidgets("the sources screen shows a plugin's streams as soon as it answers, while a slower one still looks", (t) async {
      final beta = Completer<void>();
      debugPluginEngine = (code, query) async {
        if (code.contains('ALPHA')) return _engine(code, query);
        await beta.future; // (Beta's site is slow)
        return {
          'streams': [
            {'url': 'https://cdn.test/beta.mp4', 'quality': '720p', 'server': 'Beta Main'},
          ],
          'log': const [],
        };
      };
      await t.runAsync(() => Addons.install(_repo));
      await Bed.pumpShell(t);
      // (a title of its own: what was looked up for another test's title is kept app-wide, and in
      // a test it belongs to that test's clock)
      await Bed.push(t, SourcesPage(media: Bed.freshTitle()));
      for (var i = 0; i < 30 && find.textContaining('Alpha Fast').evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await Bed.settle(t, rounds: 1);
      }
      expect(find.textContaining('Alpha Fast'), findsWidgets, reason: "Alpha's link, before Beta has answered (log: ${PluginLog.lines.value})");
      expect(find.textContaining('Beta Main'), findsNothing);
      beta.complete();
      for (var i = 0; i < 30 && find.textContaining('Beta Main').evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await Bed.settle(t, rounds: 1);
      }
      expect(find.textContaining('Beta Main'), findsWidgets, reason: "then Beta's, with Alpha's still there");
      expect(find.textContaining('Alpha Fast'), findsWidgets);
      await Bed.back(t);
    }, variant: desktop);

    testWidgets("a row stays put as more streams come in: later ones go below, the ring stays on its row; asking for another sort reorders", (t) async {
      final alpha = Completer<void>();
      debugPluginEngine = (code, query) async {
        if (code.contains('ALPHA')) {
          await alpha.future; // (Alpha, first in the repository, is slow)
          return _engine(code, query);
        }
        return {
          'streams': [
            {'url': 'https://cdn.test/beta.mp4', 'quality': '720p', 'server': 'Beta Main'},
          ],
          'log': const [],
        };
      };
      await t.runAsync(() => Addons.install(_repo));
      await Bed.pumpShell(t);
      await Bed.push(t, SourcesPage(media: Bed.freshTitle()));
      Future<void> until(String text) async {
        for (var i = 0; i < 30 && find.textContaining(text).evaluate().isEmpty; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await Bed.settle(t, rounds: 1);
        }
        expect(find.textContaining(text), findsWidgets);
      }

      // whether the remote's ring is on the row that says [text]
      bool ringOn(String text) {
        final ring = FocusManager.instance.primaryFocus?.context;
        var on = false;
        find.textContaining(text).evaluate().first.visitAncestorElements((e) => !(on = e == ring));
        return on;
      }

      await until('Beta Main');
      final beta = find.textContaining('Beta Main').first;
      final was = t.getTopLeft(beta);
      await Bed.dpadMode(t);
      await Bed.focus(t, find.ancestor(of: beta, matching: find.byType(Pressable)).first);
      expect(ringOn('Beta Main'), isTrue);
      alpha.complete();
      await until('Alpha Fast');
      expect(t.getTopLeft(find.textContaining('Beta Main').first), was, reason: "Beta's row didn't move (nor did the filters above it grow: Alpha's stream names a language)");
      expect(t.getTopLeft(find.textContaining('Alpha Fast').first).dy, greaterThan(was.dy), reason: 'Alpha came later: below, though it is first in the repository');
      expect(ringOn('Beta Main'), isTrue, reason: 'the ring stays on the row it was on');
      expect(find.text('Language'), findsOneWidget, reason: 'its filter, in the room kept for it');

      // asked for, another order: the best first
      await t.tap(find.text('Addon order'));
      await Bed.settle(t, rounds: 2);
      await t.tap(find.text('Highest quality').last);
      await Bed.settle(t, rounds: 2);
      expect(t.getTopLeft(find.textContaining('Alpha Fast').first).dy, lessThan(t.getTopLeft(find.textContaining('Beta Main').first).dy));
      await Bed.back(t);
    }, variant: desktop);

    testWidgets('adding a repository says how many of its plugins have come down, then nothing', (t) async {
      final seen = <String>[];
      void heard() => seen.add('${PluginRepos.installing.value?.done}/${PluginRepos.installing.value?.total}');
      PluginRepos.installing.addListener(heard);
      addTearDown(() => PluginRepos.installing.removeListener(heard));
      await t.runAsync(() => Addons.install(_repo));
      expect(seen.first, '0/2');
      expect(seen, containsAllInOrder(['1/2', '2/2', 'null/null']));
    }, variant: desktop);

    test("a plugin's link as an addon stream: the plugin's name, then quality, server and language; HLS though its link doesn't say", () async {
      final a = Addon.ofPlugins(const PluginRepoInfo(url: _repo, name: 'Test plugins', plugins: [PluginEntry(id: 'alpha', name: 'Alpha', url: 'u')]));
      final s = Addons.pluginStream(
        a,
        const PluginHit(PluginEntry(id: 'alpha', name: 'Alpha', url: 'u'), FoundStream(url: 'https://cdn.test/alpha/master', type: 'hls', quality: '1080p', server: 'Alpha Fast', audio: 'English')),
      );
      expect((s.name, s.description, s.quality), ('Alpha', '1080p · Alpha Fast · English', '1080p'));
      expect(s.toSource().hls, isTrue);
      expect(Addon.fromJson(a.toJson())?.plugins, isTrue, reason: 'kept as a plugin repository in your synced addons');
    });

    testWidgets('the Plugin log, from the addon row with a remote; removing the addon takes its scripts off the device', (t) async {
      await t.runAsync(() => Addons.install(_repo)); // (files are written in real time)
      PluginLog.add('Alpha', ['looked for Oppenheimer (2023)']);
      await openSettings(t, 'Addons');
      await Bed.settle(t, rounds: 2);
      await pressOn(t, find.descendant(of: find.byTooltip('Plugin log'), matching: find.byType(Pressable)));
      expect(find.text('Plugin log'), findsWidgets);
      expect(find.textContaining('[Alpha] looked for Oppenheimer (2023)'), findsOneWidget);
      await pressOn(t, find.widgetWithText(Pressable, 'Close'));
      expect(find.textContaining('[Alpha] looked for'), findsNothing);
      final kept = Directory('${dir.path}${Platform.pathSeparator}${PluginRepos.repoKey(_repo)}');
      expect(kept.existsSync(), isTrue);
      Addons.remove(Addons.list.value.firstWhere((a) => a.plugins));
      for (var i = 0; i < 10 && kept.existsSync(); i++) {
        await t.pump();
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      expect(kept.existsSync(), isFalse);
    }, variant: desktop);
  });
}
