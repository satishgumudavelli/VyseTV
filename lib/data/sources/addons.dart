import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../anime/anilist.dart';
import '../app_settings.dart';
import 'badges.dart';
import 'film_sources/common.dart' show getTmdbMetadata, fetchText, HttpError;
import 'knaben.dart';
import 'plugins/js_plugins.dart';
import 'plugins/plugin_catalogs.dart';
import '../net.dart';
import 'sources.dart' show StreamSource;
import '../playback/stream_proxy.dart';
import '../subtitles/subtitles.dart' show SubtitleTrack, subtitleTrack;
import '../catalog/meta_addons.dart';
import '../catalog/tmdb.dart';
import 'torrents.dart';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36';

/// One catalog a metadata addon offers: a list of titles to browse (a Home row, a Discover
/// page), some of them searchable. From the manifest's `catalogs`.
@immutable
class AddonCatalog {
  const AddonCatalog({
    required this.type,
    required this.id,
    required this.name,
    this.genres = const [],
    this.genreRequired = false,
    this.search = false,
    this.searchOnly = false,
    this.skip = false,
    this.otherRequired = false,
  });

  /// What it lists (movie, series, anime, channel, tv…) and its id within the addon.
  final String type;
  final String id;
  final String name;

  /// The choices of its genre filter (some addons list years or services here).
  final List<String> genres;

  /// It only lists one genre at a time (Cinemeta's "New" lists one year).
  final bool genreRequired;

  /// It takes a search, or only answers one.
  final bool search;
  final bool searchOnly;

  /// It comes a page at a time (`skip`).
  final bool skip;

  /// It needs something VyseTV can't give it (the ids of what you follow): never asked.
  final bool otherRequired;

  /// It can be a row on Home: it lists something without being asked for a genre or a search.
  bool get board => !genreRequired && !searchOnly && !otherRequired;

  /// It can be browsed on Discover (with a genre picked, when it needs one).
  bool get browsable => !searchOnly && !otherRequired && (!genreRequired || genres.isNotEmpty);

  /// From a manifest's catalog, written either way the protocol allows (`extra`, or the older
  /// `extraSupported` / `extraRequired` / `genres`).
  static AddonCatalog? fromManifest(Object? j) {
    if (j is! Map || j['type'] == null || j['id'] == null) return null;
    List<String> strings(Object? v) => [for (final x in (v is List ? v : const [])) '$x'];
    final extra = [for (final e in (j['extra'] is List ? j['extra'] as List : const [])) if (e is Map && e['name'] != null) e];
    final supported = {...strings(j['extraSupported']), for (final e in extra) '${e['name']}'};
    final required = {...strings(j['extraRequired']), for (final e in extra) if (e['isRequired'] == true) '${e['name']}'};
    final genre = extra.where((e) => e['name'] == 'genre').firstOrNull;
    final genres = genre != null && genre['options'] is List ? strings(genre['options']) : strings(j['genres']);
    final name = '${j['name'] ?? ''}'.trim();
    return AddonCatalog(
      type: '${j['type']}',
      id: '${j['id']}',
      name: name.isEmpty ? '${j['id']}' : name,
      genres: genres,
      genreRequired: required.contains('genre'),
      search: supported.contains('search'),
      searchOnly: required.contains('search'),
      skip: supported.contains('skip'),
      otherRequired: required.any((n) => n != 'genre' && n != 'search' && n != 'skip'),
    );
  }

  Map<String, dynamic> toJson() => {
    't': type,
    'i': id,
    'n': name,
    if (genres.isNotEmpty) 'g': genres,
    if (genreRequired) 'gr': true,
    if (search) 's': true,
    if (searchOnly) 'so': true,
    if (skip) 'k': true,
    if (otherRequired) 'x': true,
  };

  static AddonCatalog? fromJson(Object? j) {
    if (j is! Map || j['t'] is! String || j['i'] is! String) return null;
    return AddonCatalog(
      type: j['t'] as String,
      id: j['i'] as String,
      name: '${j['n'] ?? j['i']}',
      genres: [for (final g in (j['g'] is List ? j['g'] as List : const [])) '$g'],
      genreRequired: j['gr'] == true,
      search: j['s'] == true,
      searchOnly: j['so'] == true,
      skip: j['k'] == true,
      otherRequired: j['x'] == true,
    );
  }
}

/// A Stremio addon you installed: a metadata addon (catalogs to browse, the details of titles),
/// a stream addon (finds videos), a subtitle addon, or any mix of them.
@immutable
class Addon {
  const Addon({
    required this.manifestUrl,
    required this.id,
    required this.name,
    this.version = '',
    this.description = '',
    this.logo,
    this.streams = false,
    this.subtitles = false,
    this.configurable = false,
    this.streamTypes = const [],
    this.streamPrefixes = const [],
    this.subtitleTypes = const [],
    this.subtitlePrefixes = const [],
    this.enabled = true,
    this.catalogs = const [],
    this.meta = false,
    this.metaTypes = const [],
    this.metaPrefixes = const [],
    this.catalogsRead = true,
    this.addonCatalogs = const [],
    this.needsSetup = false,
    this.plugins = false,
    this.browse,
    this.comicsOff = const [],
  });

  /// Where its manifest is: `https://…/manifest.json` (a plugin repository: its `repo.json`).
  final String manifestUrl;
  final String id;
  final String name;
  final String version;
  final String description;
  final String? logo;
  final bool streams;
  final bool subtitles;
  final bool configurable;
  final List<String> streamTypes; // empty: any
  final List<String> streamPrefixes; // the ids it understands ("tt", "kitsu"); empty: IMDb's
  final List<String> subtitleTypes;
  final List<String> subtitlePrefixes;
  final bool enabled;

  /// Its catalogs (Home rows, Discover, search), in the manifest's order.
  final List<AddonCatalog> catalogs;

  /// It gives the details of titles (Stremio's `meta`): of the [metaTypes] (empty: any) whose
  /// ids start with one of [metaPrefixes] (empty: any).
  final bool meta;
  final List<String> metaTypes;
  final List<String> metaPrefixes;

  /// Saved by a version that reads catalogs. One saved before then is read again once (an
  /// addon installed for its streams may have had catalogs all along).
  final bool catalogsRead;

  /// Lists of other addons it offers (Stremio's `addon_catalog`: Cinemeta's Official and
  /// Community lists), to install from.
  final List<AddonCatalog> addonCatalogs;

  /// It has to be set up on its own page before it can be installed
  /// (`behaviorHints.configurationRequired`): seen in an addon list, never in yours.
  final bool needsSetup;

  /// A repository of scraper plugins (plugins/js_plugins.dart), not a Stremio addon: its
  /// [manifestUrl] is the repository's file, and each plugin in it is asked for streams.
  final bool plugins;

  /// A plugin repository: the plugins whose catalogs you browse (Settings > Addons,
  /// plugins/plugin_catalogs.dart). Null: not picked yet.
  final List<String>? browse;

  /// A plugin repository's comic plugins you turned off: the others' catalogs are in the Manga
  /// section (data/manga/plugin_comics.dart), never on Home.
  final List<String> comicsOff;

  /// It offers something to browse, or the details of titles.
  bool get metadata => catalogs.isNotEmpty || meta;

  /// Whether it gives the details of [id], a title of kind [type].
  bool metaFor(String type, String id) =>
      meta && (metaTypes.isEmpty || metaTypes.contains(type)) && (metaPrefixes.isEmpty || metaPrefixes.any(id.startsWith));

  String get base => manifestUrl.replaceFirst(RegExp(r'/manifest\.json$'), '');
  String? get configureUrl => configurable && !plugins ? '$base/configure' : null;

  /// Part of VyseTV itself, not installed from a link: it can be turned off and moved in the
  /// list, but not removed. Its "manifest" is just a name (`builtin:…`).
  bool get builtIn => manifestUrl.startsWith('builtin:');

