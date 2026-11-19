// Opening a portal's films and series in VyseTV's own player (lib/data/live_tv/iptv_playback.dart).
import 'package:flutter/material.dart';

import '../../data/live_tv/iptv_playback.dart';
import '../../data/live_tv/live_tv.dart';
import '../../models/iptv/iptv_models.dart';
import '../player/player_page.dart';

/// A portal's film, as the player takes it.
IptvVideo iptvFilm(VerifiedPortal portal, IptvStream film) =>
    IptvVideo(title: film.name, url: LiveItem.stream(portal, film, IptvSection.vod).url, image: film.icon);

/// One episode of a portal's series.
IptvVideo iptvEpisode(VerifiedPortal portal, IptvStream series, IptvEpisode e) => IptvVideo(
  title: e.title,
  url: LiveItem.episode(portal, series, e).url,
  image: e.image.isNotEmpty ? e.image : series.icon,
  overview: e.plot,
  season: e.season,
  number: e.episode,
);

/// Plays [playback] in the film player: the one with the audio and subtitle menus, the episode
/// list and Next.
Future<void> openIptvVideo(BuildContext context, IptvPlayback playback) => Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
  transitionDuration: const Duration(milliseconds: 360),
  reverseTransitionDuration: const Duration(milliseconds: 260),
  pageBuilder: (_, _, _) => PlayerPage(media: playback.media, episode: playback.episode, server: playback),
  transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
));
