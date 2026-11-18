// The pages of phase 8 (Profile and settings), each opened ready to be walked or photographed.
// Shared by the Windows and the Android files.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/screens/profile/profile_page.dart';
import 'package:vyse_tv/screens/shell/shell.dart';
import 'package:vyse_tv/widgets/common.dart';

import '../harness.dart';
import 'phase6_pages.dart' show pressOn;

typedef Opener = Future<void> Function(WidgetTester t);

/// Opens Profile and settings the way a user does: the avatar at the foot of the rail, or
/// Profile in a phone's bottom bar.
Future<void> openProfile(WidgetTester t) async {
  await Bed.pumpShell(t);
  if (OnScreens.current.size.width < 640) {
    final item = find.descendant(of: find.byType(BottomBar), matching: find.text('Profile'));
    await t.scrollUntilVisible(item, 200, scrollable: find.descendant(of: find.byType(BottomBar), matching: find.byType(Scrollable)));
    await t.tap(item);
  } else {
    await t.tap(find.descendant(of: find.byType(SideRail), matching: find.byType(Avatar)));
  }
  await Bed.settle(t, rounds: 5);
  expect(find.byType(ProfilePage), findsOneWidget);
}

const settingsTabs = ['Account', 'Party profile', 'Appearance', 'Addons', 'Sources', 'Debrid', 'Playback', 'Subtitles', 'About', 'Danger Zone'];

/// Opens settings on [tab].
Future<void> openSettings(WidgetTester t, String tab) async {
  await openProfile(t);
  final control = find.descendant(of: find.byType(ProfilePage), matching: find.widgetWithText(Pressable, tab));
  if (OnScreens.current.size.width < 640) {
    // on a phone the tabs are a row that scrolls sideways and builds only what is in view
    final row = find.descendant(of: find.byType(ProfilePage), matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right));
    await t.scrollUntilVisible(find.descendant(of: row.first, matching: find.text(tab)), 120, scrollable: row.first);
    await t.pump(const Duration(milliseconds: 300));
  }
  await pressOn(t, control.first);
}

final Map<String, Opener> phase8Pages = {
  for (final tab in settingsTabs) 'Settings, $tab': (t) => openSettings(t, tab),
};
