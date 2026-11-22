// Lounges on a desktop: a wide window (the lounges in the side panel, who's in a lounge beside its
// chat), a laptop and a narrow window. Pictures to docs/dpad/pictures/lounges; no layout may
// overflow at any of the sizes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/party/lounges.dart';
import 'package:vyse_tv/screens/party/lounge_page.dart';
import 'package:vyse_tv/screens/party/lounges_view.dart';

import 'bed/fake_lounges.dart';
import 'bed/phase9_pages.dart';
import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screens = OnScreens([Screens.desktop, Screens.laptop, const Screen('narrow', Size(640, 700))]);

  testWidgets('Lounges on a desktop: Party, a lounge, the list', (t) async {
    addTearDown(() {
      FakeLounges.uninstall();
      signOut();
    });
    final problems = await Bed.overflows(() async {
      signIn();
      FakeLounges().install();
      await Bed.pumpShell(t);
      await Bed.openSection(t, 'party');
      await Bed.settle(t, rounds: 5);
      expect(find.widgetWithText(LoungeRow, 'General'), findsOneWidget);
      await Bed.picture(t, 'lounges/w1-party');

      openLounge(Bed.sectionNavigator(t), Lounges.official.value.firstWhere((l) => l.id == 'general')).ignore();
      await Bed.settle(t, rounds: 6);
      expect(find.byType(LoungePage), findsOneWidget);
      await Bed.picture(t, 'lounges/w2-general');
      Bed.sectionNavigator(t).pop();
      await Bed.settle(t, rounds: 4);

      openLoungeList(Bed.sectionNavigator(t)).ignore();
      await Bed.settle(t, rounds: 6);
      expect(find.byType(LoungesPage), findsOneWidget);
      await Bed.picture(t, 'lounges/w3-find');
      Bed.sectionNavigator(t).pop();
      await Bed.settle(t, rounds: 4);
    });
    expect(problems, isEmpty);
  }, variant: screens);
}

