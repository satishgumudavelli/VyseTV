// Media3's hand-over to mpv as a setting (on unless turned off), the title page's Resume, and the
// VyseTV source a title last played from asked first when you carry on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart' show Media;
import 'package:vyse_tv/data/phone_edit/phone_settings.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/data/subtitles/subtitle_style.dart';
import 'package:vyse_tv/mpv/mpv.dart' show Player;
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'bed/fake_net.dart';
import 'bed/phase6_pages.dart' show pressOn;
import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

const _handOver = "Switch to mpv when Media3 can't play";

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final desktop = OnScreens([Screens.desktop]);
  late FakeRoute route;
  final asked = <String>[];
  setUp(() {
    asked.clear();
    FilmSource source(String id) => FilmSource(
      id: id,
      name: id,
      note: '',
      scraper: (_) async {
        asked.add(id);
        return [FoundStream(url: 'http://files.test/$id.mp4', type: 'mp4')];
      },
    );
    debugFilmSources = [source('first'), source('second')];
    route = Bed.http.route;
    Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/mp4') : route(method, uri);
  });
  tearDown(() {
    debugFilmSources = null;
    Bed.http.route = route;
  });

  /// Opens the player on [media] and waits for the first video it opens.
  Future<void> play(WidgetTester t, {Media? media}) async {
    await Bed.openPlayer(t, media: media);
    for (var i = 0; i < 30 && !Bed.videoCalls.any((c) => c.contains('files.test/')) && !Bed.exoCalls.any((c) => c.contains('files.test/')); i++) {
      await Bed.settle(t, rounds: 1);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    }
  }

  group('the hand-over to mpv', () {
    tearDown(() {
      PlayerEngine.debugOffered = null;
      Player.debugExoOnAnyPlatform = false;
      AppSettings.playerEngine.set('');
      AppSettings.mpvHandOver.set(true);
    });

    testWidgets('Settings > Playback on Media3: a switch, on until turned off, worked with a remote; not there on mpv', (t) async {
      PlayerEngine.debugOffered = true;
      AppSettings.playerEngine.set(''); // (not chosen: Media3)
      await openSettings(t, 'Playback');
      await Bed.settle(t, rounds: 2);
      expect(find.text(_handOver), findsOneWidget);
      expect(PlayerEngine.handOver, isTrue, reason: 'on unless turned off, as before');
      final row = find.ancestor(of: find.text(_handOver), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Row'));
      final toggle = find.descendant(of: row.first, matching: find.byType(Pressable));
      expect(toggle, findsOneWidget);
      await pressOn(t, toggle);
      expect(PlayerEngine.handOver, isFalse);
      await pressOn(t, toggle);
      expect(PlayerEngine.handOver, isTrue);
      PlayerEngine.choose(PlayerEngine.mpv);
      await Bed.settle(t, rounds: 2);
      expect(find.text(_handOver), findsNothing, reason: 'mpv has nothing to hand over');
    }, variant: desktop);

    test('the phone page has it too, with Media3', () async {
      PlayerEngine.debugOffered = true;
      AppSettings.playerEngine.set('');
      final item = phoneSections(fonts: const [SubtitleStyle.defaultFont]).expand((s) => s.items).firstWhere((i) => i.id == 'device.handOver');
      expect(item.kind, 'toggle');
      expect((await item.take({'v': false}))?.what, '$_handOver: off');
      expect(PlayerEngine.handOver, isFalse);
    });

    testWidgets('the player tells Media3 as it starts: hand over, or (turned off) say it does not play', (t) async {
      PlayerEngine.debugOffered = true;
      Player.debugExoOnAnyPlatform = true;
      AppSettings.playerEngine.set('');
      String? told() => Bed.exoCalls.where((c) => c.startsWith('setAllowMpvFallback')).lastOrNull;
      Bed.exoCalls.clear();
      await play(t);
      expect(told(), 'setAllowMpvFallback {allow: true}');
      await Bed.closePlayer(t);
      t.takeException(); // (Continue watching hears the progress saved as the player closes)

      AppSettings.mpvHandOver.set(false);
      Bed.exoCalls.clear();
      await play(t);
      expect(told(), 'setAllowMpvFallback {allow: false}');
      await Bed.closePlayer(t);
      t.takeException();
    }, variant: desktop);
  });

  group('carrying on', () {
    testWidgets('a film played from the second source: that source is asked first next time, and stays remembered', (t) async {
      final film = Bed.freshTitle();
      WatchProgress.record(film, position: const Duration(minutes: 12), duration: const Duration(minutes: 100), server: 'second');
      Bed.videoCalls.clear();
      await play(t, media: film);
      expect(asked.first, 'second', reason: 'the source it played from, before the first in your order');
      expect(Bed.videoCalls.where((c) => c.contains('files.test/')).first, contains('files.test/second.mp4'));
      await Bed.closePlayer(t);
      t.takeException();
      expect(WatchProgress.find(film)?.server, 'second');
    }, variant: desktop);

    testWidgets("a title's page offers to carry on: Resume a film; a show's episode, by name, opened with a remote", (t) async {
      final film = Bed.freshTitle();
      WatchProgress.record(film, position: const Duration(minutes: 30), duration: const Duration(minutes: 100));
      await Bed.pumpShell(t);
      await Bed.push(t, DetailsPage(media: film));
      expect(find.widgetWithText(Pressable, 'Resume'), findsOneWidget);
      await Bed.back(t);

      final show = Bed.freshTitle(series: true);
      WatchProgress.record(show, position: const Duration(minutes: 10), duration: const Duration(minutes: 45), season: 2, episode: 3);
      await Bed.push(t, DetailsPage(media: show));
      final resume = find.widgetWithText(Pressable, 'Resume S2:E3');
      expect(resume, findsOneWidget);
      await pressOn(t, resume);
      await Bed.settle(t, rounds: 4);
      final player = t.widget<PlayerPage>(find.byType(PlayerPage));
      expect((player.episode?.season, player.episode?.number), (2, 3));
      await Bed.closePlayer(t);
      t.takeException();
    }, variant: desktop);
  });
}