  /// VyseTV's own torrent source: Knaben, a search engine over the public torrent sites
  /// (lib/data/sources/knaben.dart). Films and shows, by title; anime isn't covered.
  static const knaben = Addon(
    manifestUrl: 'builtin:knaben',
    id: 'vyse.knaben',
    name: 'Knaben',
    description: 'Built in. Finds torrents for films and shows on Knaben, a torrent search engine. They play with P2P streaming or your debrid service.',
    streams: true,
    streamTypes: ['movie', 'series'],
  );

  /// VyseTV's own catalog and details: Home, Discover, the details pages and search come from
  /// TMDB while it is on. Turned off, they come only from your metadata addons.
  static const tmdb = Addon(
    manifestUrl: 'builtin:tmdb',
    id: 'vyse.tmdb',
    name: 'TMDB',
    description: 'Built in. Home, Discover, details and search from The Movie Database. Turn it off to browse only your metadata addons.',
    meta: true,
    metaTypes: ['movie', 'series'],
  );

  /// Every built-in addon, in the order a fresh install lists them (after your own).
  static const builtIns = [tmdb, knaben];

  Addon copyWith({bool? enabled}) => Addon(
    manifestUrl: manifestUrl,
    id: id,
    name: name,
    version: version,
    description: description,
    logo: logo,
    streams: streams,
    subtitles: subtitles,
    configurable: configurable,
    streamTypes: streamTypes,
    streamPrefixes: streamPrefixes,
    subtitleTypes: subtitleTypes,
    subtitlePrefixes: subtitlePrefixes,
    enabled: enabled ?? this.enabled,
    catalogs: catalogs,
    meta: meta,
    metaTypes: metaTypes,
    metaPrefixes: metaPrefixes,
    catalogsRead: catalogsRead,
    addonCatalogs: addonCatalogs,
    needsSetup: needsSetup,
    plugins: plugins,
    browse: browse,
    comicsOff: comicsOff,
  );

  /// A plugin repository as an addon: films and shows' streams, from its plugins; and the
  /// catalogs of those you browse ([browse]; not picked yet: a scraper list's that list titles,
  /// none of a Vega provider's), with their titles' details.
  factory Addon.ofPlugins(PluginRepoInfo r, {List<String>? browse, List<String> comicsOff = const []}) {
    final on = browse ?? [for (final p in r.plugins) if (!p.vega && !p.comic && p.catalogs.isNotEmpty) p.id];
    return Addon(
      manifestUrl: r.url,
      id: 'plugins.${PluginRepos.repoKey(r.url)}',
      name: r.name,
      description: pluginsAbout(r.plugins),
      streams: true,
      streamTypes: const ['movie', 'series'],
      plugins: true,
      // (a comic plugin's catalogs are in the Manga section instead)
      catalogs: [
        for (final p in r.plugins)
          if (on.contains(p.id) && !p.comic)
            for (final c in p.catalogs) PluginCatalogs.addonCatalog(p, c),
      ],
      // (its titles' details stay, with their catalogs off: they are in your history)
      meta: r.plugins.any((p) => p.catalogs.isNotEmpty && !p.comic),
      metaPrefixes: [PluginCatalogs.prefix(r.url)],
      browse: on,
      comicsOff: comicsOff,
    );
  }

  /// "12 plugins: A, B, C and 9 more".
  static String pluginsAbout(List<PluginEntry> l) {
    final names = l.map((p) => p.name).toList();
    final shown = names.take(3).join(', ');
    return '${l.length} plugin${l.length == 1 ? '' : 's'}: $shown${names.length > 3 ? ' and ${names.length - 3} more' : ''}';
  }

