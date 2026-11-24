// Each episode keeps its own resume spot, and the source a show was played from is remembered.
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';

final show = Media.fromJson({'id': 2, 'name': 'A Show', 'first_air_date': '2021-01-01'}, tv: true);

void rec(int e, int min, {Map<String, dynamic>? pick}) =>
    WatchProgress.record(show, position: Duration(minutes: min), duration: const Duration(minutes: 40), season: 1, episode: e, pick: pick);

void main() {
  setUp(() => WatchProgress.entries.value = const []);

  test('going back to an earlier episode resumes at its own spot', () {
    rec(1, 12);
    rec(2, 5);
    expect(WatchProgress.resumeSeconds(show, season: 1, episode: 1), 12 * 60);
    expect(WatchProgress.resumeSeconds(show, season: 1, episode: 2), 5 * 60);
    expect(WatchProgress.resumeSeconds(show, season: 1, episode: 3), 0);
  });

  test('a finished episode has no spot', () {
    rec(1, 12);
    rec(1, 39);
    rec(2, 5);
    expect(WatchProgress.resumeSeconds(show, season: 1, episode: 1), 0);
  });

  test('the pick stays through later saves and survives JSON', () {
    rec(1, 12, pick: {'a': 'https://x/manifest.json', 'b': 'g', 'q': '1080p', 'c': false});
    rec(2, 5);
    final e = WatchProgress.find(show)!;
    expect(e.pick!['a'], 'https://x/manifest.json');
    final back = WatchEntry.fromJson(e.toJson());
    expect(back.pick, e.pick);
    expect(back.positions, e.positions);
  });
}
