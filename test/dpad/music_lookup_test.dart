// Music lookups (2026-11-23): the user said YouTube Music plays hit and miss. Measured that day
// against YouTube with the app's own lookup: 2 of 34 songs came back with nothing (the lookup's
// own time-out on a candidate, not YouTube refusing), both answered when asked again a moment
// later, and every song waited 3-8 s for its lookup. So the player asks once more when nothing
// comes back (never more than twice), and looks the next song up while one plays. Here the
// lookup is made up; nothing is asked of the network.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/music/music_player.dart';
import 'package:vyse_tv/models/music/music_track.dart';

import 'harness.dart';

MusicTrack _song(String id) => MusicTrack.fromJson({'id': id, 'title': 'Song $id', 'artist': 'Someone', 'durationSeconds': 200});

/// An address the made-up lookup gives: good for six hours, like YouTube's.
MusicAddress _address(String id) => (
  url: 'https://media.test/$id.webm?expire=${DateTime.now().add(const Duration(hours: 6)).millisecondsSinceEpoch ~/ 1000}',
  userAgent: null,
);

/// The app's music player (made once the bed is up).
MusicPlayer get player => MusicPlayer.instance;

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  final asked = <String, int>{};
  setUp(asked.clear);
  tearDown(() async {
    MusicPlayer.debugLookup = null;
    await player.stop();
  });

  /// Lets the player's waits run (the second ask comes 1.5 s after the first).
  Future<void> wait(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 500));
    }
  }

  testWidgets('a lookup that finds nothing is asked once more, and the song plays', (t) async {
    MusicPlayer.debugLookup = (s) async => (asked[s.id] = (asked[s.id] ?? 0) + 1) == 1 ? null : _address(s.id);
    player.playQueue([_song('a1')]).ignore();
    await wait(t);
    expect(asked['a1'], 2, reason: 'nothing the first time: asked again');
    expect((player.current?.id, player.error, player.resolving), ('a1', null, false), reason: 'and it plays');
  });

  testWidgets('never more than twice: a song that finds nothing either time is given up', (t) async {
    MusicPlayer.debugLookup = (s) async {
      asked[s.id] = (asked[s.id] ?? 0) + 1;
      return null;
    };
    player.playQueue([_song('b1')]).ignore();
    await wait(t);
    await wait(t);
    expect(asked['b1'], 2, reason: 'a burst of lookups is what makes YouTube refuse a device');
    expect(player.error, contains('Song b1'), reason: 'and it says so');
  });

  testWidgets('the next song is looked up while one plays, and starts from what that found', (t) async {
    MusicPlayer.debugLookup = (s) async {
      asked[s.id] = (asked[s.id] ?? 0) + 1;
      return _address(s.id);
    };
    player.playQueue([_song('c1'), _song('c2'), _song('c3')]).ignore();
    await wait(t);
    expect((asked['c1'], asked['c2']), (1, null), reason: 'only the song on now, at first');
    player.debugLookAhead();
    await wait(t);
    expect(asked['c2'], 1, reason: 'the next one is looked up ahead');
    expect(asked['c3'], isNull, reason: 'only the next one');
    player.next().ignore();
    await wait(t);
    expect((player.current?.id, player.error), ('c2', null));
    expect(asked['c2'], 1, reason: 'it starts from what was found ahead, not asking again');
  });

  testWidgets('a song looked up ahead that found nothing is asked again when it comes on', (t) async {
    MusicPlayer.debugLookup = (s) async {
      final n = asked[s.id] = (asked[s.id] ?? 0) + 1;
      return s.id == 'd2' && n <= 2 ? null : _address(s.id);
    };
    player.playQueue([_song('d1'), _song('d2')]).ignore();
    await wait(t);
    player.debugLookAhead();
    await wait(t);
    expect(asked['d2'], 2, reason: 'ahead: asked, and once more after nothing');
    player.next().ignore();
    await wait(t);
    expect((player.current?.id, player.error), ('d2', null), reason: 'asked again when it came on, and it plays');
    expect(asked['d2'], 3);
  });
}
