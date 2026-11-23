import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/anime/anilist.dart';
import '../../data/catalog/tmdb.dart';
import '../../data/playback/watch_progress.dart';
import '../player/player_episodes.dart';
import '../player/player_page.dart' show PlayerEpisode;

/// Continue watching's "Up next": a show whose episode was watched to the end stays on the row
/// with the episode after it, once that one is out.
///
/// Only shows that could have one are asked about: the episode they're on finished, not taken
/// off the row, watched in the last [window]. Each answer is kept on the device with the episode
/// it follows, so Home opening again asks nothing; it is asked again only once the show has moved
/// on, once an episode that wasn't out yet is due, or after a few days of "nothing after it".
/// Shows waiting for an answer are asked one at a time, the most recently watched first.
abstract final class UpNext {
  /// Shows last watched longer ago than this aren't offered an episode, nor asked about.
  static const window = Duration(days: 90);

  /// "Nothing after it": asked again after this, or after [overRecheck] for a show that has ended.
  static const recheck = Duration(days: 3);
  static const overRecheck = Duration(days: 30);

  /// A question that failed (offline, the service down) is asked again after this.
  static const retry = Duration(minutes: 10);

  static const _key = 'watch.upNext';

  /// Goes up each time an answer comes in.
  static final answered = ValueNotifier<int>(0);

  static final _answers = <String, _Answer>{};
  static SharedPreferences? _prefs;
  static Future<void>? _loading;

  /// Reads the answers kept on the device. At start, with the rest of what's watched, so the
  /// row has its cards from its first frame.
  static Future<void> initialize() => _loading ??= () async {
    final p = _prefs = await SharedPreferences.getInstance();
    try {
      final raw = p.getString(_key);
      if (raw == null) return;
      (json.decode(raw) as Map).forEach((k, v) {
        final a = _Answer.fromJson(v as Map);
        if (a != null) _answers['$k'] = a;
      });
      answered.value++;
    } catch (_) {}
  }();

  /// Whether [e] is a show that could have an episode after the one it's on.
  static bool couldHaveNext(WatchEntry e, [DateTime? now]) =>
      e.season != null && e.episode != null && e.media.isTv && e.finished && !e.hidden && (now ?? DateTime.now()).difference(e.updated) < window;

  /// The episode to offer for [e]: the one after the episode it's on, when that one is out.
  /// Null for a film, a show still part-way through an episode, or one with nothing after it
  /// (or not known yet).
  static PlayerEpisode? of(WatchEntry e) {
    final now = DateTime.now();
    if (!couldHaveNext(e, now)) return null;
    final a = _answers[e.media.key];
    if (a == null || a.after != _item(e) || a.next == null) return null;
    final out = a.out;
    return out == null || !out.isAfter(now) ? a.next : null;
  }

  /// Whether [e]'s show is waiting for an answer, or being asked about now.
  static bool asking(WatchEntry e) => _queue.contains(e.media.key) || _inFlight?.$1 == e.media.key;

  /// Asks about the shows in [entries] that need it (see [UpNext]); nothing for the rest.
  static void lookUp(List<WatchEntry> entries) {
    final loaded = _prefs != null;
    if (!loaded) {
      initialize().then((_) => lookUp(WatchProgress.entries.value), onError: (Object _) {});
      return;
    }
    final now = DateTime.now();
    _queue
      ..clear()
      ..addAll([
        for (final e in entries)
          if (_needs(e, now)) e.media.key,
      ]);
    _run();
  }

  static String _item(WatchEntry e) => WatchProgress.itemKey(season: e.season, episode: e.episode);

  /// Whether [e] has to be asked about: a show that could have a next episode, with no answer
  /// for the episode it's on, or one that has gone stale. Not while that's being asked already,
  /// nor straight after it failed.
  static bool _needs(WatchEntry e, DateTime now) {
    if (!couldHaveNext(e, now)) return false;
    final key = e.media.key, item = _item(e);
    if (_inFlight == (key, item)) return false;
    final failed = _failed[key];
    if (failed != null && failed.$1 == item && now.difference(failed.$2) < retry) return false;
    final a = _answers[key];
    return a == null || a.after != item || !a.fresh(now);
  }

  /// Shows waiting to be asked about, most recently watched first.
  static final _queue = <String>[];

  /// The show being asked about now, and the episode its answer follows.
  static (String, String)? _inFlight;

  /// When asking about a show last failed, and for which episode.
  static final _failed = <String, (String, DateTime)>{};

  /// Each show's episode list, kept for a while: asked again once it has moved on (an episode
  /// marked watched on the card), the season it's in is already here.
  static final _stores = <String, (EpisodeStore, DateTime)>{};
  static const _storeLife = Duration(hours: 6);

  /// Changes each time [debugReset] runs, so a question from before it is dropped.
  static int _round = 0;
  static bool _busy = false;

