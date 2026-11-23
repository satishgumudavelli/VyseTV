import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../catalog/tmdb.dart';

/// One episode to mark watched or unwatched: its season and number (anime: season 0, numbered
/// straight through), and its name and length in minutes when known.
typedef EpisodeMark = ({int season, int number, String? name, int? runtime});

/// Where the viewer is (or was) in a film or a show. One per title; the newest first.
class WatchEntry {
  const WatchEntry({
    required this.media,
    required this.position,
    required this.duration,
    required this.updated,
    this.season,
    this.episode,
    this.episodeName,
    this.hidden = false,
    this.episodes = const {},
    this.subtitle,
    this.subDelay = 0,
    this.marks = const {},
    this.server,
  });

  final Media media;
  final int? season;
  final int? episode;
  final String? episodeName;
  final Duration position;
  final Duration duration;
  final DateTime updated;

  /// Taken off the Continue watching row by hand (still in History).
  final bool hidden;

  /// Shows: furthest point reached in each episode watched, keyed "S1E2", 0..1.
  final Map<String, double> episodes;

  /// The subtitle that was on for this film or episode (the file: provider, id, url, language…),
  /// or {'off': true} when they were turned off; null when nothing was chosen. Picked up again
  /// when you carry on watching, ahead of the default in Settings.
  final Map<String, dynamic>? subtitle;

  /// Its timing nudge, in seconds.
  final double subDelay;

  /// Watched and unwatched marks, and when they were made (ms since 1970; negative: marked
  /// unwatched), keyed like [episodes] ("S1E2"), or "film". Kept only where the time matters
  /// when two copies meet (another device's, a service's): a mark made by hand, and a watch that
  /// came after an unwatched mark. An unwatched mark keeps an older watch on Trakt or Simkl, or
  /// on another device, from bringing the episode back.
  final Map<String, int> marks;

  /// The VyseTV source it was last played from (a film source link's party key): asked first
  /// when you carry on, and for the next episode.
  final String? server;

  double get fraction => duration.inMilliseconds <= 0 ? 0 : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  Duration get left => duration - position;
  bool get finished => fraction >= WatchProgress.finishedAt;

  /// On the Continue watching row: started (something marked unwatched is back at the start),
  /// not finished, not taken off by hand.
  bool get inContinue => !finished && !hidden && position > Duration.zero;
  int get episodesFinished => episodes.values.where((f) => f >= WatchProgress.finishedAt).length;

  /// Nothing watched at all: everything in it was marked unwatched. Kept (so the unwatched marks
  /// travel), but not shown in History.
  bool get blank => position == Duration.zero && episodes.isEmpty;

  /// Whether the film (or episode "S1E2" of the show) counts as watched.
  bool seen(String item) => item == WatchProgress.film ? finished : (episodes[item] ?? 0) >= WatchProgress.finishedAt;

  WatchEntry copyWith({
    bool? hidden,
    Duration? position,
    Duration? duration,
    DateTime? updated,
    Map<String, double>? episodes,
    Map<String, int>? marks,
  }) => WatchEntry(
    media: media,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    updated: updated ?? this.updated,
    season: season,
    episode: episode,
    episodeName: episodeName,
    hidden: hidden ?? this.hidden,
    episodes: episodes ?? this.episodes,
    subtitle: subtitle,
    subDelay: subDelay,
    marks: marks ?? this.marks,
    server: server,
  );

  Map<String, dynamic> toJson() => {
    'media': {
      'id': media.id,
      'title': media.title,
      'tv': media.isTv,
      'overview': media.overview,
      'poster_path': media.posterPath,
      'backdrop_path': media.backdropPath,
      'vote_average': media.rating,
      'genre_ids': media.genreIds,
      'date': media.date.isNotEmpty ? media.date : (media.year ?? ''),
      if (media.anime) 'anime': true,
      ...media.addonFields,
    },
    if (season != null) 's': season,
    if (episode != null) 'e': episode,
    if (episodeName != null) 'n': episodeName,
    'p': position.inMilliseconds,
    'd': duration.inMilliseconds,
    'u': updated.millisecondsSinceEpoch,
    if (hidden) 'h': true,
    if (episodes.isNotEmpty) 'x': episodes,
    'sub': ?subtitle,
    if (subDelay != 0) 'sd': subDelay,
    if (marks.isNotEmpty) 'w': marks,
    'srv': ?server,
  };

