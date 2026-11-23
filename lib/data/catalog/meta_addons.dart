import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../net.dart';
import '../sources/addons.dart';
import 'tmdb.dart';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36';

/// One episode (a video) of a title from a metadata addon, from its details' `videos`. In a
/// collection, one of its films.
@immutable
class AddonVideo {
  const AddonVideo({
    required this.id,
    required this.season,
    required this.episode,
    required this.name,
    this.overview = '',
    this.thumbnail,
    this.poster,
    this.released,
    this.runtime,
    this.imdbSeason,
    this.imdbEpisode,
    this.tmdbId,
    this.inline = const [],
  });

  /// The id the stream addons are asked for it by (`tt0944947:1:1`, `kitsu:7442:1`).
  final String id;

  /// Its season (0: a run with no seasons, numbered straight through) and number.
  final int season;
  final int episode;
  final String name;
  final String overview;

  /// Its still (a full address, or a TMDB picture path), and a poster when it is a film.
  final String? thumbnail;
  final String? poster;
  final DateTime? released;
  final int? runtime;

  /// Where IMDb counts it, when the addon says (Kitsu does).
  final int? imdbSeason;
  final int? imdbEpisode;

  /// TMDB's id for it, when the addon says (TMDB Collections does for each film).
  final int? tmdbId;

  /// Streams the addon put in the video itself (Stremio's `streams` on a video).
  final List<Map<String, dynamic>> inline;

  bool get upcoming => released != null && released!.isAfter(DateTime.now());
}

/// A title's details as a metadata addon gives them: what its details page, its episodes and its
/// sources go by.
class AddonMeta {
  AddonMeta({
    required this.media,
    required this.details,
    required this.videos,
    required this.type,
    required this.from,
    this.logo,
    this.imdb,
    this.defaultVideo,
    this.parts = const [],
  });

  /// The title as the details say (its kind, pictures, and TMDB's id when the addon gave one).
  final Media media;
  final MediaDetails details;

  /// Every episode, by season and then number.
  final List<AddonVideo> videos;

  /// What the stream addons are asked for it as (the details' own type).
  final String type;
  final Addon from;
  final String? logo;
  final String? imdb;

  /// The one video a film-like title plays (`behaviorHints.defaultVideoId`).
  final String? defaultVideo;

  /// A collection (a set of films, as TMDB Collections lists them): each of its films as a
  /// title of its own, opened, played and kept on its own. Empty for anything else.
  final List<Media> parts;

  bool get collection => parts.isNotEmpty;

  List<AddonVideo> season(int n) => [for (final v in videos) if (v.season == n) v];
  AddonVideo? video(int? season, int? episode) => videos.where((v) => v.season == season && v.episode == episode).firstOrNull;
}

/// One of your metadata addons' catalogs, with the addon it belongs to.
@immutable
class CatalogRef {
  const CatalogRef(this.addon, this.catalog);
  final Addon addon;
  final AddonCatalog catalog;

  String get key => '${addon.manifestUrl}|${catalog.type}|${catalog.id}';

  /// "Popular · Movies": the catalog's name and what it lists.
  String get title => MetaAddons.catalogTitle(catalog);

  @override
  bool operator ==(Object other) => other is CatalogRef && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// What a Stremio link asks for (`stremio:///detail/movie/tt…`, the same after Stremio Web's
/// `#`): a title's page, a search, or a catalog.
sealed class StremioLink {
  const StremioLink();

  /// The link's request, or null when it isn't one VyseTV knows.
  static StremioLink? parse(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null) return null;
    final String route;
    if (uri.scheme == 'stremio') {
      route = '${uri.host.isEmpty ? '' : '/${uri.host}'}${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    } else if ((uri.scheme == 'http' || uri.scheme == 'https') && uri.host.endsWith('stremio.com') && uri.fragment.isNotEmpty) {
      route = uri.fragment;
    } else {
      return null;
    }
    final at = route.indexOf('?');
    final path = at < 0 ? route : route.substring(0, at);
    final query = at < 0 ? const <String, String>{} : Uri.splitQueryString(route.substring(at + 1));
    final parts = [for (final p in path.split('/')) if (p.isNotEmpty) Uri.decodeComponent(p)];
    if (parts.isEmpty) return null;
    switch (parts.first) {
      case 'detail' when parts.length >= 3:
        return StremioDetail(parts[1], parts[2]);
      case 'search' when (query['search'] ?? query['query'] ?? '').trim().isNotEmpty:
        return StremioSearch((query['search'] ?? query['query'])!.trim());
      case 'discover' when parts.length >= 4:
        return StremioDiscover(parts[1], parts[2], parts[3], genre: query['genre']);
    }
    return null;
  }
}

