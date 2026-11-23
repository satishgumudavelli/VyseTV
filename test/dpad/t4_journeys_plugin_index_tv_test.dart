// Find plugins on a TV: the page as a remote sees it, every card and filter reachable, OK installs.

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

import 'bed/walker.dart';
import 'harness.dart';

Map<String, Object?> _repo(String name, int plugins, List<String> langs, {bool featured = false}) => {
  'url': 'https://repos.test/${name.toLowerCase().replaceAll(' ', '-')}/manifest.json',
  'kind': 'scrapers',
  'name': name,
  'author': 'someone',
  'description': featured ? 'Films and shows from many sites, in many languages.' : '',
  'plugins': plugins,
  'names': ['$name One', '$name Two', '$name Three'],
  'languages': langs,
  'updated': '2026-11-21',
  'stars': featured ? 12 : 0,
  'featured': featured,
};

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
  });
  final tv = OnScreens([Screens.tv]);

  testWidgets('a TV: the ring on the first card, every card and filter reachable, OK installs', (t) async {
    final dir = Directory.systemTemp.createTempSync('vyse_index_tv_');
    PluginIndex.debugUrl = 'https://index.test/plugins/index.json';
    PluginIndex.debugDir = dir;
    PluginIndex.debugReset();
    PluginRepos.debugDir = dir;
    PluginRepos.debugReset();
    final route = Bed.http.route;
    addTearDown(() {
      Bed.http.route = route;
      PluginIndex.debugUrl = null;
      PluginIndex.debugDir = null;
      PluginRepos.debugDir = null;
      Addons.list.value = const [];
      AppSettings.addons.set('[]');
      dir.deleteSync(recursive: true);
    });
    Bed.http.route = (method, uri) => switch (uri.host) {
      'index.test' => FakeReply(
        200,
        utf8.encode(jsonEncode({
          'v': 1,
          'repos': [
            _repo('All in One', 66, ['en', 'hi', 'ar', 'es'], featured: true),
            _repo('Turkish Mix', 17, ['tr']),
            _repo('Anime Corner', 29, ['en', 'ja']),
            _repo('Latino', 10, ['es']),
            _repo('Arabic Cinema', 18, ['ar']),
          ],
        })),
        type: 'application/json',
      ),
      'repos.test' when uri.path.endsWith('manifest.json') => FakeReply(
        200,
        utf8.encode(jsonEncode({
          'name': 'Turkish Mix',
          'scrapers': [
            {'id': 'one', 'name': 'One', 'filename': 'one.js'},
          ],
        })),
        type: 'application/json',
      ),
      'repos.test' => FakeReply(200, utf8.encode('module.exports = { getStreams: async function () { return []; } };'), type: 'text/javascript'),
      _ => route(method, uri),
    };

    await Bed.pumpShell(t);
    await Bed.push(t, const PluginIndexPage());
    for (var i = 0; i < 20 && find.text('Turkish Mix').evaluate().isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await Bed.settle(t, rounds: 1);
    }
    await Bed.dpadMode(t);
    await Bed.settle(t, rounds: 2);
    await Bed.picture(t, 'plugin_index/tv');

    final walk = await Walker(t, settle: () => Bed.settle(t, rounds: 1), isNavbar: (_) => true, ignore: (label) => !label.contains('PluginIndexPage')).run(maxPresses: 1500);
    for (final p in walk.problems) {
      debugPrint('PROBLEM $p', wrapWidth: 2000);
    }
    walk.expectClean();
    expect(walk.where('_RepoCard'), hasLength(5));

    // OK on Turkish Mix's card, as a remote does
    final card = find.ancestor(of: find.text('Turkish Mix'), matching: find.byType(Pressable)).first;
    await Bed.focus(t, card);
    await Bed.ok(t);
    for (var i = 0; i < 20 && !Addons.list.value.any((a) => a.plugins); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await Bed.settle(t, rounds: 1);
    }
    expect(Addons.list.value.where((a) => a.plugins).single.manifestUrl, 'https://repos.test/turkish-mix/manifest.json');
    expect(find.descendant(of: card, matching: find.text('Installed')), findsOneWidget);
    await Bed.back(t);
    expect(find.byType(PluginIndexPage), findsNothing, reason: 'Back leaves the page');
  }, variant: tv);
}
