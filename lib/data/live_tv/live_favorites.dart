import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/iptv/iptv_models.dart';
import 'portal_names.dart';

/// A favorite channel, with what it takes to play it again from Live TV > Favorites without
/// opening its portal or its playlist first: its name, its picture and its address.
class FavoriteChannel {
  const FavoriteChannel({required this.key, required this.title, required this.url, this.logo, this.from});

  /// What makes it this channel: [LiveFavorites.keyOf] for a portal's, [LiveFavorites.keyOfM3u]
  /// for a playlist's.
  final String key;
  final String title;
  final String url;
  final String? logo;

  /// Where it is from, as the list says under its name: the portal's or the playlist's name.
  final String? from;

  Map<String, Object?> toJson() => {
    'k': key,
    't': title,
    'u': url,
    if (logo != null && logo!.isNotEmpty) 'l': logo,
    if (from != null && from!.isNotEmpty) 'f': from,
  };

  static FavoriteChannel? fromJson(Object? j) {
    if (j is! Map) return null;
    final key = j['k'], title = j['t'], url = j['u'];
    if (key is! String || title is! String || url is! String || url.isEmpty) return null;
    return FavoriteChannel(key: key, title: title, url: url, logo: j['l'] as String?, from: j['f'] as String?);
  }
}

/// Favorite live channels, kept on this device. A portal's channel is a favorite by its portal
/// and its id (the same channel on two portals is two favorites), a playlist's by its address.
class LiveFavorites {
  static const _prefsKey = 'live_tv_favorite_channels';
  static const _savedKey = 'live_tv_favorite_list';

  /// The keys of every favorite. Replaced (never changed in place) on every toggle, so
  /// listeners can compare by identity.
  static final ids = ValueNotifier<Set<String>>(const {});

  /// The favorites themselves, for the one place that lists them all, newest first.
  static final saved = ValueNotifier<List<FavoriteChannel>>(const []);
  static bool _loaded = false;

  static String keyOf(VerifiedPortal p, IptvStream s) => '${p.key}|${s.streamId}';
  static String keyOfM3u(String url) => 'm3u|$url';

  static bool has(VerifiedPortal p, IptvStream s) => ids.value.contains(keyOf(p, s));

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      // anything starred before the load finished stays
      ids.value = {...?prefs.getStringList(_prefsKey), ...ids.value};
      final raw = prefs.getString(_savedKey);
      if (raw != null) {
        final list = [for (final j in json.decode(raw) as List) ?FavoriteChannel.fromJson(j)];
        final have = {for (final c in saved.value) c.key};
        saved.value = [...saved.value, for (final c in list) if (!have.contains(c.key)) c];
      }
    } catch (_) {
      // unreadable: what was starred this run is kept
    }
  }

  /// Stars [channel], or takes its star away.
  static void toggleChannel(FavoriteChannel channel) {
    final keys = {...ids.value};
    final list = [...saved.value]..removeWhere((c) => c.key == channel.key);
    if (!keys.remove(channel.key)) {
      keys.add(channel.key);
      list.insert(0, channel);
    }
    ids.value = keys;
    saved.value = list;
    _save();
  }

  /// A portal's channel: [url] is its stream's address.
  static void toggle(VerifiedPortal p, IptvStream s, {required String url}) =>
      toggleChannel(FavoriteChannel(key: keyOf(p, s), title: s.name, url: url, logo: s.icon, from: portalLabel(p)));

  /// Favorites starred before there was a list of them are only a key. Given their portal's
  /// channels (the portal is open), they get their name, picture and address, and join the list.
  static void adopt(VerifiedPortal p, Iterable<IptvStream> streams, String Function(IptvStream) urlOf) {
    final prefix = '${p.key}|';
    final have = {for (final c in saved.value) c.key};
    final bare = {
      for (final k in ids.value)
        if (k.startsWith(prefix) && !have.contains(k)) k,
    };
    if (bare.isEmpty) return;
    final found = [
      for (final s in streams)
        if (bare.contains(keyOf(p, s))) FavoriteChannel(key: keyOf(p, s), title: s.name, url: urlOf(s), logo: s.icon, from: portalLabel(p)),
    ];
    if (found.isEmpty) return;
    saved.value = [...saved.value, ...found];
    _save();
  }

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, ids.value.toList());
      await prefs.setString(_savedKey, json.encode([for (final c in saved.value) c.toJson()]));
    } catch (_) {
      // kept in memory; saved with the next change
    }
  }

  /// Tests: as on a device where nothing was ever starred.
  @visibleForTesting
  static void debugReset() {
    _loaded = false;
    ids.value = const {};
    saved.value = const [];
  }
}
