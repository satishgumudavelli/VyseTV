import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/catalog/tmdb.dart';
import '../data/playback/watch_progress.dart';
import '../data/trackers/tracker_hub.dart';
import 'common.dart';

/// The green History uses for "finished": a watched tick is the same thing.
const watchedGreen = Color(0xFF3DDC97);

/// Marks a film watched or unwatched (and tells Trakt and Simkl), and says so.
void setFilmWatched(BuildContext context, Media media, {required bool watched, int? runtime}) {
  TrackerHub.markFilm(media, watched: watched, runtime: runtime);
  _said(context, watched ? 'Marked as watched' : 'Marked as unwatched', watched);
}

/// Marks episodes watched or unwatched (and tells the services), and says so: [what] names
/// them when it's more than one ("Season 2").
void setEpisodesWatched(BuildContext context, Media media, List<EpisodeMark> episodes, {required bool watched, String? what}) {
  TrackerHub.markEpisodes(media, episodes, watched: watched);
  _said(context, '${what == null ? 'Marked' : '$what marked'} as ${watched ? 'watched' : 'unwatched'}', watched);
}

void _said(BuildContext context, String text, bool watched) {
  if (!context.mounted) return;
  showToast(context, Text(text, style: const TextStyle(fontSize: 13)), icon: watched ? Icons.check_circle_rounded : Icons.remove_done_rounded);
}

/// "Mark watched" / "Watched" beside a film's Play and Save: the same pill as Save, with a tick
/// that fills in green once it's watched (played to the end, marked here, or on Trakt or Simkl).
class WatchedButton extends StatelessWidget {
  const WatchedButton({super.key, required this.media, this.runtime});
  final Media media;

  /// Minutes, for a film never started here.
  final int? runtime;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<WatchEntry>>(
    valueListenable: WatchProgress.entries,
    builder: (context, _, _) {
      final on = WatchProgress.isSeen(media);
      return Pressable(
        onTap: () => setFilmWatched(context, media, watched: !on, runtime: runtime),
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .95 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: on ? watchedGreen.withValues(alpha: hovered ? .2 : .13) : Colors.white.withValues(alpha: hovered ? .14 : .06),
              border: Border.all(color: on ? watchedGreen.withValues(alpha: .45) : Colors.white.withValues(alpha: hovered ? .22 : .08)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(on ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded, size: 17, color: on ? watchedGreen : VyseColors.text),
                const SizedBox(width: 7),
                Text(on ? 'Watched' : 'Mark watched', style: const TextStyle(color: VyseColors.text, fontWeight: FontWeight.w600, fontSize: 13)),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// A small round tick: green and filled when watched, faint when not.
class WatchedTick extends StatelessWidget {
  const WatchedTick({super.key, required this.seen, this.size = 18, this.hovered = false});
  final bool seen;
  final double size;
  final bool hovered;

  @override
  Widget build(BuildContext context) => Icon(
    seen ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
    size: size,
    color: seen ? watchedGreen : Colors.white.withValues(alpha: hovered ? .85 : .4),
  );
}
