// T4 for the second round of TV feedback (a tester's 55" TCL, 2026-11-17): the manga reader (it
// ran out of memory, and the remote's keys turned chapters), the picture shaking when the audio
// track changed with an upscaler on, the Skip buttons, Music's player on a TV, and an audiobook
// giving way to a song. The bed is told it is a TV, as in phase 11.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/nav.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/audiobooks/audiobook_player.dart';
import 'package:vyse_tv/data/playback/intro_db.dart';
import 'package:vyse_tv/mpv/mpv.dart' as pz;
import 'package:vyse_tv/dpad/dpad_seek.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/screens/manga/manga_reader_page.dart';
import 'package:vyse_tv/screens/music/music_player_page.dart';
import 'package:vyse_tv/widgets/audiobook_widgets.dart' show ActiveMiniPlayer, BookMiniBar, TvNowPlaying;
import 'package:vyse_tv/widgets/common.dart';
import 'package:vyse_tv/widgets/music_widgets.dart' show MiniPlayer;

import 'bed/phase7_pages.dart' show startMusic, startBook, quiet;
import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

/// The reader over the app on chapter 2 of the bed's series, with [pages] pages a chapter.
Future<void> _reader(WidgetTester t, {int pages = 75, int startPage = 0}) async {
  MangaReaderPage.debugPages = (c) async => [for (var i = 0; i < pages; i++) 'https://manga.example/${c.id}/p$i.jpg'];
  addTearDown(() => MangaReaderPage.debugPages = null);
  await Bed.pumpShell(t);
  rootNavigatorKey.currentState!.push(MaterialPageRoute<void>(
    builder: (_) => MangaReaderPage(manga: Bed.manga[0], chapters: Bed.chapters, index: 1, startPage: startPage),
  ));
  await Bed.settle(t, rounds: 6);
  expect(find.byType(MangaReaderPage), findsOneWidget);
}

Future<void> _leave(WidgetTester t) async {
  for (var i = 0; i < 3 && find.byType(MangaReaderPage).evaluate().isNotEmpty; i++) {
    await Bed.back(t);
  }
  expect(find.byType(MangaReaderPage), findsNothing);
}

final _strips = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_StripPage');
String _label() => FocusManager.instance.primaryFocus?.debugLabel ?? '';

