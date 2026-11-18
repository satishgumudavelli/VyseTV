// T4 for phase 7: journeys through Music (its own frame and its players), the audiobook player
// and the manga reader with arrows, OK and Back only. Nothing plays in the bed (no YouTube
// Music, no audio engine): the players have a song or a book, a queue and all their controls.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/audiobooks/audiobook_player.dart';
import 'package:vyse_tv/data/music/music_player.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/dpad/dpad_seek.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/screens/audiobooks/audiobook_player_page.dart';
import 'package:vyse_tv/screens/manga/manga_reader_page.dart';
import 'package:vyse_tv/screens/music/music_pages.dart';
import 'package:vyse_tv/screens/music/music_shell.dart';
import 'package:vyse_tv/screens/music/music_player_page.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'bed/phase7_pages.dart';
import 'harness.dart';

String _scope() {
  for (FocusNode? n = FocusManager.instance.primaryFocus; n != null; n = n.parent) {
    final label = n.debugLabel ?? '';
    if (label.startsWith('music ') || label == 'navbar') return label;
  }
  return '';
}

String _label() => FocusManager.instance.primaryFocus?.debugLabel ?? '';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.windows);
    await Bed.withContent();
  });
  final screen = OnScreens([Screens.desktop]);

  testWidgets('Music: starts on its page; the sidebar, the search bar and the app’s navbar are each one step away', (t) async {
    await phase7Pages['Music']!(t);
    expect(find.byType(MusicShell), findsOneWidget);
    await Bed.down(t);
    expect(_scope(), 'music page', reason: 'Music starts on its page, not on the sidebar');
    final home = Bed.focused();
    Future<void> leftOffThePage() async {
      for (var i = 0; i < 10 && _scope() == 'music page'; i++) {
        await Bed.left(t);
      }
    }

    await leftOffThePage();
    expect(_scope(), 'music sidebar', reason: 'Left off the page is the sidebar of Music itself');
    await Bed.down(t, times: 3);
    expect(_scope(), 'music sidebar');
    final side = Bed.focused();
    await Bed.right(t);
    expect(_scope(), 'music page');
    expect(Bed.focused(), home, reason: 'back in the page, on what you left');
    await leftOffThePage();
    expect(Bed.focused(), side, reason: 'and the sidebar gives back its own place too');
    await Bed.left(t);
    expect(_scope(), 'navbar', reason: 'Left off the sidebar is the navbar of the app');
    await Bed.right(t);
    expect(_scope(), isNot('navbar'));

    // up to the search bar and back
    if (_scope() != 'music page') await Bed.right(t);
    for (var i = 0; i < 12 && _scope() == 'music page'; i++) {
      await Bed.up(t);
    }
    expect(_scope(), 'music search', reason: 'Up off the top of the page is the search bar');
    await Bed.down(t);
    expect(_scope(), 'music page');
  }, variant: screen);

  testWidgets('Music: a page opened from the sidebar; Back goes back that page, then to the navbar', (t) async {
    await phase7Pages['Music']!(t);
    await Bed.dpadMode(t);
    await Bed.focus(t, find.widgetWithText(Pressable, 'Liked songs'));
    await Bed.ok(t);
    await Bed.settle(t, rounds: 4);
    expect(find.byType(LikedSongsPage), findsOneWidget);
    expect(_scope(), 'music page', reason: 'the page opened beside the sidebar and focus went into it');
    await Bed.down(t, times: 3);
    expect(Bed.focusInView(), isTrue);
    await Bed.back(t);
    expect(find.byType(LikedSongsPage), findsNothing, reason: 'Back goes back one of Music’s own pages');
    expect(find.byType(MusicShell), findsOneWidget);
    expect(Bed.focused(), isNot('nothing'));
    await Bed.back(t);
    expect(_scope(), 'navbar', reason: 'with no page of its own left, Back is the app’s: to the navbar');
    expect(find.byType(MusicShell), findsOneWidget);
  }, variant: screen);

  testWidgets('Music with a song on: the player bar is under everything; its seek bar seeks; the queue opens beside the page', (t) async {
    await phase7Pages['Music, with a song on']!(t);
    await Bed.down(t);
    final home = Bed.focused();
    for (var i = 0; i < 30 && _scope() != 'music bar'; i++) {
      await Bed.down(t);
    }
    expect(_scope(), 'music bar', reason: 'Down off the foot of the page is the player bar');
    for (var i = 0; i < 4 && _scope() == 'music bar'; i++) {
      await Bed.up(t);
    }
    expect(_scope(), 'music page', reason: 'Up from the bar returns to the page you came from');
    expect(home, isNot('nothing'));
    for (var i = 0; i < 30 && _scope() != 'music bar'; i++) {
      await Bed.down(t);
    }
    // the queue
    final queue = Bed.nodeOf(t, find.byWidgetPredicate((w) => w is Pressable && w.tooltip == 'Up next'));
    for (var i = 0; i < 12 && !queue.hasPrimaryFocus; i++) {
      await Bed.right(t);
      if (!queue.hasPrimaryFocus && i > 5) await Bed.up(t);
    }
    expect(queue.hasPrimaryFocus, isTrue, reason: 'the Up next button is reachable along the bar');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 3);
    expect(find.text('Up next'), findsWidgets);
    for (var i = 0; i < 4 && _scope() == 'music bar'; i++) {
      await Bed.up(t);
    }
    expect(_scope(), isNot('music bar'));
    for (var i = 0; i < 10 && _scope() != 'music queue'; i++) {
      await Bed.right(t);
    }
    expect(_scope(), 'music queue', reason: 'Right off the page is the queue, when it is open');
    for (var i = 0; i < 6 && _scope() == 'music queue'; i++) {
      await Bed.left(t);
    }
    expect(_scope(), 'music page', reason: 'and Left off the queue is the page again');
    await quiet(t);
  }, variant: screen);

  testWidgets('the full music player: a D-pad is put on its controls; the seek bar and the volume are stops; Back closes', (t) async {
    await phase7Pages['Music, the full player']!(t);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(_label(), 'music player', reason: 'with a mouse in charge focus rests on the page (Left and Right seek)');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump(const Duration(milliseconds: 100));
    expect(InputModeTracker.currentMode, InputMode.pointer, reason: 'seeking is not navigating: no ring');
    await Bed.down(t);
    expect(Bed.focused(), isNot('nothing'), reason: 'Down puts focus on the controls');
    // (every control here is reached with arrows in the walk, t3_walk_phase7; this test is
    // about what the two sliders do once focus is on them)
    final seek = Bed.nodeOf(t, find.byType(DpadSeekStop));
    await Bed.focus(t, find.byType(DpadSeekStop));
    expect(seek.hasPrimaryFocus, isTrue, reason: 'the seek bar is a stop');
    await Bed.right(t, times: 2);
    expect(seek.hasPrimaryFocus, isTrue, reason: 'Left and Right on it seek; focus stays');
    await Bed.down(t);
    expect(seek.hasPrimaryFocus, isFalse, reason: 'Down leaves it for the buttons under it');

    final volume = Bed.nodeOf(t, find.byType(DpadSlider));
    for (var i = 0; i < 4 && !volume.hasPrimaryFocus; i++) {
      await Bed.down(t);
    }
    expect(volume.hasPrimaryFocus, isTrue, reason: 'Down from the buttons reaches the volume, a line of its own');
    final was = MusicPlayer.instance.volume;
    await Bed.left(t, times: 3);
    expect(MusicPlayer.instance.volume, was - 15, reason: 'Left turns it down a step at a time');
    await Bed.right(t, times: 3);
    expect(MusicPlayer.instance.volume, was);
    expect(volume.hasPrimaryFocus, isTrue);
    await Bed.up(t);
    expect(volume.hasPrimaryFocus, isFalse, reason: 'Up leaves it (a plain slider would have kept it)');

    await Bed.back(t);
    expect(find.byType(MusicPlayerPage), findsNothing, reason: 'its controls never hide, so one Back closes the player');
    expect(Bed.focused(), isNot('nothing'));
    await quiet(t);
  }, variant: screen);

  testWidgets('the audiobook player: a D-pad is put on its controls; chapters beside them; Back closes', (t) async {
    await phase7Pages['Audiobooks, the player']!(t);
    expect(find.byType(AudiobookPlayerPage), findsOneWidget);
    expect(_label(), 'audiobook player');
    await Bed.dpadMode(t);
    await Bed.settle(t, rounds: 2);
    expect(Bed.focused(), isNot('nothing'), reason: 'a D-pad taking over is put straight on the controls');
    for (var i = 0; i < 6 && !Bed.focused().contains('_Chapters'); i++) {
      await Bed.right(t);
    }
    expect(Bed.focused(), contains('_Chapters'), reason: 'Right from the controls reaches the chapter list');
    await Bed.down(t, times: 2);
    final chapter = AudiobookPlayer.instance.chapter;
    await Bed.ok(t);
    await Bed.settle(t, rounds: 2);
    expect(AudiobookPlayer.instance.chapter, isNot(chapter), reason: 'OK on a chapter goes to it');
    await Bed.left(t, times: 6);
    expect(Bed.focused(), isNot(contains('_Chapters')));

    // Speed is a list that opens from a button drawn as a chip: the button is the stop, and
    // OK opens its list
    final speed = find.byWidgetPredicate((w) => w is PopupMenuButton<double>);
    final speedNode = Focus.of(t.element(find.descendant(of: speed, matching: find.byType(IgnorePointer)).first));
    speedNode.requestFocus();
    await Bed.settle(t, rounds: 2);
    expect(speedNode.hasPrimaryFocus, isTrue, reason: 'the button itself takes focus, not the chip drawn on it');
    await Bed.ok(t);
    await Bed.settle(t, rounds: 2);
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem<double>), findsWidgets, reason: 'OK opens the list of speeds');
    await Bed.down(t);
    await Bed.back(t);
    await Bed.settle(t, rounds: 2);
    expect(find.byWidgetPredicate((w) => w is PopupMenuItem<double>), findsNothing, reason: 'Back closes the list and only the list');
    expect(find.byType(AudiobookPlayerPage), findsOneWidget);
    await Bed.back(t);
    expect(find.byType(AudiobookPlayerPage), findsNothing);
    await quiet(t);
  }, variant: screen);

  testWidgets('the manga reader: arrows read and start no D-pad mode; OK changes the fit; holding OK brings the bar up; Back hides it; Back again leaves', (t) async {
    MangaReaderPage.debugPages = (c) async => [for (var i = 0; i < 6; i++) 'https://manga.example/${c.id}/p$i.jpg'];
    addTearDown(() => MangaReaderPage.debugPages = null);
    await phase7Pages['Manga, the reader']!(t);
    expect(find.byType(MangaReaderPage), findsOneWidget);
    expect(_label(), 'reader');
    expect(find.textContaining('Chapter 2  ·  1 / 6'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await Bed.settle(t, rounds: 2);
    expect(find.textContaining('Chapter 2  ·  2 / 6'), findsOneWidget, reason: 'Right is the next page, in scroll mode too (it was the next chapter: a remote ran through them)');
    expect(InputModeTracker.currentMode, InputMode.pointer, reason: 'reading is not navigating: no ring');
    expect(_label(), 'reader');

    await Bed.ok(t);
    expect(find.textContaining(RegExp('^(Fit page|Fit width)\$')), findsOneWidget, reason: 'OK changes the fit, and a toast says to which');
    expect(_label(), 'reader', reason: 'focus stays on the page');
    await Bed.dpadMode(t);
    await t.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await t.pump(const Duration(milliseconds: 700));
    await t.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await Bed.settle(t, rounds: 2);
    expect(Bed.focused(), contains('GlassIconButton'), reason: 'holding OK puts focus on the bar');
    expect(find.byType(MangaReaderPage), findsOneWidget, reason: 'letting go of OK presses nothing there');
    await Bed.right(t, times: 2);
    await Bed.left(t);
    expect(find.textContaining('Chapter 2  ·  2 / 6'), findsOneWidget, reason: 'on the bar, arrows move between its buttons; the page stays');
    await Bed.up(t, times: 6);
    expect(Bed.focused(), isNot(contains('_WinButton')), reason: 'a held Up stops on the bar');

    await Bed.back(t);
    expect(find.byType(MangaReaderPage), findsOneWidget, reason: 'the first Back hides the bar');
    expect(_label(), 'reader');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await Bed.settle(t, rounds: 2);
    expect(find.textContaining('Chapter 2  ·  1 / 6'), findsOneWidget, reason: 'and the arrows read again');
    await Bed.back(t);
    expect(find.byType(MangaReaderPage), findsNothing, reason: 'the second Back leaves');
    expect(Bed.focused(), isNot('nothing'));
  }, variant: screen);

  group('the kit’s pieces by themselves', () {
    testWidgets('a slider is one stop: Left and Right change it by a step within its ends; Up and Down move on', (t) async {
      var value = 50.0;
      await t.pumpWidget(Bed.app(Scaffold(
        body: Center(
          child: StatefulBuilder(
            builder: (context, set) => Column(mainAxisSize: MainAxisSize.min, children: [
              Pressable(onTap: () {}, builder: (_, _, _) => const SizedBox(width: 200, height: 50, child: Center(child: Text('above')))),
              SizedBox(
                width: 300,
                child: DpadSlider(
                  value: value,
                  max: 100,
                  step: 20,
                  onChanged: (v) => set(() => value = v),
                  child: Slider(value: value, max: 100, onChanged: (v) => set(() => value = v)),
                ),
              ),
              Pressable(onTap: () {}, builder: (_, _, _) => const SizedBox(width: 200, height: 50, child: Center(child: Text('below')))),
            ]),
          ),
        ),
      )));
      await t.pump(const Duration(milliseconds: 300));
      await Bed.dpadMode(t);
      final slider = Bed.nodeOf(t, find.byType(DpadSlider));
      expect(Bed.focused(), contains('above'), reason: 'the page starts on its first control');
      await Bed.down(t);
      expect(slider.hasPrimaryFocus, isTrue);
      await Bed.right(t, times: 2);
      expect(value, 90);
      await Bed.right(t, times: 3);
      expect(value, 100, reason: 'it stops at its end');
      await Bed.left(t);
      expect(value, 80);
      expect(slider.hasPrimaryFocus, isTrue);
      await Bed.down(t);
      expect(Bed.focused(), contains('below'));
      await Bed.up(t);
      expect(slider.hasPrimaryFocus, isTrue);
      await Bed.up(t);
      expect(Bed.focused(), contains('above'));
      // a mouse still drags it
      final box = t.getRect(find.byType(Slider));
      await t.tapAt(Offset(box.left + box.width * .25, box.center.dy));
      await t.pump(const Duration(milliseconds: 300));
      expect(value, closeTo(25, 6));
    }, variant: screen);

    testWidgets('a page with pages of its own inside it answers Back first', (t) async {
      final inner = GlobalKey<NavigatorState>();
      await t.pumpWidget(Bed.app(Scaffold(
        body: DpadBackScope(
          onBack: () {
            final nav = inner.currentState!;
            if (!nav.canPop()) return false;
            nav.pop();
            return true;
          },
          child: Navigator(
            key: inner,
            onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const Center(child: Text('first'))),
          ),
        ),
      )));
      await t.pump(const Duration(milliseconds: 300));
      expect(DpadBackScope.handle(), isFalse, reason: 'nothing of its own to go back from');
      inner.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Center(child: Text('second'))));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('second'), findsOneWidget);
      expect(DpadBackScope.handle(), isTrue);
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('second'), findsNothing);
      expect(find.text('first'), findsOneWidget);
      expect(DpadBackScope.handle(), isFalse);
    }, variant: screen);
  });
}