  /// From a manifest (https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/manifest.md).
  factory Addon.fromManifest(String url, Map<String, dynamic> j) {
    final resources = (j['resources'] as List?) ?? const [];
    List<String> strings(Object? v) => [for (final x in (v as List?) ?? const []) '$x'];
    final rootTypes = strings(j['types']);
    final rootPrefixes = strings(j['idPrefixes']);
    Map<dynamic, dynamic>? res(String n) => resources.whereType<Map>().where((r) => r['name'] == n).firstOrNull;
    bool has(String n) => resources.any((r) => r == n) || res(n) != null;
    List<String> types(String n) => res(n)?['types'] != null ? strings(res(n)!['types']) : rootTypes;
    List<String> prefixes(String n) => res(n)?['idPrefixes'] != null ? strings(res(n)!['idPrefixes']) : rootPrefixes;
    final hints = j['behaviorHints'] is Map ? j['behaviorHints'] as Map : const {};
    final logo = '${j['logo'] ?? ''}';
    return Addon(
      manifestUrl: url,
      id: '${j['id'] ?? url}',
      name: '${j['name'] ?? 'Addon'}'.trim(),
      version: '${j['version'] ?? ''}',
      description: '${j['description'] ?? ''}'.trim(),
      logo: logo.startsWith('http') ? logo : null,
      streams: has('stream'),
      subtitles: has('subtitles'),
      configurable: hints['configurable'] == true,
      streamTypes: types('stream'),
      streamPrefixes: prefixes('stream'),
      subtitleTypes: types('subtitles'),
      subtitlePrefixes: prefixes('subtitles'),
      catalogs: [for (final c in (j['catalogs'] is List ? j['catalogs'] as List : const [])) ?AddonCatalog.fromManifest(c)],
      meta: has('meta'),
      metaTypes: types('meta'),
      metaPrefixes: prefixes('meta'),
      addonCatalogs: [for (final c in (j['addonCatalogs'] is List ? j['addonCatalogs'] as List : const [])) ?AddonCatalog.fromManifest(c)],
      needsSetup: hints['configurationRequired'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'url': manifestUrl,
    'id': id,
    'name': name,
    'version': version,
    'description': description,
    'logo': ?logo,
    'streams': streams,
    'subtitles': subtitles,
    'configurable': configurable,
    'st': streamTypes,
    'sp': streamPrefixes,
    'ut': subtitleTypes,
    'up': subtitlePrefixes,
    'on': enabled,
    'cat': [for (final c in catalogs) c.toJson()],
    if (meta) 'meta': true,
    if (metaTypes.isNotEmpty) 'mt': metaTypes,
    if (metaPrefixes.isNotEmpty) 'mp': metaPrefixes,
    if (addonCatalogs.isNotEmpty) 'ac': [for (final c in addonCatalogs) c.toJson()],
    if (plugins) 'pl': true,
    'pb': ?browse,
    if (comicsOff.isNotEmpty) 'co': comicsOff,
  };

  static Addon? fromJson(Map<String, dynamic> j) {
    try {
      List<String> l(String k) => [for (final x in (j[k] as List?) ?? const []) '$x'];
      return Addon(
        manifestUrl: j['url'] as String,
        id: j['id'] as String,
        name: j['name'] as String,
        version: j['version'] as String? ?? '',
        description: j['description'] as String? ?? '',
        logo: j['logo'] as String?,
        streams: j['streams'] == true,
        subtitles: j['subtitles'] == true,
        configurable: j['configurable'] == true,
        streamTypes: l('st'),
        streamPrefixes: l('sp'),
        subtitleTypes: l('ut'),
        subtitlePrefixes: l('up'),
        enabled: j['on'] != false,
        catalogs: [for (final c in (j['cat'] is List ? j['cat'] as List : const [])) ?AddonCatalog.fromJson(c)],
        meta: j['meta'] == true,
        metaTypes: l('mt'),
        metaPrefixes: l('mp'),
        catalogsRead: j.containsKey('cat'),
        addonCatalogs: [for (final c in (j['ac'] is List ? j['ac'] as List : const [])) ?AddonCatalog.fromJson(c)],
        plugins: j['pl'] == true,
        browse: j['pb'] is List ? [for (final x in j['pb'] as List) '$x'] : null,
        comicsOff: l('co'),
      );
    } catch (_) {
      return null;
    }
  }
}

/// An episode of a title from a metadata addon, as the stream addons know it: the id its video
/// goes by, and where IMDb counts it (when the addon says so, or its numbers are IMDb's own).
@immutable
class AddonVideoRef {
  const AddonVideoRef({required this.season, required this.episode, required this.id, this.imdbSeason, this.imdbEpisode, this.inline = const []});
  final int season;
  final int episode;
  final String id;
  final int? imdbSeason;
  final int? imdbEpisode;

  /// The streams its addon put in the episode itself.
  final List<Map<String, dynamic>> inline;
}

/// What to ask addons for: one film, or one episode, under every id we know for it.
@immutable
class AddonTarget {
  const AddonTarget({
    required this.type,
    this.imdb,
    this.tmdb,
    this.kitsu,
    this.season,
    this.episode,
    this.anime = false,
    this.title,
    this.year,
    this.raw,
    this.video,
    this.imdbSeason,
    this.imdbEpisode,
    this.videos = const [],
    this.inline = const [],
    this.inlineFrom,
  });
  final String type; // movie, series (an addon title: whatever its addon calls it)
  final String? imdb;
  final int? tmdb;
  final int? kitsu;
  final int? season;
  final int? episode; // anime: counted straight through
  final bool anime;

  /// Its name and year, for the built-in source, which searches by title (Stremio addons go
  /// by the ids above). Not set for anime.
  final String? title;
  final int? year;

  /// A title from a metadata addon: its own id (`tt0944947`, `kitsu:7442`, `yt_id:…`), and for an
  /// episode the id its video goes by (`tt0944947:1:1`, `kitsu:7442:1`). An addon that takes
  /// these ids is asked for them as they are, the way Stremio asks.
  final String? raw;
  final String? video;

  /// Where IMDb counts the episode, for addons that only take IMDb's ids (null: unknown).
  final int? imdbSeason;
  final int? imdbEpisode;

  /// Every episode of that addon title, to find another episode's ids by.
  final List<AddonVideoRef> videos;

  /// Streams its details carry for this film or episode themselves (a video's `streams`), and
  /// the addon they came from: listed as that addon's own on the sources screen.
  final List<Map<String, dynamic>> inline;
  final Addon? inlineFrom;

  AddonTarget withEpisode(int? season, int? episode) {
    if (raw != null) {
      final v = videos.where((v) => v.season == season && v.episode == episode).firstOrNull;
      return AddonTarget(
        type: type,
        imdb: imdb,
        tmdb: tmdb,
        season: season,
        episode: episode,
        title: title,
        year: year,
        raw: raw,
        video: v?.id,
        imdbSeason: v?.imdbSeason,
        imdbEpisode: v?.imdbEpisode,
        videos: videos,
        inline: v?.inline ?? const [],
        inlineFrom: inlineFrom,
      );
    }
    return AddonTarget(type: type, imdb: imdb, tmdb: tmdb, kitsu: kitsu, season: season, episode: episode, anime: anime, title: title, year: year);
  }

  /// The id [prefixes] understands (an addon that names none takes IMDb ids), or null.
  String? idFor(List<String> prefixes) {
    bool takes(String id) => prefixes.isEmpty ? id.startsWith('tt') : prefixes.any(id.startsWith);
    if (raw != null) {
      final episodeOf = video != null || (season != null && episode != null);
      final own = video ?? (episodeOf ? '$raw:$season:$episode' : raw!);
      if (takes(own)) return own;
      // IMDb's and TMDB's ids, for an episode only where IMDb's numbers for it are known
      final s = imdbSeason, e = imdbEpisode;
      final known = !episodeOf || type == 'movie' || (s != null && e != null);
      for (final id in [
        if (imdb != null && known) episodeOf && type != 'movie' ? '$imdb:$s:$e' : imdb!,
        if (tmdb != null && known) episodeOf && type != 'movie' ? 'tmdb:$tmdb:$s:$e' : 'tmdb:$tmdb',
      ]) {
        if (takes(id)) return id;
      }
      return null;
    }
    final series = type == 'series';
    final tt = imdb == null ? null : (anime ? (series ? null : imdb) : (series ? '$imdb:$season:$episode' : imdb));
    final kt = kitsu == null ? null : (series ? 'kitsu:$kitsu:$episode' : 'kitsu:$kitsu');
    final tm = tmdb == null || anime ? null : (series ? 'tmdb:$tmdb:$season:$episode' : 'tmdb:$tmdb');
    for (final id in anime ? [kt, tt] : [tt, tm]) {
      if (id == null) continue;
      if (prefixes.isEmpty ? id.startsWith('tt') : prefixes.any(id.startsWith)) return id;
    }
    return null;
  }

  bool typeOk(List<String> types) => types.isEmpty || types.contains(type) || (anime && types.contains('anime'));
}

/// One stream an addon offered, with what its text says about it read out: quality, source,
/// codec, HDR, audio, languages, size, seeders and whether a debrid service has it cached.
class AddonStream {
  AddonStream({
    required this.addon,
    required this.url,
    required this.text,
    this.name = '',
    this.description = '',
    this.filename,
    this.bingeGroup,
    this.headers = const {},
    this.sizeBytes,
    this.infoHash,
    this.fileIdx,
    this.trackers = const [],
    this.external,
    this.subtitles = const [],
    this.hls,
    this.plugin,
  });
  final Addon addon;

  /// An HLS playlist, said by its source (a plugin's link need not end in .m3u8); null: by its link.
  final bool? hls;
  final String url; // empty for a torrent, and for a plugin's link still to be found on this device

  /// A plugin's link: which plugin found it and which of its links it is (a watch party's guests
  /// run that plugin themselves: [Addons.pluginAgain]).
  final PluginRef? plugin;

  /// A plugin's link the host of a watch party played, to be found again here.
  bool get findHere => plugin != null && url.isEmpty;

  /// Which stream this is in a watch party: a plugin's link by its plugin and place (each device
  /// finds its own link), a torrent by its file, anything else by its link.
  String get partyKey => plugin?.key ?? (torrent ? '$infoHash:$fileIdx' : url);

  /// Not a video VyseTV plays but a link that opens elsewhere: a web page (`externalUrl`), a
  /// YouTube video (`ytId`, opened on YouTube), or a Stremio link (`stremio:///detail/…`, opened
  /// in VyseTV). Listed after what plays; never picked by autoplay.
  final String? external;

  /// The stream's own subtitle files (Stremio's `subtitles` on a stream), offered with it.
  final List<SubtitleTrack> subtitles;
  final String? infoHash; // a torrent, played peer to peer by our engine
  final int? fileIdx; // which file in the torrent (from 0)
  final List<String> trackers;
  bool get torrent => infoHash != null;
  final String text; // the addon's name + description lines, as sent
  final String name; // its name line(s), e.g. Torrentio over 4k
  final String description; // the rest, as the addon formatted it
  final String? filename;
  final String? bingeGroup; // the same release for the next episode
  final Map<String, String> headers;
  final int? sizeBytes;

  static AddonStream? parse(Addon addon, Map<String, dynamic> j) {
    final url = '${j['url'] ?? ''}';
    final hash = '${j['infoHash'] ?? ''}';
    final isTorrent = !url.startsWith('http') && RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(hash);
    final yt = '${j['ytId'] ?? ''}'.trim(), page = '${j['externalUrl'] ?? ''}'.trim();
    final external = url.startsWith('http') || isTorrent
        ? null
        : (yt.isNotEmpty ? 'https://www.youtube.com/watch?v=${Uri.encodeComponent(yt)}' : (page.startsWith('http') || page.startsWith('stremio:') ? page : null));
    // links play directly; torrents through our engine where it runs; a page or YouTube video
    // opens where it lives; anything else (archives, Usenet) needs Stremio's own server
    if (!url.startsWith('http') && !(isTorrent && Torrents.supported) && external == null) return null;
    final hints = j['behaviorHints'] is Map ? j['behaviorHints'] as Map : const {};
    final proxy = hints['proxyHeaders'] is Map ? hints['proxyHeaders'] as Map : const {};
    final request = proxy['request'] is Map ? proxy['request'] as Map : const {};
    final text = [j['name'], j['description'] ?? j['title']].whereType<String>().join('\n').trim();
    return AddonStream(
      addon: addon,
      url: url,
      text: text,
      name: '${j['name'] ?? ''}'.trim(),
      description: '${j['description'] ?? j['title'] ?? ''}'.trim(),
      filename: hints['filename'] as String?,
      bingeGroup: hints['bingeGroup'] as String?,
      headers: {for (final e in request.entries) '${e.key}': '${e.value}'},
      sizeBytes: (hints['videoSize'] as num?)?.toInt(),
      infoHash: isTorrent ? hash.toLowerCase() : null,
      fileIdx: isTorrent ? (j['fileIdx'] as num?)?.toInt() : null,
      trackers: [
        if (isTorrent)
          for (final s in (j['sources'] as List?) ?? const [])
            if ('$s'.startsWith('tracker:')) '$s'.substring(8),
      ],
      external: external,
      subtitles: [
        for (final (i, s) in (j['subtitles'] is List ? j['subtitles'] as List : const []).whereType<Map>().indexed)
          if ('${s['url'] ?? ''}'.startsWith('http'))
            subtitleTrack(
              'stream-${addon.id}-${hash.isEmpty ? url.hashCode : hash}-$i',
              addon.name,
              '${s['lang'] ?? 'eng'}',
              '${s['url']}',
              format: RegExp(r'\.(vtt|ass|ssa)(\?|$)').firstMatch('${s['url']}')?.group(1) ?? 'srt',
            ),
      ],
    );
  }

  /// It plays in VyseTV's player (a link or a torrent), rather than opening elsewhere.
  bool get playable => external == null;

  // the description and the file name (which often says more), with dots as spaces
  late final String _raw = '$text\n${filename ?? ''}';
  late final String _t = _raw.replaceAll(RegExp(r'[._]'), ' ');
  bool _has(String pattern) => RegExp(pattern, caseSensitive: false).hasMatch(_t);

  /// 4K, 1440p, 1080p, 720p, 480p or SD (unknown).
  late final String quality = _has(r'2160p|\b4k\b|\buhd\b')
      ? '4K'
      : _has(r'1440p|\b2k\b')
          ? '1440p'
          : _has(r'1080p|\bfhd\b|full ?hd')
              ? '1080p'
              : _has(r'720p|\bhd\b')
                  ? '720p'
                  : _has(r'480p|576p')
                      ? '480p'
                      : 'SD';
  int get qualityRank => const {'4K': 5, '1440p': 4, '1080p': 3, '720p': 2, '480p': 1}[quality] ?? 0;

  /// The quality filter it falls under: 4K, 1080p (1440p too), 720p or SD.
  String get bucket => switch (quality) {
    '4K' => '4K',
    '1440p' || '1080p' => '1080p',
    '720p' => '720p',
    _ => 'SD',
  };

  late final String? source = _has(r'\bremux\b')
      ? 'Remux'
      : _has(r'blu-?ray|\bbd ?rip\b|\bbr ?rip\b|\bbdremux\b|\bbd\b|\bbd(?=\d{3,4}p)')
          ? 'BluRay'
          : _has(r'web-?dl|\bwebdl\b')
              ? 'WEB-DL'
              : _has(r'web-?rip')
                  ? 'WEBRip'
                  : _has(r'\bhdtv\b')
                      ? 'HDTV'
                      : _has(r'dvd-?rip|\bdvd\b')
                          ? 'DVD'
                          : _has(r'\bcam\b|\bhdcam\b|\btelesync\b|\bts\b')
                              ? 'Cam'
                              : null;

  late final String? codec = _has(r'\bav1\b')
      ? 'AV1'
      : _has(r'hevc|x ?265|h ?265')
          ? 'HEVC'
          : _has(r'\bavc\b|x ?264|h ?264')
              ? 'AVC'
              : null;
  late final bool tenBit = _has(r'10 ?bit');

  /// Dolby Vision, HDR10+, HDR10 or HDR.
  late final String? hdr = _has(r'dolby ?vision|\bdovi\b|\bdv\b')
      ? 'Dolby Vision'
      : _has(r'hdr ?10 ?\+|hdr10plus')
          ? 'HDR10+'
          : _has(r'hdr ?10')
              ? 'HDR10'
              : _has(r'\bhdr\b')
                  ? 'HDR'
                  : null;

  late final String? audio = [
    if (_has(r'atmos')) 'Atmos',
    if (_has(r'true ?hd'))
      'TrueHD'
    else if (_has(r'dts ?-?hd ?(ma)?|dts ?x\b'))
      'DTS-HD'
    // release names stick the channels on: DD5.1, AAC2.0
    else if (_has(r'\bdts(?=\d|\b)'))
      'DTS'
    else if (_has(r'\bddp|dd\+|e-?ac-?3|eac3'))
      'Dolby Digital+'
    else if (_has(r'\bdd(?=\d|\b)|\bac-?3\b|dolby digital'))
      'Dolby Digital'
    else if (_has(r'\bflac(?=\d|\b)'))
      'FLAC'
    else if (_has(r'\baac(?=\d|\b)'))
      'AAC'
    else if (_has(r'\bopus(?=\d|\b)'))
      'Opus',
  ].join(' ').trim().let((s) => s.isEmpty ? null : s);

  // "Atmos.7.1" and "DDP5.1", but not the tail of a version number like 2.5.1
  late final String? channels = RegExp(r'(?<!\d)(?<!\d\.)([2578])[ .]([01])(?![\d])').firstMatch(_raw)?.let((m) => '${m[1]}.${m[2]}');

  /// 7.1 → 71, 5.1 → 51, stereo → 20; 0 when it doesn't say.
  late final int channelRank = ((double.tryParse(channels ?? '') ?? 0) * 10).round();

  /// Atmos over everything, then the lossless tracks, Dolby Digital+, Dolby Digital, the rest.
  late final int audioRank = () {
    final a = audio ?? '';
    final base = a.contains('TrueHD')
        ? 6
        : a.contains('DTS-HD')
        ? 5
        : a.contains('Digital+')
        ? 4
        : a.contains('Dolby Digital')
        ? 3
        : a.contains('DTS') || a.contains('FLAC')
        ? 2
        : a.isEmpty || a == 'Atmos'
        ? 0
        : 1;
    return (a.contains('Atmos') ? 10 : 0) + base;
  }();

  int get sourceRank => const {'Remux': 6, 'BluRay': 5, 'WEB-DL': 4, 'WEBRip': 3, 'HDTV': 2, 'DVD': 1, 'Cam': -5}[source] ?? 0;

  /// How it ranks for "Play best": a cinema recording last whatever it claims, what plays right
  /// away (a link, or cached) first, then the picture (4K down), then the sound (7.1 over 5.1
  /// over stereo, and Atmos over Dolby Digital within each).
  late final int rank = !playable
      ? -1
      : (source == 'Cam' ? 0 : 10000000) + (cached || !torrent ? 1000000 : 0) + qualityRank * 100000 + channelRank * 1000 + audioRank * 10;

  /// The languages it's in: its flags (🇯🇵 → Japanese), the badge template's language badges, and
  /// "Multi" when it says so.
  late final List<String> languages = <String>{
    for (final m in _flags.allMatches(text)) ?_flagLanguage(m[0]!),
    for (final b in Badges.languages(badges)) b.name,
    if (_has(r'\bmulti\b|dual ?audio')) 'Multi',
  }.toList();

  static final _flags = RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);

  /// What the badge patterns read: the text and file name, with flags spelled out as languages.
  late final String _badgeText = '$_raw ${[for (final m in _flags.allMatches(text)) ?_flagLanguage(m[0]!)].join(' ')}';

  /// The badges this stream earns from the badge template (4K, Remux, Dolby Vision, Atmos, EN…).
  late final List<SourceBadge> badges = Badges.of(_badgeText);

  late final int? seeders = RegExp(r'👤\s*(\d+)').firstMatch(text)?.let((m) => int.tryParse(m[1]!));

  /// Ready to play from a debrid service right away ([RD+], ⚡, "cached").
  late final bool cached = RegExp(r'\[(RD|AD|PM|TB|DL|ED|OC|PKP|EN)\+\]|⚡|\bcached\b|instant', caseSensitive: false).hasMatch(text);

  late final int? size = sizeBytes ??
      RegExp(r'(\d+(?:[.,]\d+)?)\s*(TB|GB|GiB|MB|MiB)\b', caseSensitive: false).firstMatch(text)?.let((m) {
        final n = double.tryParse(m[1]!.replaceAll(',', '.')) ?? 0;
        final u = m[2]!.toUpperCase();
        final mult = u.startsWith('T') ? 1e12 : (u.startsWith('G') ? 1e9 : 1e6);
        return (n * mult).round();
      });

  String? get sizeLabel {
    final s = size;
    if (s == null || s <= 0) return null;
    return s >= 1e9 ? '${(s / 1e9).toStringAsFixed(s >= 1e10 ? 0 : 1)} GB' : '${(s / 1e6).round()} MB';
  }

  /// The release's file name: the hint, or the first line of the description that looks like one.
  late final String? release = filename ??
      text.split('\n').skip(1).map((l) => l.trim()).where((l) => RegExp(r'\S+[.\s]\S+').hasMatch(l) && l.length > 12 && !l.contains('👤')).firstOrNull;

  /// The playable source for the player: the addon's own name as the server.
  StreamSource toSource() => StreamSource(
    url: url,
    server: addon.name,
    quality: quality,
    referrer: headers['Referer'] ?? headers['referer'] ?? '',
    userAgent: headers['User-Agent'] ?? headers['user-agent'] ?? _ua,
    headers: headers,
    hls: hls ?? url.contains('.m3u8'),
  );
}

/// 🇯🇵 → "Japanese": the country's main language, where there is one clearly.
String? _flagLanguage(String flag) {
  final country = String.fromCharCodes(flag.runes.map((r) => r - 0x1F1E6 + 65));
  const lang = {
    'GB': 'English', 'US': 'English', 'AU': 'English', 'CA': 'English', 'JP': 'Japanese', 'FR': 'French',
    'ES': 'Spanish', 'MX': 'Latino', 'AR': 'Latino', 'DE': 'German', 'IT': 'Italian', 'RU': 'Russian',
    'UA': 'Ukrainian', 'KR': 'Korean', 'CN': 'Chinese', 'TW': 'Chinese', 'HK': 'Chinese', 'IN': 'Hindi',
    'BR': 'Portuguese', 'PT': 'Portuguese', 'NL': 'Dutch', 'PL': 'Polish', 'TR': 'Turkish', 'SA': 'Arabic',
    'AE': 'Arabic', 'EG': 'Arabic', 'SE': 'Swedish', 'DK': 'Danish', 'NO': 'Norwegian', 'FI': 'Finnish',
    'GR': 'Greek', 'IL': 'Hebrew', 'TH': 'Thai', 'VN': 'Vietnamese', 'ID': 'Indonesian', 'CZ': 'Czech',
    'HU': 'Hungarian', 'RO': 'Romanian', 'BG': 'Bulgarian', 'IR': 'Persian',
  };
  return lang[country];
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// One step of your autoplay order: what a source has to be for the step to take it. A part
/// left open (null) isn't asked about.
@immutable
class AutoplayStep {
  const AutoplayStep({this.quality, this.audio, this.channels});
  final String? quality; // one of [qualities]
  final String? audio; // one of [audios]
  final String? channels; // one of [layouts]

  static const qualities = ['4K', '1080p', '720p', 'SD'];
  static const audios = ['Atmos', 'TrueHD', 'DTS-HD', 'Dolby Digital+', 'Dolby Digital', 'DTS', 'AAC'];
  static const layouts = ['7.1', '5.1', '2.0'];

  /// A family takes its better members too: Dolby Digital also takes Dolby Digital+, and DTS
  /// takes DTS-HD.
  bool matches(AddonStream s) =>
      (quality == null || s.bucket == quality) && (audio == null || (s.audio ?? '').contains(audio!)) && (channels == null || s.channels == channels);

  String get label => quality == null && audio == null && channels == null ? 'Anything' : [?quality, ?audio, ?channels].join(' · ');

  Map<String, String> toJson() => {'q': ?quality, 'a': ?audio, 'c': ?channels};

  static AutoplayStep? fromJson(Object? j) {
    if (j is! Map) return null;
    String? one(String key, List<String> of) => of.contains(j[key]) ? j[key] as String : null;
    return AutoplayStep(quality: one('q', qualities), audio: one('a', audios), channels: one('c', layouts));
  }
}

/// Your own order for "Autoplay the best source" (Settings → Playback): steps it tries from the
/// top down. With none, it goes by [AddonStream.rank]: 4K first, then the best sound.
class AutoplayOrder {
  static List<AutoplayStep> get steps {
    try {
      return [for (final j in json.decode(AppSettings.autoplayOrder.value) as List) ?AutoplayStep.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  static void save(List<AutoplayStep> steps) => AppSettings.autoplayOrder.set(steps.isEmpty ? '' : json.encode([for (final s in steps) s.toJson()]));

  /// [streams] in the order autoplay tries them. Each goes to the first step that takes it
  /// (a cinema recording to none: it only ever plays as a last resort), and what no step takes
  /// comes last, or is left out when you've said only your steps count. Within a step the best
  /// first ([Addons.byBest]; ties stay as the addons sent them).
  ///
  /// A step's best two lead, then the next step's: when one doesn't play, the fallback moves
  /// down your order rather than through every copy of the same thing.
  static List<AddonStream> arrange(Iterable<AddonStream> streams) {
    final order = steps;
    final groups = [for (var i = 0; i <= order.length; i++) <(int, AddonStream)>[]];
    for (final (i, s) in streams.indexed) {
      if (!s.playable) continue; // (a page or a YouTube video: opened by hand, never played by itself)
      final step = s.source == 'Cam' ? -1 : order.indexWhere((x) => x.matches(s));
      groups[step < 0 ? order.length : step].add((i, s));
    }
    if (order.isNotEmpty && !AppSettings.autoplayRest.value) groups.last.clear();
    for (final g in groups) {
      g.sort((a, b) {
        final d = Addons.byBest(a.$2, b.$2);
        return d != 0 ? d : a.$1 - b.$1;
      });
    }
    return [
      for (final g in groups) ...g.take(2).map((e) => e.$2),
      for (final g in groups) ...g.skip(2).map((e) => e.$2),
    ];
  }
}

/// A stream picked on the sources screen, and what it was picked for (to find the next
/// episode's on the same addon).
class AddonPick {
  const AddonPick(this.stream, this.target);
  final AddonStream stream;
  final AddonTarget target;
}

/// Your Stremio addons: installing, turning on and off, ordering, and asking them for streams and
/// subtitles. The list lives in the synced settings.
class Addons {
  static final list = ValueNotifier<List<Addon>>(const []);
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    AppSettings.addons.addListener(_load);
    _load();
    unawaited(refresh());
  }

  /// Reads every installed addon's manifest again, at most once a day unless [force]: an addon
  /// that changed what it offers (a configured one's catalogs, a new version) is kept current, in
  /// its place and on or off as you left it. One that doesn't answer stays as it was.
  static Future<void> refresh({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - AppSettings.addonsRefreshed.value < const Duration(days: 1).inMilliseconds) return;
    AppSettings.addonsRefreshed.set(now);
    final fresh = <String, Addon>{};
    await Future.wait([
      for (final a in list.value)
        if (!a.builtIn)
          () async {
            try {
              // a plugin repository: its plugins whose version changed are downloaded again
              fresh[a.manifestUrl] = a.plugins
                  ? Addon.ofPlugins(await PluginRepos.install(a.manifestUrl), browse: a.browse, comicsOff: a.comicsOff)
                  : Addon.fromManifest(a.manifestUrl, await _manifest(a.manifestUrl));
            } catch (_) {}
          }(),
    ]);
    if (fresh.isEmpty) return;
    _save([for (final a in list.value) fresh[a.manifestUrl]?.copyWith(enabled: a.enabled) ?? a]);
  }

  static void _load() {
    List<Addon> saved;
    try {
      saved = [
        for (final j in (json.decode(AppSettings.addons.value) as List).cast<Map<String, dynamic>>()) ?Addon.fromJson(j),
      ];
    } catch (_) {
      saved = const [];
    }
    list.value = withBuiltIns(saved);
    for (final a in list.value) {
      if (!a.builtIn && !a.plugins && !a.catalogsRead && _reread.add(a.manifestUrl)) unawaited(_readAgain(a));
    }
  }

  static final _reread = <String>{};

  /// An addon saved before VyseTV read catalogs: its manifest once more, for what it offers to
  /// browse. Kept as it was if that fails.
  static Future<void> _readAgain(Addon old) async {
    try {
      final fresh = Addon.fromManifest(old.manifestUrl, await _manifest(old.manifestUrl));
      final l = [...list.value];
      final i = l.indexWhere((x) => x.manifestUrl == old.manifestUrl);
      if (i < 0) return;
      l[i] = fresh.copyWith(enabled: l[i].enabled);
      _save(l);
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> _manifest(String url) async {
    final r = await netClient.get(Uri.parse(url), headers: {'User-Agent': _ua, 'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw StateError('HTTP ${r.statusCode}');
    return json.decode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// [saved] with the built-in addons in it: each stays where you put it and on or off as you
  /// left it (only that is taken from the saved copy; its name and description are the app's),
  /// and one the list doesn't have yet goes at the end, turned on.
  static List<Addon> withBuiltIns(List<Addon> saved) {
    Addon? builtIn(Addon a) => Addon.builtIns.where((b) => b.manifestUrl == a.manifestUrl).firstOrNull;
    return [
      for (final a in saved)
        if (!a.builtIn) a else if (builtIn(a) != null) builtIn(a)!.copyWith(enabled: a.enabled),
      for (final b in Addon.builtIns)
        if (!saved.any((a) => a.manifestUrl == b.manifestUrl)) b,
    ];
  }

  static void _save(List<Addon> l) {
    list.value = l;
    AppSettings.addons.set(json.encode([for (final a in l) a.toJson()]));
  }

  static List<Addon> get streamAddons => [for (final a in list.value) if (a.enabled && a.streams) a];
  static List<Addon> get subtitleAddons => [for (final a in list.value) if (a.enabled && a.subtitles) a];

  /// Whether TMDB, the built-in metadata addon, is on (it is, until you turn it off).
  static bool get tmdbOn => list.value.where((a) => a.manifestUrl == Addon.tmdb.manifestUrl).firstOrNull?.enabled ?? true;

  /// Your metadata addons that are on, in your order (TMDB not among them).
  static List<Addon> get metaAddons => [for (final a in list.value) if (a.enabled && !a.builtIn && a.metadata) a];

  /// Those of them with catalogs to browse.
  static List<Addon> get catalogAddons => [for (final a in metaAddons) if (a.catalogs.isNotEmpty) a];

  /// Home, Discover and search come only from your metadata addons: TMDB is off.
  static bool get addonsOnly => !tmdbOn;

  /// `stremio://host/manifest.json`, a configure page's link, or the manifest's own address.
  static String normalize(String input) {
    var u = input.trim();
    if (u.startsWith('stremio://')) u = 'https://${u.substring(10)}';
    if (!u.startsWith('http')) u = 'https://$u';
    u = u.replaceFirst(RegExp(r'/configure/?$'), '');
    if (!u.endsWith('/manifest.json')) u = '${u.replaceFirst(RegExp(r'/+$'), '')}/manifest.json';
    return u;
  }

  /// Reads the addon's manifest and adds it (or updates it, for a link you already have).
  /// Throws a readable message when it offers nothing VyseTV uses. A new addon with catalogs goes
  /// just above TMDB, so its rows lead on Home; any other goes at the end. A plugin repository's
  /// link (a `repo.json`, or a Vega `manifest.json`: a list) adds it as an addon of its own.
  static Future<Addon> install(String input) async {
    final given = normalizeRepoUrl(input);
    // a .json link is read as it is: a plugin repository, or a Stremio manifest
    if (given.startsWith('http') && RegExp(r'\.json(\?|#|$)').hasMatch(given)) {
      Object? j;
      String? text;
      try {
        text = await fetchText(given, timeout: const Duration(seconds: 20));
        j = json.decode(text);
      } catch (e) {
        if (!given.endsWith('/manifest.json')) {
          throw e is HttpError && (e.status == 404 || e.status == 410)
              ? "That link is gone (404): the file was deleted or moved."
              : "Couldn't read that link. Check it (a repo.json, or an addon's manifest.json).";
        }
      }
      if (isPluginRepo(j)) return _installPlugins(given, text!);
    }
    final url = normalize(input);
    final Map<String, dynamic> j;
    try {
      j = await _manifest(url);
    } catch (_) {
      throw "Couldn't read that addon. Check the link (it ends in manifest.json).";
    }
    final a = Addon.fromManifest(url, j);
    if ((j['behaviorHints'] is Map) && (j['behaviorHints'] as Map)['configurationRequired'] == true) {
      throw '${a.name} needs setting up first: open its configure page, then paste the link it gives you.';
    }
    if (!a.streams && !a.subtitles && !a.metadata) {
      throw "${a.name} doesn't offer catalogs, details, streams or subtitles, so it has nothing to add here.";
    }
    final l = [...list.value];
    final i = l.indexWhere((x) => x.manifestUrl == url || x.id == a.id);
    if (i >= 0) {
      l[i] = a.copyWith(enabled: l[i].enabled);
    } else if (a.catalogs.isNotEmpty) {
      final t = l.indexWhere((x) => x.manifestUrl == Addon.tmdb.manifestUrl);
      l.insert(t < 0 ? l.length : t, a);
    } else {
      l.add(a);
    }
    _save(l);
    return a;
  }

  /// A plugin repository's plugins downloaded to this device, and added (or updated) as an addon
  /// at the end of the list.
  static Future<Addon> _installPlugins(String url, String text) async {
    final PluginRepoInfo info;
    try {
      info = await PluginRepos.install(url, text: text);
    } on FormatException catch (e) {
      throw e.message;
    }
    final l = [...list.value];
    final i = l.indexWhere((x) => x.manifestUrl == url);
    final a = Addon.ofPlugins(info, browse: i >= 0 ? l[i].browse : null, comicsOff: i >= 0 ? l[i].comicsOff : const []);
    if (i >= 0) {
      l[i] = a.copyWith(enabled: l[i].enabled);
    } else if (a.catalogs.isNotEmpty) {
      // (with catalogs, like a metadata addon: just above TMDB, so its rows lead on Home)
      final t = l.indexWhere((x) => x.manifestUrl == Addon.tmdb.manifestUrl);
      l.insert(t < 0 ? l.length : t, a);
    } else {
      l.add(a);
    }
    _save(l);
    return a;
  }

  /// Plugin repository [a]'s catalogs: those of the plugins in [on] (Settings > Addons), and of
  /// its comic plugins all but [comicsOff] (null: as they are).
  static Future<void> setBrowse(Addon a, List<String> on, {List<String>? comicsOff}) async {
    final info = await PluginRepos.local(a.manifestUrl) ?? await PluginRepos.install(a.manifestUrl);
    final l = [...list.value];
    final i = l.indexWhere((x) => x.manifestUrl == a.manifestUrl);
    if (i < 0) return;
    l[i] = Addon.ofPlugins(info, browse: on, comicsOff: comicsOff ?? l[i].comicsOff).copyWith(enabled: l[i].enabled);
    _save(l);
  }

  /// (A built-in addon stays: it is turned off instead. A plugin repository's scripts leave this
  /// device with it.)
  static void remove(Addon a) {
    if (a.builtIn) return setEnabled(a, false);
    if (a.plugins) unawaited(PluginRepos.remove(a.manifestUrl));
    _save([for (final x in list.value) if (x.manifestUrl != a.manifestUrl) x]);
  }
  static void setEnabled(Addon a, bool on) => _save([for (final x in list.value) x.manifestUrl == a.manifestUrl ? x.copyWith(enabled: on) : x]);

  static void move(Addon a, int by) {
    final l = [...list.value];
    final i = l.indexWhere((x) => x.manifestUrl == a.manifestUrl);
    final j = i + by;
    if (i < 0 || j < 0 || j >= l.length) return;
    l.insert(j, l.removeAt(i));
    _save(l);
  }

  // ── what to ask for ──

  static final _imdb = <String, Future<String?>>{};

  /// A film or an episode of a show from TMDB, an anime from AniList, or a title from a metadata
  /// addon (under its own ids: see [MetaAddons.target]).
  static Future<AddonTarget> target(Media m, {int? season, int? episode, Anime? anime}) async {
    if (m.isAddon && anime == null) return MetaAddons.target(m, season: season, episode: episode);
    if (anime != null) {
      final x = await AnimeExtras.of(anime.id);
      return AddonTarget(type: anime.isMovie ? 'movie' : 'series', imdb: x.imdbId, kitsu: x.kitsuId, episode: episode, anime: true);
    }
    final imdb = await (_imdb[m.key] ??= Tmdb.get('/${m.isTv ? 'tv' : 'movie'}/${m.id}/external_ids').then(
      (j) => (j['imdb_id'] as String?)?.let((s) => s.startsWith('tt') ? s : null),
      onError: (Object _) {
        _imdb.remove(m.key);
        return null;
      },
    ));
    return AddonTarget(
      type: m.isTv ? 'series' : 'movie',
      imdb: imdb,
      tmdb: m.id,
      season: season,
      episode: episode,
      title: m.title,
      year: int.tryParse(m.year ?? ''),
    );
  }

  /// [a]'s playable streams for [t], and how many torrents it offered that only a debrid
  /// service set up in the addon could turn into links. Null when it doesn't cover this kind of
  /// title; throws on failure.
  /// [onSome]: a plugin repository's streams so far, each time one of its plugins finds some (it
  /// asks many sites, some slow); other addons answer all at once.
  static Future<({List<AddonStream> streams, int torrents})?> streams(Addon a, AddonTarget t, {void Function(List<AddonStream> soFar)? onSome}) async {
    if (a.plugins) return _pluginStreams(a, t, onSome);
    if (a.builtIn) return _builtInStreams(a, t);
    final id = t.idFor(a.streamPrefixes);
    if (id == null || !t.typeOk(a.streamTypes)) return null;
    final r = await netClient
        .get(Uri.parse('${a.base}/stream/${t.type}/$id.json'), headers: {'User-Agent': _ua, 'Accept': 'application/json'})
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw StateError('HTTP ${r.statusCode}');
    final j = json.decode(utf8.decode(r.bodyBytes));
    final list = (j is Map ? (j['streams'] as List?) ?? const [] : const []).whereType<Map<String, dynamic>>().toList();
    return (
      streams: [for (final s in list) ?AddonStream.parse(a, s)],
      torrents: Torrents.supported ? 0 : list.where((s) => s['infoHash'] != null && s['url'] == null).length,
    );
  }

  /// The built-in source's torrents for [t]. It searches by title, so it needs one (anime has
  /// none here and isn't covered), and for a show a season and an episode. A torrent comes
  /// without a file picked: the episode's file is found by name when it plays.
  static Future<({List<AddonStream> streams, int torrents})?> _builtInStreams(Addon a, AddonTarget t) async {
    final title = t.title;
    final series = t.type == 'series';
    if (t.anime || title == null || title.trim().isEmpty || !t.typeOk(a.streamTypes)) return null;
    if (series && (t.season == null || t.episode == null)) return null;
    // (an addon title's episode: where IMDb counts it, which release names go by, when known)
    final season = t.imdbSeason ?? t.season, episode = t.imdbEpisode ?? t.episode;
    final hits = await Knaben.search(title: title, series: series, year: t.year, season: season, episode: episode);
    if (!Torrents.supported) return (streams: const <AddonStream>[], torrents: hits.length);
    return (streams: [for (final h in hits) knabenStream(a, h)], torrents: 0);
  }

  /// What a plugin repository's plugins found for [t]. They look titles up by name (and TMDB and
  /// IMDb ids), so a title needs one; a show, a season and an episode. Null when not covered.
  static Future<({List<AddonStream> streams, int torrents})?> _pluginStreams(Addon a, AddonTarget t, void Function(List<AddonStream>)? onSome) async {
    if (!t.typeOk(a.streamTypes)) return null;
    final ask = await _pluginAsk(a.manifestUrl, t);
    if (ask == null) return null;
    List<AddonStream> streams(List<PluginHit> hits) => [
      for (final h in hits)
        if (_playsHere(h)) pluginStream(a, h),
    ];
    // one of its plugins' own titles: that plugin alone, asked for it by its own id
    final hits = ask.plugin != null
        ? await PluginRepos.findFor(a.manifestUrl, ask.query, only: ask.plugin)
        : await PluginRepos.find(a.manifestUrl, ask.query, onSome: onSome == null ? null : (l) => onSome(streams(l)));
    return (streams: streams(hits), torrents: 0);
  }

  /// What the plugins of the repository at [repo] are asked for [t]: one of its plugins' own
  /// titles (from its catalogs) by its own id, that plugin alone ([plugin]); anything else as
  /// [_pluginQuery] says, every plugin. Null when it can't be asked.
  static Future<({Map<String, Object?> query, String? plugin})?> _pluginAsk(String repo, AddonTarget t) async {
    // (an episode of its own goes by its own id; a show of its own whose episodes came from TMDB,
    // by the show's and TMDB's numbers)
    final own = PluginCatalogs.unwrap(repo, t.video) ?? PluginCatalogs.unwrap(repo, t.raw);
    if (own != null) {
      final series = t.type == 'series';
      return (
        query: <String, Object?>{
          'ownId': own.own,
          'type': series ? 'tv' : 'movie',
          'isTv': series,
          'season': series ? t.season : null,
          'episode': series ? t.episode : null,
          'title': t.title,
          'year': t.year,
          'tmdbId': t.tmdb,
          'imdbId': t.imdb,
        },
        plugin: own.plugin,
      );
    }
    final q = await _pluginQuery(t);
    return q == null ? null : (query: q, plugin: null);
  }

  /// (the Linux build's mpv has no DASH: a manifest it can't open isn't offered)
  static bool _playsHere(PluginHit h) => !(h.stream.type == 'dash' && Platform.isLinux);

  /// What plugins are asked for [t] (the plugin contract's query: plugins/README.md). Null when
  /// it can't be asked: no title known, or a show's episode without its numbers.
  static Future<Map<String, Object?>?> _pluginQuery(AddonTarget t) async {
    final series = t.type == 'series';
    // (an addon title's episode: where IMDb counts it, which sites go by, when known)
    final season = t.imdbSeason ?? t.season, episode = t.imdbEpisode ?? t.episode;
    if (series && (season == null || episode == null)) return null;
    final meta = t.tmdb == null ? null : await getTmdbMetadata('${t.tmdb}', series);
    final title = meta != null && meta.title.isNotEmpty ? meta.title : t.title;
    if (title == null || title.trim().isEmpty) return null;
    return {
      'tmdbId': t.tmdb,
      'imdbId': meta?.imdbId ?? t.imdb,
      'type': series ? 'tv' : 'movie',
      'isTv': series,
      'title': title,
      'originalTitle': meta != null && meta.originalTitle.isNotEmpty ? meta.originalTitle : title,
      'titles': meta != null && meta.titles.isNotEmpty ? meta.titles : [title],
      'isAnime': meta?.isAnime ?? t.anime,
      'year': meta?.year ?? t.year,
      'season': series ? season : null,
      'episode': series ? episode : null,
    };
  }

  /// A plugin's link as a stream: the plugin's name, then its quality, server and language.
  /// [ref]: which plugin and link it stands for in a watch party (the one found, unless said).
  @visibleForTesting
  static AddonStream pluginStream(Addon a, PluginHit h, {PluginRef? ref}) {
    final s = h.stream;
    final what = [if (s.quality != 'Auto') s.quality, if (s.server != 'Server') s.server, ?s.audio].join(' · ');
    final description = [if (what.isNotEmpty) what, if (s.label case final l? when l.trim().isNotEmpty) l.trim()].join('\n');
    return AddonStream(
      addon: a,
      url: s.url,
      text: '${h.plugin.name}\n$description',
      name: h.plugin.name,
      description: description,
      headers: s.headers,
      hls: s.type == 'hls',
      plugin: ref ?? PluginRef.of(a.manifestUrl, h),
    );
  }

  /// A watch party's guest: the host's plugin stream [p] found again on this device. Only which
  /// plugin and which of its links travel, never the host's link (a plugin's links are often only
  /// good for whoever asked): that plugin runs here, even when its repository isn't one of your
  /// addons, and its links come back most like the host's first (the same server, quality,
  /// label, language). When it finds nothing here, the repository's other plugins are asked
  /// until one finds something. Empty when nothing is found.
  static Future<List<AddonPick>> pluginAgain(AddonPick p, {int most = 6}) async {
    final ref = p.stream.plugin;
    if (ref == null) return const [];
    final ({Map<String, Object?> query, String? plugin})? asked;
    try {
      asked = await _pluginAsk(ref.repo, p.target);
    } catch (_) {
      return const [];
    }
    if (asked == null) return const [];
    Future<List<PluginHit>> ask({String? only, String? except}) async {
      try {
        return (await PluginRepos.findFor(ref.repo, asked!.query, only: only, except: except)).where(_playsHere).toList();
      } catch (_) {
        return const []; // (the repository couldn't be read)
      }
    }

    var hits = await ask(only: ref.id);
    // (a plugin's own title is only its own to find)
    if (hits.isEmpty && asked.plugin == null) hits = await ask(except: ref.id);
    // (each keeps the host's ref: what the room says is playing stays the same thing here)
    return [for (final h in closestHits(ref, hits).take(most)) AddonPick(pluginStream(p.stream.addon, h, ref: ref), p.target)];
  }

  /// A Knaben result as a stream, written the way Torrentio writes its own (the release's name,
  /// then seeders and size), so quality, sound, size and seeders read out of it the same way.
  static AddonStream knabenStream(Addon a, KnabenHit h) {
    final bytes = h.bytes ?? 0;
    final size = bytes <= 0 ? null : (bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(bytes >= 1e10 ? 0 : 1)} GB' : '${(bytes / 1e6).round()} MB');
    final description = [
      h.name,
      ['👤 ${h.seeders}', if (size != null) '💾 $size', if (h.pack) 'Season pack'].join(' · '),
    ].join('\n');
    return AddonStream(
      addon: a,
      url: '',
      text: '${a.name}\n$description',
      name: a.name,
      description: description,
      infoHash: h.infoHash,
      trackers: h.trackers,
      sizeBytes: bytes > 0 ? bytes : null,
      // a pack has the next episode too: "next episode" stays on it
      bingeGroup: h.pack ? 'knaben|${h.infoHash}' : null,
    );
  }

  /// Best first, for "Play best" and the quality sort: [AddonStream.rank], then HDR, the
  /// release's source (Remux down) and seeders.
  static int byBest(AddonStream a, AddonStream b) {
    for (final d in [
      b.rank - a.rank,
      (b.hdr != null ? 1 : 0) - (a.hdr != null ? 1 : 0),
      b.sourceRank - a.sourceRank,
      (b.seeders ?? 0) - (a.seeders ?? 0),
    ]) {
      if (d != 0) return d;
    }
    return 0;
  }

  /// Every stream addon's streams for [t] together (only those [where] allows), in the order
  /// autoplay tries them: your autoplay order, or best first without one
  /// ([AutoplayOrder.arrange]). A slow addon gets [patience], then it goes with what the others
  /// sent.
  static Future<List<AddonStream>> best(AddonTarget t, {Duration patience = const Duration(seconds: 8), bool Function(AddonStream)? where}) async {
    final addons = streamAddons;
    if (addons.isEmpty) return const [];
    final got = List<List<AddonStream>>.filled(addons.length, const []);
    final done = Completer<void>();
    var left = addons.length, timeUp = false;
    void check() {
      if (!done.isCompleted && (left == 0 || (timeUp && got.any((l) => l.isNotEmpty)))) done.complete();
    }

    for (final (i, a) in addons.indexed) {
      unawaited(() async {
        try {
          // (a plugin repository's streams count as they come: a slow plugin can't hold up autoplay)
          got[i] = (await streams(a, t, onSome: (l) {
                got[i] = l;
                check();
              }))?.streams ??
              const [];
        } catch (_) {}
        left--;
        check();
      }());
    }
    final timer = Timer(patience, () {
      timeUp = true;
      check();
    });
    await done.future;
    timer.cancel();
    final all = [for (final l in got) ...l];
    return AutoplayOrder.arrange(where == null ? all : all.where(where));
  }

  /// Every subtitle addon's files for [t], together. [filename] and [size]: the video's, when
  /// the stream playing says (Stremio sends them so an addon can match the exact release).
  static Future<List<SubtitleTrack>> subtitles(AddonTarget t, {String? filename, int? size}) async {
    final extra = [
      if (size != null && size > 0) 'videoSize=$size',
      if (filename != null && filename.isNotEmpty) 'filename=${Uri.encodeComponent(filename)}',
    ].join('&');
    final all = await Future.wait([
      for (final a in subtitleAddons)
        () async {
          final id = t.idFor(a.subtitlePrefixes);
          if (id == null || !t.typeOk(a.subtitleTypes)) return const <SubtitleTrack>[];
          try {
            final r = await netClient
                .get(Uri.parse('${a.base}/subtitles/${t.type}/$id${extra.isEmpty ? '' : '/$extra'}.json'), headers: {'User-Agent': _ua, 'Accept': 'application/json'})
                .timeout(const Duration(seconds: 15));
            if (r.statusCode != 200) return const <SubtitleTrack>[];
            final j = json.decode(utf8.decode(r.bodyBytes));
            final subs = j is Map ? (j['subtitles'] as List?) ?? const [] : const [];
            return [
              for (final (i, s) in subs.whereType<Map>().indexed)
                if ('${s['url'] ?? ''}'.startsWith('http'))
                  subtitleTrack(
                    'addon-${a.id}-$i',
                    a.name,
                    '${s['lang'] ?? 'eng'}',
                    '${s['url']}',
                    format: RegExp(r'\.(vtt|ass|ssa)(\?|$)').firstMatch('${s['url']}')?.group(1) ?? 'srt',
                  ),
            ];
          } catch (_) {
            return const <SubtitleTrack>[];
          }
        }(),
    ]);
    return [for (final l in all) ...l];
  }

  /// The same addon's stream for another episode: the same release (bingeGroup) when it has it,
  /// else the same quality, else its first.
  static Future<AddonPick?> follow(AddonPick p, int? season, int? episode) async {
    final t = p.target.withEpisode(season, episode);
    try {
      final l = (await streams(p.stream.addon, t))?.streams.where((s) => s.playable).toList();
      if (l == null || l.isEmpty) return null;
      final was = p.stream;
      final same = was.bingeGroup == null ? null : l.where((s) => s.bingeGroup == was.bingeGroup).firstOrNull;
      return AddonPick(same ?? l.where((s) => s.quality == was.quality && s.cached == was.cached).firstOrNull ?? l.first, t);
    } catch (_) {
      return null;
    }
  }

  /// The player's source for [p], with the headers its host wants on every request.
  static StreamSource sourceOf(AddonPick p) {
    final s = p.stream.toSource();
    if (s.headers.isNotEmpty) StreamProxy.instance.useHeaders(s.url, s.headers);
    return s;
  }
}
