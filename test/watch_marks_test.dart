// Watched and unwatched by hand (lib/data/playback/watch_progress.dart), and the rules for when
// two copies meet: this device's and the account's, or a watch from Trakt or Simkl. Also what
// the tracker outbox does with a mark and its undo (lib/data/trackers/outbox.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';
import 'package:vyse_tv/data/trackers/outbox.dart';
import 'package:vyse_tv/data/trackers/tracker.dart';

final film = Media.fromJson({'id': 1, 'title': 'A Film', 'release_date': '2020-01-01'}, tv: false);
final show = Media.fromJson({'id': 2, 'name': 'A Show', 'first_air_date': '2021-01-01'}, tv: true);

DateTime at(int minute) => DateTime(2026, 11, 20, 12).add(Duration(minutes: minute));
EpisodeMark ep(int s, int n) => (season: s, number: n, name: null, runtime: 40);

WatchEntry entry({
  required Media media,
  int? season,
  int? episode,
  int position = 10,
  int duration = 40,
  required DateTime updated,
  Map<String, double> episodes = const {},
  Map<String, int> marks = const {},
}) => WatchEntry(
  media: media,
  season: season,
  episode: episode,
  position: Duration(minutes: position),
  duration: Duration(minutes: duration),
  updated: updated,
  episodes: episodes,
  marks: marks,
);

