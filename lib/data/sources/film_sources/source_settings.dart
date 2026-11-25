import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../app_settings.dart';
import 'film_sources.dart';

/// Settings → Sources: the order film and TV sources are asked in, and which are off.

List<String> _ids(String raw) => [for (final s in raw.split(',')) if (s.trim().isNotEmpty) s.trim()];

/// Every source in your order. Ones the saved order doesn't know yet (added by an update) go
/// right after the source they follow in the default order (Cinejoy under Movy).
List<FilmSource> orderedFilmSources() {
  final byId = {for (final s in filmSources) s.id: s};
  final out = <FilmSource>[for (final id in _ids(AppSettings.sourceOrder.value)) ?byId[id]];
  for (final (i, s) in filmSources.indexed) {
    if (!out.contains(s)) out.insert(i == 0 ? 0 : out.indexOf(filmSources[i - 1]) + 1, s);
  }
  return out;
}

bool filmSourceOn(FilmSource s) => !_ids(AppSettings.sourcesOff.value).contains(s.id);

void setFilmSourceOrder(List<FilmSource> order) {
  final ids = [for (final s in order) s.id];
  final def = [for (final s in filmSources) s.id];
  AppSettings.sourceOrder.set(ids.join(',') == def.join(',') ? '' : ids.join(','));
}

void setFilmSourceOn(FilmSource s, bool on) {
  final off = _ids(AppSettings.sourcesOff.value)..remove(s.id);
  if (!on) off.add(s.id);
  AppSettings.sourcesOff.set(off.join(','));
}

/// The sources a play asks, in your order, without the ones you turned off.
List<FilmSource> activeFilmSources() => debugFilmSources ?? [for (final s in orderedFilmSources()) if (filmSourceOn(s)) s];

/// Tests: made-up sources in place of yours (no site is asked).
@visibleForTesting
List<FilmSource>? debugFilmSources;

/// A party host's list, in their order. Ones this version doesn't have are left out.
List<FilmSource> filmSourcesFrom(List<String> ids) {
  final byId = {for (final s in filmSources) s.id: s};
  return [for (final id in ids) ?byId[id]];
}
