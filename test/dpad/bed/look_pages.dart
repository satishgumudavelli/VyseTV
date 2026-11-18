// The pictures taken for looking at (T5), shared by the Windows and the Android file: each
// page with focus where a D-pad first lands, and part-way along a row or a grid. Reached with
// arrow keys only.
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/details/person_page.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/screens/player/sources_page.dart';
import 'package:vyse_tv/widgets/dialogs/p2p_consent.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../harness.dart';
import 'phase6_pages.dart';
import 'phase7_pages.dart';
import 'phase8_pages.dart';
import 'phase9_pages.dart';

Future<void> lookAtPhase3(WidgetTester t) async {
  final phone = OnScreens.current.size.width < 640;
  await Bed.pumpShell(t);
  await Bed.down(t);
  await Bed.picture(t, 'phase3/home_1_first_focus');
  await Bed.down(t);
  await Bed.right(t, times: 2);
  await Bed.picture(t, 'phase3/home_2_continue_watching');
  await Bed.down(t);
  await Bed.right(t, times: 3);
  await Bed.picture(t, 'phase3/home_3_mid_row');
  await Bed.down(t, times: 2);
  await Bed.picture(t, 'phase3/home_4_posters');
  if (phone) {
    await Bed.down(t, times: 14);
    await Bed.picture(t, 'phase3/home_5_navbar');
    await Bed.right(t, times: 3);
    await Bed.ok(t);
  } else {
    await Bed.left(t, times: 8);
    await Bed.picture(t, 'phase3/home_5_navbar');
    await Bed.down(t, times: 3);
    await Bed.picture(t, 'phase3/home_6_navbar_movies');
    await Bed.ok(t);
  }
  await Bed.picture(t, 'phase3/movies_1_first_focus');
  await Bed.down(t, times: 2);
  await Bed.right(t, times: 2);
  await Bed.picture(t, 'phase3/movies_2_grid');
  await Bed.down(t, times: 3);
  await Bed.picture(t, 'phase3/movies_3_grid_lower');

  await Bed.pumpShell(t);
  await Bed.openSection(t, 'list');
  await Bed.down(t);
  await Bed.picture(t, 'phase3/list_1_first_focus');
  await Bed.down(t, times: 2);
  await Bed.right(t);
  await Bed.picture(t, 'phase3/list_2_card_button');

  await Bed.pumpShell(t);
  await Bed.openSection(t, 'history');
  await Bed.down(t, times: 3);
  await Bed.picture(t, 'phase3/history_1_row');
  await Bed.right(t, times: 2);
  await Bed.picture(t, 'phase3/history_2_row_button');
}

Future<void> lookAtPhase4(WidgetTester t) async {
  await Bed.pumpShell(t);
  await Bed.push(t, DetailsPage(media: Bed.catalogue[0]));
  await Bed.down(t);
  await Bed.picture(t, 'phase4/film_1_first_focus');
  await Bed.down(t, times: 2);
  await Bed.right(t, times: 2);
  await Bed.picture(t, 'phase4/film_2_cast');

  await Bed.pumpShell(t);
  await Bed.push(t, DetailsPage(media: Bed.catalogue[81]));
  await Bed.down(t);
  for (var i = 0; i < 8 && !Bed.focused().contains('Play E'); i++) {
    await Bed.down(t);
  }
  await Bed.right(t, times: 2);
  await Bed.settle(t, rounds: 2);
  await Bed.picture(t, 'phase4/series_1_episode_picker');

  await Bed.pumpShell(t);
  await Bed.push(t, const PersonPage(id: 500, name: 'Mara Ellison', profilePath: '/f500.jpg'));
  await Bed.down(t, times: 3);
  await Bed.picture(t, 'phase4/person_1');

  // (at a TV's width this page's own header row overflows by 19 px: see t3_walk_title_android)
  await Bed.overflows(() async {
    await Bed.pumpShell(t);
    await Bed.push(t, SourcesPage(media: Bed.catalogue[0]));
    await Bed.down(t, times: 2);
    await Bed.picture(t, 'phase4/sources_1');
  });

  await Bed.pumpShell(t);
  await Bed.openSection(t, 'search');
  // a word of its own per screen: an answer fetched during one test never arrives in the next
  t.testTextInput.enterText('night ${OnScreens.current.name}');
  await t.sendKeyEvent(LogicalKeyboardKey.enter);
  await Bed.settle(t);
  await Bed.picture(t, 'phase4/search_1_typing');
  await Bed.down(t, times: 2);
  await Bed.picture(t, 'phase4/search_2_results');

  await Bed.pumpShell(t);
  await Bed.down(t, times: 2);
  final was = AppSettings.p2pStreaming.value;
  AppSettings.p2pStreaming.value = false;
  allowP2p(FocusManager.instance.primaryFocus!.context!).ignore();
  await Bed.settle(t, rounds: 4);
  await Bed.right(t);
  await Bed.picture(t, 'phase4/dialog_p2p_allow');
  await Bed.back(t);
  AppSettings.p2pStreaming.value = was;
}

