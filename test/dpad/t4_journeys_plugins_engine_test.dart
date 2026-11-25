// Scraper plugins in the real JavaScript engine (QuickJS): a plugin's answer and its log, the
// sandbox (no way to this device's network), the memory limit, and a Vega provider run through
// its adapter. The engine's library comes from a build of the app; without one these say they
// were skipped. On Windows, after `flutter build windows --debug`:
//
//   PATH="$PWD/build/windows/x64/runner/Debug:$PATH" flutter test test/dpad/t4_journeys_plugins_engine_test.dart
//
// On Linux: LIBQUICKJSC_TEST_PATH=build/linux/x64/release/bundle/lib/libquickjs_c_bridge_plugin.so.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/plugins/js_plugins.dart';

bool _engineHere() {
  try {
    if (Platform.isWindows) {
      DynamicLibrary.open('quickjs_c_bridge.dll');
    } else if (Platform.isLinux) {
      DynamicLibrary.open(Platform.environment['LIBQUICKJSC_TEST_PATH'] ?? 'libquickjs_c_bridge_plugin.so');
    } else {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

const _query = {
  'tmdbId': 872585,
  'imdbId': 'tt15398776',
  'type': 'movie',
  'isTv': false,
  'title': 'Oppenheimer',
  'originalTitle': 'Oppenheimer',
  'titles': ['Oppenheimer'],
  'isAnime': false,
  'year': 2023,
  'season': null,
  'episode': null,
};

// A Vega provider that needs no network: it searches a fixed list, reads a page with cheerio,
// builds links with URL and URLSearchParams.
const _posts = r'''
exports.getSearchPosts = async function (a) {
  return a.searchQuery.toLowerCase().indexOf('oppenheimer') === 0
    ? [{ title: 'Download Oppenheimer (2023) 1080p', link: '/oppenheimer-2023/', image: '' }, { title: 'Other (2001)', link: '/other/', image: '' }]
    : [];
};
''';
const _meta = r'''
exports.getMeta = async function (a) {
  const { cheerio } = a.providerContext;
  const $ = cheerio.load('<div class="dl"><a href="/go/1">720p</a><a href="/go/2">1080p</a></div>');
  const links = $('.dl a').map((i, e) => ({ title: $(e).text(), quality: $(e).text(), directLinks: [{ title: 'Movie', link: new URL($(e).attr('href'), 'https://site.test/').href, type: 'movie' }] })).get();
  return { title: 'Oppenheimer', image: '', synopsis: '', type: 'movie', linkList: links, imdbId: 'tt15398776' };
};
''';
const _stream = r'''
exports.getStream = async function (a) {
  const u = new URL(a.link);
  const sp = new URLSearchParams({ id: u.pathname.split('/').pop() });
  return [{ server: 'Alpha', link: 'https://cdn.test/v' + sp.get('id') + '.m3u8?x=' + sp.toString(), type: 'm3u8', quality: '1080' }, { server: 'DRM', link: 'https://cdn.test/d.mpd', type: 'mpd', drm: { type: 'widevine' } }];
};
''';

String _module(String name, String body) => '__vega.module("$name", function (exports, module, require, __awaiter, providerGlobal) {\n$body\n});\n';

void main() {
  final here = _engineHere();
  final skip = here ? false : 'needs the engine library from a build of the app (see the top of this file)';
  final helpers = File('assets/plugins/helpers.js').readAsStringSync();

  test('composing a Vega plugin: its modules wrapped, episodes and catalog optional', () async {
    final asked = <String>[];
    final code = await composeVegaPlugin('https://h.test/r/dist/alpha', '1.5', (u) async {
      asked.add(u);
      if (u.endsWith('episodes.js') || u.endsWith('catalog.js')) throw HttpError(404, u);
      return '/*${u.split('/').last}*/';
    });
    expect(code, startsWith('${vegaMarker}alpha\n'));
    expect(code, contains('__vega.source("https://h.test/r", "alpha");'));
    expect(code, allOf(contains('__vega.module("posts"'), contains('__vega.module("stream"'), isNot(contains('"episodes"')), isNot(contains('"catalog"'))));
    expect(asked, hasLength(5));
    await expectLater(composeVegaPlugin('https://h.test/r/dist/alpha', '1', (u) async => throw HttpError(500, u)), throwsA(isA<HttpError>()));
  });

  test("a plugin's answer, and its console lines for the log", () async {
    final res = await executeScriptForTest(r'''
      async function getStreams(q) {
        console.log('looking for', q.title, q.year);
        return [{ url: 'https://cdn.test/' + q.imdbId + '.m3u8', quality: '1080p', server: 'Test' }];
      }''', _query, helpers);
    expect(res['error'], isNull, reason: '${res['log']}');
    expect(res['log'], ['looking for Oppenheimer 2023']);
    final s = parseStreams(res['streams']);
    expect((s.single.url, s.single.type, s.single.quality), ('https://cdn.test/tt15398776.m3u8', 'hls', '1080p'));
  }, skip: skip);

  test("the sandbox: a plugin can't reach this device (http says why, status 0)", () async {
    final res = await executeScriptForTest(r'''
      async function getStreams(q) {
        var a = await http('http://127.0.0.1:9/'), b = await http('http://router.local/'), c = await http('http://192.168.1.1/');
        return [{ url: 'https://x.test/a', label: [a.status, a.error, b.status, c.status].join('|') }];
      }''', _query, helpers);
    expect(res['error'], isNull, reason: '${res['log']}');
    expect(parseStreams(res['streams']).single.label, "0|Bad state: this device's network is off limits|0|0");
  }, skip: skip);

  test('a plugin that eats memory is stopped at the limit, not the app', () async {
    final res = await executeScriptForTest(r'''
      async function getStreams(q) {
        var a = [];
        for (;;) a.push(new Array(1000000).fill(7));
      }''', _query, helpers);
    expect('${res['error']}', contains('memory'));
  }, skip: !here ? skip : (pluginMemoryLimited ? false : "this build's engine library can't cap memory (flutter_js's Windows one)"));

  // a scraper from a scraper list, run as VyseTV runs it: the Vega runtime, the scraper-list adapter, then it
  Future<Map<String, Object?>> scraper(String code, Map<String, Object?> query) => executeScriptForTest(
    '${File('assets/plugins/vega_runtime.js').readAsStringSync()}\n${File('assets/plugins/scraper_runtime.js').readAsStringSync()}\n${composeScraperPlugin('site', '1', code)}',
    query,
    helpers,
  );

  test("a scraper from a scraper list: CommonJS, cheerio and crypto-js by require, and its answer turned into VyseTV's", () async {
    final res = await scraper(r'''
      var cheerio = require('cheerio-without-node-native');
      var CryptoJS = require('crypto-js');
      async function getStreams(tmdbId, mediaType, season, episode) {
        var $ = cheerio.load('<a class="v" href="https://cdn.test/v/1080.m3u8">1080p</a>');
        console.log('asked', tmdbId, mediaType, season, episode);
        return [{ name: 'Site', title: 'Film (2023)', size: '1.2 GB', quality: '1080p',
          url: $('a.v').attr('href') + '?s=' + CryptoJS.MD5('x').toString(), headers: { Referer: 'https://site.test/' } }];
      }
      module.exports = { getStreams };''', _query);
    expect(res['error'], isNull, reason: '${res['log']}');
    expect(res['log'], ['asked 872585 movie undefined undefined']);
    final s = parseStreams(res['streams']).single;
    expect((s.url, s.type, s.quality, s.server, s.label), ('https://cdn.test/v/1080.m3u8?s=9dd4e461268c8034f5c8564e155c67a6', 'hls', '1080p', 'Site', 'Film (2023) · 1.2 GB'));
    expect(s.headers, {'Referer': 'https://site.test/'});
  }, skip: skip);

  test('timers: setTimeout gives an id that clearTimeout stops; setInterval and clearInterval', () async {
    final res = await executeScriptForTest(r'''
      async function getStreams(q) {
        var fired = [];
        var a = setTimeout(function () { fired.push('a'); }, 10);
        var b = setTimeout(function (x) { fired.push(x); }, 20, 'b');
        clearTimeout(a);
        var ticks = 0, i = setInterval(function () { if (++ticks === 3) clearInterval(i); }, 5);
        await new Promise(function (ok) { setTimeout(ok, 120); });
        return [{ url: 'https://x.test/', label: fired.join(',') + '|' + ticks + '|' + (typeof a) }];
      }''', _query, helpers);
    expect(res['error'], isNull, reason: '${res['log']}');
    expect(parseStreams(res['streams']).single.label, 'b|3|number');
  }, skip: skip);

  test('a scraper that sets a global getStreams, asked for an episode; one with no TMDB id to go by is not asked', () async {
    const code = r'''
      globalThis.getStreams = async function (id, type, s, e) { return [{ name: 'G', url: 'https://cdn.test/' + id + '/' + type + '/' + s + '/' + e + '.mp4' }]; };''';
    final res = await scraper(code, {..._query, 'tmdbId': 1399, 'type': 'tv', 'isTv': true, 'season': 2, 'episode': 3});
    expect(res['error'], isNull, reason: '${res['log']}');
    expect(parseStreams(res['streams']).single.url, 'https://cdn.test/1399/tv/2/3.mp4');
    final none = await scraper(code, {..._query, 'tmdbId': null});
    expect(parseStreams(none['streams']), isEmpty);
  }, skip: skip);

  test('a Vega provider answers getStreams through its adapter', () async {
    final runtime = File('assets/plugins/vega_runtime.js').readAsStringSync();
    final code = '$runtime\n${vegaMarker}alpha\n__vega.source("https://repo.test", "alpha");\n${_module('posts', _posts)}${_module('meta', _meta)}${_module('stream', _stream)}';
    final res = await executeScriptForTest(code, _query, helpers);
    expect(res['error'], isNull, reason: '${res['log']}');
    final streams = parseStreams(res['streams']);
    // 1080p first, then 720p; the DRM stream is left out; the query string built by URLSearchParams
    expect([for (final s in streams) s.url.split('?').first], ['https://cdn.test/v2.m3u8', 'https://cdn.test/v1.m3u8'], reason: '${res['log']}');
    expect(streams.every((s) => s.type == 'hls'), isTrue);
  }, skip: skip);

  // ── browsing a plugin, the way a Stremio metadata addon is browsed ──

  test("a Vega provider browsed: its lists read without the runtime; a page; a show's page with its episodes; an episode's streams by its own id", () async {
    const catalog = r'''
exports.catalog = [{ title: 'New', filter: '' }, { title: 'Netflix', filter: 'web-series/netflix' }];
exports.genres = [{ title: 'Action', filter: 'category/action' }];
''';
    const posts = r'''
exports.getPosts = async function (a) {
  return a.filter === 'category/action'
    ? [{ title: 'Download Heat (1995) 1080p', link: '/heat/', image: 'https://i.test/h.jpg' }]
    : [{ title: 'Download Dark (Season 1) Hindi 720p [1GB]', link: '/dark-s1/', image: 'https://i.test/d.jpg' }, { title: 'Download Heat (1995) 1080p', link: '/heat/', image: '' }];
};
exports.getSearchPosts = async function (a) { return [{ title: 'Download Dark (Season 1)', link: '/dark-s1/', image: '' }]; };
''';
    const meta = r'''
exports.getMeta = async function (a) {
  return { title: 'Dark (Season 1)', synopsis: 'A town.', image: 'https://i.test/d.jpg', imdbId: 'tt5753856', type: 'series', tags: ['Drama'],
    linkList: [{ title: 'Season 1 720p', quality: '720', episodesLink: 'https://site.test/dark-s1/720' }, { title: 'Season 1 1080p', quality: '1080', episodesLink: 'https://site.test/dark-s1/1080' }] };
};
''';
    const episodes = r'''
exports.getEpisodes = async function (a) {
  var q = a.url.split('/').pop();
  return [{ title: 'Episode 1', link: 'https://site.test/e1-' + q }, { title: 'Episode 2', link: 'https://site.test/e2-' + q }];
};
''';
    const stream = r'''
exports.getStream = async function (a) { return [{ server: 'S', link: 'https://cdn.test/' + a.link.split('/').pop() + '.mp4', type: 'mp4' }]; };
''';
    final code = '${vegaMarker}alpha\n__vega.source("https://repo.test", "alpha");\n'
        '${_module('catalog', catalog)}${_module('posts', posts)}${_module('meta', meta)}${_module('episodes', episodes)}${_module('stream', stream)}';
    final runtime = File('assets/plugins/vega_runtime.js').readAsStringSync();

    final d = await executeScriptForTest('$vegaDescribeStub\n$code', const {}, '', entry: '__vyseDescribe');
    expect(d['error'], isNull, reason: '${d['log']}');
    expect(d['value'], {
      'catalogs': [
        {'title': 'New', 'filter': ''},
        {'title': 'Netflix', 'filter': 'web-series/netflix'},
      ],
      'genres': [
        {'title': 'Action', 'filter': 'category/action'},
      ],
      'search': true,
      'meta': true,
    }, reason: 'read from its catalog module, nothing else run');

    final page = await executeScriptForTest('$runtime\n$code', {'filter': '', 'page': 1, 'type': 'movie'}, helpers, entry: '__vegaCatalog');
    expect(page['error'], isNull, reason: '${page['log']}');
    final metas = ((page['value'] as Map)['metas'] as List).cast<Map>();
    expect([for (final m in metas) '${m['id']} ${m['type']} ${m['name']} ${m['releaseInfo']}'], ['/dark-s1/ series Dark null', '/heat/ movie Heat 1995'],
        reason: 'its names without "Download" and the formats; a show told by its title');
    final genre = await executeScriptForTest('$runtime\n$code', {'filter': '', 'page': 1, 'genre': 'Action'}, helpers, entry: '__vegaCatalog');
    expect(((genre['value'] as Map)['metas'] as List).single['id'], '/heat/', reason: "a genre: that genre's filter asked");

    final details = await executeScriptForTest('$runtime\n$code', {'link': '/dark-s1/'}, helpers, entry: '__vegaMeta');
    expect(details['error'], isNull, reason: '${details['log']}');
    final m = (details['value'] as Map)['meta'] as Map;
    expect((m['type'], m['name'], m['imdb_id'], m['description']), ('series', 'Dark', 'tt5753856', 'A town.'));
    expect([for (final v in (m['videos'] as List).cast<Map>()) '${v['id']} ${v['season']}x${v['episode']}'], ['/dark-s1/|1|1 1x1', '/dark-s1/|1|2 1x2'],
        reason: 'its season once (the best quality), its episodes numbered');

    final res = await executeScriptForTest('$runtime\n$code', {'ownId': '/dark-s1/|1|2', 'isTv': true, 'season': 1, 'episode': 2}, helpers);
    expect(res['error'], isNull, reason: '${res['log']}');
    expect([for (final s in parseStreams(res['streams'])) s.url], containsAll(['https://cdn.test/e2-1080.mp4', 'https://cdn.test/e2-720.mp4']),
        reason: 'the episode from its page, no search');
  }, skip: skip);

  test('a scraper that lists titles: getCatalog asked both ways scripts write it, getMeta, and getStreams by its own ids', () async {
    const code = r'''
module.exports = {
  getCatalog: async function (a) {
    if (a.catalogId === 'paged') return { items: [{ id: 'x:' + (a.pageToken || 1), name: 'Page ' + (a.pageToken || 1), type: 'movie' }], nextPageToken: a.pageToken ? null : '2' };
    return { metas: [{ id: 'x:' + ((a.extra && a.extra.search) || 'all'), name: 'Found', type: 'tv' }, { name: 'no id' }] };
  },
  getMeta: async function (a) { return { meta: { id: a.id, type: 'tv', name: 'Show', videos: [{ id: a.id + ':1:1', season: 1, episode: 1 }] } }; },
  getStreams: async function (id, type, s, e) { return [{ name: 'Own', url: 'https://cdn.test/' + encodeURIComponent(id) + '/' + type + '/' + s + '/' + e }]; }
};''';
    Future<Map<String, Object?>> call(String entry, Map<String, Object?> args) => executeScriptForTest(
      '${File('assets/plugins/vega_runtime.js').readAsStringSync()}\n${File('assets/plugins/scraper_runtime.js').readAsStringSync()}\n${composeScraperPlugin('x', '1', code)}',
      args,
      helpers,
      entry: entry,
    );
    final first = await call('__scraperCatalog', {'catalogId': 'paged', 'type': 'movie', 'skip': 0});
    expect(first['error'], isNull, reason: '${first['log']}');
    expect(first['value'], {
      'metas': [
        {'id': 'x:1', 'name': 'Page 1', 'type': 'movie'},
      ],
      'next': '2',
    }, reason: 'the paged way: its token for the next page');
    final second = await call('__scraperCatalog', {'catalogId': 'paged', 'type': 'movie', 'skip': 1, 'pageToken': '2'});
    expect(second['value'], {
      'metas': [
        {'id': 'x:2', 'name': 'Page 2', 'type': 'movie'},
      ],
    });
    final found = await call('__scraperCatalog', {'catalogId': 'list', 'type': 'tv', 'search': 'abc'});
    expect(found['value'], {
      'metas': [
        {'id': 'x:abc', 'name': 'Found', 'type': 'tv'},
      ],
    }, reason: "Stremio's way, the search in extra; one with no id left out");
    final meta = await call('__scraperMeta', {'id': 'x:abc', 'type': 'tv'});
    expect(((meta['value'] as Map)['meta'] as Map)['videos'], [
      {'id': 'x:abc:1:1', 'season': 1, 'episode': 1},
    ]);
    final res = await scraper(code, {'ownId': 'x:abc:1:1', 'type': 'tv', 'isTv': true, 'season': 1, 'episode': 1});
    expect(parseStreams(res['streams']).single.url, 'https://cdn.test/x%3Aabc%3A1%3A1/tv/1/1', reason: 'asked by its own id, not a TMDB one');
  }, skip: skip);

  test("a comic provider: a series' chapters (its direct links and its chapters list, each once), a chapter's pages with their headers; its pictures are never a video's streams", () async {
    const meta = r'''
exports.getMeta = async function (a) {
  return { title: 'Paper Moon', image: 'https://img.test/c.jpg', synopsis: 'A comic.', tags: ['Drama'], cast: ['Ink Artist'], type: 'comic',
    linkList: [{ title: 'Chapters', directLinks: [{ title: 'Chapter 1', link: '/c/1', chapterNumber: 1 }] }, { title: 'More', episodesLink: '/c/list' }] };
};
''';
    const episodes = r'''
exports.getEpisodes = async function (a) { return [{ title: 'Chapter 2', link: '/c/2', chapterNumber: '2' }, { title: 'Chapter 1, again', link: '/c/1', chapterNumber: 1 }]; };
''';
    const stream = r'''
exports.getStream = async function (a) {
  return [{ index: 1, server: 'Page 2', link: 'https://img.test' + a.link + '/2.jpg', type: 'image', headers: { Referer: 'https://site.test/' } },
          { index: 0, server: 'Page 1', link: 'https://img.test' + a.link + '/1.jpg', type: 'image', headers: { Referer: 'https://site.test/' } }];
};
exports.getPages = exports.getStream;
''';
    const posts = r'''
exports.getSearchPosts = async function () { return []; };
''';
    final code = '${vegaMarker}ink\n__vega.source("https://repo.test", "ink");\n'
        '${_module('posts', posts)}${_module('meta', meta)}${_module('episodes', episodes)}${_module('stream', stream)}';
    final runtime = File('assets/plugins/vega_runtime.js').readAsStringSync();

    final series = await executeScriptForTest('$runtime\n$code', {'link': '/series/1/'}, helpers, entry: '__vegaComic');
    expect(series['error'], isNull, reason: '${series['log']}');
    final v = series['value'] as Map;
    expect(((v['meta'] as Map)['title'], (v['meta'] as Map)['author'], (v['meta'] as Map)['synopsis']), ('Paper Moon', 'Ink Artist', 'A comic.'));
    expect([for (final c in (v['chapters'] as List).cast<Map>()) '${c['link']} ${c['number']}'], ['/c/1 1', '/c/2 2'], reason: 'each chapter once, its number read');

    final pages = await executeScriptForTest('$runtime\n$code', {'link': '/c/1'}, helpers, entry: '__vegaPages');
    expect(pages['error'], isNull, reason: '${pages['log']}');
    expect((pages['value'] as Map)['pages'], [
      {'url': 'https://img.test/c/1/1.jpg', 'headers': {'Referer': 'https://site.test/'}},
      {'url': 'https://img.test/c/1/2.jpg', 'headers': {'Referer': 'https://site.test/'}},
    ], reason: 'in page order, with their headers');

    final asVideo = await executeScriptForTest('$runtime\n$code', {'ownId': '/series/1/', 'isTv': false}, helpers);
    expect(asVideo['error'], isNull, reason: '${asVideo['log']}');
    expect(parseStreams(asVideo['streams']), isEmpty, reason: "a comic's pages are pictures, not a video");
  }, skip: skip);
}
