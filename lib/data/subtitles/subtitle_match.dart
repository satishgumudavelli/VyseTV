import 'subtitles.dart';

/// A watch party guest showing the host's subtitle. A link the host got may not answer the
/// guest's device, so the guest looks the same file up in the list it fetched itself and plays
/// its own link to it.

/// The host's subtitle as a track, from what the room's state carries.
SubtitleTrack hostSubtitle(Map<String, dynamic> h) => SubtitleTrack(
      id: '${h['id']}',
      provider: '${h['provider']}',
      lang: '${h['lang'] ?? ''}',
      language: '${h['language'] ?? h['lang'] ?? ''}',
      release: '${h['release'] ?? ''}',
      url: '${h['url']}',
      format: '${h['format'] ?? 'srt'}',
      translated: h['translated'] == true,
    );

/// The same file as [host] in [tracks] (this device's list): same provider and language, then
/// the same release name (the same position in the provider's list first), the same link, or,
/// when the provider gives no name, the same position. Links in [failed] are left out.
SubtitleTrack? subtitleCopy(SubtitleTrack host, Iterable<SubtitleTrack> tracks, {Set<String> failed = const {}}) {
  final same = [
    for (final t in tracks)
      if (t.provider == host.provider && t.lang == host.lang && t.translated == host.translated && !failed.contains(t.url)) t,
  ];
  final named = host.release.isEmpty ? const <SubtitleTrack>[] : same.where((t) => t.release == host.release).toList();
  return named.where((t) => t.id == host.id).firstOrNull ??
      same.where((t) => t.url == host.url).firstOrNull ??
      named.firstOrNull ??
      (host.release.isEmpty ? same.where((t) => t.id == host.id && t.release.isEmpty).firstOrNull : null);
}

/// Another file in [host]'s language, when its own won't load here: one inside the video (timed
/// to it, forced ones last), then one from the same provider, then any real one, then a machine
/// translation.
SubtitleTrack? subtitleNear(SubtitleTrack host, Iterable<SubtitleTrack> tracks, {Set<String> failed = const {}}) {
  final near = inLanguage(tracks.where((t) => !failed.contains(t.url) && t.url != host.url), host.lang);
  bool forced(SubtitleTrack t) => t.release.contains('Forced');
  return near.where((t) => t.provider == 'Built in' && !forced(t)).firstOrNull ??
      near.where((t) => t.provider == host.provider && !t.translated).firstOrNull ??
      near.where((t) => !t.translated && !forced(t)).firstOrNull ??
      near.where((t) => !forced(t)).firstOrNull;
}