/// A title's page: [type] and [id] as the addons know them.
class StremioDetail extends StremioLink {
  const StremioDetail(this.type, this.id);
  final String type;
  final String id;
}

class StremioSearch extends StremioLink {
  const StremioSearch(this.query);
  final String query;
}

/// A catalog: the addon's manifest address, what it lists and its id, at [genre].
class StremioDiscover extends StremioLink {
  const StremioDiscover(this.manifestUrl, this.type, this.catalogId, {this.genre});
  final String manifestUrl;
  final String type;
  final String catalogId;
  final String? genre;
}

/// Stremio metadata addons (lib/data/sources/addons.dart keeps the list): their catalogs (Home
/// rows, Discover, search), the details of their titles, collections of films, the lists of
/// addons some offer, and matching titles to TMDB so the built-in film sources can play them.
///
/// The protocol: https://github.com/Stremio/stremio-addon-sdk/tree/master/docs/api
abstract final class MetaAddons {
  // What catalogs and details said about titles, kept for this run: their logo art, their IMDb
  // id, and which addon listed them (asked first for their details).
  static final _logos = <String, String>{};
  static final _imdb = <String, String>{};
  static final _origin = <String, String>{};

  /// The shape of a catalog's pictures (`posterShape`: poster, square or landscape), as its
  /// first page said.
  static final _shapes = <String, String>{};

  /// Every answer, shared while it is on its way and kept for the run; a failed one is
  /// forgotten so the next call asks again.
  static final _cache = <String, Future<Object?>>{};

  static Future<T> _memo<T>(String key, Future<T> Function() fetch) {
    final had = _cache[key];
    if (had != null) return had.then((v) => v as T);
    final f = fetch();
    _cache[key] = f;
    f.then((_) {}, onError: (Object _) {
      _cache.remove(key);
    });
    return f;
  }

  @visibleForTesting
  static void debugReset() {
    _cache.clear();
    _logos.clear();
    _imdb.clear();
    _origin.clear();
    _shapes.clear();
  }

  static Future<Object?> _get(String url) async {
    final r = await netClient.get(Uri.parse(url), headers: {'User-Agent': _ua, 'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw StateError('HTTP ${r.statusCode}');
    return json.decode(utf8.decode(r.bodyBytes));
  }

  // ── titles ──

  /// A title from a catalog or a details answer, as the app shows titles ([Media]), or null
  /// when it has no id or name. [type]: the catalog's, for an item that doesn't say its own.
  static Media? media(Object? raw, {String? type, Addon? from}) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? raw['imdb_id'] ?? ''}'.trim();
    final name = '${raw['name'] ?? raw['title'] ?? ''}'.trim();
    if (id.isEmpty || name.isEmpty) return null;
    final kind = '${raw['type'] ?? type ?? 'movie'}'.trim();
    final released = '${raw['released'] ?? ''}';
    final info = '${raw['releaseInfo'] ?? raw['year'] ?? ''}';
    final year = RegExp(r'(1[89]|20)\d\d').firstMatch(info.isNotEmpty ? info : released)?.group(0);
    final m = Media(
      id: _tmdbOf(id, raw) ?? Media.addonNumber(id),
      title: name,
      isTv: _seriesLike(kind) || (raw['videos'] is List && _episodic(id, raw['videos'] as List)),
      overview: '${raw['description'] ?? raw['overview'] ?? ''}'.trim(),
      posterPath: _picture(raw['poster']),
      backdropPath: _picture(raw['background']),
      rating: double.tryParse('${raw['imdbRating'] ?? ''}') ?? 0,
      year: year,
      date: RegExp(r'^\d{4}-\d\d-\d\d').hasMatch(released) ? released.substring(0, 10) : (year ?? ''),
      addonId: id,
      addonType: kind,
    );
    final logo = _http(raw['logo']);
    if (logo != null) _logos[m.key] = logo;
    final imdb = '${raw['imdb_id'] ?? ''}';
    if (imdb.startsWith('tt')) _imdb[m.key] = imdb;
    if (from != null) _origin.putIfAbsent(m.key, () => from.manifestUrl);
    return m;
  }

  /// A Stremio title made from a link or an id alone ([StremioDetail]): its page fills in the
  /// rest from the addons.
  static Media bare(String type, String id) =>
      Media(id: _tmdbOf(id, const {}) ?? Media.addonNumber(id), title: '', isTv: _seriesLike(type), addonId: id, addonType: type);

  static bool _seriesLike(String type) => type == 'series' || type == 'anime' || type == 'channel';

  /// More than one video, and they are the title's own (`tt0944947:1:1` under `tt0944947`), not
  /// other titles (a collection's films).
  static bool _episodic(String id, List videos) {
    final ids = [for (final v in videos) if (v is Map) '${v['id'] ?? ''}'];
    return ids.length > 1 && ids.any((v) => v.startsWith(id));
  }

