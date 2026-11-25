// Plugins that list titles to browse (plugins/README.md): their catalogs and their titles' details
// answered the way a Stremio addon answers them, so Home, Discover, search and the details pages
// show them like any metadata addon's (lib/data/catalog/meta_addons.dart asks here for a plugin
// repository). A plugin's title goes by `pl:<repository key>:<plugin id>:<its own id>` and plays
// from that plugin, asked for its own id (addons.dart).
//
// Which plugins' catalogs show is yours to pick in Settings > Addons: a scraper list's are on when
// it is added, a Vega provider's off (a repository of them can list hundreds).

import 'package:flutter/foundation.dart';

import '../addons.dart';
import 'js_plugins.dart';

abstract final class PluginCatalogs {
  /// What the ids of the repository at [repoUrl]'s titles start with.
  static String prefix(String repoUrl) => 'pl:${PluginRepos.repoKey(repoUrl)}:';

  /// A title of [plugin] (its own id [own]) as VyseTV knows it.
  static String wrap(String repoUrl, String plugin, String own) => '${prefix(repoUrl)}$plugin:$own';

  /// [id] as its plugin and its own id, when it is one of [repoUrl]'s titles.
  static ({String plugin, String own})? unwrap(String repoUrl, String? id) {
    final p = prefix(repoUrl);
    if (id == null || !id.startsWith(p)) return null;
    final rest = id.substring(p.length);
    final at = rest.indexOf(':');
    if (at <= 0 || at == rest.length - 1) return null;
    return (plugin: rest.substring(0, at), own: rest.substring(at + 1));
  }

  /// A plugin's name as a heading: "!HDFilmCehennemi" (a sorting trick) is "HDFilmCehennemi".
  static String plainName(String name) => name.replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '').trim();

  /// [c], one of plugin [p]'s catalogs, as one of its repository's addon catalogs: its id
  /// `<plugin>/<catalog>`, its name led by the plugin's.
  static AddonCatalog addonCatalog(PluginEntry p, PluginCatalog c) => AddonCatalog(
    type: c.kind,
    id: '${p.id}/${c.id}',
    name: '${plainName(p.name)} · ${c.name}',
    genres: c.genres,
    genreRequired: c.genreRequired,
    search: c.search,
    searchOnly: c.searchOnly,
    skip: true,
  );

  // ── pages ──
  // A Vega provider counts pages (how many a page holds: its first page's); a paged script hands
  // the token for the page after each one.
  static final _size = <String, int>{};
  static final _next = <String, String>{};
  static final _paged = <String>{};

  @visibleForTesting
  static void debugReset() {
    _size.clear();
    _next.clear();
    _paged.clear();
  }

  static Future<PluginEntry?> _plugin(String repoUrl, String id) async {
    final info = await PluginRepos.local(repoUrl) ?? await PluginRepos.install(repoUrl);
    return info.plugins.where((p) => p.id == id).firstOrNull;
  }

  /// One page of [c], a catalog of the plugin repository [a] (the first, or after [skip] titles),
  /// as a Stremio addon answers: `{metas: [...]}`, the titles' ids made [a]'s.
  static Future<Map<String, Object?>> page(Addon a, AddonCatalog c, {String? genre, String? search, int skip = 0}) async {
    final at = c.id.indexOf('/');
    if (at <= 0) return const {'metas': []};
    final p = await _plugin(a.manifestUrl, c.id.substring(0, at));
    final pc = p?.catalogs.where((x) => x.id == c.id.substring(at + 1)).firstOrNull;
    if (p == null || pc == null) return const {'metas': []};
    final key = '${a.manifestUrl}|${c.id}|${genre ?? ''}|${search ?? ''}';
    final Object? r;
    if (p.vega) {
      final size = _size[key];
      final page = skip <= 0 ? 1 : 1 + (size == null || size == 0 ? 1 : (skip / size).round());
      r = await PluginRepos.ask(a.manifestUrl, p.id, '__vegaCatalog', {'filter': pc.filter ?? '', 'page': page, 'search': ?search, 'genre': ?genre, 'type': pc.kind});
    } else {
      String? token;
      if (skip > 0 && _paged.contains(key)) {
        token = _next['$key|$skip'];
        if (token == null) return const {'metas': []}; // (the last page was the last)
      }
      r = await PluginRepos.ask(a.manifestUrl, p.id, '__scraperCatalog', {
        'catalogId': pc.id,
        'type': pc.type,
        'skip': skip,
        'pageToken': ?token,
        'search': ?search,
        'genre': ?genre,
      });
    }
    final metas = r is Map && r['metas'] is List ? r['metas'] as List : const [];
    final out = [for (final m in metas.take(200)) if (m is Map && m['id'] != null) _own(a.manifestUrl, p.id, m, pc.kind)];
    if (p.vega && skip <= 0) _size[key] = out.length;
    if (r is Map && r['next'] is String && out.isNotEmpty) {
      _paged.add(key);
      _next['$key|${skip + out.length}'] = r['next'] as String;
    }
    return {'metas': out};
  }

  /// [id]'s details from its plugin, as a Stremio addon answers: `{meta: {...}}`; the meta is
  /// null when the plugin gives none (its page then shows TMDB's, or its catalog's copy).
  static Future<Map<String, Object?>> meta(Addon a, String type, String id) async {
    final own = unwrap(a.manifestUrl, id);
    if (own == null) return const {'meta': null};
    final p = await _plugin(a.manifestUrl, own.plugin);
    if (p == null || !p.details) return const {'meta': null};
    final r = p.vega
        ? await PluginRepos.ask(a.manifestUrl, p.id, '__vegaMeta', {'link': own.own})
        : await PluginRepos.ask(a.manifestUrl, p.id, '__scraperMeta', {'id': own.own, 'type': type == 'series' ? 'tv' : type});
    final m = r is Map ? r['meta'] : null;
    if (m is! Map || m.isEmpty) return const {'meta': null};
    // (its key stays the catalog's)
    return {
      'meta': {..._own(a.manifestUrl, p.id, m, type), 'id': id},
    };
  }

  /// A plugin's title (or details) with its ids, and its episodes', made the repository's; its
  /// kind in VyseTV's words ("tv" is a show).
  static Map<String, Object?> _own(String repoUrl, String plugin, Map raw, String kind) {
    final m = <String, Object?>{for (final e in raw.entries) '${e.key}': e.value};
    final ownId = '${raw['id']}';
    m['id'] = wrap(repoUrl, plugin, ownId);
    final t = '${raw['type'] ?? kind}';
    m['type'] = t == 'tv' || t == 'show' ? 'series' : t;
    if (m['name'] == null && raw['title'] != null) m['name'] = raw['title'];
    // a site's titles often have one picture: its page shows it behind, as the sources screen does
    if (m['background'] is! String && m['poster'] is String) m['background'] = m['poster'];
    if (raw['videos'] is List) {
      m['videos'] = [
        for (final v in raw['videos'] as List)
          if (v is Map) {for (final e in v.entries) '${e.key}': e.value, 'id': wrap(repoUrl, plugin, '${v['id'] ?? '$ownId:${v['season']}:${v['episode']}'}')},
      ];
    }
    return m;
  }
}
