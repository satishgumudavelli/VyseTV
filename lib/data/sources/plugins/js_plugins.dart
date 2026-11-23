// Scraper plugins: JavaScript files from a repository you add as an addon (Settings > Addons),
// each run in a sandboxed JavaScript engine to find the streams for a film or an episode. The
// app ships none. A repository answers as one addon, next to your Stremio addons
// (addons.dart); VyseTV's own sources are not touched.
//
// A repository is a `repo.json` (README.md here), a Vega provider manifest (a JSON list), or a
// scraper list (a manifest.json with a "scrapers" list of CommonJS scrapers). Its
// scripts are kept in files on each device: the addon itself, synced with your account, holds
// only the link, so another device downloads them the first time it needs them.
//
// What a script can do is only what the bridge below gives it: `http()` to fetch web pages
// (never this device's own network) and plain computation. No files, no other apps.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../net.dart';
import '../film_sources/common.dart';

const _maxPlugins = 100;
const _maxScript = 512 * 1024;
const _maxBody = 8 * 1024 * 1024;
const _runTimeout = Duration(seconds: 25);

/// What one script may hold in memory: one that runs away is stopped, not the app.
const _memoryLimit = 96 * 1024 * 1024;

/// Plugins of a repository asked at once: each is an engine of its own, so as many as the device
/// has cores, 3 to 8 (a TV has few cores and little memory).
final int _atOnce = math.max(3, math.min(8, Platform.numberOfProcessors));

/// Scripts downloaded at once when a repository is added or updated.
const _downloadsAtOnce = 8;

// ── repositories ──

/// A plugin as its repository lists it.
@immutable
class PluginEntry {
  const PluginEntry({
    required this.id,
    required this.name,
    required this.url,
    this.version = '',
    this.note = '',
    this.types = const ['movie', 'tv'],
    this.vega = false,
    this.scraper = false,
  });

  /// Its own id in the repository (also its script's file name).
  final String id;
  final String name;

  /// Where its script comes from (a Vega provider: its folder of built modules).
  final String url;
  final String version, note;

  /// 'movie' and/or 'tv'.
  final List<String> types;

  /// A Vega provider, run on the Vega runtime (assets/plugins/vega_runtime.js).
  final bool vega;

  /// A scraper from a scraper list, run on the scraper-list adapter (assets/plugins/scraper_runtime.js).
  final bool scraper;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'url': url, 'version': version, 'note': note, 'types': types, if (vega) 'vega': true, if (scraper) 'scraper': true};

  static PluginEntry? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['name'] is! String || j['url'] is! String) return null;
    return PluginEntry(
      id: j['id'] as String,
      name: j['name'] as String,
      url: j['url'] as String,
      version: '${j['version'] ?? ''}',
      note: '${j['note'] ?? ''}',
      types: _types(j['types']),
      vega: j['vega'] == true,
      scraper: j['scraper'] == true,
    );
  }
}

List<String> _types(Object? v) {
  final t = <String>{
    if (v is List)
      for (final x in v)
        if (x == 'movie') 'movie' else if (x == 'tv' || x == 'series') 'tv',
  }.toList();
  return t.isEmpty ? const ['movie', 'tv'] : t;
}

/// A repository as this device has it.
@immutable
class PluginRepoInfo {
  const PluginRepoInfo({required this.url, required this.name, required this.plugins});

  /// The `repo.json` (or Vega `manifest.json`) link.
  final String url;
  final String name;
  final List<PluginEntry> plugins;
}

/// The repository file is not there any more (HTTP 404 or 410): it was deleted or moved.
class RepoGone extends FormatException {
  RepoGone(String url) : super('That link is gone (404): the repository file was deleted or moved.', url);
}

/// A GitHub page link to the file becomes the link to its raw text; a bare repository link
/// means its `repo.json` on the default branch. Anything else is used as given.
String normalizeRepoUrl(String input) {
  final u = input.trim();
  final blob = RegExp(r'^https?://github\.com/([^/]+)/([^/]+)/blob/(.+)$').firstMatch(u);
  if (blob != null) return 'https://raw.githubusercontent.com/${blob[1]}/${blob[2]}/${blob[3]}';
  final bare = RegExp(r'^https?://github\.com/([^/]+)/([^/#?]+?)(?:\.git)?/?$').firstMatch(u);
  if (bare != null) return 'https://raw.githubusercontent.com/${bare[1]}/${bare[2]}/HEAD/repo.json';
  return u;
}

/// Whether [j] (a JSON file just read) is a plugin repository: a `repo.json` with a "plugins"
/// list, a scraper list (a "scrapers" list), or a Vega manifest (a list of providers).
bool isPluginRepo(Object? j) =>
    (j is Map && (j['plugins'] is List || j['scrapers'] is List)) || (j is List && j.isNotEmpty && j.every((p) => p is Map && p['value'] is String));