  static WatchEntry fromJson(Map<String, dynamic> j) {
    final m = j['media'] as Map<String, dynamic>;
    final tv = m['tv'] as bool;
    final date = (m['date'] ?? '') as String;
    return WatchEntry(
      media: Media.fromJson({...m, tv ? 'first_air_date' : 'release_date': date}, tv: tv),
      season: j['s'] as int?,
      episode: j['e'] as int?,
      episodeName: j['n'] as String?,
      position: Duration(milliseconds: j['p'] as int),
      duration: Duration(milliseconds: j['d'] as int),
      updated: DateTime.fromMillisecondsSinceEpoch(j['u'] as int),
      hidden: j['h'] == true,
      episodes: {for (final e in ((j['x'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toDouble()},
      subtitle: j['sub'] is Map ? Map<String, dynamic>.from(j['sub'] as Map) : null,
      subDelay: (j['sd'] as num?)?.toDouble() ?? 0,
      marks: {for (final e in ((j['w'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toInt()},
      server: j['srv'] as String?,
    );
  }
}

/// Watch history, kept on this device. The Continue watching row is the unfinished part of it;
/// History shows all of it.
class WatchProgress {
  static final entries = ValueNotifier<List<WatchEntry>>(const []);
  static const _key = 'watch.progress';
  static const _max = 500;

  /// At or past this, a title counts as finished: it leaves Continue watching, stays in History.
  static const finishedAt = .95;
  static SharedPreferences? _prefs;

  static Future<void> initialize() async {
    final p = _prefs = await SharedPreferences.getInstance();
    try {
      final raw = p.getString(_key);
      if (raw == null) return;
      entries.value = [for (final e in (json.decode(raw) as List).cast<Map<String, dynamic>>()) ?_tryParse(e)];
    } catch (_) {}
  }

  static WatchEntry? _tryParse(Map<String, dynamic> j) {
    try {
      return WatchEntry.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  static bool _same(Media a, Media b) => a.key == b.key;

  static WatchEntry? find(Media m) => entries.value.where((e) => _same(e.media, m)).firstOrNull;

  /// What the Continue watching row shows.
  static List<WatchEntry> get continueWatching => entries.value.where((e) => e.inContinue).toList();

  /// Seconds into [media] (that episode, for shows) where you left it, or 0 when you didn't or
  /// finished it: where a watch party you start carries on from.
  static double resumeSeconds(Media media, {int? season, int? episode}) {
    final s = find(media);
    if (s == null || s.season != season || s.episode != episode || s.fraction >= finishedAt) return 0;
    return s.position.inMilliseconds / 1000;
  }

  /// Records where playback is. Anything actually started counts.
  static void record(
    Media media, {
    required Duration position,
    required Duration duration,
    int? season,
    int? episode,
    String? episodeName,
    Map<String, dynamic>? subtitle,
    double subDelay = 0,
    String? server,
  }) {
    if (duration < const Duration(minutes: 1) || position < const Duration(seconds: 3)) return;
    final old = find(media);
    final f = (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    final episodes = {...?old?.episodes};
    final marks = {...?old?.marks};
    final k = itemKey(season: season, episode: episode);
    if (k != film && f > (episodes[k] ?? 0)) episodes[k] = f;
    // watched to the end after it was marked unwatched: watched again, as of now
    if (f >= finishedAt && (marks[k] ?? 0) < 0) marks[k] = DateTime.now().millisecondsSinceEpoch;
    _set([
      WatchEntry(
        media: media,
        season: season,
        episode: episode,
        episodeName: episodeName,
        position: position,
        duration: duration,
        updated: DateTime.now(),
        episodes: episodes,
        subtitle: subtitle,
        subDelay: subDelay,
        marks: marks,
        server: server ?? old?.server,
      ),
      ...entries.value.where((e) => !_same(e.media, media)),
    ].take(_max).toList());
  }

  // ── watched and unwatched, by hand ──

  /// The film itself, as a mark's key.
  static const film = 'film';

  /// What a mark is about: an episode ("S1E2"; anime are season 0), or [film].
  static String itemKey({int? season, int? episode}) => season == null || episode == null ? film : 'S${season}E$episode';

  /// Whether [media] (that episode, for a show) counts as watched here.
  static bool isSeen(Media media, {int? season, int? episode}) => find(media)?.seen(itemKey(season: season, episode: episode)) ?? false;

  static int _ms(DateTime t) => t.millisecondsSinceEpoch;

  /// Marks a film watched (finished, as if played to the end: it leaves Continue watching) or
  /// unwatched (back at the start, and off Continue watching). [runtime] (minutes) is for a film
  /// never started here. False when it already was.
  static bool markFilm(Media media, {required bool watched, int? runtime, DateTime? at}) {
    final now = at ?? DateTime.now();
    final old = find(media);
    if ((old?.finished ?? false) == watched) return false;
    final d = old != null && old.duration > Duration.zero ? old.duration : Duration(minutes: runtime ?? 100);
    final mark = {film: watched ? _ms(now) : -_ms(now)};
    _put(
      old == null
          ? WatchEntry(media: media, position: d, duration: d, updated: now, marks: mark)
          : old.copyWith(position: watched ? d : Duration.zero, duration: d, updated: now, marks: {...old.marks, ...mark}),
    );
    return true;
  }

  /// Marks episodes of a show (or an anime) watched or unwatched. Watched counts as played to
  /// the end; unwatched takes the tick off. Continue watching follows: the episode it's on
  /// leaves it when marked watched, and an episode marked watched while nothing is on the go
  /// becomes where the show is. Returns the episodes that changed (ones already so are left).
  static List<EpisodeMark> markEpisodes(Media media, List<EpisodeMark> list, {required bool watched, DateTime? at}) {
    final now = at ?? DateTime.now();
    final old = find(media);
    final episodes = {...?old?.episodes};
    final marks = {...?old?.marks};
    final changed = <EpisodeMark>[];
    for (final e in list) {
      final k = itemKey(season: e.season, episode: e.number);
      if (((episodes[k] ?? 0) >= finishedAt) == watched) continue;
      if (watched) {
        episodes[k] = 1;
      } else {
        episodes.remove(k);
      }
      marks[k] = watched ? _ms(now) : -_ms(now);
      changed.add(e);
    }
    if (changed.isEmpty) return changed;
    final last = changed.reduce((a, b) => b.season > a.season || (b.season == a.season && b.number > a.number) ? b : a);
    final current = old?.season == null || old?.episode == null ? null : itemKey(season: old!.season, episode: old.episode);
    final onIt = changed.any((e) => itemKey(season: e.season, episode: e.number) == current);
    if (old == null || (watched && !onIt && !old.inContinue)) {
      final d = Duration(minutes: last.runtime ?? 45);
      _put(WatchEntry(
        media: old?.media ?? media,
        season: last.season,
        episode: last.number,
        episodeName: last.name,
        position: d,
        duration: d,
        updated: now,
        hidden: old?.hidden ?? false,
        episodes: episodes,
        marks: marks,
        server: old?.server,
      ));
      return changed;
    }
    final d = old.duration > Duration.zero ? old.duration : const Duration(minutes: 45);
    var position = old.position;
    if (onIt && watched) position = d;
    if (onIt && !watched && old.finished) position = Duration.zero;
    _put(old.copyWith(position: position, duration: d, updated: now, episodes: episodes, marks: marks));
    return changed;
  }

  /// Puts [e] in place of its title's entry, in date order.
  static void _put(WatchEntry e) {
    final rest = entries.value.where((x) => !_same(x.media, e.media)).toList();
    final i = rest.indexWhere((x) => !x.updated.isAfter(e.updated));
    rest.insert(i < 0 ? rest.length : i, e);
    _set(rest.take(_max).toList());
  }

  // ── watched elsewhere ──

  /// Watches from Trakt or Simkl, title by title: [WatchEntry]s changed or made for them.
  /// Returns how many titles changed. Nothing here is sent anywhere.
  static int applyWatched(List<({Media media, Map<String, DateTime> items, int? runtime})> titles) {
    final list = [...entries.value];
    var n = 0;
    for (final t in titles) {
      final i = list.indexWhere((e) => _same(e.media, t.media));
      final next = withWatched(i < 0 ? null : list[i], t.media, t.items, runtime: t.runtime);
      if (next == null) continue;
      if (i < 0) {
        list.add(next);
      } else {
        list[i] = next;
      }
      n++;
    }
    if (n == 0) return 0;
    list.sort((a, b) => b.updated.compareTo(a.updated));
    _set(list.take(_max).toList());
    return n;
  }

  /// [old] (null: nothing here yet) with watches from elsewhere: [items] by "S1E2" (or [film])
  /// and when. Watched is a union: one watched here already stays as it is, and one marked
  /// unwatched here after that watch stays unwatched. The newest watch moves the title on, as
  /// playing it here would, unless it's older than what was last done here or something else is
  /// on the go here. Null when nothing changes.
  @visibleForTesting
  static WatchEntry? withWatched(WatchEntry? old, Media media, Map<String, DateTime> items, {int? runtime}) {
    final episodes = {...?old?.episodes};
    final marks = {...?old?.marks};
    final took = <String, DateTime>{};
    for (final MapEntry(key: k, value: at) in items.entries) {
      final m = marks[k];
      if (m != null && m < 0 && -m >= _ms(at)) continue; // marked unwatched here since
      if (k == film) {
        if (old != null && (old.finished || (old.inContinue && !at.isAfter(old.updated)))) continue; // seen, or being watched again here
      } else {
        if ((episodes[k] ?? 0) >= finishedAt) continue;
        episodes[k] = 1;
      }
      if (m != null && m < 0) marks[k] = _ms(at);
      took[k] = at;
    }
    if (took.isEmpty) return null;
    final last = took.entries.reduce((a, b) => b.value.isAfter(a.value) ? b : a);
    final newer = old == null || last.value.isAfter(old.updated);
    final updated = newer ? last.value : old.updated;
    if (last.key == film) {
      final d = old != null && old.duration > Duration.zero ? old.duration : Duration(minutes: runtime ?? 100);
      if (old == null) return WatchEntry(media: media, position: d, duration: d, updated: updated, marks: marks);
      return old.copyWith(position: d, duration: d, updated: updated, marks: marks);
    }
    final current = old?.season == null || old?.episode == null ? null : itemKey(season: old!.season, episode: old.episode);
    if (old == null || (newer && (last.key == current || !old.inContinue))) {
      final se = RegExp(r'^S(\d+)E(\d+)$').firstMatch(last.key)!;
      final on = last.key == current ? old : null; // finished where it was
      final d = on != null && on.duration > Duration.zero ? on.duration : Duration(minutes: runtime ?? 45);
      return WatchEntry(
        media: old?.media ?? media,
        season: int.parse(se[1]!),
        episode: int.parse(se[2]!),
        episodeName: on?.episodeName,
        position: d,
        duration: d,
        updated: updated,
        hidden: old?.hidden ?? false,
        episodes: episodes,
        subtitle: on?.subtitle,
        subDelay: on?.subDelay ?? 0,
        marks: marks,
        server: old?.server,
      );
    }
    return old.copyWith(updated: updated, episodes: episodes, marks: marks);
  }

  /// One title's entry from two places (this device and the account) as one: the newer copy's
  /// place in the title and progress, and each episode's watched state from whichever copy
  /// marked it last (a mark made by hand beats a watch with no time; a watch beats a tie).
  @visibleForTesting
  static WatchEntry combine(WatchEntry mine, WatchEntry theirs) {
    final base = mine.updated.isAfter(theirs.updated) ? mine : theirs;
    final episodes = <String, double>{};
    final marks = <String, int>{film: ?base.marks[film]};
    final keys = {...mine.episodes.keys, ...theirs.episodes.keys, ...mine.marks.keys, ...theirs.marks.keys}..remove(film);
    for (final k in keys) {
      final a = _claim(mine, k), b = _claim(theirs, k);
      final fa = mine.episodes[k], fb = theirs.episodes[k];
      final mineWins = b == null || (a != null && _beats(a, b));
      final w = mineWins ? a : b;
      if (w == null) {
        // neither says watched or unwatched: how far in, the furthest
        episodes[k] = math.max(fa ?? 0, fb ?? 0);
        continue;
      }
      if (w.$1) {
        episodes[k] = math.max(fa ?? 0, fb ?? 0);
      } else {
        final part = [?fa, ?fb].where((f) => f < finishedAt);
        if (part.isNotEmpty) episodes[k] = part.reduce(math.max);
      }
      final mark = (mineWins ? mine : theirs).marks[k];
      if (mark != null) marks[k] = mark;
    }
    final current = base.season == null || base.episode == null ? null : itemKey(season: base.season, episode: base.episode);
    final unseen = current != null && base.finished && (episodes[current] ?? 0) < finishedAt;
    return WatchEntry(
      media: base.media,
      season: base.season,
      episode: base.episode,
      episodeName: base.episodeName,
      position: unseen ? Duration.zero : base.position,
      duration: base.duration,
      updated: base.updated,
      hidden: base.hidden,
      episodes: episodes,
      subtitle: base.subtitle,
      subDelay: base.subDelay,
      marks: marks,
      server: base.server,
    );
  }

  /// What [e] says about episode [k]: watched or not, and since when (null: some time before).
  /// The episode it's on was watched as of its last update.
  static (bool, int?)? _claim(WatchEntry e, String k) {
    final m = e.marks[k];
    if (m != null) return (m > 0, m.abs());
    if ((e.episodes[k] ?? 0) < finishedAt) return null;
    final on = e.season != null && e.episode != null && itemKey(season: e.season, episode: e.episode) == k;
    return (true, on ? _ms(e.updated) : null);
  }

  static bool _beats((bool, int?) a, (bool, int?) b) {
    final (ta, tb) = (a.$2, b.$2);
    if (ta != null && tb != null) return ta > tb || (ta == tb && a.$1);
    if (ta != null || tb != null) return ta != null;
    return a.$1;
  }

  /// Off the Continue watching row only.
  static void dismiss(Media media) =>
      _set([for (final e in entries.value) _same(e.media, media) ? e.copyWith(hidden: true) : e]);

  /// Out of History altogether.
  static void remove(Media media) => _set(entries.value.where((e) => !_same(e.media, media)).toList());

  static void clear() => _set(const []);

  /// Titles brought in from another service (Trakt, Simkl, AniList). One only
  /// replaces what's here when it's newer, and keeps the episodes already watched here. The
  /// oldest fall off the end first, so an import never pushes out recent watching.
  static void merge(List<WatchEntry> incoming) {
    final byKey = {for (final e in entries.value) e.media.key: e};
    for (final w in incoming) {
      final old = byKey[w.media.key];
      if (old != null && !w.updated.isAfter(old.updated)) continue;
      final episodes = {...?old?.episodes};
      final marks = {...?old?.marks};
      w.episodes.forEach((k, f) {
        if (f > (episodes[k] ?? 0)) episodes[k] = f;
        // (newer than anything here: it beats an unwatched mark)
        if (f >= finishedAt && (marks[k] ?? 0) < 0) marks[k] = _ms(w.updated);
      });
      byKey[w.media.key] = WatchEntry(
        media: w.media,
        season: w.season,
        episode: w.episode,
        episodeName: w.episodeName,
        position: w.position,
        duration: w.duration,
        updated: w.updated,
        episodes: episodes,
        // an import knows nothing of subtitles: keep this device's for the same episode
        subtitle: w.subtitle ?? (old != null && old.season == w.season && old.episode == w.episode ? old.subtitle : null),
        subDelay: w.subtitle != null ? w.subDelay : (old != null && old.season == w.season && old.episode == w.episode ? old.subDelay : 0),
        marks: marks,
        server: w.server ?? old?.server,
      );
    }
    final list = byKey.values.toList()..sort((a, b) => b.updated.compareTo(a.updated));
    _set(list.take(_max).toList());
  }

  // ── account sync ──

  static Future<Map<String, Map<String, dynamic>>> syncSnapshot() async => {for (final e in entries.value) e.media.key: e.toJson()};

  /// The account's copy of a title (null: removed from History on another device). Combined
  /// with this device's ([combine]): marks made here that the account hasn't heard of yet
  /// stay, and go up with the next change.
  static Future<void> syncApply(String key, Map<String, dynamic>? data) async {
    final old = entries.value.where((e) => e.media.key == key).firstOrNull;
    final list = entries.value.where((e) => e.media.key != key).toList();
    final w = data == null ? null : _tryParse(data);
    if (w != null) {
      list.add(old == null ? w : combine(old, w));
      list.sort((a, b) => b.updated.compareTo(a.updated));
    }
    _set(list.take(_max).toList());
  }

  /// This device's copy and the account's, combined, for the first sync after signing in.
  static Map<String, dynamic> syncMerge(Map<String, dynamic> mine, Map<String, dynamic> theirs) {
    final a = _tryParse(mine), b = _tryParse(theirs);
    if (a == null || b == null) return b == null ? mine : theirs;
    return combine(a, b).toJson();
  }

  static void _set(List<WatchEntry> list) {
    entries.value = list;
    _prefs?.setString(_key, json.encode([for (final e in list) e.toJson()]));
  }
}
