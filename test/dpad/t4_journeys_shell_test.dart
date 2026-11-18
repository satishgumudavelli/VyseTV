// T4: journeys through the shell, Home and the browsing sections, pressed out key by key with
// what should be true after each step. Windows, with only the keyboard.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/party/party.dart' show PartyProfile;
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/screens/shell/floating.dart';
import 'package:vyse_tv/screens/party/dm_page.dart' show MiniChat, MiniChatBubble;
import 'package:vyse_tv/screens/details/details_page.dart';
import 'package:vyse_tv/screens/discover/discover_page.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/screens/shell/shell.dart';
import 'package:vyse_tv/widgets/hero_carousel.dart';

import 'harness.dart';

bool _railOpen(WidgetTester t) => t.getSize(find.byType(SideRail)).width > 200;
bool _inNavbar() => Bed.focused().contains('SideRail');

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final screen = OnScreens([Screens.laptop]);

  testWidgets('the first arrow shows where focus is and does not move it', (t) async {
    await Bed.pumpShell(t);
    expect(InputModeTracker.currentMode, InputMode.pointer);
    expect(Bed.focused(), 'nothing', reason: 'with a mouse, nothing on Home holds focus');
    await Bed.down(t);
    expect(InputModeTracker.currentMode, InputMode.keyboard);
    expect(Bed.focused(), contains("_PlayButton"), reason: 'Home starts on the hero\'s Play');
    await Bed.down(t);
    expect(Bed.focused(), contains('Continue watching'));
    // the mouse moves, then an arrow: the ring comes back where it was, without moving
    final here = Bed.focused();
    await t.tapAt(const Offset(640, 30));
    await t.pump(const Duration(milliseconds: 300));
    expect(InputModeTracker.currentMode, InputMode.pointer);
    await Bed.right(t);
    expect(Bed.focused(), here, reason: 'the press that picks the remote up only shows the ring');
    await Bed.right(t);
    expect(Bed.focused(), isNot(here));
  }, variant: screen);

  testWidgets('down the rows of Home and back up: each row gives back the card you left', (t) async {
    await Bed.pumpShell(t);
    await Bed.down(t, times: 2);
    expect(Bed.focused(), contains('Continue watching'));
    await Bed.right(t, times: 2);
    final third = Bed.focused();
    expect(third, contains('Marrow'));
    await Bed.down(t);
    expect(Bed.focused(), contains('Hot right now'));
    await Bed.right(t, times: 3);
    final inHot = Bed.focused();
    await Bed.up(t);
    expect(Bed.focused(), third, reason: 'back to the card you left in that row, not the nearest one');
    await Bed.down(t);
    expect(Bed.focused(), inHot);
    expect(Bed.focusInView(), isTrue);
    // sideways never leaves the row for another line
    await Bed.right(t, times: 30);
    expect(Bed.focused(), contains('Hot right now'), reason: 'Right at the end of a row stays in the row');
    expect(Bed.focusInView(), isTrue);
  }, variant: screen);

  testWidgets('Left from the page reaches the rail, which opens; Right goes back to the card you left', (t) async {
    await Bed.pumpShell(t);
    await Bed.down(t, times: 3);
    await Bed.right(t);
    final card = Bed.focused();
    await Bed.left(t, times: 2);
    expect(Bed.focused(), contains("_RailItem in SideRail 'Home'"), reason: 'Left from the first card: the rail, on the section you are in');
    expect(_railOpen(t), isTrue, reason: 'the rail opens while focus is in it');
    await Bed.right(t);
    expect(Bed.focused(), isNot(contains('SideRail')));
    expect(_railOpen(t), isFalse);
    // (Left took one step along the row first, so the card you left the page from is its first)
    expect(Bed.focused(), contains('Hot right now'));
    expect(Bed.focused(), isNot(card));
    await Bed.right(t);
    expect(Bed.focused(), card);
  }, variant: screen);

  testWidgets('choosing a section in the rail goes to it; its page takes focus', (t) async {
    await Bed.pumpShell(t);
    await Bed.down(t);
    await Bed.left(t);
    expect(Bed.focused(), contains("'Home'"));
    await Bed.down(t, times: 3);
    expect(Bed.focused(), contains("'Movies'"));
    expect(find.byType(HomePage), findsOneWidget, reason: 'moving along the rail does not switch sections');
    await Bed.ok(t);
    expect(find.text('Every film on TMDB'), findsOneWidget);
    expect(_inNavbar(), isFalse, reason: 'OK on a section is also going to it');
    expect(Bed.focused(), isNot('nothing'));
    expect(_railOpen(t), isFalse);
    // the rail now opens on Movies, the section on screen
    await Bed.left(t, times: 8);
    expect(Bed.focused(), contains("_RailItem in SideRail 'Movies'"));
  }, variant: screen);

  testWidgets('Back: one step per press: page, then navbar, then the first section, then nothing', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'discover');
    await Bed.down(t, times: 3);
    expect(Bed.focused(), contains('_DiscoverCard'));
    final card = Bed.focused();
    await Bed.ok(t);
    expect(find.byType(DetailsPage), findsOneWidget);
    expect(Bed.focused(), isNot('nothing'), reason: 'a page that opens takes focus');

    await Bed.back(t);
    expect(find.byType(DetailsPage), findsNothing, reason: 'first Back: leave the page');
    expect(Bed.focused(), card, reason: 'R6: back on the card that opened it');
    expect(Bed.focusInView(), isTrue);

    await Bed.back(t);
    expect(Bed.focused(), contains("_RailItem in SideRail 'Discover'"), reason: 'second Back: from the page to the navbar');
    expect(find.byType(DiscoverPage), findsOneWidget);

    await Bed.back(t);
    expect(find.byType(HomePage), findsOneWidget, reason: 'third Back: the first section');
    expect(Bed.focused(), contains("_RailItem in SideRail 'Home'"));

    await Bed.back(t);
    expect(find.byType(HomePage), findsOneWidget, reason: 'on a desktop Escape never closes the window');
    expect(Bed.focused(), contains("'Home'"));
  }, variant: screen);

  testWidgets('holding Back is still one Back', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'discover');
    await Bed.down(t, times: 3);
    await Bed.ok(t);
    expect(find.byType(DetailsPage), findsOneWidget);
    await t.sendKeyDownEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 12; i++) {
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await t.pump(const Duration(milliseconds: 40));
    }
    await t.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await Bed.settle(t, rounds: 4);
    expect(find.byType(DetailsPage), findsNothing);
    expect(find.byType(DiscoverPage), findsOneWidget, reason: 'the hold must not have carried on to the navbar and Home');
    expect(Bed.focused(), contains('_DiscoverCard'));
  }, variant: screen);

  testWidgets('with a mouse in charge, Escape leaves a page but never changes section', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'discover');
    expect(InputModeTracker.currentMode, InputMode.pointer);
    await Bed.back(t);
    await Bed.back(t);
    expect(find.byType(DiscoverPage), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
    expect(InputModeTracker.currentMode, InputMode.pointer, reason: 'Escape is not a wish to navigate by keys');
  }, variant: screen);

  testWidgets('R7: a page that is covered cannot take focus, and gets it back when uncovered', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'discover');
    await Bed.down(t, times: 3);
    final card = FocusManager.instance.primaryFocus!;
    await Bed.ok(t);
    expect(find.byType(DetailsPage), findsOneWidget);
    expect(card.canRequestFocus, isFalse, reason: 'the list is under the details page');
    card.requestFocus();
    await t.pump(const Duration(milliseconds: 100));
    expect(card.hasFocus, isFalse, reason: 'asking makes no difference while covered');
    expect(Bed.focused(), isNot('nothing'));
    await Bed.back(t);
    expect(card.hasPrimaryFocus, isTrue);
  }, variant: screen);

  testWidgets('Home\'s spotlight: Up from the hero opens it, Left and Right browse, Down leaves', (t) async {
    await Bed.pumpShell(t);
    await Bed.down(t);
    expect(Bed.focused(), contains('_PlayButton'));
    double hero() => t.getSize(find.byType(HeroCarousel)).height;
    final resting = hero();
    await Bed.up(t);
    await Bed.settle(t, rounds: 4);
    expect(hero(), 720, reason: 'the spotlight fills the window');
    expect(find.text('The Long Night'), findsWidgets);
    await Bed.right(t);
    await Bed.settle(t, rounds: 4);
    expect(find.text('Harbour Lights: The Series'), findsWidgets, reason: 'Right browses to the next slide');
    await Bed.left(t);
    await Bed.settle(t, rounds: 4);
    expect(find.text('The Long Night'), findsWidgets);
    expect(Bed.focused(), contains('_PlayButton'), reason: 'focus stays on Play while browsing');
    await Bed.down(t);
    await Bed.settle(t, rounds: 4);
    expect(hero(), resting, reason: 'Down leaves the spotlight');
    await Bed.down(t);
    expect(Bed.focused(), contains('Continue watching'));
    // Back leaves it too, and only it
    await Bed.up(t, times: 2);
    await Bed.settle(t, rounds: 4);
    expect(hero(), 720);
    await Bed.back(t);
    expect(hero(), resting);
    expect(Bed.focused(), contains('_PlayButton'));
  }, variant: screen);

  testWidgets('the window buttons: Up from the top of the rail, Down comes back', (t) async {
    await Bed.pumpShell(t);
    await Bed.down(t);
    await Bed.left(t);
    expect(Bed.focused(), contains("'Home'"));
    await Bed.up(t);
    expect(Bed.focused(), contains('_WinButton'));
    await Bed.right(t, times: 5);
    expect(Bed.focused(), contains('_WinButton'), reason: 'Right at the last one stays');
    await Bed.down(t);
    expect(Bed.focused(), contains("_RailItem in SideRail 'Home'"));
  }, variant: screen);

  testWidgets('the floating chat never takes focus by itself; the rail\'s entry is the way in, Back the way out', (t) async {
    await Bed.pumpShell(t);
    MiniChat.now.value = (partner: const PartyProfile(id: 'u1', username: 'mara', name: 'Mara Ellison'), open: false);
    addTearDown(MiniChat.close);
    await Bed.settle(t, rounds: 2);
    expect(find.byType(MiniChatBubble), findsOneWidget);
    expect(find.text('Chat'), findsNothing, reason: 'a mouse just clicks the bubble: the rail has no entry for it');

    // arrows on the page never wander into it, however far they are pushed
    await Bed.down(t, times: 3);
    await Bed.right(t, times: 25);
    expect(FloatingLayer.region.hasFocus, isFalse);
    await Bed.down(t, times: 3);
    await Bed.up(t, times: 2);
    expect(FloatingLayer.region.hasFocus, isFalse);

    await Bed.left(t, times: 25);
    expect(Bed.focused(), contains('SideRail'));
    expect(find.text('Chat'), findsOneWidget, reason: 'with a D-pad the rail offers the way in');
    for (var i = 0; i < 20 && !Bed.focused().contains('_RailFloating'); i++) {
      await Bed.down(t);
    }
    expect(Bed.focused(), contains('_RailFloating'));
    await Bed.ok(t);
    expect(FloatingLayer.region.hasFocus, isTrue, reason: 'OK on the entry puts focus on the bubble');
    expect(Bed.focused(), isNot('nothing'));
    await Bed.right(t);
    await Bed.down(t);
    expect(FloatingLayer.region.hasFocus, isTrue, reason: 'arrows do not fall out of it onto the page');

    await Bed.back(t);
    expect(FloatingLayer.region.hasFocus, isFalse, reason: 'Back leaves it');
    expect(Bed.focused(), contains('SideRail'));
    expect(find.byType(HomePage), findsOneWidget, reason: 'and does nothing else');

    // Left leaves it too. Coming back in lands where you were inside it (the close button,
    // stepped onto with Right above): one Left is back on the bubble, the next is out.
    await Bed.ok(t);
    expect(FloatingLayer.region.hasFocus, isTrue);
    expect(Bed.focused(), contains('MiniChatBubble'));
    await Bed.left(t);
    expect(FloatingLayer.region.hasFocus, isTrue);
    await Bed.left(t);
    expect(Bed.focused(), contains("_RailFloating in SideRail 'Chat'"));
  }, variant: screen);

  testWidgets('a text box lets the arrows out, and keeps them while they have work in it', (t) async {
    await Bed.pumpShell(t);
    await Bed.openSection(t, 'history');
    await Bed.down(t);
    // (that arrows reach the search box is the walk's job, t3; here focus is put on it)
    final box = t.widget<EditableText>(find.byType(EditableText).first).focusNode;
    box.requestFocus();
    await t.pump(const Duration(milliseconds: 300));
    expect(box.hasPrimaryFocus, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.keyB);
    t.testTextInput.enterText('blue');
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('blue'), findsOneWidget);
    // the caret is at the end: Left has work to do in the box and stays in it
    await Bed.left(t);
    expect(box.hasPrimaryFocus, isTrue, reason: 'Left moves the caret, not the focus');
    await Bed.down(t);
    expect(box.hasPrimaryFocus, isFalse, reason: 'Down leaves a one-line box');
    expect(Bed.focused(), isNot('nothing'));
  }, variant: screen);
}