  static String? _http(Object? v) => v is String && v.startsWith('http') ? v : null;

  /// A picture: a full address, or a TMDB picture path (`/abc.jpg`, which [Media] draws from TMDB).
  static String? _picture(Object? v) => v is String && (v.startsWith('http') || (v.startsWith('/') && v.length > 1)) ? v : null;

  static int? _positive(Object? v) => switch (v) {
    final num n when n > 0 => n.toInt(),
    final String s when (int.tryParse(s) ?? 0) > 0 => int.parse(s),
    _ => null,
  };

  /// TMDB's id for an addon title, when the addon gives it: a `tmdb:` id, Cinemeta's
  /// `moviedb_id`, or `tmdb_id` / `tmdbId`.
  static int? _tmdbOf(String id, Map raw) {
    if (id.startsWith('tmdb:')) return _positive(id.substring(5).split(':').first);
    return _positive(raw['moviedb_id']) ?? _positive(raw['tmdb_id']) ?? _positive(raw['tmdbId']);
  }

  /// Minutes from "57 min", "1h 42min" or a plain number.
  static int? minutes(Object? v) {
    if (v is num) return v > 0 ? v.toInt() : null;
    final s = '${v ?? ''}'.toLowerCase();
    final h = RegExp(r'(\d+)\s*h').firstMatch(s), m = RegExp(r'(\d+)\s*m').firstMatch(s);
    final total = (h == null ? 0 : int.parse(h[1]!) * 60) + (m == null ? 0 : int.parse(m[1]!));
    if (total > 0) return total;
    final n = int.tryParse(s.trim());
    return n != null && n > 0 ? n : null;
  }

  // ── catalogs ──

  /// Every catalog of your metadata addons that are on, in your order.
  static List<CatalogRef> get catalogs => [
    for (final a in Addons.catalogAddons)
      for (final c in a.catalogs) CatalogRef(a, c),
  ];

  /// "Popular · Movies": a catalog's name and what it lists (left out when the name says it).
  static String catalogTitle(AddonCatalog c) {
    final kind = typeLabel(c.type);
    final n = c.name.toLowerCase();
    if (n.contains(kind.toLowerCase()) || n.contains(c.type.toLowerCase())) return c.name;
    return '${c.name} · $kind';
  }

  /// What a catalog of [type] lists, for headings: Movies, Series, Anime, Channels…
  static String typeLabel(String type) => switch (type) {
    'movie' => 'Movies',
    'series' => 'Series',
    'anime' => 'Anime',
    'channel' => 'Channels',
    'tv' => 'TV channels',
    'other' => 'Videos',
    'collections' || 'collection' => 'Collections',
    '' => 'Titles',
    _ => '${type[0].toUpperCase()}${type.substring(1)}',
  };

  /// The shape of [r]'s pictures: 'poster' (2:3), 'square' or 'landscape' (16:9), as its first
  /// page said ('poster' until it has).
  static String shapeOf(CatalogRef r) => _shapes[r.key] ?? 'poster';

  /// An id or a type as a path segment: escaped, but with its colons left as they are
  /// (`tt0944947:1:1`), the way Stremio asks addons for them.
  static String segment(String s) => Uri.encodeComponent(s).replaceAll('%3A', ':');

  /// The address of one page of [c]: a genre, a search, how many to skip.
  static String catalogUrl(Addon a, AddonCatalog c, {String? genre, String? search, int skip = 0}) {
    final extra = [
      if (genre != null) 'genre=${Uri.encodeComponent(genre)}',
      if (search != null) 'search=${Uri.encodeComponent(search)}',
      if (skip > 0) 'skip=$skip',
    ].join('&');
    return '${a.base}/catalog/${segment(c.type)}/${segment(c.id)}${extra.isEmpty ? '' : '/$extra'}.json';
  }

  /// One page of titles from [c] (the first, or after [skip] of them).
  static Future<List<Media>> page(Addon a, AddonCatalog c, {String? genre, String? search, int skip = 0}) {
    final url = catalogUrl(a, c, genre: genre, search: search, skip: skip);
    return _memo(url, () async {
      final j = await _get(url);
      final metas = j is Map && j['metas'] is List ? j['metas'] as List : const [];
      final shape = [for (final x in metas) if (x is Map && x['posterShape'] is String) x['posterShape'] as String].firstOrNull;
      if (shape != null) _shapes['${a.manifestUrl}|${c.type}|${c.id}'] = shape == 'square' || shape == 'landscape' ? shape : 'poster';
      final seen = <String>{};
      return [
        for (final x in metas)
          if (media(x, type: c.type, from: a) case final m? when seen.add(m.key)) m,
      ];
    });
  }

  /// Whether any catalog that is on takes a search.
  static bool get searchable => catalogs.any((r) => r.catalog.search);

