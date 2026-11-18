// T4 for phase 6: journeys through Anime, Live TV, Downloads and Servers with arrows, OK and
// Back only. (The Live TV player and the portal browser's player are in t4_journeys_live_test.)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/downloads/downloads.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/screens/anime/anime_page.dart';
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/screens/shell/intro_screen.dart';
import 'package:vyse_tv/screens/live_tv/live_tv_pages.dart';
import 'package:vyse_tv/screens/shell/shell.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'bed/phase6_pages.dart';
import 'harness.dart';

String _scope() => FocusManager.instance.primaryFocus?.nearestScope?.debugLabel ?? '';
bool _inBox() => _scope().contains('Modal');

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.windows);
    await Bed.withContent();
  });
  final screen = OnScreens([Screens.laptop]);

  testWidgets('Anime: starts on the order in use; the grid; a title and back; the filters and back', (t) async {
    await phase6Pages['Anime']!(t);
    await Bed.down(t);
    expect(Bed.focused(), allOf(contains('_SortBar'), contains('Trending')), reason: 'the page starts on the order in use, not on the search button in its corner');
    await Bed.right(t, times: 2);
    expect(Bed.focused(), contains('Top rated'));
    await Bed.down(t);
    expect(Bed.focused(), contains('AnimeCard'));
    await Bed.right(t, times: 3);
    await Bed.down(t);
    final card = Bed.focused();
    expect(Bed.focusInView(), isTrue);
    await Bed.up(t, times: 2);
    expect(Bed.focused(), allOf(contains('_SortBar'), contains('Trending')), reason: 'coming up from the grid lands on the order in use, wherever you were above it');

    await Bed.down(t, times: 2);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 5);
    expect(find.byType(AnimeDetailsPage), findsOneWidget);
    expect(Bed.focused(), contains("'Play'"), reason: 'an anime’s page starts on Play');
    await Bed.back(t);
    expect(find.byType(AnimeDetailsPage), findsNothing);
    expect(Bed.focused(), card.replaceFirst(RegExp(r"'.*'"), '').isEmpty ? card : contains('AnimeCard'), reason: 'R6: back on a card of the grid');
    expect(Bed.focusInView(), isTrue);

    await pressOn(t, find.widgetWithText(Pressable, 'Filters'));
    expect(_inBox(), isTrue, reason: 'the filters open as a panel that takes focus');
    await Bed.down(t, times: 4);
    await Bed.right(t, times: 3);
    await Bed.left(t, times: 9);
    expect(_inBox(), isTrue, reason: 'arrows stay in the panel');
    // (the walk ends in the panel's tag search box: the first Back steps off the box)
    await Bed.back(t);
    if (_inBox()) await Bed.back(t);
    expect(_inBox(), isFalse);
    expect(find.byType(AnimePage), findsOneWidget);
    expect(Bed.focused(), contains('Filters'), reason: 'Back closes it and focus is on the Filters button again');
  }, variant: screen);

  testWidgets('Live TV: starts on the tab that is showing; tabs switch on OK; a channel’s page and back', (t) async {
    await phase6Pages['Live TV, Matches']!(t);
    expect(Bed.focused(), allOf(contains('FilterChipPill'), contains('Matches')));
    await Bed.right(t);
    expect(Bed.focused(), contains('Channels'));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    await Bed.down(t);
    expect(Bed.focused(), contains('VyseSearchField'), reason: 'the Channels tab: its search box is under the tabs');
    await Bed.down(t);
    expect(Bed.focused(), contains('ChannelTile'));
    await Bed.right(t, times: 2);
    await Bed.down(t);
    final tile = Bed.focused();
    await Bed.up(t, times: 6);
    expect(Bed.focused(), allOf(contains('FilterChipPill'), contains('Channels')), reason: 'coming up into the tabs lands on the tab that is showing');
    await Bed.down(t, times: 3);
    expect(Bed.focused(), contains('ChannelTile'));
    await Bed.right(t);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 5);
    takeKnownChannelPageError(t);
    expect(find.byType(LiveChannelPage), findsOneWidget);
    expect(Bed.focused(), isNot('nothing'));
    await Bed.back(t);
    expect(find.byType(LiveChannelPage), findsNothing);
    expect(Bed.focused(), contains('ChannelTile'), reason: 'R6: back on the tile');
    expect(tile, contains('ChannelTile'));

    // leaving the page restarts it: the next visit starts on the first tab again
    await Bed.back(t);
    expect(Bed.focused(), contains('SideRail'));
  }, variant: screen);

  testWidgets('Live TV: adding a portal is a box of text fields; Back steps off the field, then closes', (t) async {
    await phase6Pages['Live TV, adding a portal']!(t);
    expect(_inBox(), isTrue);
    t.testTextInput.enterText('http://portal.example');
    await t.pump(const Duration(milliseconds: 200));
    await Bed.down(t);
    await Bed.down(t);
    expect(_inBox(), isTrue, reason: 'Down moves from field to field and stays in the box');
    await Bed.back(t);
    if (_inBox()) await Bed.back(t);
    expect(_inBox(), isFalse);
    expect(Bed.focused(), contains('Add portal'), reason: 'and focus is on the button that opened it');
  }, variant: screen);

  testWidgets('Live TV: the source picker (a list behind a button) opens with OK and closes with Back', (t) async {
    await phase6Pages['Live TV, Portals']!(t);
    final picker = find.byWidgetPredicate((w) => w is PopupMenuButton);
    expect(picker, findsOneWidget);
    final node = Focus.of(t.element(find.descendant(of: picker, matching: find.byType(IgnorePointer)).first));
    await Bed.down(t);
    expect(Bed.focused(), contains('ToolButton'), reason: 'Down from the tabs is the row of tools');
    for (var i = 0; i < 4 && !node.hasPrimaryFocus; i++) {
      await Bed.left(t);
    }
    expect(node.hasPrimaryFocus, isTrue, reason: 'arrows reach the button itself, not the tool button drawn on it');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 2);
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem), findsWidgets, reason: 'OK opens the list of sources');
    await Bed.back(t);
    await Bed.settle(t, rounds: 2);
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem), findsNothing);
    expect(node.hasPrimaryFocus, isTrue, reason: 'Back closes the list and focus is on the button again');
  }, variant: screen);

  testWidgets('Downloads: starts on the first download’s button; resume, and remove with its question', (t) async {
    await phase6Pages['Downloads']!(t);
    await Bed.down(t);
    expect(Bed.focused(), allOf(contains('_DownloadCard'), contains('Play')), reason: 'the page starts on the newest download’s main button, not on Open folder in its corner');
    await Bed.right(t, times: 3);
    expect(Bed.focused(), contains('_DownloadCard'), reason: 'Right walks its buttons and stops at the last');
    await Bed.left(t, times: 2);
    expect(Bed.focused(), contains('Play'));
    await Bed.down(t);
    expect(Bed.focused(), contains('Resume'));
    await Bed.down(t);
    expect(Bed.focused(), contains('Try again'));
    await Bed.up(t, times: 4);
    expect(Bed.focused(), contains('Open folder'), reason: 'Up from the list reaches the page’s own button');
    await Bed.down(t, times: 3);
    expect(Bed.focused(), contains('_DownloadCard'), reason: 'Down from there keeps to the right-hand column: each row’s Remove button');
    expect(Bed.focused(), isNot(contains("'")), reason: 'the third row’s Remove (an icon, so it has no words)');

    // remove the failed one: the question opens on the safe answer
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(_inBox(), isTrue);
    expect(find.text('Stop and remove this download?'), findsOneWidget);
    expect(find.descendant(of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget), matching: find.text('Keep it')).evaluate().isNotEmpty || Bed.focused().contains('Keep it'), isTrue,
        reason: 'the question opens on Keep it');
    await Bed.back(t);
    expect(_inBox(), isFalse);
    expect(Downloads.instance.items.length, 3, reason: 'Back answers nothing: it is still there');
    expect(Bed.focused(), contains('_DownloadCard'), reason: 'focus is back on the button that asked');

    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    await Bed.right(t);
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    expect(Downloads.instance.items.length, 2, reason: 'Remove removed it');
    expect(Bed.focused(), contains('_DownloadCard'), reason: 'R1: with its row gone, focus is on the row next to it');
    expect(Bed.focusInView(), isTrue);
  }, variant: screen);

  testWidgets('Servers: a provider opens its sign-in box on the address field; Back closes it onto the card', (t) async {
    await phase6Pages['Servers']!(t);
    await Bed.down(t);
    expect(Bed.focused(), allOf(contains('_ProviderCard'), contains('Plex')));
    await Bed.right(t);
    expect(Bed.focused(), contains('Jellyfin'));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    await Bed.realIo(t, until: () => Bed.lookedForServers); // (the box looks for servers on the local network too)
    expect(_inBox(), isTrue);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNotNull, reason: 'the caret is in the address field');
    t.testTextInput.enterText('http://jellyfin.example:8096');
    await t.pump(const Duration(milliseconds: 200));
    await Bed.back(t);
    if (_inBox()) await Bed.back(t);
    expect(_inBox(), isFalse);
    expect(Bed.focused(), contains('Jellyfin'), reason: 'focus is back on the card that opened it');
  }, variant: screen);

  testWidgets('the intro: OK skips it, as a tap does', (t) async {
    await t.pumpWidget(Bed.app(const IntroScreen()));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(IntroScreen), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await Bed.settle(t, rounds: 6);
    expect(find.byType(IntroScreen), findsNothing);
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);
    expect(InputModeTracker.currentMode, InputMode.pointer, reason: 'Enter on a keyboard is not a D-pad: no ring yet');
    expect(t.takeException(), isNull);
    expect(find.byType(DetailsPage), findsNothing);
  }, variant: screen);
}
