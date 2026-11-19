// Stream info on a desktop (2026-11-19, docs/dpad/PLAN.md note 95): a row at the end of the
// menu's More opens it in the card, as a list; its first row goes back to More. The card keeps
// its six tabs, with More lit while Stream info shows. With a mouse, and with the keyboard.
// The TV's side is t4_journeys_tv9_test.dart and look_tv_info_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/screens/player/player_info.dart';
import 'package:vyse_tv/screens/player/player_menus.dart';

import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  late FakeRoute route;
  setUp(() {
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/first.mkv?token=SECRET123', type: 'mkv')]),
    ];
    route = Bed.http.route;
    Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
  });
  tearDown(() {
    debugFilmSources = null;
    Bed.http.route = route;
  });
  final screen = OnScreens([Screens.laptop]);

  PlayerPanel panel(WidgetTester t) => t.widget<PlayerPanel>(find.byType(PlayerPanel));
  Finder inMenu(Finder what) => find.descendant(of: find.byType(PlayerPanel), matching: what);
  Finder menuList(WidgetTester t) => inMenu(find.byType(Scrollable)).last;

  testWidgets('a desktop: More has Stream info at its end; it opens in the card as a list, and its first row goes back to More', (t) async {
    await Bed.openPlayer(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyS); // Settings, as the dock's button does
    await Bed.settle(t, rounds: 3);
    expect(panel(t).open, isTrue);
    await t.tap(inMenu(find.text('More')));
    await Bed.settle(t, rounds: 3);
    expect(inMenu(find.byType(MenuSegments<MenuTab>)), findsOneWidget);
    expect(t.widget<MenuSegments<MenuTab>>(inMenu(find.byType(MenuSegments<MenuTab>))).options.length, 6, reason: 'the card keeps its six tabs: Stream info has none');

    await t.scrollUntilVisible(find.text('Stream info'), 120, scrollable: menuList(t));
    await Bed.settle(t, rounds: 1);
    await t.tap(find.text('Stream info'));
    await Bed.settle(t, rounds: 3);
    expect(panel(t).tab, MenuTab.info);
    expect(inMenu(find.byType(InfoPane)), findsOneWidget);
    expect(t.widget<MenuSegments<MenuTab>>(inMenu(find.byType(MenuSegments<MenuTab>))).value, MenuTab.more, reason: 'More stays lit: it is where Stream info lives');
    expect(inMenu(find.text('SOURCE')), findsOneWidget);
    expect(inMenu(find.text('First')), findsOneWidget);
    expect(inMenu(find.text('files.test')), findsWidgets, reason: 'the host');
    expect(inMenu(find.textContaining('SECRET123')), findsNothing, reason: 'never the address');
    expect(inMenu(find.text('mpv')), findsWidgets, reason: 'a desktop plays with mpv');
    await Bed.picture(t, 'info/card_stream_info');

    await t.scrollUntilVisible(find.text('Copy report'), 160, scrollable: menuList(t));
    await Bed.settle(t, rounds: 1);
    expect(inMenu(find.text('OUTCOME')), findsOneWidget, reason: 'the report card is the same list, further down');
    await Bed.picture(t, 'info/card_report');
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await t.tap(find.text('Copy report'));
    await Bed.settle(t, rounds: 1);
    expect(copied, contains('VyseTV playback report'));
    expect(copied, contains('Server: files.test'));
    expect(copied, isNot(contains('SECRET123')));

    // back to More, by the list's first row
    await t.drag(menuList(t), const Offset(0, 4000));
    await Bed.settle(t, rounds: 2);
    await t.tap(inMenu(find.byIcon(Icons.arrow_back_rounded)));
    await Bed.settle(t, rounds: 3);
    expect(panel(t).tab, MenuTab.more);
    expect(inMenu(find.byType(InfoPane)), findsNothing);
    expect(inMenu(find.text('Zoom')), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await Bed.settle(t, rounds: 2);
    expect(panel(t).open, isFalse);
    await Bed.closePlayer(t);
  }, variant: screen);

  testWidgets('with the keyboard: OK on the Stream info row opens it with the ring on its first row, and OK there goes back', (t) async {
    await Bed.openPlayer(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    await Bed.settle(t, rounds: 3);
    await t.tap(inMenu(find.text('More')));
    await Bed.settle(t, rounds: 3);
    await Bed.dpadMode(t);
    String row() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<MenuRow>()?.title ?? '';
    for (var i = 0; i < 30 && !(row() == 'Stream info' && panel(t).tab == MenuTab.more); i++) {
      await Bed.down(t);
    }
    expect(row(), 'Stream info', reason: 'Down reaches the last row of More');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(panel(t).tab, MenuTab.info);
    bool inList() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<InfoPane>() != null;
    expect((inList(), row()), (true, 'Stream info'), reason: 'the ring is on the first row of the list, the way back');
    // Down reads the list a group of facts at a time, to its last row
    var stops = 0;
    for (var i = 0; i < 20 && row() != 'Copy report'; i++) {
      await Bed.down(t);
      stops++;
      expect(inList(), isTrue);
    }
    expect(row(), 'Copy report');
    expect(stops, greaterThan(3), reason: 'each group of facts is a stop on the way, so all of it scrolls into view');
    await Bed.up(t, times: stops);
    expect((inList(), row()), (true, 'Stream info'));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(panel(t).tab, MenuTab.more);
    expect(Bed.focused(), allOf(contains('MenuSegments'), contains('More')), reason: 'back in More the ring is on its tab, as when More is opened');
    await Bed.back(t);
    await Bed.closePlayer(t);
  }, variant: screen);
}