  /// Every catalog that is on and takes a search, asked for [q] together: each title with the
  /// kind of catalog that found it (movie, series, anime…). Titles in more than one come once (in
  /// the first to list them); an addon that fails is left out.
  static Future<List<(String, Media)>> search(String q) async {
    final refs = [for (final r in catalogs) if (r.catalog.search) r];
    final lists = await Future.wait([
      for (final r in refs) page(r.addon, r.catalog, search: q.trim()).catchError((Object _) => <Media>[]),
    ]);
    final seen = <String>{};
    return [
      for (final (i, l) in lists.indexed)
        for (final m in l)
          if (seen.add(m.key)) (refs[i].catalog.type, m),
    ];
  }

  // ── addon lists (Stremio's addon_catalog) ──

  /// The addons one of [a]'s lists ([c], from its `addonCatalogs`) offers, each as it would
  /// install.
  static Future<List<Addon>> addonList(Addon a, AddonCatalog c) => _memo('addons|${a.manifestUrl}|${c.type}|${c.id}', () async {
    final j = await _get('${a.base}/addon_catalog/${segment(c.type)}/${segment(c.id)}.json');
    final list = j is Map && j['addons'] is List ? j['addons'] as List : const [];
    final seen = <String>{};
    bool adult(Map manifest) => manifest['behaviorHints'] is Map && (manifest['behaviorHints'] as Map)['adult'] == true;
    return [
      for (final x in list)
        if (x is Map && x['transportUrl'] is String && x['manifest'] is Map && !adult(x['manifest'] as Map) && seen.add(Addons.normalize(x['transportUrl'] as String)))
          Addon.fromManifest(Addons.normalize(x['transportUrl'] as String), Map<String, dynamic>.from(x['manifest'] as Map)),
    ];
  });

  // ── details ──

  /// The addons that are on and give the details of [m]: the one that listed it first.
  static List<Addon> _metaSources(Media m) {
    final type = m.addonType ?? (m.isTv ? 'series' : 'movie');
    final id = m.addonId!;
    final all = [for (final a in Addons.metaAddons) if (a.metaFor(type, id)) a];
    final origin = _origin[m.key];
    all.sort((a, b) => (b.manifestUrl == origin ? 1 : 0) - (a.manifestUrl == origin ? 1 : 0));
    return all;
  }

  /// [m]'s details from the first addon that has them (the one it came from first). When none
  /// of your addons has them (a catalog-only addon, like a list): TMDB's, while TMDB is on and
  /// knows the title; else what its catalog said. Its page shows and it plays either way.
  static Future<AddonMeta> meta(Media m) => _memo('meta|${m.key}', () async {
    final type = m.addonType ?? (m.isTv ? 'series' : 'movie');
    Object? failure;
    var answered = false;
    for (final a in _metaSources(m)) {
      try {
        final j = await _get('${a.base}/meta/${segment(type)}/${segment(m.addonId!)}.json');
        answered = true;
        final raw = j is Map ? j['meta'] : null;
        if (raw is Map && raw.isNotEmpty) return _parse(raw, m, a);
      } catch (e) {
        failure = e;
      }
    }
    // every addon asked failed to answer: try again another time, rather than show less
    if (failure != null && !answered) throw failure;
    if (Addons.tmdbOn) {
      try {
        final x = await _fromTmdb(m);
        if (x != null) return x;
      } catch (_) {}
    }
    final from = Addons.list.value.where((a) => a.manifestUrl == _origin[m.key]).firstOrNull ?? Addon.tmdb;
    return _parse({'id': m.addonId, 'type': m.addonType, 'name': m.title}, m, from);
  });

  /// The details page's [MediaDetails], from [m]'s addon details.
  static Future<MediaDetails> details(Media m) async => (await meta(m)).details;

  /// Its logo art: as its catalog or details gave it (nothing is asked for it here).
  static Future<String?> logo(Media m) async {
    final known = _logos[m.key];
    if (known != null) return known;
    final had = _cache['meta|${m.key}'];
    if (had == null) return null;
    try {
      return ((await had) as AddonMeta).logo;
    } catch (_) {
      return null;
    }
  }

