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

/// "Mark all watched" beside a show's Play and Save: every episode out so far, in every season,
/// marked watched at once (and sent on to Trakt and Simkl, as a season's marks are). Green, as
/// "All watched", once they all are; pressed then, it asks before taking them all back, as that
/// takes them out of Trakt's and Simkl's history too.
class SeriesWatchedButton extends StatefulWidget {
  const SeriesWatchedButton({super.key, required this.media, required this.seasons, required this.episodes});
  final Media media;

  /// The seasons it marks, in order (a TMDB show's specials left out).
  final List<Season> seasons;

  /// A season's episodes that are out.
  final Future<List<EpisodeMark>> Function(int season) episodes;

  @override
  State<SeriesWatchedButton> createState() => _SeriesWatchedButtonState();
}

class _SeriesWatchedButtonState extends State<SeriesWatchedButton> {
  List<EpisodeMark>? _out; // every episode out so far, once fetched
  Future<List<EpisodeMark>>? _fetching;
  bool _fetchedQuietly = false;
  bool _busy = false;

  Future<List<EpisodeMark>> _fetch() => _fetching ??= () async {
    try {
      final lists = await Future.wait([for (final s in widget.seasons) widget.episodes(s.number)]);
      final all = [for (final l in lists) ...l];
      if (mounted) setState(() => _out = all);
      return all;
    } catch (_) {
      _fetching = null; // try again on a press
      rethrow;
    }
  }();

  bool _seen(EpisodeMark e) => WatchProgress.isSeen(widget.media, season: e.season, episode: e.number);

  /// Every episode out is watched. Until the list is fetched, the watched counts settle it when
  /// they can: a season (the last aside, which may still be airing) with fewer watched than it
  /// has episodes means no. Only a show that could be all watched has its list fetched.
  bool get _on {
    final out = _out;
    if (out != null) return out.isNotEmpty && out.every(_seen);
    final entry = WatchProgress.find(widget.media);
    if (entry == null || entry.episodesFinished == 0) return false;
    for (final s in widget.seasons.take(widget.seasons.length - 1)) {
      final watched = entry.episodes.entries.where((e) => e.key.startsWith('S${s.number}E') && e.value >= WatchProgress.finishedAt).length;
      if (watched < s.episodes) return false;
    }
    if (!_fetchedQuietly) {
      _fetchedQuietly = true;
      _fetch().ignore();
    }
    return false;
  }

  Future<void> _press() async {
    if (_busy) return;
    // the press does what the button says: a list fetched since it was drawn can't turn it round
    final on = _on;
    if (on && !await _askToUnmark()) return;
    if (!mounted) return;
    setState(() => _busy = true);
    List<EpisodeMark>? out;
    try {
      out = _out ?? await _fetch();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _busy = false);
    if (out == null || out.isEmpty) {
      showToast(context, const Text("Couldn't get the episode list", style: TextStyle(fontSize: 13)), icon: Icons.error_outline);
      return;
    }
    setEpisodesWatched(context, widget.media, out, watched: !on, what: 'Every episode');
  }

  Future<bool> _askToUnmark() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: VyseColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Mark all unwatched?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: 380,
            child: Text(
              'Every episode of ${widget.media.title} goes back to unwatched, here and on Trakt or Simkl if you use them.',
              style: const TextStyle(color: VyseColors.textDim, height: 1.5),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mark unwatched', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ) ==
      true;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<WatchEntry>>(
    valueListenable: WatchProgress.entries,
    builder: (context, _, _) {
      final on = _on;
      return Pressable(
        onTap: _press,
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
                if (_busy)
                  const SizedBox.square(dimension: 15, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.text))
                else
                  Icon(on ? Icons.check_circle_rounded : Icons.done_all_rounded, size: 17, color: on ? watchedGreen : VyseColors.text),
                const SizedBox(width: 7),
                Text(on ? 'All watched' : 'Mark all watched', style: const TextStyle(color: VyseColors.text, fontWeight: FontWeight.w600, fontSize: 13)),
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