// ── scraper lists ──
// A manifest.json with a "scrapers" list: each scraper a CommonJS script (its `filename`, next to
// the manifest) whose getStreams(tmdbId, mediaType, season, episode) answers [{name, title, url,
// quality, size, headers}]. VyseTV runs it inside the scraper-list adapter
// (assets/plugins/scraper_runtime.js, after the Vega runtime: fetch, axios, cheerio, crypto-js).

/// The text that starts a scraper-list plugin's script.
const scraperMarker = '// @scraper ';

({String name, List<PluginEntry> plugins}) _parseScraperList(Map<Object?, Object?> j, String manifestUrl) {
  final base = Uri.parse(manifestUrl);
  final out = <PluginEntry>[];
  final seen = <String>{};
  for (final p in j['scrapers'] as List) {
    // (one its maker turned off is left out, as in the apps it was made for)
    if (p is! Map || p['filename'] is! String || p['enabled'] == false) continue;
    final url = base.resolve(p['filename'] as String);
    if (url.scheme != 'https' && url.scheme != 'http') continue;
    final id = '${p['id'] ?? ''}'.trim();
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(id) || !seen.add(id)) continue;
    final langs = [for (final l in p['contentLanguage'] is List ? p['contentLanguage'] as List : const []) '$l'.toUpperCase()];
    out.add(PluginEntry(
      id: id,
      name: '${p['name'] ?? id}',
      url: '$url',
      version: '${p['version'] ?? ''}',
      note: langs.join(' · '),
      types: _types(p['supportedTypes'] ?? p['types']),
      scraper: true,
    ));
    if (out.length >= _maxPlugins) break;
  }
  return (name: '${j['name'] ?? ''}'.trim(), plugins: out);
}

/// A scraper's [code] as a plugin script: run in a function of its own by the scraper-list adapter,
/// which answers VyseTV's getStreams(query) with it.
String composeScraperPlugin(String id, String version, String code) =>
    '$scraperMarker$id\n// @scraper-version $version\n'
    '__scrapers.load(${jsonEncode(id)}, function (module, exports, require) {\n$code\n});\n'
    'var getStreams = __scrapers.getStreams;\n';

// ── Vega providers ──
// A Vega repository's manifest.json is a list of providers, each built into
// dist/<value>/{posts,meta,stream,episodes}.js next to it. VyseTV puts those modules together
// into one script that assets/plugins/vega_runtime.js (axios, cheerio, an adapter) runs: it
// searches the provider's site for the title, opens the page and resolves the stream.

/// Providers that are not about films and shows, or hand out torrents or live channels: left out.
const _vegaSkip = {'torrentio', 'youtube', 'durbinLive', 'liveTgTv'};

/// The text that starts a Vega plugin's script.
const vegaMarker = '// @vega-provider ';

({String name, List<PluginEntry> plugins}) _parseVegaManifest(List<Object?> list, String manifestUrl) {
  // the repository's folder: the manifest's link without its query and its file name
  final clean = manifestUrl.split(RegExp(r'[?#]')).first;
  final base = clean.substring(0, clean.lastIndexOf('/'));
  final out = <PluginEntry>[];
  final seen = <String>{};
  for (final p in list) {
    if (p is! Map || p['value'] is! String) continue;
    final value = (p['value'] as String).trim();
    if (p['disabled'] == true || _vegaSkip.contains(value) || !RegExp(r'^[A-Za-z0-9_.-]{1,60}$').hasMatch(value)) continue;
    final id = 'vega-$value';
    if (!seen.add(id)) continue;
    final kind = '${p['type'] ?? ''}';
    out.add(PluginEntry(id: id, name: '${p['display_name'] ?? value}', url: '$base/dist/$value', version: '${p['version'] ?? ''}', note: kind, vega: true));
    if (out.length >= _maxPlugins) break;
  }
  return (name: 'Vega providers', plugins: out);
}

/// The script of the Vega provider whose built modules are at [distUrl] (`…/dist/<value>`):
/// posts, meta and stream are needed, episodes is optional. [fetch] downloads one file.
Future<String> composeVegaPlugin(String distUrl, String version, Future<String> Function(String url) fetch) async {
  final value = distUrl.substring(distUrl.lastIndexOf('/') + 1);
  final base = distUrl.substring(0, distUrl.length - '/dist/$value'.length);
  final b = StringBuffer('$vegaMarker$value\n// @vega-version $version\n__vega.source(${jsonEncode(base)}, ${jsonEncode(value)});\n');
  const modules = ['posts', 'meta', 'stream', 'episodes'];
  // (all four at once; episodes may be missing)
  final codes = await Future.wait([
    for (final m in modules)
      fetch('$distUrl/$m.js').then<String?>((c) => c, onError: (Object e) {
        if (m == 'episodes' && e is HttpError && e.status == 404) return null;
        throw e;
      }),
  ]);
  for (final (i, m) in modules.indexed) {
    if (codes[i] case final code?) b.write('__vega.module(${jsonEncode(m)}, function (exports, module, require, __awaiter, providerGlobal) {\n$code\n});\n');
  }
  return b.toString();
}