void main() {
  setUp(() => WatchProgress.entries.value = const []);

  group('marking by hand', () {
    test('a film marked watched is finished and leaves Continue watching; unwatched goes back to the start, out of sight', () {
      WatchProgress.record(film, position: const Duration(minutes: 30), duration: const Duration(minutes: 100));
      expect(WatchProgress.continueWatching.map((e) => e.media.key), [film.key]);

      expect(WatchProgress.markFilm(film, watched: true, at: at(1)), isTrue);
      final w = WatchProgress.find(film)!;
      expect(w.finished, isTrue, reason: 'the same "finished" as playing to the end');
      expect(w.duration, const Duration(minutes: 100), reason: 'its real length is kept');
      expect(WatchProgress.continueWatching, isEmpty);
      expect(WatchProgress.isSeen(film), isTrue);
      expect(WatchProgress.markFilm(film, watched: true, at: at(2)), isFalse, reason: 'already watched: nothing changes, nothing to send');

      expect(WatchProgress.markFilm(film, watched: false, at: at(3)), isTrue);
      final u = WatchProgress.find(film)!;
      expect(u.finished, isFalse);
      expect(u.position, Duration.zero);
      expect(u.blank, isTrue, reason: 'nothing watched: not shown in History');
      expect(u.inContinue, isFalse, reason: 'and not on Continue watching at 0%');
      expect(u.marks[WatchProgress.film], -at(3).millisecondsSinceEpoch, reason: 'the unwatched mark and when');
    });

    test('a film never started, marked watched, gets an entry of its own length', () {
      WatchProgress.markFilm(film, watched: true, runtime: 95, at: at(0));
      final w = WatchProgress.find(film)!;
      expect(w.duration, const Duration(minutes: 95));
      expect(w.finished, isTrue);
    });

    test('the episode Continue watching is on, marked watched, leaves it; others are just ticked', () {
      WatchProgress.record(show, position: const Duration(minutes: 12), duration: const Duration(minutes: 40), season: 1, episode: 3);
      expect(WatchProgress.continueWatching, hasLength(1));

      final first = WatchProgress.markEpisodes(show, [ep(1, 1), ep(1, 2)], watched: true, at: at(1));
      expect(first, hasLength(2));
      expect(WatchProgress.continueWatching, hasLength(1), reason: 'marking other episodes leaves S1E3 on the go');
      expect(WatchProgress.find(show)!.episode, 3);

      WatchProgress.markEpisodes(show, [ep(1, 3)], watched: true, at: at(2));
      final e = WatchProgress.find(show)!;
      expect(e.finished, isTrue);
      expect(WatchProgress.continueWatching, isEmpty);
      expect([for (var n = 1; n <= 3; n++) e.seen('S1E$n')], [true, true, true]);
      expect(WatchProgress.markEpisodes(show, [ep(1, 2)], watched: true, at: at(3)), isEmpty, reason: 'already watched');
    });

    test('with nothing on the go, the latest episode marked becomes where the show is', () {
      WatchProgress.markEpisodes(show, [ep(1, 1)], watched: true, at: at(0));
      WatchProgress.markEpisodes(show, [ep(1, 4), ep(1, 2), ep(2, 1)], watched: true, at: at(1));
      final e = WatchProgress.find(show)!;
      expect((e.season, e.episode), (2, 1));
      expect(e.finished, isTrue);
    });

    test('the finished episode it is on, marked unwatched, goes back to the start and off the row', () {
      WatchProgress.markEpisodes(show, [ep(1, 1), ep(1, 2)], watched: true, at: at(0));
      WatchProgress.markEpisodes(show, [ep(1, 2)], watched: false, at: at(1));
      final e = WatchProgress.find(show)!;
      expect(e.seen('S1E2'), isFalse);
      expect(e.seen('S1E1'), isTrue);
      expect(e.position, Duration.zero);
      expect(e.inContinue, isFalse);
      expect(e.blank, isFalse, reason: 'S1E1 is still watched: it stays in History');
      expect(e.marks['S1E2'], -at(1).millisecondsSinceEpoch);
    });

    test('played to the end after being marked unwatched: watched again, as of then', () {
      WatchProgress.markEpisodes(show, [ep(1, 1)], watched: true, at: at(0));
      WatchProgress.markEpisodes(show, [ep(1, 1)], watched: false, at: at(1));
      WatchProgress.record(show, position: const Duration(minutes: 39), duration: const Duration(minutes: 40), season: 1, episode: 1);
      final e = WatchProgress.find(show)!;
      expect(e.seen('S1E1'), isTrue);
      expect(e.marks['S1E1']!, greaterThan(0));
    });
  });

  group('watched elsewhere (Trakt, Simkl)', () {
    test('a union: something already watched here is left alone', () {
      final old = entry(media: show, season: 1, episode: 2, position: 40, updated: at(5), episodes: {'S1E2': 1});
      expect(WatchProgress.withWatched(old, show, {'S1E2': at(9)}), isNull, reason: 'nothing changes, so nothing goes anywhere');
    });

    test('marked unwatched here after the watch there: stays unwatched', () {
      final old = entry(media: show, season: 1, episode: 1, position: 40, updated: at(10), episodes: {'S1E1': 1}, marks: {'S1E2': -at(10).millisecondsSinceEpoch});
      expect(WatchProgress.withWatched(old, show, {'S1E2': at(5)}), isNull);
    });

    test('watched there after it was marked unwatched here: watched, and the mark says when', () {
      final old = entry(media: show, season: 1, episode: 1, position: 40, updated: at(10), episodes: {'S1E1': 1}, marks: {'S1E2': -at(5).millisecondsSinceEpoch});
      final e = WatchProgress.withWatched(old, show, {'S1E2': at(10)})!;
      expect(e.seen('S1E2'), isTrue);
      expect(e.marks['S1E2'], at(10).millisecondsSinceEpoch);
    });

    test('the episode on the go here, finished there later: it leaves Continue watching', () {
      final old = entry(media: show, season: 1, episode: 3, position: 12, updated: at(0), episodes: {'S1E3': .3});
      final e = WatchProgress.withWatched(old, show, {'S1E3': at(30)})!;
      expect(e.finished, isTrue);
      expect(e.inContinue, isFalse);
      expect(e.updated, at(30));
    });

    test('a watch there older than what was played here only adds the tick', () {
      final old = entry(media: show, season: 1, episode: 3, position: 12, updated: at(30), episodes: {'S1E3': .3});
      final e = WatchProgress.withWatched(old, show, {'S1E1': at(5)})!;
      expect(e.seen('S1E1'), isTrue);
      expect((e.episode, e.position, e.updated), (3, const Duration(minutes: 12), at(30)), reason: 'Continue watching is as it was');
    });

    test('a film being watched again here is not finished by an older watch there', () {
      final old = entry(media: film, position: 20, duration: 100, updated: at(30));
      expect(WatchProgress.withWatched(old, film, {WatchProgress.film: at(5)}), isNull);
      final e = WatchProgress.withWatched(old, film, {WatchProgress.film: at(40)})!;
      expect(e.finished, isTrue);
    });

    test('a title new here gets an entry, finished on the latest episode watched there', () {
      final e = WatchProgress.withWatched(null, show, {'S1E1': at(1), 'S1E5': at(9), 'S1E2': at(3)}, runtime: 50)!;
      expect((e.season, e.episode, e.finished, e.updated), (1, 5, true, at(9)));
      expect(e.episodesFinished, 3);
      expect(e.duration, const Duration(minutes: 50));
    });

    test('applyWatched puts them in History, newest first, and counts what changed', () {
      WatchProgress.markFilm(film, watched: true, at: at(0));
      final n = WatchProgress.applyWatched([
        (media: film, items: {WatchProgress.film: at(50)}, runtime: null), // already watched: no change
        (media: show, items: {'S1E1': at(20)}, runtime: null),
      ]);
      expect(n, 1);
      expect(WatchProgress.entries.value.map((e) => e.media.key), [show.key, film.key]);
    });
  });

  group('this device and the account', () {
    test('each episode goes by whichever copy marked it last', () {
      final mine = entry(media: show, season: 1, episode: 1, position: 40, updated: at(10), episodes: {'S1E1': 1, 'S1E2': 1}, marks: {'S1E2': at(10).millisecondsSinceEpoch});
      final theirs = entry(media: show, season: 1, episode: 1, position: 40, updated: at(20), episodes: {'S1E1': 1, 'S1E3': 1}, marks: {'S1E2': -at(5).millisecondsSinceEpoch, 'S1E3': at(20).millisecondsSinceEpoch});
      final c = WatchProgress.combine(mine, theirs);
      expect(c.seen('S1E2'), isTrue, reason: 'marked watched here (10) after it was unwatched there (5)');
      expect(c.seen('S1E3'), isTrue, reason: 'marked there');
      expect(c.seen('S1E1'), isTrue);
      expect(c.updated, at(20), reason: 'the newer copy says where the show is');

      final later = entry(media: show, season: 1, episode: 1, position: 40, updated: at(30), episodes: {'S1E1': 1}, marks: {'S1E2': -at(30).millisecondsSinceEpoch});
      expect(WatchProgress.combine(c, later).seen('S1E2'), isFalse, reason: 'unwatched later wins');
    });

    test('an unwatched mark beats a tick with no time; the episode a copy is on counts as of its last change', () {
      final mine = entry(media: show, season: 1, episode: 4, position: 40, updated: at(1), episodes: {'S1E2': 1, 'S1E4': 1});
      final theirs = entry(media: show, season: 1, episode: 4, position: 40, updated: at(5), episodes: {'S1E4': 1}, marks: {'S1E2': -at(3).millisecondsSinceEpoch});
      expect(WatchProgress.combine(mine, theirs).seen('S1E2'), isFalse);

      // finished S1E4 here at 10, after it was marked unwatched there at 6
      final played = entry(media: show, season: 1, episode: 4, position: 40, updated: at(10), episodes: {'S1E4': 1});
      final unmarked = entry(media: show, season: 1, episode: 3, position: 0, updated: at(6), marks: {'S1E4': -at(6).millisecondsSinceEpoch});
      expect(WatchProgress.combine(played, unmarked).seen('S1E4'), isTrue);
      expect(WatchProgress.combine(unmarked, played).seen('S1E4'), isTrue, reason: 'the same either way round');
    });

    test('the episode the newer copy is on, unwatched by the other copy later: back to the start', () {
      final mine = entry(media: show, season: 1, episode: 2, position: 0, updated: at(8), episodes: {'S1E1': 1}, marks: {'S1E2': -at(8).millisecondsSinceEpoch});
      final theirs = entry(media: show, season: 1, episode: 2, position: 40, updated: at(9), episodes: {'S1E1': 1, 'S1E2': 1}, marks: {'S1E2': at(2).millisecondsSinceEpoch});
      final c = WatchProgress.combine(mine, theirs);
      expect(c.seen('S1E2'), isFalse);
      expect(c.position, Duration.zero, reason: 'its "finished" goes with the tick');
      expect(c.inContinue, isFalse);
    });

    test('combining is settled: doing it again, or the other way round, changes nothing more', () {
      final a = entry(media: show, season: 1, episode: 3, position: 12, updated: at(4), episodes: {'S1E1': 1, 'S1E3': .3}, marks: {'S1E2': -at(4).millisecondsSinceEpoch});
      final b = entry(media: show, season: 1, episode: 2, position: 40, updated: at(2), episodes: {'S1E2': 1, 'S1E5': 1}, marks: {'S1E5': at(1).millisecondsSinceEpoch});
      final c = WatchProgress.combine(a, b);
      expect(WatchProgress.combine(c, b).toJson(), c.toJson());
      expect(WatchProgress.combine(a, c).toJson(), c.toJson());
      expect(WatchProgress.combine(c, c).toJson(), c.toJson());
      expect(WatchProgress.combine(b, a).episodes, c.episodes);
      expect(WatchProgress.syncMerge(a.toJson(), b.toJson()), c.toJson());
    });

    test('the account copy arriving keeps the marks this device made', () async {
      WatchProgress.markEpisodes(show, [ep(1, 1), ep(1, 2)], watched: true, at: at(10));
      final theirs = entry(media: show, season: 1, episode: 5, position: 40, updated: at(20), episodes: {'S1E5': 1});
      await WatchProgress.syncApply(show.key, theirs.toJson());
      final e = WatchProgress.find(show)!;
      expect([e.seen('S1E1'), e.seen('S1E2'), e.seen('S1E5')], [true, true, true]);
      expect(e.episode, 5, reason: 'where the newer copy is');
      await WatchProgress.syncApply(show.key, null);
      expect(WatchProgress.find(show), isNull, reason: 'removed from History on another device: removed here');
    });

    test('marks survive the trip through JSON', () {
      final e = entry(media: show, season: 1, episode: 1, updated: at(0), episodes: {'S1E1': 1}, marks: {'S1E1': 5, 'S1E2': -7});
      expect(WatchEntry.fromJson(e.toJson()).marks, {'S1E1': 5, 'S1E2': -7});
      expect(entry(media: film, updated: at(0)).toJson().containsKey('w'), isFalse, reason: 'nothing added when there are none');
    });
  });

  group('the outbox', () {
    setUp(() => Outbox.removeService(TrackerId.trakt));
    OutboxItem item(String kind) => OutboxItem(service: TrackerId.trakt, kind: kind, key: 'tv/2/1/3', data: {'ref': {}});

    test('unwatched replaces a watched still waiting; watched again brings that one back', () {
      Outbox.put(item('watched'));
      Outbox.put(item('unwatched'));
      expect(Outbox.items.map((i) => i.kind), ['unwatched'], reason: 'it still goes: Trakt may have the play from elsewhere');
      Outbox.put(item('watched'));
      expect(Outbox.items.map((i) => i.kind), ['watched'], reason: 'the first watched never went: it is back');
    });

    test('watched after an unwatched still waiting: the two cancel, so the play is not sent twice', () {
      Outbox.put(item('unwatched'));
      Outbox.put(item('watched'));
      expect(Outbox.items, isEmpty);
    });
  });
}