/// Holds [key] for [held], the way a remote sends it (one press, then repeats), and lets go.
Future<void> _hold(WidgetTester t, LogicalKeyboardKey key, Duration held) async {
  await t.sendKeyDownEvent(key, platform: 'android');
  var gone = Duration.zero;
  await t.pump(const Duration(milliseconds: 400));
  gone += const Duration(milliseconds: 400);
  while (gone < held) {
    await t.sendKeyRepeatEvent(key, platform: 'android');
    await t.pump(const Duration(milliseconds: 50));
    gone += const Duration(milliseconds: 50);
  }
  await t.sendKeyUpEvent(key, platform: 'android');
  await Bed.settle(t, rounds: 3);
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
  });
  final tv = OnScreens([Screens.tv]);

  testWidgets('the manga reader builds and fetches only the pages near the screen, each decoded no larger than it is shown', (t) async {
    expect(PlatformDetector.isTV(), isTrue);
    await _reader(t);
    expect(find.textContaining('1 / 75'), findsOneWidget);
    expect(_strips, findsWidgets);
    expect(_strips.evaluate().length, lessThan(8),
        reason: 'of 75 pages only those near the screen are built (every one was, at full size, and a TV ran out of memory within a minute)');
    final dpr = t.view.devicePixelRatio;
    for (final e in _strips.evaluate()) {
      final w = e.widget as dynamic;
      expect(w.decodeWidth as int, lessThanOrEqualTo((960 * dpr).round()), reason: 'decoded at the width it is shown, not the size it was sent');
    }
    // on a TV a strip starts at Fit page: a whole page on the screen, not its top third
    final first = t.getSize(_strips.first);
    expect(first.height, lessThanOrEqualTo(540.0 + 1));
    // the first time a D-pad opens the reader, it says what OK does now
    expect(find.text('OK changes the fit. Hold OK for the menu.'), findsOneWidget);
    await _leave(t);
    await t.pump(const Duration(seconds: 3)); // (that toast goes)
  }, variant: tv);

  testWidgets('the reader opens on the saved page, without fetching the pages before it', (t) async {
    await _reader(t, startPage: 40);
    expect(find.textContaining('41 / 75'), findsOneWidget);
    final numbers = [for (final e in _strips.evaluate()) (e.widget as dynamic).number as int];
    expect(numbers, contains(41));
    expect(numbers.every((n) => n > 35), isTrue, reason: 'only the pages round page 41 were built: $numbers');
    await _leave(t);
  }, variant: tv);

  testWidgets('the reader on a remote: Right is the next page; a held Right stops at the end of the chapter; Right there is the next chapter', (t) async {
    await _reader(t, pages: 4);
    expect(find.textContaining('Chapter 2  ·  1 / 4'), findsOneWidget);
    expect(_label(), 'reader');
    await Bed.right(t);
    expect(find.textContaining('Chapter 2  ·  2 / 4'), findsOneWidget, reason: 'Right is the next page (it was the next chapter, in scroll mode)');
    expect(_label(), 'reader', reason: 'reading moves no focus');
    await _hold(t, LogicalKeyboardKey.arrowRight, const Duration(seconds: 3));
    expect(find.textContaining('Chapter 2'), findsWidgets, reason: 'a held Right reads on to the end of the chapter and stops there (it ran through chapter after chapter)');
    expect(find.text('End of Chapter 2'), findsOneWidget);
    await Bed.right(t);
    await Bed.settle(t, rounds: 4);
    expect(find.textContaining('Chapter 3  ·  1 / 4'), findsOneWidget, reason: 'Right on the end card: the next chapter, at its first page');
    await Bed.left(t);
    await Bed.settle(t, rounds: 4);
    expect(find.textContaining('Chapter 2  ·  1 / 4'), findsOneWidget, reason: 'Left at the top of the first page: the chapter before');
    await _leave(t);
  }, variant: tv);

  testWidgets('the reader on a remote: OK changes the fit; holding OK brings the bar up and presses nothing; Back hides it; Back again leaves', (t) async {
    await _reader(t, pages: 4);
    final before = t.getSize(_strips.first).width;
    await Bed.ok(t);
    expect(find.text('Fit width'), findsOneWidget, reason: 'OK changes the fit (a strip on a TV starts at Fit page)');
    expect(t.getSize(_strips.first).width, greaterThan(before + 100), reason: 'the pages are as wide as the screen now');
    expect(_label(), 'reader');
    await Bed.ok(t);
    expect(find.text('Fit page'), findsOneWidget, reason: 'and round again');
    expect(t.getSize(_strips.first).width, closeTo(before, 1));

    await _hold(t, LogicalKeyboardKey.select, const Duration(milliseconds: 700));
    expect(Bed.focused(), contains('GlassIconButton'), reason: 'holding OK: the bar, with focus on it');
    expect(find.byType(MangaReaderPage), findsOneWidget, reason: 'letting go of OK presses nothing on the bar (its first button is Back)');
    await Bed.back(t);
    expect(find.byType(MangaReaderPage), findsOneWidget, reason: 'Back hides the bar');
    expect(_label(), 'reader');
    // the Menu key brings it up as well
    await t.sendKeyEvent(LogicalKeyboardKey.contextMenu, platform: 'android');
    await Bed.settle(t, rounds: 2);
    expect(Bed.focused(), contains('GlassIconButton'));
    await Bed.back(t);
    await Bed.back(t);
    expect(find.byType(MangaReaderPage), findsNothing, reason: 'Back again leaves');
  }, variant: tv);

  testWidgets('page mode goes round Fit page, Fit width and Stretch; Left and Right turn the pages', (t) async {
    await _reader(t, pages: 4);
    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    await Bed.settle(t, rounds: 3);
    expect(find.text('Page mode'), findsOneWidget);
    for (final fit in ['Fit width', 'Stretch', 'Fit page']) {
      await Bed.ok(t);
      expect(find.text(fit), findsOneWidget, reason: 'OK: $fit');
    }
    await Bed.right(t);
    await Bed.settle(t, rounds: 2);
    expect(find.textContaining('2 / 4'), findsOneWidget);
    await Bed.left(t);
    await Bed.settle(t, rounds: 2);
    expect(find.textContaining('1 / 4'), findsOneWidget);
    // (back to scroll mode for the tests after this one: the mode is remembered)
    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    await Bed.settle(t, rounds: 3);
    await _leave(t);
    await t.pump(const Duration(seconds: 3)); // (the last toast goes)
  }, variant: tv);

  testWidgets('the upscaler: applied again with nothing changed, mpv is told nothing; a change is one write, never an empty list first', (t) async {
    final player = pz.Player();
    final fx = pz.PictureEffects(player);
    Bed.videoCalls.clear();
    List<String> shaders() => [for (final c in Bed.videoCalls) if (c.contains('glsl-shaders')) c];
    await t.runAsync(() => fx.apply(upscaler: pz.Upscaler.byId('nvscaler'), ambient: false));
    expect(shaders(), hasLength(1), reason: '${Bed.videoCalls}');
    expect(shaders().single, allOf(contains('glsl-shaders, set'), contains('NVScaler.glsl')));
    // an audio track is changed; mpv says the picture's size again; the page applies again
    await t.runAsync(() => fx.apply(upscaler: pz.Upscaler.byId('nvscaler'), ambient: false, videoAspect: 16 / 9));
    await t.runAsync(() => fx.apply(upscaler: pz.Upscaler.byId('nvscaler'), ambient: false, videoAspect: 16 / 9));
    expect(shaders(), hasLength(1),
        reason: 'nothing changed, so nothing is sent (on Android each change of the list moved the picture between two renderers: it shook)');
    await t.runAsync(() => fx.apply(upscaler: pz.Upscaler.byId('artcnn'), ambient: false));
    expect(shaders(), hasLength(2));
    expect(shaders().last, contains('glsl-shaders, set'), reason: 'from one upscaler to another in one write: the list is never empty on the way');
    expect(shaders().where((c) => c.contains('clr')), isEmpty);
    await t.runAsync(() => fx.apply(upscaler: pz.Upscaler.off, ambient: false));
    expect(shaders().last, contains('glsl-shaders, clr'), reason: 'off empties it');
    await t.runAsync(() => player.dispose());
  }, variant: tv);

  testWidgets('Settings > Playback > Skip buttons: each kind is on or off by itself with OK; one turned off is not offered', (t) async {
    AppSettings.skipButtonsOff.set('');
    addTearDown(() => AppSettings.skipButtonsOff.set(''));
    await openSettings(t, 'Playback');
    expect(find.text('Skip buttons'), findsOneWidget);
    Finder chip(String name) => find.ancestor(of: find.text(name), matching: find.byType(Pressable)).first;
    await Bed.dpadMode(t);
    await Bed.focus(t, chip('Recap'));
    await Bed.ok(t);
    expect(AppSettings.skipButtonsOff.value, 'recap');
    expect(skipOffered(SegmentKind.recap), isFalse, reason: 'Skip recap is not offered');
    expect(skipOffered(SegmentKind.intro), isTrue);
    expect(skipOffered(SegmentKind.credits), isTrue);
    await Bed.focus(t, chip('Credits'));
    await Bed.ok(t);
    expect(AppSettings.skipButtonsOff.value, 'recap,credits');
    await Bed.focus(t, chip('Recap'));
    await Bed.ok(t);
    expect(AppSettings.skipButtonsOff.value, 'credits', reason: 'and back on');
    expect(skipOffered(SegmentKind.recap), isTrue);
  }, variant: tv);

  testWidgets('on a TV, Music shows the song playing at its top; OK on it opens the full player, with the seek bar and no volume', (t) async {
    await Bed.pumpShell(t);
    await startMusic(t);
    await Bed.openSection(t, 'music');
    await Bed.settle(t, rounds: 4);
    final bar = find.descendant(of: find.byType(TvNowPlaying), matching: find.byType(MiniPlayer));
    expect(bar, findsOneWidget, reason: 'the song playing, at the top of Music');
    expect(find.byType(ActiveMiniPlayer), findsNothing, reason: 'and still no bar floating over every page');
    await Bed.focus(t, find.descendant(of: bar, matching: find.byType(Pressable)).first);
    await Bed.ok(t);
    expect(find.byType(MusicPlayerPage), findsOneWidget, reason: 'OK opens the full player: the cover and the seek bar');
    expect(find.byType(DpadSeekStop), findsWidgets, reason: 'a seek bar the remote can use');
    expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Volume'), findsNothing, reason: 'the remote sets a TV’s volume');
    await Bed.back(t);
    expect(find.byType(MusicPlayerPage), findsNothing);
    await t.pumpWidget(const SizedBox());
    await quiet(t);
  }, variant: tv);

  testWidgets('a song started while a book plays: the book lets go of its stream, keeps its place, and play picks it up at that second', (t) async {
    await Bed.pumpShell(t);
    await startBook(t);
    expect(AudiobookPlayer.instance.book, isNotNull);
    Bed.audioCalls.clear();
    await startMusic(t);
    await Bed.settle(t, rounds: 2);
    final book = [for (final c in Bed.audioCalls) if (c.startsWith('mpv_audio_player_2 ')) c];
    expect(book.where((c) => c.contains('[stop]')), isNotEmpty,
        reason: 'stopped, not just paused: a paused stream goes on downloading ahead, and on a TV the song that had just started stuttered ($book)');
    expect(AudiobookPlayer.instance.book, isNotNull, reason: 'the book keeps its place in its bar and on its page');
    expect(AudiobookPlayer.instance.playing, isFalse);
    await Bed.openSection(t, 'audiobooks');
    await Bed.settle(t, rounds: 3);
    expect(find.descendant(of: find.byType(TvNowPlaying), matching: find.byType(BookMiniBar)), findsOneWidget, reason: 'on a TV the book shows at the top of Audiobooks');
    await AudiobookPlayer.instance.seek(const Duration(minutes: 3));
    expect(AudiobookPlayer.instance.position.value, const Duration(minutes: 3));
    Bed.audioCalls.clear();
    // (not waited for: the bed's audio engine never says a file has loaded)
    AudiobookPlayer.instance.toggle().ignore();
    await Bed.settle(t, rounds: 2);
    final again = [for (final c in Bed.audioCalls) if (c.startsWith('mpv_audio_player_2 ')) c];
    expect(again.where((c) => c.contains('name: start') && c.contains('180')), isNotEmpty, reason: 'play opens it again at the second it was at ($again)');
    expect(again.where((c) => c.contains('loadfile')), isNotEmpty);
    await t.pumpWidget(const SizedBox());
    await quiet(t);
  }, variant: tv);
}
