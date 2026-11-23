// The plugin index: every public repository of scraper plugins that works today, for Settings >
// Addons > Find plugins. Built once a day on VyseTV's own server (it searches the public code
// hosts and reads each repository's manifest), so a device downloads one small file instead of
// asking hundreds of places. Kept on the device, so the page opens at once and offline too.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../account/account.dart' show accountServer;
import '../../net.dart';

/// A repository in the index.
@immutable
class PluginListing {
  const PluginListing({
    required this.url,
    required this.name,
    this.kind = 'scrapers',
    this.author = '',
    this.description = '',
    this.plugins = 0,
    this.names = const [],
    this.languages = const [],
    this.types = const ['movie', 'tv'],
    this.updated,
    this.stars = 0,
    this.icon,
    this.featured = false,
    this.adult = false,
  });

  /// Its link: what Install adds (as pasting it in Settings > Addons does).
  final String url;
  final String name;

  /// 'scrapers' (a scraper list), 'vega' (Vega providers) or 'plugins' (a repo.json).
  final String kind;
  final String author;
  final String description;

  /// How many plugins it has turned on, and their names (the first forty).
  final int plugins;
  final List<String> names;

  /// The languages its plugins say they're in ('en', 'tr'…), and 'movie' and/or 'tv'.
  final List<String> languages;
  final List<String> types;

  /// When its repository last changed.
  final DateTime? updated;
  final int stars;
  final String? icon;

  /// Hand-picked by people who list these (shown first, with their description).
  final bool featured;

  /// For adults: shown only with adult content allowed (Settings > Anime).
  final bool adult;

  static PluginListing? fromJson(Object? j) {
    if (j is! Map || j['url'] is! String || '${j['url']}'.isEmpty) return null;
    List<String> strings(Object? v) => [for (final x in v is List ? v : const []) '$x'];
    final icon = '${j['icon'] ?? ''}';
    return PluginListing(
      url: j['url'] as String,
      name: '${j['name'] ?? ''}'.trim().isEmpty ? Uri.parse(j['url'] as String).pathSegments.elementAtOrNull(1) ?? 'Plugins' : '${j['name']}'.trim(),
      kind: '${j['kind'] ?? 'scrapers'}',
      author: '${j['author'] ?? ''}',
      description: '${j['description'] ?? ''}',
      plugins: (j['plugins'] as num?)?.toInt() ?? 0,
      names: strings(j['names']),
      languages: strings(j['languages']),
      types: strings(j['types']).isEmpty ? const ['movie', 'tv'] : strings(j['types']),
      updated: DateTime.tryParse('${j['updated'] ?? ''}'),
      stars: (j['stars'] as num?)?.toInt() ?? 0,
      icon: icon.startsWith('https://') ? icon : null,
      featured: j['featured'] == true,
      adult: j['adult'] == true,
    );
  }

  /// Whether it matches [query]: its name, author, description or a plugin's name, any case.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        author.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q) ||
        names.any((n) => n.toLowerCase().contains(q));
  }
}

/// The index as last downloaded: when it was built, and its repositories.
@immutable
class PluginIndexData {
  const PluginIndexData(this.built, this.repos);
  final DateTime? built;
  final List<PluginListing> repos;

  static PluginIndexData parse(String text) {
    final j = json.decode(text);
    if (j is! Map || j['repos'] is! List) throw const FormatException('not a plugin index');
    return PluginIndexData(DateTime.tryParse('${j['updated'] ?? ''}'), [for (final r in j['repos'] as List) ?PluginListing.fromJson(r)]);
  }
}

abstract final class PluginIndex {
  /// Where the index is (a test's own); the app: on its server.
  @visibleForTesting
  static String? debugUrl;

  /// Where a test keeps the device's copy (the app: its support folder).
  @visibleForTesting
  static Directory? debugDir;

  static String get _url => debugUrl ?? '$accountServer/plugins/index.json';

  static PluginIndexData? _memory;
  static DateTime? _fetched;
  static Future<PluginIndexData>? _loading;

  @visibleForTesting
  static void debugReset() {
    _memory = null;
    _fetched = null;
    _loading = null;
  }

  static Future<File> _file() async {
    final dir = debugDir ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}plugin_index.json');
  }

  /// The index: this device's copy while it is fresh (a few hours), else downloaded again; the
  /// copy when the server can't be reached. Throws a message fit to show when there's neither.
  static Future<PluginIndexData> load({bool fresh = false}) {
    final m = _memory, at = _fetched;
    if (!fresh && m != null && at != null && DateTime.now().difference(at) < const Duration(hours: 6)) return Future.value(m);
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  /// This device's copy, at once, with no download (null when there's none yet).
  static Future<PluginIndexData?> kept() async {
    if (_memory case final m?) return m;
    try {
      final f = await _file();
      if (f.existsSync()) return _memory = PluginIndexData.parse(await f.readAsString());
    } catch (_) {}
    return null;
  }

  static Future<PluginIndexData> _load() async {
    try {
      if (_url.startsWith('/')) throw StateError('no server');
      final r = await netClient.get(Uri.parse(_url), headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) throw StateError('HTTP ${r.statusCode}');
      final text = utf8.decode(r.bodyBytes);
      final data = PluginIndexData.parse(text);
      _memory = data;
      _fetched = DateTime.now();
      try {
        await (await _file()).writeAsString(text);
      } catch (_) {}
      return data;
    } catch (_) {
      final copy = await kept();
      if (copy != null) return copy;
      throw "Couldn't load the plugin list. Check your connection and try again.";
    }
  }
}