/// A repository file: `{"name": "…", "plugins": [{"id","name","url","version","note","types"}]}`
/// (each `url` may be relative to the file), or a Vega manifest.
({String name, List<PluginEntry> plugins}) parseRepoFile(String text, String repoUrl) {
  final Object? j;
  try {
    j = jsonDecode(text);
  } catch (_) {
    throw const FormatException('That link is not a JSON file.');
  }
  if (j is List) return _parseVegaManifest(j, repoUrl);
  if (j is Map && j['plugins'] is! List && j['scrapers'] is List) return _parseScraperList(j, repoUrl);
  if (j is! Map || j['plugins'] is! List) throw const FormatException('Not a plugin repository: it has no "plugins" list.');
  final base = Uri.parse(repoUrl);
  final out = <PluginEntry>[];
  final seen = <String>{};
  for (final p in j['plugins'] as List) {
    if (p is! Map || p['url'] is! String) continue;
    final url = base.resolve(p['url'] as String);
    if (url.scheme != 'https' && url.scheme != 'http') continue;
    final id = '${p['id'] ?? ''}'.trim().isEmpty ? url.pathSegments.last.replaceAll(RegExp(r'\.js$'), '') : '${p['id']}'.trim();
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(id) || !seen.add(id)) continue;
    out.add(PluginEntry(id: id, name: '${p['name'] ?? id}', url: '$url', version: '${p['version'] ?? ''}', note: '${p['note'] ?? ''}', types: _types(p['types'])));
    if (out.length >= _maxPlugins) break;
  }
  return (name: '${j['name'] ?? ''}'.trim(), plugins: out);
}

/// What the plugins said on their runs (their console.log lines, errors, timeouts), newest last:
/// a TV's Android log can't be read, so Settings > Addons shows it.
abstract final class PluginLog {
  static final lines = ValueNotifier<List<String>>(const []);
  static const _max = 300;

  static void add(String source, List<String> entries) {
    if (entries.isEmpty) return;
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final tag = source.isEmpty ? '' : '[$source] ';
    final next = [...lines.value, for (final e in entries) '$stamp $tag$e'];
    lines.value = next.length > _max ? next.sublist(next.length - _max) : next;
    if (kDebugMode) {
      for (final e in entries) {
        debugPrint('[plugin${source.isEmpty ? '' : ' $source'}] $e');
      }
    }
  }

  static void clear() => lines.value = const [];
}

/// The plugins of one repository looking for one title: what they found so far, and all of it.
class _Run {
  final at = DateTime.now();
  final hits = ValueNotifier<List<PluginHit>>(const []);
  late final Future<List<PluginHit>> done;
}

/// A stream a plugin found.
@immutable
class PluginHit {
  const PluginHit(this.plugin, this.stream);
  final PluginEntry plugin;
  final FoundStream stream;
}

/// The repositories on this device: their lists and scripts, in files of their own.
abstract final class PluginRepos {
  /// Where a test keeps them (the app: its support folder).
  @visibleForTesting
  static Directory? debugDir;

  /// Forgets what was read (a test's next repository starts afresh).
  @visibleForTesting
  static void debugReset() {
    _info.clear();
    _scripts.clear();
    _found.clear();
    _failures.clear();
    PluginLog.clear();
  }

  static final _info = <String, PluginRepoInfo?>{};
  static final _scripts = <String, String>{};
  static final _busy = <String, Future<PluginRepoInfo>>{};

