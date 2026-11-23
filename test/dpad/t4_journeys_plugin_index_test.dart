// Settings > Addons > Find plugins: the community's plugin repositories, from the index VyseTV's
// server builds every day, to search and install with one press, by mouse or remote.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/sources/plugins/js_plugins.dart';
import 'package:vyse_tv/data/sources/plugins/plugin_index.dart';
import 'package:vyse_tv/screens/profile/plugin_index_page.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'bed/phase6_pages.dart' show pressOn;
import 'bed/phase8_pages.dart' show openSettings;
import 'bed/walker.dart';
import 'harness.dart';

const _index = 'https://index.test/plugins/index.json';

Map<String, Object?> _repo(String name, int plugins, {String kind = 'scrapers', List<String> langs = const ['en'], bool featured = false, bool adult = false, int stars = 0, String updated = '2026-11-20', String description = ''}) => {
  'url': 'https://repos.test/${name.toLowerCase().replaceAll(' ', '-')}/manifest.json',
  'kind': kind,
  'name': name,
  'author': 'maker-${name.length}',
  'description': description,
  'plugins': plugins,
  'names': ['$name One', '$name Two'],
  'languages': langs,
  'types': ['movie', 'tv'],
  'updated': updated,
  'stars': stars,
  'featured': featured,
  'adult': adult,
};

