// T5 for phase 2: real pages with focus put on a control from code (arrows do not move focus
// between regions until phase 3), saved to docs/dpad/pictures/phase2 to be looked at.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/discover/discover_page.dart';
import 'package:vyse_tv/widgets/common.dart';
import 'package:vyse_tv/widgets/media_rows.dart';

import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));

  testWidgets('Home: the hero\'s Play, a Continue watching card, a poster', (t) async {
    await Bed.pumpShell(t);
    await Bed.dpadMode(t);
    await Bed.focus(t, find.byType(Pressable).first);
    final play = find.ancestor(of: find.text('Play'), matching: find.byType(Pressable)).first;
    await Bed.focus(t, play);
    await Bed.picture(t, 'phase2/home_play');
    await Bed.focus(t, find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ResumeCard').at(1));
    await Bed.picture(t, 'phase2/home_continue');
    await Bed.focus(t, find.byType(LandscapeCard).at(1));
    await Bed.picture(t, 'phase2/home_landscape');
    await Bed.focus(t, find.byType(PosterCard).at(2));
    await Bed.picture(t, 'phase2/home_poster');
  }, variant: OnScreens(Screens.windows));

  testWidgets('Discover: a chip and a grid card; Details: its buttons', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'discover');
    await Bed.dpadMode(t);
    final inPage = find.descendant(of: find.byType(DiscoverPage), matching: find.byType(Pressable));
    await Bed.focus(t, inPage.at(1));
    await Bed.picture(t, 'phase2/discover_chip');
    await Bed.focus(t, inPage.at(22));
    await Bed.picture(t, 'phase2/discover_card');
    await Bed.push(t, DetailsPage(media: Bed.catalogue[0]));
    await Bed.dpadMode(t);
    final onDetails = find.descendant(of: find.byType(DetailsPage), matching: find.byType(Pressable));
    await Bed.focus(t, find.ancestor(of: find.text('Play'), matching: find.byType(Pressable)).last);
    await Bed.picture(t, 'phase2/details_play');
    await Bed.focus(t, onDetails.first);
    await Bed.picture(t, 'phase2/details_back');
  }, variant: OnScreens(Screens.windows));
}
