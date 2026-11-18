// T3 for the video player at a TV's size and on a phone: the controls, the settings menu and
// the episode list walked with arrows only. (The desktop sizes are in t4_journeys_player_test.)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/walker.dart';
import 'harness.dart';

Future<WalkReport> _walk(WidgetTester t, String what, {bool Function(String label)? ignore}) async {
  final report = await Walker(t, settle: () async {}, isNavbar: (_) => true, ignore: ignore).run(maxPresses: 1500);
  debugPrint('$what: walked ${report.places.length} places in ${report.presses} presses, ${report.problems.length} problem(s)');
  for (final p in report.problems) {
    debugPrint('PROBLEM $p', wrapWidth: 2000);
  }
  return report;
}

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.android));
  final screen = OnScreens(Screens.android);

  testWidgets('a film: the controls and every tab of the menu', (t) async {
    await Bed.openPlayer(t);
    await Bed.down(t);
    // (a narrow screen has its own Play, in the middle of the picture)
    final play = OnScreens.current == Screens.phone ? '_PhoneTransport' : 'PlayKey';
    expect(Bed.focused(), contains(play), reason: 'the controls come up with focus on Play');
    final controls = await _walk(t, 'controls');
    controls.expectClean();
    expect(controls.where(play), isNotEmpty);
    expect(controls.where('PlayerRail'), isNotEmpty);
    expect(controls.where('_Tool').length, greaterThanOrEqualTo(3));

    await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    await Bed.settle(t, rounds: 3);
    expect(FocusManager.instance.primaryFocus?.nearestScope?.debugLabel, 'player menu');
    final menu = await _walk(t, 'menu', ignore: (label) => !label.contains('player_menus.dart'));
    menu.expectClean();
    expect(menu.where('MenuSegments<MenuTab>').length, 6, reason: 'every tab was reached');
    await Bed.closePlayer(t);
  }, variant: screen);

  testWidgets('a series: the controls and the episode list', (t) async {
    await Bed.openPlayer(t, series: true);
    await Bed.down(t);
    (await _walk(t, 'controls')).expectClean();
    await t.sendKeyEvent(LogicalKeyboardKey.keyE);
    await Bed.settle(t, rounds: 4);
    expect(Bed.focused(), contains('_EpisodeRow'));
    final list = await _walk(t, 'episodes', ignore: (label) => !label.contains('EpisodesPanel'));
    list.expectClean();
    expect(list.where('_EpisodeRow').length, greaterThan(3));
    await Bed.closePlayer(t);
  }, variant: screen);
}