/// The video player (with a stand-in for the video: see Bed.openPlayer) with focus on it.
Future<void> lookAtPhase5(WidgetTester t) async {
  final phone = OnScreens.current.size.width < 640;
  await Bed.openPlayer(t);
  await Bed.down(t);
  await Bed.picture(t, 'phase5/player_1_controls');
  await Bed.up(t);
  await Bed.picture(t, 'phase5/player_2_seek_bar');
  await Bed.up(t, times: 3);
  await Bed.picture(t, 'phase5/player_3_top');
  await t.sendKeyEvent(LogicalKeyboardKey.keyS);
  await Bed.settle(t, rounds: 3);
  await Bed.picture(t, 'phase5/player_4_menu_sources');
  await Bed.back(t);
  await t.sendKeyEvent(LogicalKeyboardKey.keyC);
  await Bed.settle(t, rounds: 3);
  await Bed.picture(t, 'phase5/player_5_menu_subtitles');
  await Bed.up(t);
  await Bed.ok(t);
  await Bed.settle(t, rounds: 3);
  await Bed.picture(t, 'phase5/player_6_subtitle_sync');
  await Bed.closePlayer(t);

  await Bed.openPlayer(t, series: true);
  await Bed.down(t);
  await t.sendKeyEvent(LogicalKeyboardKey.keyE);
  await Bed.settle(t, rounds: 4);
  await Bed.picture(t, 'phase5/player_7_episodes');
  await Bed.down(t, times: 3);
  await Bed.picture(t, 'phase5/player_8_episodes_down');
  await Bed.closePlayer(t);

  if (phone) return; // the small window is reached from the side rail, which a phone has not got
  await Bed.openPlayer(t);
  await t.sendKeyEvent(LogicalKeyboardKey.keyM);
  await Bed.settle(t, rounds: 5);
  await Bed.down(t);
  await Bed.left(t, times: 25);
  for (var i = 0; i < 20 && !Bed.focused().contains('_RailFloating'); i++) {
    await Bed.down(t);
  }
  await Bed.ok(t);
  await Bed.picture(t, 'phase5/mini_1_focus');
  MiniPlayer.close();
  await Bed.settle(t, rounds: 3);
}

/// Anime, Live TV, Downloads and Servers with focus on them (the bed has content: see
/// Bed.withContent). Each page as a D-pad first meets it, then a few presses in.
Future<void> lookAtPhase6(WidgetTester t) async {
  for (final page in phase6Pages.entries) {
    await page.value(t);
    final name = page.key.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');
    await Bed.down(t);
    await Bed.picture(t, 'phase6/${name}_1');
    await Bed.down(t, times: 2);
    await Bed.right(t);
    await Bed.picture(t, 'phase6/${name}_2');
    t.takeException(); // (the channel page's own, see takeKnownChannelPageError)
    // a fresh app for the next page: a box left open would sit over it
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Music, Manga and Audiobooks, their players and the reader, with focus on them.
Future<void> lookAtPhase7(WidgetTester t) async {
  for (final page in phase7Pages.entries) {
    if (cannotBeBuiltHere(page.key)) continue;
    Future<void> look() async {
      await page.value(t);
      final name = page.key.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');
      await Bed.dpadMode(t);
      await Bed.settle(t, rounds: 2);
      if (page.key.contains('reader')) await Bed.ok(t);
      await Bed.down(t);
      await Bed.picture(t, 'phase7/${name}_1');
      await Bed.down(t, times: 2);
      await Bed.right(t);
      await Bed.picture(t, 'phase7/${name}_2');
      await quiet(t);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(milliseconds: 100));
    }

    // Music's own player bar is a fixed 528 points wide in its middle: in a window narrower
    // than about 1340 its row is too wide by a few dozen points while a song is on, with or
    // without a D-pad. A layout matter on the plan's follow-up list, not something to hide.
    final barTooWide = page.key == 'Music, with a song on' && OnScreens.current.size.width >= 1100 && OnScreens.current.size.width < 1340;
    if (barTooWide) {
      await Bed.overflows(look);
    } else {
      await look();
    }
  }
}

/// Profile and settings, every group, with focus on it.
Future<void> lookAtPhase8(WidgetTester t) async {
  for (final page in phase8Pages.entries) {
    await page.value(t);
    final name = page.key.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');
    await Bed.picture(t, 'phase8/${name}_1_tab');
    // into what the tab shows (beside the tabs on a wide screen, under them on a phone)
    await (OnScreens.current.size.width < 640 ? Bed.down(t) : Bed.right(t));
    await Bed.down(t, times: 2);
    await Bed.picture(t, 'phase8/${name}_2');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> lookAtPhase9(WidgetTester t) async {
  addTearDown(signOut);
  for (final page in phase9Pages.entries) {
    await page.value(t);
    await Bed.dpadMode(t);
    await Bed.settle(t, rounds: 2);
    final name = page.key.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');
    await Bed.picture(t, 'phase9/${name}_1_first_focus');
    await Bed.down(t);
    await Bed.right(t);
    await Bed.picture(t, 'phase9/${name}_2_down_right');
    await Bed.up(t, times: 2);
    await Bed.left(t);
    await Bed.picture(t, 'phase9/${name}_3_up_left');
    if (page.key == 'Party, a room') {
      // someone in the room, and the menu OK opens on them
      final people = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Tile');
      if (people.evaluate().length > 1) {
        await Bed.focus(t, people.at(1));
        await Bed.picture(t, 'phase9/${name}_4_someone');
        await Bed.ok(t);
        await Bed.settle(t, rounds: 4);
        await Bed.down(t);
        await Bed.left(t);
        await Bed.picture(t, 'phase9/${name}_5_their_menu');
        await Bed.back(t);
        await Bed.settle(t, rounds: 3);
      }
      final bar = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_RoundToggle');
      if (bar.evaluate().isNotEmpty) {
        await Bed.focus(t, bar.first);
        await Bed.right(t);
        await Bed.picture(t, 'phase9/${name}_6_voice_bar');
      }
    }
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 100));
    signOut();
  }
}