  static Future<Directory> _dir(String url) async {
    final root = debugDir ?? Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}plugins');
    return Directory('${root.path}${Platform.pathSeparator}${repoKey(url)}');
  }

  /// A short, stable id for a repository's link (not `hashCode`, which differs from run to run).
  static String repoKey(String url) {
    var h = 0x811c9dc5;
    for (final c in utf8.encode(url)) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(36);
  }

  /// What this device has of the repository at [url]; null when nothing (not downloaded here yet).
  static Future<PluginRepoInfo?> local(String url) async {
    if (_info.containsKey(url)) return _info[url];
    PluginRepoInfo? info;
    try {
      final f = File('${(await _dir(url)).path}${Platform.pathSeparator}index.json');
      if (f.existsSync()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map && j['plugins'] is List) {
          info = PluginRepoInfo(url: url, name: '${j['name'] ?? ''}', plugins: [for (final p in j['plugins'] as List) ?PluginEntry.fromJson(p)]);
        }
      }
    } catch (_) {}
    return _info[url] = info;
  }

  /// What an update does with a repository's plugins: the ones still at the same version are kept
  /// as they are, the new and changed ones are downloaded, the ones it no longer lists are dropped.
  @visibleForTesting
  static ({List<String> keep, List<String> fetch, List<String> drop}) planUpdate(List<PluginEntry> installed, List<PluginEntry> listed) {
    final have = {for (final p in installed) p.id: p};
    final keep = <String>[], fetch = <String>[];
    for (final e in listed) {
      final h = have[e.id];
      // (a plugin with no version can't be told from its update: it is always downloaded again)
      if (h != null && e.version.isNotEmpty && h.version == e.version && h.url == e.url) {
        keep.add(e.id);
      } else {
        fetch.add(e.id);
      }
    }
    final listedIds = {for (final e in listed) e.id};
    return (keep: keep, fetch: fetch, drop: [for (final p in installed) if (!listedIds.contains(p.id)) p.id]);
  }

  /// A repository's scripts being downloaded: how many of how many (Settings shows it).
  static final installing = ValueNotifier<({String url, int done, int total})?>(null);

  /// Reads the repository at [url] ([text]: its file, when already read) and keeps its plugins on
  /// this device: only the new ones and those whose version changed are downloaded. Throws a
  /// message fit to show.
  static Future<PluginRepoInfo> install(String url, {String? text}) => _busy[url] ??= () async {
    try {
      return await _install(url, text);
    } finally {
      unawaited(_busy.remove(url));
    }
  }();

  static Future<PluginRepoInfo> _install(String url, String? text) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http') || uri.host.isEmpty) throw const FormatException('Paste a link starting with https://');
    if (text == null) {
      try {
        text = await fetchText(url, timeout: const Duration(seconds: 20));
      } catch (e) {
        if (e is HttpError && (e.status == 404 || e.status == 410)) throw RepoGone(url);
        throw FormatException('Could not open that link ($e).');
      }
    }
    final parsed = parseRepoFile(text, url);
    if (parsed.plugins.isEmpty) throw const FormatException('That repository lists no plugins.');
    final old = await local(url);
    final plan = planUpdate(old?.plugins ?? const [], parsed.plugins);
    final dir = await _dir(url);
    dir.createSync(recursive: true);
    File file(PluginEntry e) => File('${dir.path}${Platform.pathSeparator}${e.id}.js');
    final entries = parsed.plugins;
    // the ones still at the same version are kept; the rest are downloaded, several at once
    final got = <PluginEntry?>[for (final e in entries) plan.keep.contains(e.id) && file(e).existsSync() ? e : null];
    final todo = [for (var i = 0; i < entries.length; i++) if (got[i] == null) i];
    var next = 0, done = 0;
    installing.value = (url: url, done: 0, total: todo.length);
    Future<void> worker() async {
      while (next < todo.length) {
        final i = todo[next++];
        final e = entries[i];
        try {
          final code = e.vega
              ? await composeVegaPlugin(e.url, e.version, (u) => fetchText(u, timeout: const Duration(seconds: 20)))
              : e.scraper
              ? composeScraperPlugin(e.id, e.version, await fetchText(e.url, timeout: const Duration(seconds: 20)))
              : await fetchText(e.url, timeout: const Duration(seconds: 20));
          if (code.length <= _maxScript) {
            await file(e).writeAsString(code);
            _scripts.remove('$url#${e.id}');
            got[i] = e;
          }
        } catch (_) {
          // a script that can't be downloaded now keeps the copy this device has
          if (file(e).existsSync()) got[i] = old?.plugins.where((p) => p.id == e.id).firstOrNull ?? e;
        }
        installing.value = (url: url, done: ++done, total: todo.length);
      }
    }

    try {
      await Future.wait([for (var w = 0; w < _downloadsAtOnce; w++) worker()]);
    } finally {
      installing.value = null;
    }
    final kept = [for (final e in got) ?e];
    if (kept.isEmpty) throw const FormatException("None of the repository's scripts could be downloaded.");
    for (final id in plan.drop) {
      try {
        File('${dir.path}${Platform.pathSeparator}$id.js').deleteSync();
      } catch (_) {}
      _scripts.remove('$url#$id');
    }
    final info = PluginRepoInfo(url: url, name: parsed.name.isEmpty ? uri.host : parsed.name, plugins: kept);
    await File('${dir.path}${Platform.pathSeparator}index.json').writeAsString(jsonEncode({
      'url': url,
      'name': info.name,
      'plugins': [for (final p in kept) p.toJson()],
    }));
    _info[url] = info;
    _found.removeWhere((k, _) => k.startsWith('$url|'));
    return info;
  }

  /// Takes the repository's scripts off this device.
  static Future<void> remove(String url) async {
    _info.remove(url);
    _scripts.removeWhere((k, _) => k.startsWith('$url#'));
    _found.removeWhere((k, _) => k.startsWith('$url|'));
    try {
      final d = await _dir(url);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
  }

  static Future<String?> _script(String url, PluginEntry p) async {
    final key = '$url#${p.id}';
    if (_scripts[key] case final s?) return s;
    try {
      final f = File('${(await _dir(url)).path}${Platform.pathSeparator}${p.id}.js');
      if (!f.existsSync()) return null;
      return _scripts[key] = await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// What each plugin found for a title, kept a few minutes (the sources screen opened again,
  /// the next episode's source looked for).
  static final _found = <String, _Run>{};

  /// How many times in a row each plugin failed (an error, no answer in time): one that keeps
  /// failing (its site is gone) is asked after the rest.
  static final _failures = <String, int>{};

  /// Every plugin of the repository at [url] asked for [query] (the plugin contract's query:
  /// README.md), [_atOnce] at a time; what they found, in the repository's order. [onSome] hears
  /// what has been found so far each time a plugin finds something, so a slow one holds nothing
  /// up. Downloads the repository first when this device doesn't have it (an addon synced from
  /// another device).
  static Future<List<PluginHit>> find(String url, Map<String, Object?> query, {void Function(List<PluginHit> soFar)? onSome}) async {
    final key = '$url|${jsonEncode(query)}';
    final had = _found[key];
    final _Run run;
    if (had != null && DateTime.now().difference(had.at) < const Duration(minutes: 10)) {
      run = had;
    } else {
      run = _found[key] = _Run();
      run.done = _find(url, query, run.hits);
      // (nothing found, or it failed: asked again next time)
      unawaited(run.done.then((l) {
        if (l.isEmpty && _found[key] == run) _found.remove(key);
      }, onError: (Object _) {
        if (_found[key] == run) _found.remove(key);
      }));
    }
    if (onSome == null) return run.done;
    void tell() => onSome(run.hits.value);
    if (run.hits.value.isNotEmpty) tell();
    run.hits.addListener(tell);
    try {
      return await run.done;
    } finally {
      run.hits.removeListener(tell);
    }
  }

  static Future<List<PluginHit>> _find(String url, Map<String, Object?> query, ValueNotifier<List<PluginHit>> soFar) async {
    final info = await local(url) ?? await install(url);
    final tv = query['isTv'] == true;
    final plugins = [for (final p in info.plugins) if (p.types.contains(tv ? 'tv' : 'movie')) p];
    int fails(int i) => _failures['$url#${plugins[i].id}'] ?? 0;
    final order = [for (var i = 0; i < plugins.length; i++) i]..sort((a, b) => fails(a) != fails(b) ? fails(a) - fails(b) : a - b);
    final found = List<List<PluginHit>>.filled(plugins.length, const []);
    var next = 0;
    Future<void> worker() async {
      while (next < order.length) {
        final i = order[next++];
        final p = plugins[i];
        final code = await _script(url, p);
        if (code == null) continue;
        try {
          found[i] = [for (final s in await runPlugin(code, query, name: p.name)) PluginHit(p, s)];
          _failures.remove('$url#${p.id}');
        } catch (_) {
          _failures['$url#${p.id}'] = fails(i) + 1; // (what went wrong is in the plugin log)
        }
        if (found[i].isNotEmpty) soFar.value = [for (final l in found) ...l];
      }
    }

    await Future.wait([for (var w = 0; w < _atOnce; w++) worker()]);
    return [for (final l in found) ...l];
  }
}

// ── running a plugin ──

/// What the script's global functions are. `getStreams(query)` is the plugin's own entry point.
const _prelude = r'''
var __cb = {}, __n = 0;
function http(url, opts) {
  return new Promise(function (resolve) {
    var id = ++__n;
    __cb[id] = resolve;
    sendMessage('http', JSON.stringify({ id: id, url: String(url), opts: opts || {} }));
  });
}
function __reply(id, r) { var f = __cb[id]; delete __cb[id]; if (f) f(r); }
// timers: the engine's setTimeout gives no id back and has no clearTimeout; these do, over it
(function () {
  var later = typeof setTimeout === 'function' ? setTimeout : null, on = {}, n = 0;
  if (!later) return;
  globalThis.setTimeout = function (fn, ms) {
    var args = Array.prototype.slice.call(arguments, 2), id = ++n;
    on[id] = true;
    later(function () { if (on[id]) { delete on[id]; if (typeof fn === 'function') fn.apply(null, args); } }, ms || 0);
    return id;
  };
  globalThis.clearTimeout = function (id) { delete on[id]; };
  globalThis.setInterval = function (fn, ms) {
    var args = Array.prototype.slice.call(arguments, 2), id = ++n;
    on[id] = true;
    (function tick() { later(function () { if (!on[id]) return; if (typeof fn === 'function') fn.apply(null, args); if (on[id]) tick(); }, ms || 0); })();
    return id;
  };
  globalThis.clearInterval = globalThis.clearTimeout;
})();
var __b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function btoa(s) {
  s = String(s); var o = '';
  for (var i = 0; i < s.length; i += 3) {
    var a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
    o += __b64[a >> 2] + __b64[((a & 3) << 4) | (b >> 4 || 0)] +
      (isNaN(b) ? '=' : __b64[((b & 15) << 2) | (c >> 6 || 0)]) + (isNaN(c) ? '=' : __b64[c & 63]);
  }
  return o;
}
function atob(s) {
  s = String(s).replace(/[^A-Za-z0-9+\/]/g, ''); var o = '';
  for (var i = 0; i < s.length; i += 4) {
    var a = __b64.indexOf(s[i]), b = __b64.indexOf(s[i + 1]), c = __b64.indexOf(s[i + 2]), d = __b64.indexOf(s[i + 3]);
    o += String.fromCharCode((a << 2) | (b >> 4));
    if (c >= 0) o += String.fromCharCode(((b & 15) << 4) | (c >> 2));
    if (d >= 0) o += String.fromCharCode(((c & 3) << 6) | d);
  }
  return o;
}
function __run(q) {
  try {
    Promise.resolve(getStreams(q)).then(
      function (r) { sendMessage('done', JSON.stringify({ ok: true, streams: r || [] })); },
      function (e) { sendMessage('done', JSON.stringify({ ok: false, error: String((e && e.message) || e) })); });
  } catch (e) { sendMessage('done', JSON.stringify({ ok: false, error: String((e && e.message) || e) })); }
}
// console.log / info / warn / error: kept in the plugin log (a TV has no readable logcat)
console.log = console.info = console.warn = console.error = function () {
  var a = [];
  for (var i = 0; i < arguments.length; i++) a.push(String(arguments[i]));
  sendMessage('plog', JSON.stringify(a.join(' ')));
};
''';

/// The engine a test runs plugins in instead ([code], its query: {streams, log, error?}), where
/// the real one's library isn't there.
@visibleForTesting
Future<Map<String, Object?>> Function(String code, Map<String, Object?> query)? debugPluginEngine;

JavascriptRuntime _newRuntime() {
  // a script that never ends is stopped by the engine after 20 s; one that eats memory, at the
  // limit, where the engine's library can set one
  if (Platform.isAndroid || Platform.isLinux || Platform.isWindows) {
    return QuickJsRuntime2(timeout: 20000, memoryLimit: _canLimitMemory ? _memoryLimit : null);
  }
  return getJavascriptRuntime(xhr: false);
}

/// Whether this build's QuickJS library can cap a script's memory. flutter_js asks for the
/// function only when a limit is set, and its Windows library (0.8.7) has none: asking would fail
/// every plugin. (Read after the Linux library is loaded its own way: see _loadQuickJsDeepBound.)
final bool _canLimitMemory = () {
  try {
    final lib = Platform.isWindows
        ? DynamicLibrary.open('quickjs_c_bridge.dll')
        : Platform.isLinux
        ? DynamicLibrary.open(Platform.environment['LIBQUICKJSC_PATH'] ?? Platform.environment['LIBQUICKJSC_TEST_PATH'] ?? 'libquickjs_c_bridge_plugin.so')
        : Platform.isAndroid
        ? DynamicLibrary.open('libfastdev_quickjs_runtime.so')
        : null;
    return lib?.providesSymbol('jsSetMemoryLimit') ?? false;
  } catch (_) {
    return false;
  }
}();

/// Whether plugins run with a memory limit here (for tests).
@visibleForTesting
bool get pluginMemoryLimited => _canLimitMemory;

bool _deepBound = false;

/// Linux: loads the QuickJS library so that it uses its own functions before anyone else's.
///
/// mpv's bundled libmujs exports `js_malloc` too, with another meaning. Once mpv has loaded it,
/// QuickJS's calls to its own `js_malloc` land in mujs and the app crashes the first time a plugin
/// runs. With RTLD_DEEPBIND the library looks in itself first. It is loaded under the same name
/// flutter_js asks for later, so it gets this already-loaded copy.
void _loadQuickJsDeepBound() {
  if (_deepBound || !Platform.isLinux) return;
  _deepBound = true;
  try {
    final dlopen = DynamicLibrary.process().lookupFunction<Pointer<Void> Function(Pointer<Utf8>, Int32), Pointer<Void> Function(Pointer<Utf8>, int)>('dlopen');
    final name = 'libquickjs_c_bridge_plugin.so'.toNativeUtf8();
    dlopen(name, 0x2 | 0x8); // RTLD_NOW | RTLD_DEEPBIND
    malloc.free(name);
  } catch (_) {}
}

String? _vegaRuntimeJs, _scraperRuntimeJs;

/// assets/plugins/vega_runtime.js: what a Vega provider runs on (see tool/vega_runtime).
Future<String> _vegaRuntime() async => _vegaRuntimeJs ??= await rootBundle.loadString('assets/plugins/vega_runtime.js');

/// assets/plugins/scraper_runtime.js: what a scraper from a scraper list runs on, after the Vega
/// runtime (see tool/vega_runtime).
Future<String> _scraperRuntime() async => _scraperRuntimeJs ??= await rootBundle.loadString('assets/plugins/scraper_runtime.js');

String? _helpersJs;

/// assets/plugins/helpers.js: the title-matching functions every plugin can call.
Future<String> _helpers() async {
  if (_helpersJs != null) return _helpersJs!;
  try {
    return _helpersJs = await rootBundle.loadString('assets/plugins/helpers.js');
  } catch (_) {
    return '';
  }
}

/// Runs a plugin's `getStreams(query)` and returns what it found. Throws when it failed (said in
/// the plugin log, with its own lines).
Future<List<FoundStream>> runPlugin(String code, Map<String, Object?> query, {String name = ''}) async {
  final Map<String, Object?> res;
  final engine = debugPluginEngine;
  if (engine != null) {
    res = await engine(code, query);
  } else {
    // a script stuck in a loop would hold up whatever thread runs it until the engine stops it:
    // it runs in an isolate of its own, never the screen's
    _loadQuickJsDeepBound();
    final helpers = await _helpers();
    if (code.startsWith(vegaMarker)) {
      code = '${await _vegaRuntime()}\n$code';
    } else if (code.startsWith(scraperMarker)) {
      code = '${await _vegaRuntime()}\n${await _scraperRuntime()}\n$code';
    }
    final script = code;
    try {
      res = await Isolate.run(() => _execute(script, query, helpers)).timeout(_runTimeout + const Duration(seconds: 5));
    } on TimeoutException {
      PluginLog.add(name, ['stopped: no answer in ${(_runTimeout + const Duration(seconds: 5)).inSeconds} s']);
      rethrow;
    }
  }
  final error = res['error'] as String?;
  final streams = parseStreams(res['streams']);
  PluginLog.add(name, [
    ...((res['log'] as List?) ?? const []).map((l) => '$l'),
    if (error != null) 'ERROR: $error' else 'done: ${streams.length} stream${streams.length == 1 ? '' : 's'}',
  ]);
  if (error != null) throw StateError(error);
  return streams;
}

/// [_execute] for tests that have the real engine: runs [code] (after [helpers]) and returns
/// {streams, log, error?}.
@visibleForTesting
Future<Map<String, Object?>> executeScriptForTest(String code, Map<String, Object?> query, String helpers) {
  _loadQuickJsDeepBound();
  return _execute(code, query, helpers);
}

/// Runs the script in a fresh engine. Returns {streams, log, error?}: what it answered, the lines
/// it logged (kept even when it fails or runs out of time), and the reason when it failed.
Future<Map<String, Object?>> _execute(String code, Map<String, Object?> query, String helpers) async {
  final logs = <String>[];
  final rt = _newRuntime();
  final done = Completer<Map<String, dynamic>>();
  var closed = false;
  // the engine runs a promise's next step only when asked: after every call into it, and often
  final pump = Timer.periodic(const Duration(milliseconds: 15), (_) {
    if (!closed) rt.executePendingJob();
  });
  try {
    rt.onMessage('plog', (a) {
      if (a is String && logs.length < 300) logs.add(a.length > 400 ? '${a.substring(0, 400)}…' : a);
      return null;
    });
    rt.onMessage('done', (a) {
      if (!done.isCompleted) done.complete(a is Map ? Map<String, dynamic>.from(a) : {'ok': false, 'error': 'bad answer'});
      return null;
    });
    rt.onMessage('http', (a) {
      final id = a is Map ? a['id'] : null;
      if (id is! int) return null;
      // (answered later, never inside the call from the script: the engine can't be re-entered)
      unawaited(() async {
        Map<String, Object?> res;
        try {
          res = await _request('${a['url']}', a['opts'] is Map ? Map<String, dynamic>.from(a['opts'] as Map) : const {});
        } catch (e) {
          res = {'status': 0, 'error': '$e', 'text': '', 'headers': <String, String>{}, 'url': '${a['url']}'};
        }
        if (closed) return;
        // (the reply is an object literal: JSON is valid JavaScript)
        rt.evaluate('__reply($id, ${jsonEncode(res)})');
        rt.executePendingJob();
      }());
      return null;
    });
    final pre = rt.evaluate(_prelude);
    if (pre.isError) throw StateError('engine: ${pre.stringResult}');
    if (helpers.isNotEmpty) {
      final h = rt.evaluate(helpers, sourceUrl: 'helpers.js');
      if (h.isError) throw StateError('helpers: ${h.stringResult}');
    }
    final loaded = rt.evaluate(code, sourceUrl: 'plugin.js');
    if (loaded.isError) throw StateError('script: ${loaded.stringResult}');
    final started = rt.evaluate(
      'typeof getStreams === "function" ? __run(${jsonEncode(query)}) : sendMessage("done", JSON.stringify({ok:false,error:"no getStreams function"}))',
    );
    if (started.isError) throw StateError('script: ${started.stringResult}');
    rt.executePendingJob();
    final r = await done.future.timeout(_runTimeout);
    if (r['ok'] != true) throw StateError('${r['error']}');
    return {'streams': r['streams'] is List ? r['streams'] as List : const [], 'log': logs};
  } catch (e) {
    return {'streams': const [], 'log': logs, 'error': e.toString().split('\n').first};
  } finally {
    closed = true;
    pump.cancel();
    try {
      rt.dispose();
    } catch (_) {}
  }
}

/// A plugin's answer as streams: `[{url, type?, quality?, server?, label?, audio?, headers?}]`.
/// Anything that isn't an http(s) link is left out.
@visibleForTesting
List<FoundStream> parseStreams(Object? v) {
  if (v is! List) return const [];
  final out = <FoundStream>[];
  for (final s in v) {
    if (s is! Map) continue;
    final url = s['url'];
    if (url is! String || !(url.startsWith('http://') || url.startsWith('https://'))) continue;
    final h = s['headers'];
    out.add(
      FoundStream(
        url: url,
        type: s['type'] is String ? s['type'] as String : null,
        quality: s['quality'] == null ? 'Auto' : '${s['quality']}',
        server: s['server'] == null ? 'Server' : '${s['server']}',
        label: s['label'] is String ? s['label'] as String : null,
        audio: audioOf(s['audio']),
        headers: h is Map ? {for (final e in h.entries) '${e.key}': '${e.value}'} : const {},
      ),
    );
  }
  return out;
}

// ── the script's network: web only, never this device's own network ──

/// Whether [a] is an address on this device or its local network, which a script may not reach
/// (the torrent engine, routers, other apps).
@visibleForTesting
bool isPrivateAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 10 || b[0] == 0 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }
  if (b.length == 16) {
    if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7
    // ::ffff:a.b.c.d
    if (b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff) {
      return isPrivateAddress(InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))));
    }
  }
  return false;
}

