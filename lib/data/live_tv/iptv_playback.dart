// A film or a series' episode from an IPTV portal, in VyseTV's own player.
//
// They used to open in the channel player, which changes channels and little else: no audio
// menu, no subtitles, no speed, no way on to the next episode. The film player has all of
// that, and it lists the audio and subtitle tracks the file itself carries. This hands it the
// stream as an OutsidePlayback (see ../playback/outside_play.dart): none of it reaches
// VyseTV's history, your trackers or Party. Where you stopped is remembered on this device.

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../screens/player/player_episodes.dart' show EpisodeInfo, EpisodeStore;
import '../../screens/player/player_page.dart' show PlayerEpisode;
import '../catalog/tmdb.dart' show Media, Season;
import '../playback/outside_play.dart';
import '../sources/sources.dart' show StreamSource;

/// One film, or one episode of a series, as a portal lists it.
class IptvVideo {
  const IptvVideo({required this.title, required this.url, this.image, this.overview = '', this.season = 1, this.number = 1});
  final String title;
  final String url;
  final String? image;
  final String overview;
  final int season;
  final int number;
}

class IptvPlayback implements OutsidePlayback {
  /// A film.
  IptvPlayback.film(IptvVideo film, {required this.portal})
    : _film = film,
      episodes = null,
      episode = null,
      media = Media(id: _id(film.url), title: film.title, isTv: false, overview: film.overview, posterPath: _art(film.image));

  /// A series, starting on [start]. [all] is every episode the portal lists for it: the player's
  /// episode list and its Next button go by them.
  IptvPlayback.series({required String show, required List<IptvVideo> all, required IptvVideo start, required String portal, String? poster})
    : this._series(Media(id: _id('$portal/$show'), title: show, isTv: true, posterPath: _art(poster)), all, start, portal);

  IptvPlayback._series(this.media, List<IptvVideo> all, IptvVideo start, this.portal)
    : _film = null,
      episodes = IptvEpisodeStore(media, all),
      episode = PlayerEpisode(season: start.season, number: start.number, name: start.title);

  /// The portal's name, as you gave it.
  final String portal;
  final IptvVideo? _film;
  IptvVideo? _now;

  @override
  final Media media;
  @override
  final PlayerEpisode? episode;
  @override
  final IptvEpisodeStore? episodes;

  @override
  String get label => 'IPTV · $portal';
  @override
  String get note => 'From your portal';
  @override
  String? get logo => null;

  @override
  Future<ServerStream> open(PlayerEpisode? ep) async {
    final video = ep == null ? _film : episodes?.video(ep.season, ep.number);
    if (video == null) throw StateError("The portal doesn't list this episode.");
    _now = video;
    final path = Uri.tryParse(video.url)?.path.toLowerCase() ?? '';
    return ServerStream(
      source: StreamSource(
        url: video.url,
        server: label,
        quality: '',
        referrer: '',
        // (a portal is told what the channel player has always told it: libmpv)
        userAgent: 'libmpv',
        headers: const {'User-Agent': 'libmpv'},
        hls: path.endsWith('.m3u8') || path.endsWith('.m3u'),
      ),
      resumeAt: await IptvPlaces.of(video.url),
    );
  }

  @override
  void progress(Duration position, Duration duration, {required bool paused}) {
    final video = _now;
    if (video != null) IptvPlaces.put(video.url, position, duration);
  }

  @override
  Future<void> close() => IptvPlaces.flush();

  static String? _art(String? url) => url == null || url.isEmpty ? null : url;
}

/// A series' episodes as its portal lists them, for the player's episode list and Up next.
class IptvEpisodeStore extends EpisodeStore {
  IptvEpisodeStore(super.show, List<IptvVideo> all) {
    for (final v in all) {
      // (a portal can list an episode twice: the first is the one its page shows first)
      _videos.putIfAbsent((v.season, v.number), () => v);
    }
  }

  final _videos = <(int, int), IptvVideo>{};

  IptvVideo? video(int season, int number) => _videos[(season, number)];

  /// Real seasons first, specials (season 0) last.
  @override
  Future<List<Season>> get seasons async {
    final count = <int, int>{};
    for (final (season, _) in _videos.keys) {
      count[season] = (count[season] ?? 0) + 1;
    }
    final numbers = count.keys.toList()..sort((a, b) => a == 0 ? 1 : (b == 0 ? -1 : a.compareTo(b)));
    return [for (final n in numbers) Season(n, n == 0 ? 'Specials' : 'Season $n', count[n]!, null, null)];
  }

  @override
  Future<List<EpisodeInfo>> season(int n) async {
    final list = [
      for (final e in _videos.entries)
        if (e.key.$1 == n) e.value,
    ]..sort((a, b) => a.number.compareTo(b.number));
    return [
      for (final v in list)
        EpisodeInfo(n, v.number, v.title.trim().isEmpty ? 'Episode ${v.number}' : v.title, v.overview, v.image == null || v.image!.isEmpty ? null : v.image, null, null),
    ];
  }
}

/// Where you stopped in each IPTV film and episode, on this device (the newest 300).
class IptvPlaces {
  static const _key = 'iptv.vod.places';
  static Map<String, List<int>>? _all; // a video's id -> [seconds in, when (ms)]
  static Timer? _saving;

  static Future<Map<String, List<int>>> _load() async {
    final have = _all;
    if (have != null) return have;
    final out = <String, List<int>>{};
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        for (final e in (json.decode(raw) as Map<String, dynamic>).entries) {
          final v = e.value;
          if (v is List && v.length >= 2) out[e.key] = [(v[0] as num).toInt(), (v[1] as num).toInt()];
        }
      }
    } catch (_) {
      // unreadable: start again
    }
    return _all = out;
  }

  /// Where to carry on from, if it was left part of the way through.
  static Future<Duration?> of(String url) async {
    final at = (await _load())['${_id(url)}'];
    return at == null ? null : Duration(seconds: at[0]);
  }

  /// The first half minute is not a place to come back to, and neither are the credits.
  static void put(String url, Duration position, Duration duration) {
    final all = _all;
    if (all == null || duration < const Duration(minutes: 1)) return;
    final key = '${_id(url)}';
    final credits = Duration(seconds: (duration.inSeconds * .05).round().clamp(30, 300));
    if (position > const Duration(seconds: 30) && position < duration - credits) {
      all[key] = [position.inSeconds, DateTime.now().millisecondsSinceEpoch];
    } else if (all.remove(key) == null) {
      return;
    }
    _saving ??= Timer(const Duration(seconds: 5), flush);
  }

  static Future<void> flush() async {
    _saving?.cancel();
    _saving = null;
    final all = _all;
    if (all == null) return;
    if (all.length > 300) {
      final newest = all.entries.toList()..sort((a, b) => b.value[1].compareTo(a.value[1]));
      all
        ..clear()
        ..addEntries(newest.take(300));
    }
    try {
      await (await SharedPreferences.getInstance()).setString(_key, json.encode(all));
    } catch (_) {
      // kept in memory; saved with the next one
    }
  }

  /// Tests: forgets what is in memory, so the next read is from storage.
  static void debugForget() {
    _saving?.cancel();
    _saving = null;
    _all = null;
  }
}

/// A number that stays the same for the same text from one run to the next (a String's own
/// hashCode needn't). Not the address itself: that holds the portal's sign-in.
int _id(String text) {
  var h = 0x811c9dc5;
  for (final c in utf8.encode(text)) {
    h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return h & 0x3fffffff;
}