  static AddonMeta _parse(Map raw, Media base, Addon from) {
    final own = media(raw, type: base.addonType, from: from);
    final kind = '${raw['type'] ?? base.addonType ?? 'movie'}';
    final videos = _videos(raw['videos']);
    // A collection: its videos are other titles (TMDB Collections lists each film by its own
    // IMDb id), not its own episodes. A series, an anime or a channel is never one.
    final id = base.addonId!;
    final hints = raw['behaviorHints'] is Map ? raw['behaviorHints'] as Map : const {};
    final parted = !_seriesLike(kind) && hints['defaultVideoId'] == null && videos.length > 1 && videos.every((v) => !v.id.startsWith(id));
    final parts = parted ? [for (final v in videos) _part(v)] : const <Media>[];
    final tv = !parted && (_seriesLike(kind) || videos.length > 1);
    // the catalog's copy fills what the details leave out; the key (its id) stays the catalog's
    final m = Media(
      id: (own?.id ?? 0) > 0 ? own!.id : base.id,
      title: (own?.title.isNotEmpty ?? false) ? own!.title : base.title,
      isTv: tv,
      overview: (own?.overview.isNotEmpty ?? false) ? own!.overview : base.overview,
      posterPath: own?.posterPath ?? base.posterPath,
      backdropPath: own?.backdropPath ?? base.backdropPath ?? parts.map((p) => p.backdropPath).nonNulls.firstOrNull,
      rating: (own?.rating ?? 0) > 0 ? own!.rating : base.rating,
      year: own?.year ?? base.year,
      date: (own?.date.isNotEmpty ?? false) ? own!.date : base.date,
      addonId: base.addonId,
      addonType: base.addonType ?? kind,
    );
    final links = [for (final l in (raw['links'] is List ? raw['links'] as List : const [])) if (l is Map && l['name'] != null) l];
    List<String> strings(Object? v) => switch (v) {
      final List l => [for (final x in l) if ('$x'.trim().isNotEmpty) '$x'.trim()],
      final String s when s.trim().isNotEmpty => [for (final x in s.split(',')) if (x.trim().isNotEmpty) x.trim()],
      _ => const <String>[],
    };
    List<String> linked(String category) => [for (final l in links) if ('${l['category']}'.toLowerCase() == category) '${l['name']}'.trim()];
    List<String> either(Object? v, String category) {
      final a = strings(v);
      return a.isNotEmpty ? a : linked(category);
    }

    final genres = <String>{...strings(raw['genres']), ...strings(raw['genre'])}.toList();
    final cast = either(raw['cast'], 'cast');
    final seasonsOf = <int, List<AddonVideo>>{};
    for (final v in parted ? const <AddonVideo>[] : videos) {
      (seasonsOf[v.season] ??= []).add(v);
    }
    // specials stay out when there are real seasons, as on TMDB's pages
    final numbers = seasonsOf.keys.where((n) => n > 0 || seasonsOf.length == 1).toList()..sort();
    final seasons = [
      for (final n in numbers)
        Season(
          n,
          n == 0 ? 'Episodes' : 'Season $n',
          seasonsOf[n]!.length,
          seasonsOf[n]!.map((v) => v.released?.year).nonNulls.firstOrNull?.toString(),
          null,
        ),
    ];
    final trailers = <String, Video>{};
    for (final t in (raw['trailerStreams'] is List ? raw['trailerStreams'] as List : const [])) {
      if (t is Map && t['ytId'] is String) trailers.putIfAbsent(t['ytId'] as String, () => Video(t['ytId'] as String, '${t['title'] ?? 'Trailer'}', 'Trailer', true));
    }
    for (final t in (raw['trailers'] is List ? raw['trailers'] as List : const [])) {
      if (t is Map && t['source'] is String) {
        trailers.putIfAbsent(t['source'] as String, () => Video(t['source'] as String, '${t['type'] ?? 'Trailer'}', '${t['type'] ?? 'Trailer'}', true));
      }
    }
    final status = '${raw['status'] ?? ''}'.trim();
    final language = '${raw['language'] ?? ''}'.trim();
    final details = MediaDetails(
      media: m,
      runtime: parted ? null : minutes(raw['runtime']),
      genres: genres.isNotEmpty ? genres : linked('genres'),
      status: status.isEmpty ? null : '${status[0].toUpperCase()}${status.substring(1)}',
      released: DateTime.tryParse('${raw['released'] ?? ''}'),
      certification: raw['certification'] is String && (raw['certification'] as String).isNotEmpty ? raw['certification'] as String : null,
      directors: either(raw['director'], 'directors').take(3).toList(),
      writers: either(raw['writer'], 'writers').take(3).toList(),
      countries: strings(raw['country']).take(2).toList(),
      language: language.isEmpty ? null : language,
      seasonCount: tv && numbers.any((n) => n > 0) ? numbers.where((n) => n > 0).length : null,
      episodeCount: tv && videos.isNotEmpty ? videos.length : null,
      cast: [for (final c in cast.take(24)) CastMember(0, c, '', null)],
      seasons: seasons,
      videos: trailers.values.take(12).toList(),
      parts: parts,
    );
    final imdb = '${raw['imdb_id'] ?? ''}';
    final logo = _http(raw['logo']) ?? _logos[m.key];
    return AddonMeta(
      media: m,
      details: details,
      videos: videos,
      type: kind,
      from: from,
      logo: logo,
      imdb: imdb.startsWith('tt') ? imdb : (id.startsWith('tt') ? id.split(':').first : _imdb[m.key]),
      defaultVideo: hints['defaultVideoId'] is String ? hints['defaultVideoId'] as String : null,
      parts: parts,
    );
  }