final _doc = jsonEncode({
  'v': 1,
  'updated': '2026-11-23T04:17:00Z',
  'repos': [
    _repo('Big Turkish', 40, langs: ['tr', 'en'], stars: 3, updated: '2026-11-01'),
    _repo('Anime World', 12, langs: ['en', 'ja'], featured: true, description: 'Anime from many sites, subbed and dubbed.', stars: 30),
    _repo('Vega Mix', 25, kind: 'vega', langs: const [], updated: '2026-11-23'),
    _repo('Late Night', 9, adult: true),
    _repo('Arabic Cinema', 18, langs: ['ar']),
  ],
});

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screens = OnScreens([Screens.desktop, Screens.phone]);
  final desktop = OnScreens([Screens.desktop]);
  late FakeRoute route;
  late Directory dir;
  var serverUp = true;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vyse_index_');
    PluginIndex.debugUrl = _index;
    PluginIndex.debugDir = dir;
    PluginIndex.debugReset();
    PluginRepos.debugDir = dir;
    PluginRepos.debugReset();
    serverUp = true;
    route = Bed.http.route;
    Bed.http.route = (method, uri) => switch (uri.host) {
      'index.test' => serverUp ? FakeReply(200, utf8.encode(_doc), type: 'application/json') : const FakeReply(503, []),
      // the repositories themselves: a scraper list each, with one scraper
      'repos.test' when uri.path.endsWith('manifest.json') => FakeReply(
        200,
        utf8.encode(jsonEncode({
          'name': uri.pathSegments.first,
          'scrapers': [
            {'id': 'one', 'name': 'One', 'filename': 'one.js', 'supportedTypes': ['movie', 'tv']},
          ],
        })),
        type: 'application/json',
      ),
      'repos.test' => FakeReply(200, utf8.encode('async function getStreams() { return []; }\nmodule.exports = { getStreams };'), type: 'text/javascript'),
      _ => route(method, uri),
    };
  });
  tearDown(() {
    Bed.http.route = route;
    PluginIndex.debugUrl = null;
    PluginIndex.debugDir = null;
    PluginRepos.debugDir = null;
    Addons.list.value = const [];
    AppSettings.addons.set('[]');
    AppSettings.animeAdult.set(false);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Settings > Addons > Browse plugins, with a remote, and the index in.
  Future<void> open(WidgetTester t) async {
    await openSettings(t, 'Addons');
    await Bed.settle(t, rounds: 2);
    await pressOn(t, find.widgetWithText(Pressable, 'Browse plugins'));
    for (var i = 0; i < 20 && find.byType(PluginIndexPage).evaluate().isNotEmpty && find.text('Big Turkish').evaluate().isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await Bed.settle(t, rounds: 1);
    }
    expect(find.byType(PluginIndexPage), findsOneWidget);
  }

  /// Whether [a]'s card comes before [b]'s, reading the grid row by row.
  bool before(String a, String b) {
    final x = t0.getTopLeft(find.text(a)), y = t0.getTopLeft(find.text(b));
    return x.dy < y.dy || (x.dy == y.dy && x.dx < y.dx);
  }

  testWidgets('Settings > Addons > Browse plugins: the hand-picked first, then the most plugins; not the adult ones; the ring on the first card', (t) async {
    t0 = t;
    await open(t);
    expect(find.text('Late Night'), findsNothing, reason: 'adult content is off');
    expect(before('Anime World', 'Big Turkish'), isTrue, reason: 'hand-picked first');
    expect(before('Big Turkish', 'Vega Mix'), isTrue, reason: 'then the most plugins');
    // (a phone builds the cards below the fold only when scrolled to)
    if (find.text('Arabic Cinema').evaluate().isNotEmpty) expect(before('Vega Mix', 'Arabic Cinema'), isTrue);
    expect(find.textContaining('4 repositories with 95 plugins'), findsOneWidget);
    expect(find.text('12 plugins'), findsOneWidget);
    expect(find.text('Anime from many sites, subbed and dubbed.'), findsOneWidget);
    final ring = FocusManager.instance.primaryFocus?.context;
    var on = false;
    find.text('Anime World').evaluate().single.visitAncestorElements((e) => !(on = e == ring));
    expect(on, isTrue, reason: "a remote lands on the first card: ${Bed.focused()}");
    await Bed.picture(t, 'plugin_index/list');
  }, variant: screens);

  testWidgets('search, the languages and the kinds narrow it; nothing found says how to see all again', (t) async {
    t0 = t;
    await open(t);
    await t.enterText(find.byType(TextField).first, 'anime');
    await Bed.settle(t, rounds: 2);
    expect(find.text('Anime World'), findsOneWidget);
    expect(find.text('Big Turkish'), findsNothing);
    await t.enterText(find.byType(TextField).first, '');
    await Bed.settle(t, rounds: 2);
    await t.tap(find.text('Turkish'));
    await Bed.settle(t, rounds: 2);
    expect(find.text('Big Turkish'), findsOneWidget);
    expect(find.text('Arabic Cinema'), findsNothing);
    await t.tap(find.text('Vega'));
    await Bed.settle(t, rounds: 2);
    expect(find.textContaining('Nothing matches'), findsOneWidget);
    await t.tap(find.text('Show all'));
    await Bed.settle(t, rounds: 2);
    expect(find.text('Vega Mix'), findsOneWidget);
    expect(find.text('Arabic Cinema'), findsOneWidget);
  }, variant: desktop);

  testWidgets('OK on a card installs it: Installed, and in Your addons; Back returns to Settings', (t) async {
    t0 = t;
    await open(t);
    await pressOn(t, find.ancestor(of: find.text('Arabic Cinema'), matching: find.byType(Pressable)).first);
    for (var i = 0; i < 20 && !Addons.list.value.any((a) => a.plugins); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await Bed.settle(t, rounds: 1);
    }
    expect(Addons.list.value.where((a) => a.plugins).single.manifestUrl, 'https://repos.test/arabic-cinema/manifest.json');
    final card = find.ancestor(of: find.text('Arabic Cinema'), matching: find.byType(Pressable)).first;
    expect(find.descendant(of: card, matching: find.text('Installed')), findsOneWidget);
    await Bed.back(t);
    expect(find.byType(PluginIndexPage), findsNothing);
    expect(find.text('Browse plugins'), findsOneWidget, reason: 'back in Settings > Addons');
  }, variant: desktop);

  testWidgets('with a remote, every card, filter and the search box are reachable, and nothing traps the ring', (t) async {
    t0 = t;
    await open(t);
    final walk = await Walker(t, settle: () => Bed.settle(t, rounds: 1), isNavbar: (_) => true, ignore: (label) => !label.contains('PluginIndexPage')).run(maxPresses: 400);
    for (final p in walk.problems) {
      debugPrint('PROBLEM $p', wrapWidth: 2000);
    }
    walk.expectClean();
    expect(walk.where('_RepoCard'), hasLength(4));
  }, variant: desktop);

  testWidgets("the server down: this device's copy; with no copy, a note and Try again", (t) async {
    t0 = t;
    await open(t); // (a copy is kept on the device now)
    await Bed.back(t);
    PluginIndex.debugReset();
    serverUp = false;
    await open(t);
    expect(find.text('Anime World'), findsOneWidget, reason: "the device's copy");
    await Bed.back(t);
    PluginIndex.debugReset();
    for (final f in dir.listSync()) {
      if (f.path.endsWith('plugin_index.json')) f.deleteSync();
    }
    await pressOn(t, find.widgetWithText(Pressable, 'Browse plugins'));
    for (var i = 0; i < 20 && find.textContaining("Couldn't load").evaluate().isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await Bed.settle(t, rounds: 1);
    }
    expect(find.textContaining("Couldn't load the plugin list"), findsOneWidget);
    serverUp = true;
    await t.tap(find.text('Try again'));
    for (var i = 0; i < 20 && find.text('Anime World').evaluate().isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await Bed.settle(t, rounds: 1);
    }
    expect(find.text('Anime World'), findsOneWidget);
  }, variant: desktop);

  testWidgets('adult content allowed (Settings > Anime): the adult repositories show too', (t) async {
    t0 = t;
    AppSettings.animeAdult.set(true);
    await open(t);
    expect(find.text('Late Night'), findsOneWidget);
  }, variant: desktop);
}

late WidgetTester t0;
