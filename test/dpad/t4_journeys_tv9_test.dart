// Stream info and the report card on a TV (2026-11-19): a tester ran the 111477 films VyseTV
// would not play in another app on the same TV and sent its diagnostics card; the user asked
// for "that info panel thing inside the player too". docs/dpad/PLAN.md note 95 has the round.
//
// The real player page, on a PC, with the bed standing in for the Media3 plugin and for the
// device (Bed.exoAnswers, Bed.deviceAnswers, Bed.exoEvent) and a made-up film source whose link
// carries a token. What the menu looks like, with every fact filled in, is drawn in
// look_tv_info_test.dart; what the report says, in playback_report_test.dart.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/playback/playback_report.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/mpv/mpv.dart';
import 'package:vyse_tv/screens/player/player_info.dart';
import 'package:vyse_tv/screens/player/player_menus.dart';
import 'package:vyse_tv/screens/player/tv_menus.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'bed/phase6_pages.dart' show pressOn;
import 'bed/phase8_pages.dart';
import 'harness.dart';
import 'playback_report_test.dart' show fact, playing, tcl;

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  late FakeRoute route;
  setUp(() {
    PlayerEngine.debugOffered = true;
    Player.debugExoOnAnyPlatform = true;
    AppSettings.playerEngine.set('');
    PlaybackReport.debugReset();
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/first.mkv?token=SECRET123', type: 'mkv')]),
    ];
    route = Bed.http.route;
    Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
    Bed.exoAnswers['getStats'] = playing;
    Bed.deviceAnswers['getPlaybackCapabilities'] = tcl;
  });
  tearDown(() {
    PlayerEngine.debugOffered = null;
    Player.debugExoOnAnyPlatform = false;
    AppSettings.playerEngine.set('');
    debugFilmSources = null;
    Bed.http.route = route;
    Bed.exoAnswers.clear();
    Bed.deviceAnswers.clear();
  });
  final tv = OnScreens([Screens.tv]);

  String key() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<Pressable>()?.tooltip ?? '';
  String row() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<MenuRow>()?.title ?? '';
  String rail() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvRail>()?.title ?? '';
  PlayerPanel panel(WidgetTester t) => t.widget<PlayerPanel>(find.byType(PlayerPanel));
  Finder inMenu(Finder what) => find.descendant(of: find.byType(PlayerPanel), matching: what);

  Future<void> goTo(WidgetTester t, String name) async {
    for (var i = 0; i < 12 && key() != name; i++) {
      await Bed.left(t);
    }
    for (var i = 0; i < 12 && key() != name; i++) {
      await Bed.right(t);
    }
    expect(key(), name);
  }

  /// Everything the report holds, as it is kept on the device.
  String kept() => jsonEncode(PlaybackReport.last.value?.toJson());

  testWidgets('a TV: the last key of the controls opens Stream info over the picture; it says what plays and how, and never the address', (t) async {
    await Bed.openPlayer(t);
    await Bed.exoEvent(t, 'playback-restart'); // Media3 shows the first frame
    await Bed.settle(t, rounds: 2);
    await Bed.down(t); // the controls come up
    await goTo(t, 'Stream info');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect((panel(t).open, panel(t).tab), (true, MenuTab.info));
    expect(inMenu(find.widgetWithText(TvMenuFrame, 'Stream info')), findsOneWidget);
    expect((rail(), row()), ('Show', 'Stream'));
    expect(inMenu(find.text('First')), findsOneWidget, reason: 'the source, by its name');
    expect(inMenu(find.text('files.test')), findsOneWidget, reason: 'the link\'s host');
    expect(inMenu(find.textContaining('SECRET123')), findsNothing, reason: 'and nothing else of the link');
    expect(inMenu(find.text('Media3')), findsOneWidget);
    expect(inMenu(find.text('Dolby Vision, profile 5')), findsOneWidget, reason: 'what the plugin says of the picture');
    expect(inMenu(find.text('E-AC-3')), findsOneWidget);
    await Bed.picture(t, 'tv9/stream_info');

    await Bed.down(t);
    await Bed.settle(t, rounds: 1);
    expect(row(), 'Report card');
    expect(inMenu(find.text('TCL Smart TV Pro · Android 12')), findsOneWidget, reason: 'what the TV says of itself');
    expect(inMenu(find.text('4452 ms')), findsOneWidget, reason: 'Media3\'s own count to the first frame');
    expect(inMenu(find.text('Played on Media3')), findsOneWidget);
    await Bed.picture(t, 'tv9/report_card');

    await Bed.back(t);
    expect(panel(t).open, isFalse, reason: 'Back closes it, like any menu');
    expect(key(), 'Stream info', reason: 'onto its key');

    // and from Settings: the last row of More
    await goTo(t, 'Settings (S)');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 2);
    await Bed.right(t, times: 2);
    expect(rail(), 'More');
    for (var i = 0; i < 16 && row() != 'Stream info'; i++) {
      await Bed.down(t);
    }
    expect(row(), 'Stream info');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect((panel(t).open, panel(t).tab), (true, MenuTab.info));
    expect((rail(), row()), ('Show', 'Stream'), reason: 'the ring goes to where the new menu starts');
    await Bed.back(t);
    expect(panel(t).open, isFalse);
    expect(key(), 'Settings (S)', reason: 'Back closes onto the key that opened the menus');

    expect(kept(), isNot(contains('SECRET123')), reason: 'nor is the address kept on the device');
    await Bed.closePlayer(t);
  }, variant: tv);

  testWidgets('a film Media3 hands to mpv: the card says what for, and Settings still has it after the player has closed', (t) async {
    await Bed.openPlayer(t);
    await t.pump(const Duration(seconds: 5));
    Bed.exoAnswers.remove('getStats'); // (from here it is mpv that answers, with nothing yet)
    await Bed.exoEvent(t, 'backend-switched', {
      'kind': 'video',
      'reason': 'Decoder hang: c2.mtk.dvhe.stn.decoder accepted input but produced no output',
      'detail': 'Decoder hang: c2.mtk.dvhe.stn.decoder took 3 frames and showed none in 5012ms, with 8200ms of http://files.test/first.mkv?token=SECRET123 waiting',
      'afterMs': 6210,
      'stats': {...playing, 'firstFrameMs': null},
    });
    expect(find.text("Media3 can't play this picture · using mpv"), findsOneWidget);

    await Bed.down(t);
    await goTo(t, 'Stream info');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(inMenu(find.text('mpv, after Media3 could not play the picture')), findsOneWidget);
    await Bed.down(t);
    await Bed.settle(t, rounds: 1);
    expect(inMenu(find.text('Media3 could not play the picture after 6.2 s and handed it to mpv, which has not shown a picture')), findsOneWidget);
    expect(inMenu(find.textContaining('took 3 frames and showed none in 5012ms, with 8200ms of files.test waiting')), findsOneWidget, reason: 'in the plugin\'s own words, with the address cut to its host');
    expect(inMenu(find.text('c2.mtk.dvhe.stn.decoder')), findsOneWidget, reason: 'what Media3 knew of the video stays on the card');
    await Bed.picture(t, 'tv9/report_card_handed_over');
    await Bed.back(t);
    await Bed.closePlayer(t);

    final last = PlaybackReport.last.value!;
    expect(last.summary, endsWith('handed to mpv'));
    expect(fact(last.card, 'Outcome', 'What Media3 said'), contains('showed none in 5012ms'));
    expect(last.toJson()['closedAfterMs'], isNotNull, reason: 'the report outlives the player');
    expect(kept(), isNot(contains('SECRET123')));

    // Settings > Playback on a TV: the last playback, and its card
    await openSettings(t, 'Playback');
    await Bed.settle(t, rounds: 2);
    expect(find.text('Last playback'), findsOneWidget);
    expect(find.textContaining('handed to mpv'), findsOneWidget);
    await pressOn(t, find.widgetWithText(Pressable, 'Report card'));
    await Bed.settle(t, rounds: 3);
    expect(find.text('Take a photo of this card when you report a problem.'), findsOneWidget);
    expect(find.byType(FactColumn), findsNWidgets(3));
    expect(find.textContaining('handed it to mpv'), findsOneWidget);
    await Bed.picture(t, 'tv9/settings_last_playback');
    await Bed.back(t);
    await Bed.settle(t, rounds: 2);
    expect(find.text('Take a photo of this card when you report a problem.'), findsNothing, reason: 'Back closes the card');
  }, variant: tv);

  testWidgets('a link that never starts is on record too: closed with no picture', (t) async {
    Bed.exoAnswers.remove('getStats');
    await Bed.openPlayer(t);
    await t.pump(const Duration(seconds: 8));
    await Bed.closePlayer(t);
    final last = PlaybackReport.last.value!;
    expect(last.source, 'First');
    expect(last.host, 'files.test');
    expect(last.result, startsWith('Closed after '));
    expect(last.result, endsWith('with no picture'));
    expect(fact(last.card, 'Source and hardware', 'Device'), 'TCL Smart TV Pro · Android 12');
  }, variant: tv);
}
