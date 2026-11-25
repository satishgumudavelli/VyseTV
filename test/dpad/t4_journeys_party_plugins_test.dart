// A watch party with a plugin's stream: the host's link is never shared (a plugin's links are
// often only good for whoever asked). Which plugin found it, and which of its links it was,
// travel instead; each guest runs that plugin on their own device, even without the repository
// among their addons, and plays the link most like the host's. And Settings > Addons says that
// addons give sources only with Streaming mode off, with a button that turns it off.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/nav.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/data/party/rooms.dart';
import 'package:vyse_tv/data/party/watch_party.dart';
import 'package:vyse_tv/data/sources/addons.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/plugins/js_plugins.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'bed/phase8_pages.dart' show openSettings;
import 'bed/phase9_pages.dart' show room;
import 'harness.dart';

const _repo = 'https://plugins.test/repo.json';

final _repoFile = jsonEncode({
  'name': 'Test plugins',
  'plugins': [
    {'id': 'alpha', 'name': 'Alpha', 'version': '1', 'url': 'alpha.js'},
    {'id': 'beta', 'name': 'Beta', 'version': '1', 'url': 'beta.js', 'types': ['movie']},
  ],
});

const _alpha = PluginEntry(id: 'alpha', name: 'Alpha', url: 'https://plugins.test/alpha.js', version: '1');

/// What Alpha finds on the guest's device: other links than the host's (they're the guest's own),
/// one of them the host's server, quality and language.
const _guestAlpha = [
  {'url': 'https://cdn.test/guest/a.mp4', 'type': 'mp4', 'quality': '1080p', 'server': 'Alpha A', 'audio': 'English'},
  {'url': 'https://cdn.test/guest/b-hindi.mp4', 'type': 'mp4', 'quality': '720p', 'server': 'Alpha B', 'audio': 'Hindi'},
  {'url': 'https://cdn.test/guest/b.mp4', 'type': 'mp4', 'quality': '720p', 'server': 'Alpha B', 'audio': 'English'},
];

/// The host's pick: Alpha's second link (Alpha B, 720p, English), its link only good for them.
AddonPick _hostPick(Media film) {
  final addon = Addon.ofPlugins(const PluginRepoInfo(url: _repo, name: 'Test plugins', plugins: [_alpha]));
  const found = FoundStream(
    url: 'https://cdn.test/host/b.mp4?token=HOSTS-OWN',
    server: 'Alpha B',
    quality: '720p',
    type: 'mp4',
    audio: 'English',
    headers: {'Referer': 'https://alpha.test/'},
  );
  return AddonPick(
    Addons.pluginStream(addon, const PluginHit(_alpha, found, 1)),
    AddonTarget(type: 'movie', tmdb: film.id, title: film.title, year: int.tryParse(film.year ?? '')),
  );
}

