// Stream info and the report card on a TV (lib/screens/player/player_info.dart), drawn at a
// TV's size over a made-up picture, for the pictures in docs/dpad/pictures/tvinfo, and walked
// with a remote. The values are the ones a tester photographed in another app on a TCL TV
// (docs/dpad/PLAN.md note 95). The menu is the player's own (PlayerPanel, InfoPane); only the
// player behind it is left out. The real page's journey is in t4_journeys_tv9_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/playback/playback_report.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';
import 'package:vyse_tv/screens/player/player_info.dart';
import 'package:vyse_tv/screens/player/player_menus.dart';
import 'package:vyse_tv/screens/player/tv_menus.dart';

import 'harness.dart';
import 'playback_report_test.dart' show begin, playing, tcl;

class _Picture extends StatelessWidget {
  const _Picture();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2B5F8A), Color(0xFFE0A458), Color(0xFFB5462F), Color(0xFF3C2A4D)],
        stops: [0, .45, .7, 1],
      ),
    ),
    child: Align(
      alignment: Alignment(0, .86),
      child: Text('Accessing previous files relating to program VisionQuest.', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white, shadows: [Shadow(blurRadius: 4)])),
    ),
  );
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);
  final region = DpadRegionNode();
  final report = ValueNotifier<PlaybackReport?>(null);
  var refreshed = 0;

  Future<void> show(WidgetTester t) async {
    refreshed = 0;
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(Bed.app(Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const _Picture(),
          DpadRegion(
            node: region,
            child: PlayerPanel(
              open: true,
              tab: MenuTab.info,
              onTab: (_) {},
              side: 32,
              top: 0,
              dockH: 118,
              body: (fit) => InfoPane(report: report, onRefresh: () => refreshed++),
              bodyOf: (tab, fit) => InfoPane(report: report, onRefresh: () => refreshed++),
              value: (_) => report.value?.title ?? '',
            ),
          ),
        ],
      ),
    )));
    await Bed.settle(t, rounds: 3);
    await Bed.dpadMode(t);
    final start = Dpad.firstStop(region);
    expect(start, isNotNull, reason: 'the menu has somewhere to start');
    Dpad.giveFocus(start!);
    await Bed.settle(t, rounds: 2);
  }

  String ring() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<MenuRow>()?.title ?? Bed.focused();

  /// The captions of the fact columns showing, left to right.
  List<String> captions(WidgetTester t) => [
    for (final c in t.widgetList<FactColumn>(find.byType(FactColumn)))
      for (final s in c.sections)
        if (s.facts.isNotEmpty) s.title,
  ];

  testWidgets('Stream info: the whole screen, in columns; the ring on Report card shows the card', (t) async {
    report.value = begin().withDevice(tcl).withMedia3(playing).withAudio(language: 'English').withSubtitle(name: 'en', language: 'English', origin: 'Inside the file');
    final errors = await Bed.overflows(() async {
      await show(t);
      expect(find.widgetWithText(TvMenuFrame, 'Stream info'), findsOneWidget);
      expect(find.text('The Body · S1 E1'), findsOneWidget, reason: 'what is playing, beside the menu\'s name');
      expect(ring(), 'Stream', reason: 'it opens on the stream');
      expect(captions(t), ['Source', 'Player engine', 'Video', 'Audio', 'Subtitle']);
      expect(find.text('Dolby Vision, profile 5'), findsOneWidget);
      expect(find.text('cdn-7f3a.example.net'), findsOneWidget);
      expect(find.textContaining('token'), findsNothing, reason: 'the host, never the address');
      expect(refreshed, greaterThan(0), reason: 'the player is read again when the menu opens');
      await Bed.picture(t, 'tvinfo/stream');

      await Bed.down(t);
      await Bed.settle(t, rounds: 1);
      expect(ring(), 'Report card');
      expect(captions(t), ['Source and hardware', 'Decision', 'Outcome'], reason: 'the ring on a view shows it at once');
      expect(find.text('Take a photo of this screen when you report a problem.'), findsOneWidget);
      expect(find.text('c2.mtk.dvhe.stn.decoder (P5)\nc2.mtk.dvhe.st.decoder (P8)'), findsOneWidget);
      expect(find.text('4452 ms'), findsOneWidget);
      expect(find.text('Played on Media3'), findsOneWidget);
      await Bed.picture(t, 'tvinfo/card_played');

      await Bed.right(t);
      expect(ring(), 'Report card', reason: 'the facts are to read: there is nothing to press beside the views');
      await Bed.up(t);
      await Bed.settle(t, rounds: 1);
      expect(ring(), 'Stream');
      expect(captions(t).first, 'Source');
      final before = refreshed;
      await t.pump(const Duration(seconds: 5));
      expect(refreshed, greaterThan(before), reason: 'and again while it stays open: the numbers are live');
    });
    expect(errors, isEmpty, reason: 'nothing runs off its column at a TV\'s size');
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  testWidgets('the report card of a film Media3 handed to mpv says what for, in full', (t) async {
    final gaveUp = Map<String, Object?>.of(playing)..remove('firstFrameMs');
    report.value = begin().withDevice(tcl).withMedia3(gaveUp).withHandOver(
      kind: 'stream',
      reason: 'Source error',
      detail: 'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT (2002) · Source error · SocketTimeoutException: timeout',
      afterMs: 43100,
    );
    final errors = await Bed.overflows(() async {
      await show(t);
      expect(find.text('mpv, after Media3 lost the stream'), findsOneWidget);
      await Bed.picture(t, 'tvinfo/stream_handed_over');
      await Bed.down(t);
      await Bed.settle(t, rounds: 1);
      expect(find.text('Media3 lost the stream after 43 s and handed it to mpv, which has not shown a picture'), findsOneWidget);
      expect(find.textContaining('ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT (2002)'), findsOneWidget);
      await Bed.picture(t, 'tvinfo/card_handed_over');
    });
    expect(errors, isEmpty);
    // the tallest card there is: every fact that can be there, the longest words for each
    final card = t.getRect(find.byType(FactColumn).last);
    expect(card.bottom, lessThanOrEqualTo(540 - TvMenuFrame.edge.bottom + 1), reason: 'it ends above the strip the film\'s subtitles are in');
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  testWidgets('nothing opened yet: it says so', (t) async {
    report.value = null;
    await show(t);
    expect(find.text('Nothing has been opened yet.'), findsOneWidget);
    expect(ring(), 'Stream');
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  testWidgets('Settings shows the last playback\'s card in a box, with a way out', (t) async {
    final last = begin().withDevice(tcl).withMedia3(playing).closed(26000);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(Bed.app(Scaffold(
      body: Builder(
        builder: (context) => Center(child: TextButton(onPressed: () => showReportCard(context, last), child: const Text('open'))),
      ),
    )));
    await Bed.settle(t, rounds: 2);
    final errors = await Bed.overflows(() async {
      await t.tap(find.text('open'));
      await Bed.settle(t, rounds: 3);
      expect(find.text('Take a photo of this card when you report a problem.'), findsOneWidget);
      expect(find.text('TCL Smart TV Pro · Android 12'), findsOneWidget);
      expect(find.text('Played on Media3'), findsOneWidget);
      await Bed.picture(t, 'tvinfo/settings_card');
    });
    expect(errors, isEmpty);
    await t.tap(find.text('Close'));
    await Bed.settle(t, rounds: 2);
    expect(find.text('Take a photo of this card when you report a problem.'), findsNothing);
    await t.pumpWidget(const SizedBox());
  }, variant: tv);
}