  /// A collection's film as a title of its own: its own ids (an IMDb id, TMDB's when the addon
  /// says), name, year and pictures.
  static Media _part(AddonVideo v) {
    final tt = v.id.startsWith('tt') ? v.id.split(':').first : null;
    final tmdb = v.tmdbId ?? (v.id.startsWith('tmdb:') ? _positive(v.id.substring(5).split(':').first) : null);
    final when = v.released != null && v.released!.year < 2900 ? v.released : null;
    final m = Media(
      id: tmdb ?? Media.addonNumber(v.id),
      title: v.name,
      isTv: false,
      overview: v.overview,
      posterPath: v.poster ?? (tt == null ? null : 'https://images.metahub.space/poster/medium/$tt/img'),
      backdropPath: v.thumbnail,
      year: when?.year.toString(),
      date: when == null ? '' : when.toIso8601String().substring(0, 10),
      addonId: v.id,
      addonType: 'movie',
    );
    if (tt != null) _imdb[m.key] = tt;
    return m;
  }

  /// The episodes in a details answer, by season and number. A run with no seasons (a channel's
  /// videos) is season 0, numbered from the oldest.
  static List<AddonVideo> _videos(Object? raw) {
    // (a collection's film with no IMDb id goes by TMDB's, when the addon gives it)
    String idOf(Map v) {
      final id = '${v['id'] ?? ''}'.trim();
      final tmdb = _positive(v['tmdbId'] ?? v['tmdb_id']);
      return id.isNotEmpty ? id : (tmdb == null ? '' : 'tmdb:$tmdb');
    }

    final list = [for (final v in (raw is List ? raw : const [])) if (v is Map && idOf(v).isNotEmpty) v];
    final seasoned = list.any((v) => v['season'] is num);
    int? n(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    DateTime? when(Map v) => DateTime.tryParse('${v['released'] ?? v['firstAired'] ?? ''}');
    if (!seasoned) {
      list.sort((a, b) => (when(a) ?? DateTime(9999)).compareTo(when(b) ?? DateTime(9999)));
    }
    final seen = <String>{};
    final out = <AddonVideo>[];
    for (final (i, v) in list.indexed) {
      final season = seasoned ? (n(v['season']) ?? 0) : 0;
      final episode = seasoned ? (n(v['episode']) ?? n(v['number']) ?? i + 1) : i + 1;
      if (!seen.add('$season:$episode')) continue;
      final name = '${v['title'] ?? v['name'] ?? ''}'.trim();
      out.add(AddonVideo(
        id: idOf(v),
        season: season,
        episode: episode,
        name: name.isEmpty ? 'Episode $episode' : name,
        overview: '${v['overview'] ?? v['description'] ?? ''}'.trim(),
        thumbnail: _picture(v['thumbnail']),
        poster: _picture(v['poster']),
        released: when(v),
        runtime: minutes(v['runtime']),
        imdbSeason: n(v['imdbSeason']),
        imdbEpisode: n(v['imdbEpisode']),
        tmdbId: _positive(v['tmdbId'] ?? v['tmdb_id'] ?? v['moviedb_id']),
        inline: [for (final s in (v['streams'] is List ? v['streams'] as List : const [])) if (s is Map) Map<String, dynamic>.from(s)],
      ));
    }
    out.sort((a, b) => a.season != b.season ? a.season - b.season : a.episode - b.episode);
    return out;
  }

  /// [m]'s details from TMDB, when none of your addons has them: the addon title as TMDB knows it
  /// (its key stays), with a show's episodes from TMDB's seasons. Null when TMDB doesn't know it.
  static Future<AddonMeta?> _fromTmdb(Media m) async {
    final twin = await _match(m, null);
    if (twin == null) return null;
    final plain = Media(id: twin.id, title: m.title, isTv: twin.isTv, year: m.year);
    final d = await Tmdb.details(plain);
    final tt = _imdb[m.key] ?? (m.addonId!.startsWith('tt') ? m.addonId!.split(':').first : null);
    final media = Media(
      id: twin.id,
      title: d.media.title,
      isTv: twin.isTv,
      overview: d.media.overview.isNotEmpty ? d.media.overview : m.overview,
      posterPath: m.posterPath ?? d.media.posterPath,
      backdropPath: m.backdropPath ?? d.media.backdropPath,
      rating: d.media.rating > 0 ? d.media.rating : m.rating,
      year: m.year ?? d.media.year,
      date: m.date,
      addonId: m.addonId,
      addonType: m.addonType ?? (twin.isTv ? 'series' : 'movie'),
    );
    final videos = <AddonVideo>[];
    if (twin.isTv) {
      final seasons = await Future.wait([
        for (final s in d.seasons)
          Tmdb.get('/tv/${twin.id}/season/${s.number}').then((j) => (s.number, j), onError: (Object _) => (s.number, const <String, dynamic>{})),
      ]);
      for (final (s, j) in seasons) {
        for (final e in (j['episodes'] is List ? j['episodes'] as List : const []).whereType<Map>()) {
          final n = _positive(e['episode_number']);
          if (n == null) continue;
          final still = e['still_path'] as String?;
          videos.add(AddonVideo(
            id: tt != null ? '$tt:$s:$n' : 'tmdb:${twin.id}:$s:$n',
            season: s,
            episode: n,
            name: '${e['name'] ?? ''}'.trim().isEmpty ? 'Episode $n' : '${e['name']}'.trim(),
            overview: '${e['overview'] ?? ''}'.trim(),
            thumbnail: still == null ? null : 'https://image.tmdb.org/t/p/w300$still',
            released: DateTime.tryParse('${e['air_date'] ?? ''}'),
            runtime: _positive(e['runtime']),
            imdbSeason: s,
            imdbEpisode: n,
          ));
        }
      }
    }
    final details = MediaDetails(
      media: media,
      runtime: d.runtime,
      genres: d.genres,
      status: d.status,
      released: d.released,
      tagline: d.tagline,
      certification: d.certification,
      directors: d.directors,
      writers: d.writers,
      studios: d.studios,
      networks: d.networks,
      countries: d.countries,
      language: d.language,
      budget: d.budget,
      revenue: d.revenue,
      seasonCount: d.seasonCount,
      episodeCount: d.episodeCount,
      voteCount: d.voteCount,
      cast: d.cast,
      seasons: d.seasons,
      videos: d.videos,
      recommendations: d.recommendations,
    );
    return AddonMeta(
      media: media,
      details: details,
      videos: videos,
      type: m.addonType ?? (twin.isTv ? 'series' : 'movie'),
      from: Addon.tmdb,
      logo: await Tmdb.logo(plain).catchError((Object _) => null),
      imdb: tt,
    );
  }

  // ── playing ──

  /// What the stream and subtitle addons are asked for [m] (an episode when given): its own ids
  /// (the episode's video id), and IMDb's and TMDB's where they are known; with the streams its
  /// addon put in the video itself.
  static Future<AddonTarget> target(Media m, {int? season, int? episode}) async {
    AddonMeta? x;
    try {
      x = await meta(m);
    } catch (_) {}
    final raw = m.addonId!;
    // Cinemeta's and TMDB's numbers are IMDb's own; Kitsu says where IMDb counts each episode
    final imdbNumbers = raw.startsWith('tt') || raw.startsWith('tmdb:');
    final refs = [
      for (final v in x?.videos ?? const <AddonVideo>[])
        AddonVideoRef(
          season: v.season,
          episode: v.episode,
          id: v.id,
          imdbSeason: v.imdbSeason ?? (imdbNumbers ? v.season : null),
          imdbEpisode: v.imdbEpisode ?? (imdbNumbers ? v.episode : null),
          inline: v.inline,
        ),
    ];
    final episodeOf = season != null || episode != null;
    final v = episodeOf ? refs.where((r) => r.season == (season ?? 0) && r.episode == episode).firstOrNull : null;
    // a film: the video it plays (the one the details name, or its only one)
    final film = episodeOf || x == null || x.collection
        ? null
        : (x.videos.where((v) => v.id == x!.defaultVideo).firstOrNull ?? (x.videos.length == 1 ? x.videos.single : null));
    final tmdb = m.id > 0 ? m.id : ((x?.media.id ?? 0) > 0 ? x!.media.id : null);
    return AddonTarget(
      type: x?.type ?? m.addonType ?? (m.isTv ? 'series' : 'movie'),
      raw: raw,
      video: v?.id ?? (episodeOf ? null : (x?.defaultVideo ?? film?.id)),
      imdb: x?.imdb ?? _imdb[m.key] ?? (raw.startsWith('tt') ? raw.split(':').first : null),
      tmdb: tmdb,
      season: season,
      episode: episode,
      imdbSeason: v?.imdbSeason ?? (imdbNumbers ? season : null),
      imdbEpisode: v?.imdbEpisode ?? (imdbNumbers ? episode : null),
      title: m.title,
      year: int.tryParse(m.year ?? ''),
      videos: refs,
      inline: v?.inline ?? film?.inline ?? const [],
      inlineFrom: x?.from,
    );
  }

  /// [m] matched to TMDB, so the built-in film sources can play it: by the TMDB id its addon
  /// gave, else by its IMDb id, else by its name and year on TMDB. Null when it can't be.
  static Future<Media?> twin(Media m) {
    if (m.tmdbKnown) return Future.value(m);
    return _memo('twin|${m.key}', () async {
      AddonMeta? x;
      try {
        x = await meta(m);
      } catch (_) {}
      return _match(m, x);
    });
  }

  /// [twin]'s work, with what the title's details said ([x], when there are any).
  static Future<Media?> _match(Media m, AddonMeta? x) async {
    if (m.tmdbKnown) return m;
    final tv = x?.media.isTv ?? m.isTv;
    final base = x == null
        ? m
        : Media(
            id: m.id,
            title: m.title.isNotEmpty ? m.title : x.media.title,
            isTv: tv,
            overview: m.overview,
            posterPath: m.posterPath ?? x.media.posterPath,
            backdropPath: m.backdropPath ?? x.media.backdropPath,
            rating: m.rating,
            year: m.year ?? x.media.year,
            date: m.date,
            addonId: m.addonId,
            addonType: m.addonType,
          );
    if ((x?.media.id ?? 0) > 0) return base.withTmdb(x!.media.id);
    Media as(int id, bool show) => show == base.isTv
        ? base.withTmdb(id)
        : Media(
            id: id,
            title: base.title,
            isTv: show,
            overview: base.overview,
            posterPath: base.posterPath,
            backdropPath: base.backdropPath,
            rating: base.rating,
            year: base.year,
            date: base.date,
            addonId: base.addonId,
            addonType: base.addonType,
          );
    final imdb = x?.imdb ?? _imdb[m.key] ?? (m.addonId!.startsWith('tt') ? m.addonId!.split(':').first : null);
    if (imdb != null) {
      final j = await Tmdb.get('/find/$imdb', {'external_source': 'imdb_id'});
      List<Map> hits(String k) => [for (final r in (j[k] is List ? j[k] as List : const [])) if (r is Map && r['id'] is int) r];
      final movie = hits('movie_results').firstOrNull, show = hits('tv_results').firstOrNull;
      final pick = tv ? (show ?? movie) : (movie ?? show);
      if (pick != null) return as(pick['id'] as int, identical(pick, show));
    }
    // no id TMDB knows: its name (and year) on TMDB, taken only when the name is the same
    final found = await _byName(base.title, base.year, kind: m.addonType, tv: tv);
    return found == null ? null : as(found.$1, found.$2);
  }

  /// TMDB's title of this [title] (and [year], give or take one), searched as a film or a show
  /// as its addon calls it ([kind]; either, for kinds TMDB has no word for). Null unless the
  /// name is the same, letter for letter (case, spaces and marks aside).
  static Future<(int, bool)?> _byName(String title, String? year, {String? kind, required bool tv}) async {
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    final want = norm(title);
    if (want.isEmpty) return null;
    final y = int.tryParse(year ?? '');
    final kinds = switch (kind) {
      'movie' => const [false],
      'series' => const [true],
      _ => tv ? const [true, false] : const [false, true],
    };
    for (final show in kinds) {
      final j = await Tmdb.get('/search/${show ? 'tv' : 'movie'}', {'query': title, 'include_adult': 'false'});
      for (final r in (j['results'] is List ? j['results'] as List : const []).whereType<Map>()) {
        if (r['id'] is! int) continue;
        final names = [r['title'], r['name'], r['original_title'], r['original_name']].whereType<String>().map(norm);
        final date = '${r['release_date'] ?? r['first_air_date'] ?? ''}';
        final ry = date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;
        if (names.contains(want) && (y == null || ry == null || (ry - y).abs() <= 1)) return (r['id'] as int, show);
      }
    }
    return null;
  }

  /// Where TMDB counts the episode [season] x [episode] of [m] (an addon title): the numbers
  /// the built-in film sources go by. Kitsu says where IMDb (and so TMDB) counts each episode;
  /// other addons count them as IMDb does.
  static Future<(int?, int?)> tmdbEpisode(Media m, int? season, int? episode) async {
    if (!m.isAddon || episode == null) return (season, episode);
    try {
      final v = (await meta(m)).video(season, episode);
      if (v?.imdbSeason != null && v?.imdbEpisode != null) return (v!.imdbSeason, v.imdbEpisode);
    } catch (_) {}
    return (season, episode);
  }

  /// The film of collection [m] to play: the first not watched to the end (the first, once all
  /// are). Null when [m] isn't a collection.
  static Future<Media?> partToPlay(Media m, bool Function(Media part) watched) async {
    if (!m.isAddon) return null;
    final AddonMeta x;
    try {
      x = await meta(m);
    } catch (_) {
      return null;
    }
    if (!x.collection) return null;
    return x.parts.where((p) => !watched(p)).firstOrNull ?? x.parts.first;
  }
}
