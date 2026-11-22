import 'package:shared_preferences/shared_preferences.dart';

import '../catalog/tmdb.dart' show Media;
import '../playback/watch_progress.dart';
import 'library_import.dart';
import 'media_ref.dart';
import 'remote_library.dart';
import 'simkl_tracker.dart';
import 'tracker.dart';
import 'trakt_tracker.dart';

/// What you watch on Trakt and Simkl (with another app, or marked on their sites) comes into
/// VyseTV: films and episodes watched there are ticked here, and History and Continue watching
/// follow. It looks at app start and when the app comes back, at most every 15 minutes for
/// Trakt and every 2 hours for Simkl (whose daily allowance is small), and only asks for more
/// when the service says something was watched since the last look.
///
/// What comes in is never sent anywhere: not back to that service, not to the other one. It
/// reaches your other devices through Vyse Sync like anything else in History, and they don't
/// send it on either. Watched is a union: something already watched here is left as it is, and
/// something marked unwatched here after the watch there stays unwatched
/// ([WatchProgress.withWatched]).
class WatchedSync {
  static const _traktEvery = Duration(minutes: 15);
  static const _simklEvery = Duration(hours: 2);

  /// How far back the first look goes. Older watches come in with Import.
  static const firstLook = Duration(days: 30);

  /// Titles new to VyseTV at most per look, newest first.
  static const newTitles = 100;

  static bool _busy = false;

  static String _k(TrackerId id, String what) => 'trackers.${id.name}.watched.$what';

  /// Looks at the services [on] says to (signed in, and "Scrobble what I watch" on), each when
  /// it's due ([force]: now). Returns how many titles changed.
  static Future<int> pull({required bool Function(TrackerId id) on, TrackerId? only, bool force = false}) async {
    if (_busy) return 0;
    _busy = true;
    try {
      final p = await SharedPreferences.getInstance();
      var n = 0;
      for (final id in const [TrackerId.trakt, TrackerId.simkl]) {
        if ((only != null && id != only) || !on(id)) continue;
        final last = DateTime.fromMillisecondsSinceEpoch(p.getInt(_k(id, 'at')) ?? 0);
        if (!force && DateTime.now().difference(last) < (id == TrackerId.trakt ? _traktEvery : _simklEvery)) continue;
        // the user's other Simkl apps share the daily allowance: keep the last of it for scrobbles
        if (id == TrackerId.simkl && (SimklTracker.remaining ?? 500) < 50) continue;
        try {
          n += id == TrackerId.trakt ? await _trakt(p) : await _simkl(p);
          await p.setInt(_k(id, 'at'), DateTime.now().millisecondsSinceEpoch);
        } catch (_) {
          // offline, signed out or busy: the next look tries again from the same place
        }
      }
      return n;
    } finally {
      _busy = false;
    }
  }

  static Future<int> _trakt(SharedPreferences p) async {
    const id = TrackerId.trakt;
    final since = DateTime.tryParse(p.getString(_k(id, 'since')) ?? '') ?? DateTime.now().subtract(firstLook);
    final r = await TraktTracker.watchedSince(since, movies: p.getString(_k(id, 'movies')), episodes: p.getString(_k(id, 'episodes')));
    final n = await apply(r.plays);
    // next time from Trakt's own latest watched time (its clock, not this device's), less a
    // minute to be safe: a play seen twice changes nothing
    var next = since;
    for (final t in [DateTime.tryParse(r.movies), DateTime.tryParse(r.episodes)]) {
      if (t != null && t.subtract(const Duration(minutes: 1)).isAfter(next)) next = t.subtract(const Duration(minutes: 1));
    }
    await p.setString(_k(id, 'since'), next.toUtc().toIso8601String());
    await p.setString(_k(id, 'movies'), r.movies);
    await p.setString(_k(id, 'episodes'), r.episodes);
    return n;
  }

  static Future<int> _simkl(SharedPreferences p) async {
    const id = TrackerId.simkl;
    final r = await SimklTracker.watchedSince(p.getString(_k(id, 'cursor')));
    final n = await apply(r.watched);
    if (r.cursor != null) await p.setString(_k(id, 'cursor'), r.cursor!);
    return n;
  }

  /// Starts over (a service disconnected: another account may be connected next).
  static Future<void> forget(TrackerId id) async {
    final p = await SharedPreferences.getInstance();
    for (final what in const ['at', 'since', 'movies', 'episodes', 'cursor']) {
      await p.remove(_k(id, what));
    }
  }

  /// Puts [watched] (one per film or episode watched there) into History. Returns how many
  /// titles changed.
  static Future<int> apply(List<RemoteTitle> watched) async {
    if (watched.isEmpty) return 0;
    await LibraryImport.resolveIds(watched);
    final byTitle = <String, Map<String, DateTime>>{};
    final first = <String, RemoteTitle>{};
    for (final t in watched) {
      final k = t.key;
      if (k == null) continue;
      final episode = t.season != null && t.episode != null;
      if (t.kind == MediaKind.show && !episode) continue;
      final item = episode ? WatchProgress.itemKey(season: t.season, episode: t.episode) : WatchProgress.film;
      final items = byTitle[k] ??= {};
      if (items[item] == null || t.at.isAfter(items[item]!)) items[item] = t.at;
      first[k] ??= t;
    }
    DateTime latest(String k) => byTitle[k]!.values.reduce((a, b) => a.isAfter(b) ? a : b);
    final here = <String, Media>{for (final e in WatchProgress.entries.value) e.media.key: e.media};
    final fresh = byTitle.keys.where((k) => !here.containsKey(k)).toList()..sort((a, b) => latest(b).compareTo(latest(a)));
    final found = await LibraryImport.mediaFor([for (final k in fresh.take(newTitles)) first[k]!]);
    return WatchProgress.applyWatched([
      for (final MapEntry(key: k, value: items) in byTitle.entries)
        if (here[k] ?? found[k]?.media case final m?) (media: m, items: items, runtime: found[k]?.runtime),
    ]);
  }
}
