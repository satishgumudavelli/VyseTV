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

  test('composing a Vega plugin: its modules wrapped, episodes optional', () async {
    final asked = <String>[];
    final code = await composeVegaPlugin('https://h.test/r/dist/alpha', '1.5', (u) async {
      asked.add(u);
      if (u.endsWith('episodes.js')) throw HttpError(404, u);
      return '/*${u.split('/').last}*/';
    });
    expect(code, startsWith('${vegaMarker}alpha\n'));
    expect(code, contains('__vega.source("https://h.test/r", "alpha");'));
    expect(code, allOf(contains('__vega.module("posts"'), contains('__vega.module("stream"'), isNot(contains('"episodes"'))));
    expect(asked, hasLength(4));
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
}
