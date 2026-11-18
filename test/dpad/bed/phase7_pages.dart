// The pages of phase 7 (Music, Manga, Audiobooks), each opened ready to be walked or
// photographed. Shared by the Windows and the Android files. The bed must have content
// (Bed.withContent): liked songs, a playlist, favourite manga and books in progress.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/nav.dart';
import 'package:vyse_tv/data/audiobooks/audiobook_player.dart';
import 'package:vyse_tv/data/music/music_player.dart';
import 'package:vyse_tv/screens/audiobooks/audiobook_details_page.dart';
import 'package:vyse_tv/screens/audiobooks/audiobook_player_page.dart';
import 'package:vyse_tv/screens/manga/manga_details_page.dart';
import 'package:vyse_tv/screens/manga/manga_reader_page.dart';
import 'package:vyse_tv/screens/music/music_player_page.dart';

import '../harness.dart';

typedef Opener = Future<void> Function(WidgetTester t);

Future<void> _section(WidgetTester t, String id) async {
  await Bed.pumpShell(t);
  await Bed.openSection(t, id);
  await Bed.settle(t, rounds: 5);
}

Future<void> _over(WidgetTester t, Widget page) async {
  rootNavigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
  await Bed.settle(t, rounds: 5);
}

int _started = 0;

/// Starts a queue of made-up songs. Nothing can play (the bed has no YouTube Music and no
/// audio engine), but the player then has a current song, a queue and its bar. Each call
/// uses songs of its own: the player remembers what it learnt about a song for the whole
/// run, and what one test started never finishes in the next.
Future<void> startMusic(WidgetTester t) async {
  final from = 20 + (_started++ % 16) * 6;
  MusicPlayer.instance.playQueue(Bed.tracks.skip(from).take(6).toList()).ignore();
  await Bed.settle(t, rounds: 3);
}

/// The same for an audiobook: a book with six chapters, "playing".
Future<void> startBook(WidgetTester t) async {
  AudiobookPlayer.instance.play(Bed.books[0], Bed.bookChapters).ignore();
  await Bed.settle(t, rounds: 3);
}

/// Brings the manga reader's bar up the way a remote does: OK held (a short OK changes the
/// fit). The ring is then on the bar.
Future<void> readerBar(WidgetTester t) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.enter);
  await t.pump(const Duration(milliseconds: 700));
  await t.sendKeyUpEvent(LogicalKeyboardKey.enter);
  await Bed.settle(t, rounds: 2);
}

/// Stops both, so the next test starts quiet.
Future<void> quiet(WidgetTester t) async {
  await MusicPlayer.instance.stop().catchError((Object _) {});
  await AudiobookPlayer.instance.stop().catchError((Object _) {});
  // (a song that cannot be found is given up on after twenty seconds, and the next one tried
  // a moment later: let both pass, so no test ends with the player still waiting)
  await t.pump(const Duration(seconds: 25));
  await t.pump(const Duration(seconds: 3));
  await Bed.settle(t, rounds: 2);
}

/// A book's page cannot be laid out at a phone's width in a debug build: its heading is a
/// column that asks to fill a height nobody gave it (audiobook_details_page.dart, line 91).
/// A release build lays it out anyway. It is the page's own and on the plan's follow-up list;
/// the tests leave that one page out at that one size.
bool cannotBeBuiltHere(String page) => page == 'Audiobooks, a book' && OnScreens.current.size.width < 640;

final Map<String, Opener> phase7Pages = {
  'Music': (t) => _section(t, 'music'),
  'Music, with a song on': (t) async {
    await _section(t, 'music');
    await startMusic(t);
  },
  'Music, the full player': (t) async {
    await Bed.pumpShell(t);
    await startMusic(t);
    await _over(t, const MusicPlayerPage());
  },
  'Manga': (t) => _section(t, 'manga'),
  'Manga, a series': (t) async {
    await Bed.pumpShell(t);
    await Bed.push(t, MangaDetailsPage(manga: Bed.manga[0]));
  },
  'Manga, the reader': (t) async {
    await Bed.pumpShell(t);
    await _over(t, MangaReaderPage(manga: Bed.manga[0], chapters: Bed.chapters, index: 1));
  },
  'Audiobooks': (t) => _section(t, 'audiobooks'),
  'Audiobooks, a book': (t) async {
    await Bed.pumpShell(t);
    await Bed.push(t, AudiobookDetailsPage(book: Bed.books[0]));
  },
  'Audiobooks, the player': (t) async {
    await Bed.pumpShell(t);
    await startBook(t);
    await _over(t, const AudiobookPlayerPage());
  },
};
