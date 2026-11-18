// T4 for phase 11: the app on a TV (Android TV, Google TV), told apart by its system features.
// The bed is told it is one (TvDetectionService's force-TV switch): what changes there is that
// the app opens in D-pad mode, and that the on-screen keyboard comes up only when asked for.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/details/person_page.dart';
import 'package:vyse_tv/widgets/audiobook_widgets.dart' show ActiveMiniPlayer;
import 'package:vyse_tv/widgets/common.dart';
import 'package:vyse_tv/screens/search/search_page.dart';

import 'bed/phase7_pages.dart' show startMusic, quiet;
import 'harness.dart';

bool _typing() => FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);

  testWidgets('on a TV the app opens in D-pad mode, with the ring on its first control before any key', (t) async {
    expect(PlatformDetector.isTV(), isTrue);
    await Bed.pumpShell(t);
    await Bed.settle(t, rounds: 4);
    expect(find.byType(HomePage), findsOneWidget);
    expect(InputModeTracker.currentMode, InputMode.keyboard, reason: 'no touchscreen and no mouse: D-pad mode from the start');
    debugPrint('TV first focus: ${Bed.focused()}');
    expect(Bed.focused(), isNot('nothing'), reason: 'something has focus before a key is pressed');
    expect(Bed.focused(), isNot(contains('SideRail')), reason: 'on the page, not the navbar');
    expect(Bed.focused(), contains("'Play'"), reason: 'on the hero’s Play, where Home starts (as the first press finds it on a desktop), though the hero loads after Continue watching');
    expect(Bed.focusInView(), isTrue);
    await Bed.picture(t, 'phase11/tv_1_home_opens');
    // the first arrow moves (the ring was already showing, so it is not used up showing it)
    final first = Bed.focused();
    await Bed.down(t);
    expect(Bed.focused(), isNot(first));
  }, variant: tv);

  testWidgets('a video player asks mpv for hardware decoding as it starts (it never did: in software a TV managed a few frames a second)', (t) async {
    Bed.videoCalls.clear();
    await Bed.openPlayer(t);
    final asked = [for (final c in Bed.videoCalls) if (c.startsWith('setProperty') && c.contains('hwdec')) c];
    expect(asked, isNotEmpty, reason: 'calls: ${Bed.videoCalls.take(12).toList()}');
    // (this test runs on Windows, so the answer is auto; on Android it is mediacodec)
    expect(asked.first, contains('auto'));
    final init = Bed.videoCalls.indexWhere((c) => c.startsWith('initialize'));
    final hw = Bed.videoCalls.indexOf(asked.first);
    final open = Bed.videoCalls.indexWhere((c) => c.startsWith('open') || c.startsWith('command {command: [loadfile'));
    expect(init, lessThan(hw), reason: 'asked as the player starts');
    if (open >= 0) expect(hw, lessThan(open), reason: 'before the first file is opened');
    await Bed.closePlayer(t);
  }, variant: tv);

  testWidgets('on a TV the player has no volume control and plays at full volume; subtitles stay put as the controls come and go', (t) async {
    Bed.videoCalls.clear();
    await Bed.openPlayer(t);
    expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Volume'), findsNothing, reason: 'the remote sets a TV’s volume');
    final volumes = [for (final c in Bed.videoCalls) if (c.contains('name: volume')) c];
    expect(volumes, isNotEmpty);
    expect(volumes.last, contains('value: 100'), reason: 'full volume');
    String subs() => [for (final c in Bed.videoCalls) if (c.contains('sub-pos')) c].join(' | ');
    final before = subs();
    // the controls hide by themselves, then OK brings them back
    await t.pump(const Duration(seconds: 5));
    await Bed.settle(t, rounds: 2);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(subs(), before, reason: 'the subtitles were not moved as the controls hid and came back');
    await Bed.closePlayer(t);
  }, variant: tv);

  testWidgets('on a TV there is no floating music bar over the pages (Music has its own)', (t) async {
    await Bed.pumpShell(t);
    await startMusic(t);
    await Bed.settle(t, rounds: 3);
    expect(find.byType(ActiveMiniPlayer), findsNothing);
    await t.pumpWidget(const SizedBox());
    await quiet(t);
  }, variant: tv);

  testWidgets('the rings on a title’s tabs and on a biography’s Read more sit evenly round their words', (t) async {
    await Bed.pumpShell(t);
    await Bed.push(t, DetailsPage(media: Bed.catalogue[81]));
    final tab = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SectionTab').at(1);
    await Bed.focus(t, tab);
    await Bed.settle(t, rounds: 2);
    await Bed.picture(t, 'phase11/ring_title_tab');
    await Bed.back(t);
    await Bed.push(t, const PersonPage(id: 500, name: 'Mara Ellison', profilePath: '/f500.jpg'));
    final more = find.text('Read more');
    if (more.evaluate().isNotEmpty) {
      await Bed.focus(t, find.ancestor(of: more, matching: find.byType(Pressable)).first);
      await Bed.settle(t, rounds: 2);
      await Bed.picture(t, 'phase11/ring_read_more');
    } else {
      debugPrint('(this made-up biography is short: no Read more to look at)');
    }
  }, variant: tv);

  testWidgets('on a TV a text box the arrows come to keeps the keyboard down; OK brings it up; typing works', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'search');
    await Bed.settle(t, rounds: 4);
    expect(find.byType(SearchPage), findsOneWidget);
    if (_typing()) await Bed.down(t); // (off the box, if the page opened in it)
    expect(_typing(), isFalse);
    for (var i = 0; i < 4 && !_typing(); i++) {
      await Bed.up(t);
    }
    expect(_typing(), isTrue, reason: 'Up comes back to the search box');
    expect(t.testTextInput.hasAnyClients, isFalse, reason: 'with the keyboard down');
    await Bed.picture(t, 'phase11/tv_2_search_box_keyboard_down');
    t.testTextInput.log.clear();
    await t.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
    await Bed.settle(t, rounds: 2);
    expect(t.testTextInput.hasAnyClients, isTrue, reason: 'OK: the keyboard');
    expect(t.testTextInput.log.map((c) => c.method), contains('TextInput.show'));
    t.testTextInput.enterText('kite');
    await Bed.settle(t, rounds: 3);
    final box = find.descendant(of: find.byType(SearchPage), matching: find.byType(EditableText)).first;
    expect(t.widget<EditableText>(box).controller.text, 'kite');
  }, variant: tv);
}