Future<void> _checkHost(Uri u) async {
  if (u.scheme != 'http' && u.scheme != 'https') throw StateError('only http and https links');
  final host = u.host.toLowerCase();
  if (host.isEmpty || host == 'localhost' || host.endsWith('.local') || host.endsWith('.localhost') || host.endsWith('.internal')) {
    throw StateError("this device's network is off limits");
  }
  final literal = InternetAddress.tryParse(host);
  final addrs = literal != null ? [literal] : await InternetAddress.lookup(host);
  if (addrs.isEmpty || addrs.any(isPrivateAddress)) throw StateError("this device's network is off limits");
}

Future<Map<String, Object?>> _request(String url, Map<String, dynamic> opts) async {
  var u = Uri.parse(url);
  final method = '${opts['method'] ?? 'GET'}'.toUpperCase();
  final headers = <String, String>{
    if (opts['headers'] is Map)
      for (final e in (opts['headers'] as Map).entries) '${e.key}': '${e.value}',
  };
  headers.putIfAbsent('User-Agent', () => sdkUA);
  final body = opts['body'] == null ? null : (opts['body'] is String ? opts['body'] as String : jsonEncode(opts['body']));
  final timeout = Duration(milliseconds: ((opts['timeout'] as num?)?.toInt() ?? 15000).clamp(1000, 20000));
  http.Response? res;
  // redirects are followed here, so each one is checked
  for (var hop = 0; hop < 6; hop++) {
    await _checkHost(u);
    final rq = http.Request(hop == 0 ? method : 'GET', u)
      ..followRedirects = false
      ..headers.addAll(headers);
    if (hop == 0 && body != null) rq.body = body;
    final streamed = await netClient.send(rq).timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in streamed.stream.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBody) throw StateError('answer too large');
    }
    res = http.Response.bytes(bytes, streamed.statusCode, headers: streamed.headers, request: rq);
    final loc = res.headers['location'];
    if (res.statusCode >= 300 && res.statusCode < 400 && loc != null) {
      u = u.resolve(loc);
      continue;
    }
    break;
  }
  final r = res!;
  return {
    'status': r.statusCode,
    'url': '$u',
    'headers': {for (final e in r.headers.entries) e.key.toLowerCase(): e.value},
    'text': utf8.decode(r.bodyBytes, allowMalformed: true),
  };
}
