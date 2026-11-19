import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/iptv/iptv_models.dart';

/// Names you gave your portals, kept on this device. A portal comes with whatever its provider
/// called the account (often the user name: "5843256"); a name of your own is shown in its place.
class PortalNames {
  static const _prefsKey = 'live_tv_portal_names';

  /// Goes up by one whenever a name changes.
  static final changes = ValueNotifier<int>(0);
  static Map<String, String> _names = {};
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
      if (raw == null) return;
      // a name given before the load finished stays
      _names = {
        for (final e in (json.decode(raw) as Map<String, dynamic>).entries)
          if (e.value is String) e.key: e.value as String,
        ..._names,
      };
      changes.value++;
    } catch (_) {
      // unreadable: portals keep their own names
    }
  }

  static String? of(String portalKey) => _names[portalKey];

  /// Gives the portal [name]. An empty one takes yours away again.
  static void set(String portalKey, String name) {
    final clean = name.trim();
    if (clean.isEmpty) {
      if (_names.remove(portalKey) == null) return;
    } else {
      if (_names[portalKey] == clean) return;
      _names[portalKey] = clean;
    }
    changes.value++;
    _save();
  }

  static Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_prefsKey, json.encode(_names));
    } catch (_) {
      // kept in memory; saved with the next change
    }
  }

  /// Tests: as on a device where no portal was ever renamed.
  @visibleForTesting
  static void debugReset() {
    _loaded = false;
    _names = {};
  }
}

/// A portal's name as the app shows it: yours, else its own, else its address.
String portalLabel(VerifiedPortal p) => PortalNames.of(p.key) ?? (p.name.isEmpty ? p.portal.url : p.name);
