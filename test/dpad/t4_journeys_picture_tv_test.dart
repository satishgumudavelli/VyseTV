// The picture's shape on a TV (2026-11-19, docs/dpad/PLAN.md note 96): Settings > More >
// Picture > Aspect ratio, walked with a remote, on a Media3 player (the bed answers for its
// plugin: Bed.exoCalls). The phone's side is t4_journeys_picture_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/mpv/mpv.dart';
import 'package:vyse_tv/screens/player/player_menus.dart';
import 'package:vyse_tv/screens/player/tv_menus.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  late FakeRoute route;
  setUp(() {
    AppSettings.pictureShape.set('fit');
    // a made-up film source with one link that answers: the player opens it on Media3
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/first.mkv', type: 'mkv')]),
    ];
    route = Bed.http.route;
    Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
  });
  tearDown(() {
    AppSettings.pictureShape.set('fit');
    debugFilmSources = null;
    Bed.http.route = route;
  });
  final tv = OnScreens([Screens.tv]);

  testWidgets('a TV: Aspect ratio is in Settings > More, with the forced shapes; Media3 is told each one', (t) async {
    PlayerEngine.debugOffered = true;
    Player.debugExoOnAnyPlatform = true;
    AppSettings.playerEngine.set('');
    addTearDown(() {
      PlayerEngine.debugOffered = null;
      Player.debugExoOnAnyPlatform = false;
    });
    Bed.exoCalls.clear();
    String row() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<MenuRow>()?.title ?? Bed.focused();
    String rail() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvRail>()?.title ?? '';
    String key() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<Pressable>()?.tooltip ?? '';

    final errors = await Bed.overflows(() async {
      await Bed.openPlayer(t);
      await Bed.exoEvent(t, 'file-loaded');
      await Bed.down(t);
      for (var i = 0; i < 12 && key() != 'Settings (S)'; i++) {
        await Bed.right(t);
      }
      expect(key(), 'Settings (S)');
      expect(find.byTooltip('Turn sideways'), findsNothing, reason: 'no rotate button on a TV');
      await Bed.ok(t);
      await Bed.settle(t, rounds: 2);
      await Bed.right(t, times: 2);
      expect(rail(), 'More');
      expect(find.text('Aspect ratio'), findsOneWidget, reason: 'first in More\'s Picture');
      await Bed.picture(t, 'picture/tv_settings');
      // the segments: Fit Fill Stretch 16:9 4:3 21:9; the ring starts on More's first stop
      for (var i = 0; i < 6 && !Bed.focused().contains("'Fit'"); i++) {
        await Bed.up(t);
      }
      for (var i = 0; i < 6 && !Bed.focused().contains("'Fit'"); i++) {
        await Bed.down(t);
      }
      expect(Bed.focused(), contains("'Fit'"), reason: 'Down reaches the shapes');
      await Bed.right(t, times: 4);
      expect(Bed.focused(), contains("'4:3'"));
      await Bed.ok(t);
      await Bed.settle(t, rounds: 2);
      expect(Bed.exoCalls.where((c) => c.startsWith('setMpvProperty') && c.contains('video-aspect-override') && c.contains('4:3')), isNotEmpty, reason: 'Media3\'s plugin takes the shape from the mpv property');
      expect(AppSettings.pictureShape.value, 'fit', reason: 'a forced shape is not remembered');
      await Bed.picture(t, 'picture/tv_settings_4_3');
      await Bed.left(t, times: 3);
      expect(Bed.focused(), contains("'Fill'"));
      await Bed.ok(t);
      await Bed.settle(t, rounds: 2);
      expect(Bed.exoCalls.where((c) => c.startsWith('setBoxFitMode') && c.contains('mode: 1')), isNotEmpty, reason: 'Fill: Media3 crops its picture frame');
      expect(row(), isNot('Ambient lighting'), reason: 'Media3 offers no ambient lighting');
    });
    expect(errors, isEmpty);
    await Bed.back(t);
    await Bed.closePlayer(t);
  }, variant: tv);
}