/// The host's pick as a guest's device has it, from the room's state.
AddonPick _guestCopy(Media film) => WatchParty.sourcePick(WatchState(media: film, by: 'u0', source: WatchParty.sourceJson(_hostPick(film))))!;

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final desktop = OnScreens([Screens.desktop]);
  late FakeRoute route;
  late Directory dir;
  final served = <String>[];
  final ran = <String>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vyse_party_plugins_');
    PluginRepos.debugDir = dir;
    PluginRepos.debugReset();
    served.clear();
    ran.clear();
    debugPluginEngine = (code, query) async {
      ran.add(code.contains('ALPHA') ? 'Alpha' : 'Beta');
      return {'streams': code.contains('ALPHA') ? _guestAlpha : const [], 'log': const []};
    };
    route = Bed.http.route;
    Bed.http.route = (method, uri) {
      if (uri.host != 'plugins.test' && uri.host != '192.168.1.10') return route(method, uri);
      served.add('${uri.host}${uri.path}');
      if (uri.host != 'plugins.test') return const FakeReply(404, []);
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
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group("the host's plugin stream", () {
    testWidgets('travels as which plugin and which of its links, never the link or its headers; a guest gets the same stream to find', (t) async {
      final film = Bed.freshTitle();
      final host = _hostPick(film);
      final sent = WatchParty.sourceJson(host);
      final text = jsonEncode(sent);
      expect(text, isNot(contains('HOSTS-OWN')), reason: "the host's link stays on the host's device");
      expect(text, isNot(contains('alpha.test')), reason: 'and so do its headers');
      expect(sent['plugin'], containsPair('repo', _repo));
      expect(sent['plugin'], containsPair('id', 'alpha'));
      expect((sent['plugin'] as Map)['index'], 1);
      final copy = _guestCopy(film);
      expect(copy.stream.findHere, isTrue, reason: 'no link: the guest finds their own');
      expect((copy.stream.plugin!.server, copy.stream.plugin!.quality, copy.stream.plugin!.audio), ('Alpha B', '720p', 'English'));
      expect(copy.stream.addon.manifestUrl, _repo, reason: 'the repository, for a guest who has not added it');
      expect(copy.stream.partyKey, host.stream.partyKey, reason: 'the room sees the same stream on both sides');
      expect(copy.target.title, film.title, reason: 'what the plugin is asked by');

      // a Stremio addon's stream still travels as before: its link
      const stremio = Addon(manifestUrl: 'https://addon.test/manifest.json', id: 'org.test', name: 'Test addon', streams: true);
      final plain = WatchParty.sourceJson(AddonPick(AddonStream(addon: stremio, url: 'https://files.test/film.mkv', text: 'Test addon\n1080p'), host.target));
      expect((plain['url'], plain.containsKey('plugin')), ('https://files.test/film.mkv', false));
    }, variant: desktop);

    testWidgets("a guest without the repository runs only the host's plugin, from memory, and gets their own link most like the host's", (t) async {
      final film = Bed.freshTitle();
      final found = await t.runAsync(() => Addons.pluginAgain(_guestCopy(film)));
      expect([for (final p in found!) p.stream.url], [
        'https://cdn.test/guest/b.mp4',
        'https://cdn.test/guest/a.mp4',
        'https://cdn.test/guest/b-hindi.mp4',
      ], reason: 'the same server, quality and language first; a link in the same language before one in another');
      expect(found.first.stream.partyKey, _hostPick(film).stream.partyKey, reason: "it stands for the host's stream in the room");
      expect(ran, ['Alpha'], reason: "only the host's plugin was run");
      expect(served, ['plugins.test/repo.json', 'plugins.test/alpha.js'], reason: "only its list and that one script were fetched (not Beta's)");
      expect(Directory('${dir.path}${Platform.pathSeparator}${PluginRepos.repoKey(_repo)}').existsSync(), isFalse, reason: 'nothing saved on the device');
      expect(Addons.list.value, isEmpty, reason: "and it isn't added to the guest's addons");
    }, variant: desktop);

    testWidgets("when the host's plugin finds nothing here, the repository's others are asked until one does", (t) async {
      final film = Bed.freshTitle();
      debugPluginEngine = (code, query) async {
        ran.add(code.contains('ALPHA') ? 'Alpha' : 'Beta');
        return {
          'streams': code.contains('ALPHA')
              ? const []
              : const [
                  {'url': 'https://cdn.test/guest/beta.mp4', 'type': 'mp4', 'quality': '720p', 'server': 'Beta Main', 'audio': 'English'},
                ],
          'log': const [],
        };
      };
      final found = await t.runAsync(() => Addons.pluginAgain(_guestCopy(film)));
      expect([for (final p in found!) p.stream.url], ['https://cdn.test/guest/beta.mp4']);
      expect(ran, ['Alpha', 'Beta']);
    }, variant: desktop);

    testWidgets("a repository on the guest's own network, or not on the web, is never asked", (t) async {
      expect(PluginRef.fromJson({'repo': 'file:///etc/repo.json', 'id': 'alpha'}), isNull);
      final film = Bed.freshTitle();
      final sent = WatchParty.sourceJson(_hostPick(film));
      (sent['plugin'] as Map<String, Object?>)['repo'] = 'http://192.168.1.10/repo.json';
      final copy = WatchParty.sourcePick(WatchState(media: film, by: 'u0', source: sent))!;
      final found = await t.runAsync(() => Addons.pluginAgain(copy));
      expect(found, isEmpty);
      expect(served, isEmpty, reason: 'nothing was fetched from it');
      expect(ran, isEmpty);
    }, variant: desktop);

    testWidgets("a guest's player runs the host's plugin and opens its own link, never the host's", (t) async {
      final film = Bed.freshTitle();
      Rooms.mine.value = room(0); // someone else's room: you follow its host
      WatchParty.state.value = WatchState(media: film, by: 'u0', source: WatchParty.sourceJson(_hostPick(film)), link: const {'own': true});
      addTearDown(() {
        WatchParty.state.value = null;
        Rooms.mine.value = null;
      });
      Bed.videoCalls.clear();
      await Bed.pumpShell(t);
      unawaited(rootNavigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => PlayerPage(media: film, party: true))));
      bool opened() => Bed.videoCalls.any((c) => c.contains('cdn.test/guest/'));
      for (var i = 0; i < 60 && !opened(); i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await Bed.settle(t, rounds: 1);
      }
      expect(Bed.videoCalls.where((c) => c.contains('cdn.test/guest/b.mp4')), isNotEmpty, reason: 'its own link from Alpha, most like the host\'s');
      expect(Bed.videoCalls.where((c) => c.contains('HOSTS-OWN') || c.contains('cdn.test/host/')), isEmpty, reason: "the host's link is never played here");
      expect(ran, ['Alpha']);
      await Bed.closePlayer(t);
    }, variant: desktop);
  });

  group('Settings > Addons', () {
    testWidgets('says addons give sources only with Streaming mode off; its button turns it off with a remote, and stays put', (t) async {
      AppSettings.streamingMode.set(true);
      addTearDown(() => AppSettings.streamingMode.set(true));
      await openSettings(t, 'Addons');
      await Bed.settle(t, rounds: 2);
      expect(find.text('Streaming mode is on'), findsOneWidget);
      expect(find.textContaining('To use them, turn Streaming mode off'), findsOneWidget);
      // from the Addons tab, Right lands on the button: it's the first thing on the page
      await Bed.right(t);
      final button = find.widgetWithText(Pressable, 'Turn off Streaming mode');
      expect(Bed.nodeOf(t, button).hasPrimaryFocus, isTrue, reason: 'focus is on ${Bed.focused()}');
      expect(Bed.focusInView(), isTrue);
      await Bed.picture(t, 'party_plugins_addons_note_on');
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      expect(AppSettings.streamingMode.value, isFalse, reason: 'OK turned Streaming mode off');
      expect(find.text('Streaming mode is off'), findsOneWidget);
      final back = find.widgetWithText(Pressable, 'Turn Streaming mode back on');
      expect(Bed.nodeOf(t, back).hasPrimaryFocus, isTrue, reason: 'the button stays where it was, and focus with it (on ${Bed.focused()})');
      await Bed.picture(t, 'party_plugins_addons_note_off');
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      expect(AppSettings.streamingMode.value, isTrue, reason: 'and back on');
    }, variant: OnScreens([Screens.desktop, Screens.tv]));

    testWidgets('on a phone the note fits: its button goes under the text', (t) async {
      AppSettings.streamingMode.set(true);
      await openSettings(t, 'Addons');
      await Bed.settle(t, rounds: 2);
      expect(find.text('Streaming mode is on'), findsOneWidget);
      expect(t.takeException(), isNull, reason: 'nothing overflows');
      final text = t.getRect(find.text('Streaming mode is on'));
      final button = t.getRect(find.widgetWithText(Pressable, 'Turn off Streaming mode'));
      expect(button.top, greaterThan(text.bottom), reason: 'the button sits below the text');
      await Bed.picture(t, 'party_plugins_addons_note_phone');
    }, variant: OnScreens([Screens.phone]));
  });
}
