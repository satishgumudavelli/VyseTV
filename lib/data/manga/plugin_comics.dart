// Comics from your plugin repositories (a Vega provider of type "comic", a scraper that says
// "manga"): their catalogs on the Manga page, their series' chapters and pages in the Manga
// reader, the way the built-in source's are. They are never on Home, nor asked for a video.
//
// A series goes by `pl:<repository key>:<plugin id>:<its page's link>` (the same ids as other
// plugin titles: plugins/plugin_catalogs.dart), a chapter by the same with `ch:` before its link.

import 'package:flutter/foundation.dart';

import '../../models/manga/manga.dart';
import '../../models/manga/manga_chapter.dart';
import '../sources/addons.dart';
import '../sources/plugins/js_plugins.dart';
import '../sources/plugins/plugin_catalogs.dart';
import 'manga_library.dart' show MangaArt, mangaService;

/// One comic plugin you read from, with its repository's addon.
@immutable
class ComicSource {
  const ComicSource(this.addon, this.plugin);
  final Addon addon;
  final PluginEntry plugin;

  String get name => PluginCatalogs.plainName(plugin.name);
  String get key => '${addon.manifestUrl}#${plugin.id}';

  /// Its lists to browse (not its search, nor one that needs a genre picked first).
  List<PluginCatalog> get shelves => [for (final c in plugin.catalogs) if (!c.searchOnly && !c.genreRequired) c];

  /// The list a search goes to, when it takes one.
  PluginCatalog? get search => plugin.catalogs.where((c) => c.search).firstOrNull;

  @override
  bool operator ==(Object other) => other is ComicSource && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

abstract final class PluginComics {
  /// One of a plugin's series or chapters (else the built-in source's).
  static bool isPlugin(String id) => id.startsWith('pl:');

  /// The comic plugins of your repositories that are on, in your addons' order: each comic plugin
  /// with lists to browse, but those you turned off (Settings > Addons > Catalogs to browse).
  static Future<List<ComicSource>> sources() async {
    final out = <ComicSource>[];
    for (final a in Addons.list.value) {
      if (!a.enabled || !a.plugins) continue;
      try {
        final info = await PluginRepos.local(a.manifestUrl) ?? await PluginRepos.install(a.manifestUrl);
        for (final p in info.plugins) {
          if (p.comic && p.catalogs.isNotEmpty && !a.comicsOff.contains(p.id)) out.add(ComicSource(a, p));
        }
      } catch (_) {} // (a repository that can't be read now is left out)
    }
    return out;
  }

  /// A page of [c], one of [s]'s lists (or a search in it), as series.
  static Future<List<Manga>> page(ComicSource s, PluginCatalog c, {int page = 1, String? search}) async {
    final url = s.addon.manifestUrl;
    final Object? r;
    if (s.plugin.vega) {
      r = await PluginRepos.ask(url, s.plugin.id, '__vegaCatalog', {'filter': c.filter ?? '', 'page': page, 'search': ?search, 'comic': true});
    } else {
      if (page > 1) return const []; // (a scraper's list comes in one page here)
      r = await PluginRepos.ask(url, s.plugin.id, '__scraperCatalog', {'catalogId': c.id, 'type': c.type, 'skip': 0, 'search': ?search});
    }
    final metas = r is Map && r['metas'] is List ? r['metas'] as List : const [];
    return [
      for (final m in metas.take(200))
        if (m is Map && m['id'] != null && '${m['name'] ?? m['title'] ?? ''}'.trim().isNotEmpty) _series(s, m),
    ];
  }

  static Manga _series(ComicSource s, Map m) {
    final own = '${m['id']}';
    final cover = m['poster'] is String && (m['poster'] as String).startsWith('http') ? m['poster'] as String : null;
    return Manga(
      id: PluginCatalogs.wrap(s.addon.manifestUrl, s.plugin.id, own),
      title: '${m['name'] ?? m['title']}'.trim(),
      url: own,
      coverNormal: cover,
      coverSmall: cover,
      type: s.name,
    );
  }

  /// The repository, plugin and own id of one of its series or chapters.
  static ({Addon addon, String pluginId, String own})? _resolve(String id) {
    for (final a in Addons.list.value) {
      if (!a.plugins) continue;
      final u = PluginCatalogs.unwrap(a.manifestUrl, id);
      if (u != null) return (addon: a, pluginId: u.plugin, own: u.own);
    }
    return null;
  }

  static final _seriesCache = <String, Future<({Manga manga, List<MangaChapter> chapters})>>{};

  /// [m]'s details from its plugin (its synopsis, tags, author, cover) and its chapters. Kept for
  /// the run; one that failed is asked again next time.
  static Future<({Manga manga, List<MangaChapter> chapters})> series(Manga m) {
    final f = _seriesCache[m.id] ??= _load(m);
    f.then((_) {}, onError: (Object _) {
      if (_seriesCache[m.id] == f) _seriesCache.remove(m.id);
    });
    return f;
  }