  static Future<void> _run() async {
    if (_busy) return;
    _busy = true;
    final round = _round;
    try {
      while (_queue.isNotEmpty && round == _round) {
        final key = _queue.removeAt(0);
        final e = WatchProgress.entries.value.where((x) => x.media.key == key).firstOrNull;
        final now = DateTime.now();
        if (e == null || !_needs(e, now)) continue;
        final item = _item(e);
        _inFlight = (key, item);
        try {
          final a = await _ask(e, now);
          if (round != _round) return;
          _answers[key] = a;
          _failed.remove(key);
          _save();
        } catch (_) {
          if (round != _round) return;
          _failed[key] = (item, DateTime.now());
        } finally {
          if (round == _round) _inFlight = null;
        }
        answered.value++;
      }
    } finally {
      if (round == _round) _busy = false;
    }
  }

  /// The episode after the one [e] is on, from its episode list (an anime's AniList run, an addon
  /// title's from its addons).
  static Future<_Answer> _ask(WatchEntry e, DateTime now) async {
    final key = e.media.key;
    final kept = _stores[key];
    Anime? anime;
    final EpisodeStore store;
    if (kept != null && now.difference(kept.$2) < _storeLife) {
      store = kept.$1;
      if (store is AnimeEpisodeStore) anime = store.anime;
    } else {
      if (e.media.anime) anime = await AniList.details(e.media.id);
      store = anime != null ? AnimeEpisodeStore(anime) : EpisodeStore(e.media);
      _stores[key] = (store, now);
    }
    final next = await store.after(PlayerEpisode(season: e.season!, number: e.episode!));
    return _Answer(
      after: _item(e),
      asked: now,
      next: next?.toPlayer(),
      // (an anime's that isn't out yet has a date even when nobody knows it: a week from now)
      out: next != null && next.upcoming ? next.aired : null,
      over: next == null && await _over(e.media, anime),
    );
  }

  /// Whether the show has ended (or was cancelled): nothing will come after its last episode.
  static Future<bool> _over(Media m, Anime? anime) async {
    if (anime != null) return anime.status == 'FINISHED' || anime.status == 'CANCELLED';
    try {
      // (already here: finding there was no next season needed it)
      final status = (await HomeFeed.instance.details(m)).status?.toLowerCase() ?? '';
      return status == 'ended' || status == 'canceled' || status == 'cancelled';
    } catch (_) {
      return false;
    }
  }

  /// Keeps the answers (and episode lists) for titles still in History.
  static void _save() {
    final keys = {for (final e in WatchProgress.entries.value) e.media.key};
    _answers.removeWhere((k, _) => !keys.contains(k));
    _stores.removeWhere((k, _) => !keys.contains(k));
    _prefs?.setString(_key, json.encode({for (final MapEntry(:key, :value) in _answers.entries) key: value.toJson()}));
  }

  /// Forgets every answer and anything being asked (each test starts clean).
  @visibleForTesting
  static void debugReset() {
    _round++;
    _busy = false;
    _queue.clear();
    _inFlight = null;
    _failed.clear();
    _stores.clear();
    _answers.clear();
    _prefs?.remove(_key);
  }
}

/// What was found after one finished episode of a show.
class _Answer {
  const _Answer({required this.after, required this.asked, this.next, this.out, this.over = false});

  /// The finished episode this follows ("S1E3").
  final String after;
  final DateTime asked;

  /// The episode after it; null when there's none (yet).
  final PlayerEpisode? next;

  /// When [next] comes out, if it isn't out yet.
  final DateTime? out;

  /// With no [next]: the show has ended.
  final bool over;

  /// Whether it still holds: an episode that's out stays the one after; one not out yet is asked
  /// about again once it's due (dates move), and "nothing after it" after a few days.
  bool fresh(DateTime now) {
    final age = now.difference(asked);
    if (next == null) return age < (over ? UpNext.overRecheck : UpNext.recheck);
    final due = out;
    return due == null || (now.isBefore(due) && age < UpNext.recheck);
  }

  Map<String, dynamic> toJson() => {
    'a': after,
    't': asked.millisecondsSinceEpoch,
    if (next case final n?) 'n': {'s': n.season, 'e': n.number, 'name': ?n.name, 'r': ?n.runtime},
    if (out case final o?) 'o': o.millisecondsSinceEpoch,
    if (over) 'x': true,
  };

  static _Answer? fromJson(Map j) {
    try {
      final n = j['n'] as Map?;
      return _Answer(
        after: j['a'] as String,
        asked: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        next: n == null ? null : PlayerEpisode(season: n['s'] as int, number: n['e'] as int, name: n['name'] as String?, runtime: n['r'] as int?),
        out: j['o'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['o'] as int),
        over: j['x'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