  static Future<({Manga manga, List<MangaChapter> chapters})> _load(Manga m) async {
    final at = _resolve(m.id);
    if (at == null) throw StateError("the repository with this series isn't one of your addons now");
    final info = await PluginRepos.local(at.addon.manifestUrl) ?? await PluginRepos.install(at.addon.manifestUrl);
    final p = info.plugins.where((x) => x.id == at.pluginId).firstOrNull;
    if (p == null) throw StateError('its repository no longer has that plugin');
    final url = at.addon.manifestUrl;
    String chapterId(String link) => PluginCatalogs.wrap(url, p.id, 'ch:$link');
    if (p.vega) {
      final r = await PluginRepos.ask(url, p.id, '__vegaComic', {'link': at.own});
      final meta = r is Map && r['meta'] is Map ? r['meta'] as Map : const {};
      final list = r is Map && r['chapters'] is List ? r['chapters'] as List : const [];
      final cover = meta['image'] is String && (meta['image'] as String).startsWith('http') ? meta['image'] as String : null;
      final tags = [for (final t in meta['tags'] is List ? meta['tags'] as List : const []) '$t'];
      return (
        manga: Manga(
          id: m.id,
          title: '${meta['title'] ?? ''}'.trim().isEmpty ? m.title : '${meta['title']}'.trim(),
          url: m.url,
          coverNormal: cover ?? m.cover,
          coverSmall: cover ?? m.cover,
          author: meta['author'] is String ? meta['author'] as String : m.author,
          tags: tags.isEmpty ? m.tags : tags.take(24).toList(),
          type: m.type,
          year: m.year,
          status: meta['status'] is String ? _title(meta['status'] as String) : m.status,
          synopsis: meta['synopsis'] is String ? meta['synopsis'] as String : m.synopsis,
        ),
        chapters: [
          for (final (i, c) in list.whereType<Map>().indexed)
            if (c['link'] is String)
              MangaChapter(
                id: chapterId(c['link'] as String),
                rawName: '${c['title'] ?? ''}'.trim().isEmpty ? 'Chapter ${i + 1}' : '${c['title']}'.trim(),
                url: c['link'] as String,
                number: (c['number'] as num?)?.toDouble(),
                name: '${c['title'] ?? ''}'.trim().isEmpty ? null : '${c['title']}'.trim(),
              ),
        ],
      );
    }
    // a scraper's: its details' videos are the chapters
    final r = await PluginRepos.ask(url, p.id, '__scraperMeta', {'id': at.own, 'type': 'manga'});
    final meta = r is Map && r['meta'] is Map ? r['meta'] as Map : const {};
    final videos = meta['videos'] is List ? meta['videos'] as List : const [];
    return (
      manga: Manga(
        id: m.id,
        title: m.title,
        url: m.url,
        coverNormal: m.cover,
        coverSmall: m.cover,
        type: m.type,
        synopsis: meta['description'] is String ? meta['description'] as String : m.synopsis,
      ),
      chapters: [
        for (final (i, v) in videos.whereType<Map>().indexed)
          if (v['id'] != null)
            MangaChapter(
              id: chapterId('${v['id']}'),
              rawName: '${v['title'] ?? v['name'] ?? 'Chapter ${i + 1}'}',
              url: '${v['id']}',
              number: (v['episode'] as num?)?.toDouble() ?? (v['number'] as num?)?.toDouble(),
            ),
      ],
    );
  }

  static String _title(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';

  /// The headers a page's picture wants (its site's Referer, say), by its link.
  static final _headers = <String, Map<String, String>>{};
  static Map<String, String>? headersFor(String url) => _headers[url];

  /// Chapter [c]'s pages, in order: their pictures' links (their headers kept for [headersFor]).
  static Future<List<String>> pages(MangaChapter c) async {
    final at = _resolve(c.id);
    if (at == null || !at.own.startsWith('ch:')) throw StateError("the repository with this series isn't one of your addons now");
    final link = at.own.substring(3);
    final info = await PluginRepos.local(at.addon.manifestUrl) ?? await PluginRepos.install(at.addon.manifestUrl);
    final p = info.plugins.where((x) => x.id == at.pluginId).firstOrNull;
    if (p == null) throw StateError('its repository no longer has that plugin');
    final List list;
    if (p.vega) {
      final r = await PluginRepos.ask(at.addon.manifestUrl, p.id, '__vegaPages', {'link': link});
      list = r is Map && r['pages'] is List ? r['pages'] as List : const [];
    } else {
      // a scraper's chapter: its "streams" are the pages
      final hits = await PluginRepos.findFor(at.addon.manifestUrl, {'ownId': link, 'type': 'manga'}, only: p.id);
      list = [for (final h in hits) {'url': h.stream.url, 'headers': h.stream.headers}];
    }
    final out = <String>[];
    for (final x in list) {
      if (x is! Map || x['url'] is! String) continue;
      final url = x['url'] as String;
      final h = x['headers'];
      if (h is Map && h.isNotEmpty) _headers[url] = {for (final e in h.entries) '${e.key}': '${e.value}'};
      out.add(url);
    }
    return out;
  }

  @visibleForTesting
  static void debugReset() {
    _seriesCache.clear();
    _headers.clear();
  }
}

/// [m]'s chapters: from its plugin, or the built-in source.
Future<List<MangaChapter>> chaptersOf(Manga m) =>
    PluginComics.isPlugin(m.id) ? PluginComics.series(m).then((x) => x.chapters) : mangaService.getChapters(m.id);

/// Chapter [c]'s pages: from its plugin, or the built-in source.
Future<List<String>> pagesOf(MangaChapter c) => PluginComics.isPlugin(c.id) ? PluginComics.pages(c) : mangaService.getChapterImages(c.id);
