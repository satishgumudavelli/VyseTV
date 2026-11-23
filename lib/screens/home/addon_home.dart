import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/layout.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/catalog/meta_addons.dart';
import '../../data/catalog/tmdb.dart';
import '../../data/sources/addons.dart';
import '../../dpad/dpad_reveal.dart';
import '../../widgets/common.dart';
import '../../widgets/media_rows.dart';
import '../profile/profile_page.dart';

/// For a page that follows your addons (Settings > Addons): when they change while a frame is
/// being built (the list is first read by a page that is being built), [then] runs after it
/// instead. True: put off.
bool afterBuild(VoidCallback then) {
  if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) return false;
  WidgetsBinding.instance.addPostFrameCallback((_) => then());
  return true;
}

/// Your metadata addons on Home: each addon's first catalogs as rows and the rest as collection
/// cards (the genre cards' look), in your order in Settings > Addons. With TMDB off, the hero and
/// the genre cards come from them too.
abstract final class AddonHome {
  /// How many of an addon's catalogs are rows; the rest are collection cards.
  static const rows = 5;

  /// [a]'s catalogs that are rows on Home, and those that are cards (a catalog that needs a
  /// genre picked is a card: it opens on its first genre).
  static (List<CatalogRef>, List<CatalogRef>) split(Addon a) {
    final board = [for (final c in a.catalogs) if (c.board) CatalogRef(a, c)];
    final more = [for (final c in a.catalogs) if (!c.board && c.browsable) CatalogRef(a, c)];
    return (board.take(rows).toList(), [...board.skip(rows), ...more]);
  }

  /// The hero's titles with TMDB off: those of your first catalogs that have a backdrop.
  static Future<List<Media>> hero() async {
    final refs = [for (final r in MetaAddons.catalogs) if (r.catalog.board) r].take(3);
    var art = <Media>[];
    Object? error;
    for (final r in refs) {
      try {
        art = [...art, ...(await MetaAddons.page(r.addon, r.catalog)).where((m) => m.backdropPath != null && !art.any((x) => x.key == m.key))];
        if (art.length >= 8) break;
      } catch (e) {
        error = e;
      }
    }
    if (art.isEmpty && error != null) throw error;
    return art;
  }

  /// The catalog the genre cards come from with TMDB off: the first one that lists by genre.
  static CatalogRef? get genreSource => [for (final r in MetaAddons.catalogs) if (r.catalog.board && r.catalog.genres.isNotEmpty) r].firstOrNull;
}

/// A catalog's heading: its name and what it lists, then the addon's name, quieter.
class CatalogTitle extends StatelessWidget {
  const CatalogTitle({super.key, required this.ref});
  final CatalogRef ref;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(child: Text(ref.title, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
      const SizedBox(width: 10),
      Text(
        ref.addon.name,
        maxLines: 1,
        softWrap: false,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, letterSpacing: 0, color: VyseColors.textFaint),
      ),
    ],
  );
}

/// The end of a catalog's row: the whole catalog on Discover.
class _SeeAll {
  const _SeeAll();
}

/// The size of a card for a catalog whose pictures are [shape] (`posterShape`: poster, square
/// or landscape), from the width of a poster card.
(double, double) cardSize(String shape, double posterWidth) => switch (shape) {
  'landscape' => (posterWidth * 1.85, posterWidth * 1.85 * 9 / 16),
  'square' => (posterWidth * 1.15, posterWidth * 1.15),
  _ => (posterWidth, posterWidth * 1.5),
};

/// One catalog as a row of cards in its pictures' shape, ending in a card that opens all of it.
class CatalogShelf extends StatefulWidget {
  const CatalogShelf({super.key, required this.ref, required this.posterWidth});
  final CatalogRef ref;
  final double posterWidth;

  @override
  State<CatalogShelf> createState() => _CatalogShelfState();
}

class _CatalogShelfState extends State<CatalogShelf> {
  /// Posters until the first page says otherwise (a channel addon's square logos, say).
  late String _shape = MetaAddons.shapeOf(widget.ref);

  // (one that brings nothing back, or fails, isn't shown)
  @override
  Widget build(BuildContext context) {
    final ref = widget.ref;
    final (w, h) = cardSize(_shape, widget.posterWidth);
    return Shelf<Object>(
      title: ref.title,
      titleWidget: CatalogTitle(ref: ref),
      hideOnError: true,
      load: () async {
        final l = await MetaAddons.page(ref.addon, ref.catalog);
        final shape = MetaAddons.shapeOf(ref);
        if (shape != _shape) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _shape = shape);
          });
        }
        return l.isEmpty ? const <Object>[] : <Object>[...l.take(19), const _SeeAll()];
      },
      itemWidth: w,
      itemHeight: h,
      itemBuilder: (_, item, _) => switch (item) {
        final Media m => PosterCard(media: m, heroTag: 'home/${ref.key}/${m.key}'),
        _ => _SeeAllCard(onTap: () => openCatalog(context, ref)),
      },
    );
  }
}

class _SeeAllCard extends StatelessWidget {
  const _SeeAllCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlineCard(
    label: 'See all',
    onTap: onTap,
    builder: (hovered) => ColoredBox(
      color: hovered ? VyseColors.surfaceHi : const Color(0xFF0D0F18),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.arrow_forward_rounded, size: 26, color: hovered ? VyseColors.text : VyseColors.textDim),
          const SizedBox(height: 8),
          Text('See all', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: hovered ? VyseColors.text : VyseColors.textDim)),
        ],
      ),
    ),
  );
}

/// One metadata addon on Home: its first catalogs as rows, the rest as collection cards.
class AddonSection extends StatelessWidget {
  const AddonSection({super.key, required this.addon, required this.posterWidth});
  final Addon addon;
  final double posterWidth;

  @override
  Widget build(BuildContext context) {
    final (rows, cards) = AddonHome.split(addon);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in rows) CatalogShelf(key: ValueKey('catalog/${r.key}'), ref: r, posterWidth: posterWidth),
        if (cards.isNotEmpty)
          FanGrid(
            key: ValueKey('collections/${addon.manifestUrl}'),
            title: 'More from ${addon.name}',
            tiles: [for (final r in cards) CollectionTile(key: ValueKey(r.key), ref: r)],
          ),
      ],
    );
  }
}

/// A catalog as a card: three of its posters fanned over its name. Opens it on Discover (on its
/// first genre, for one that lists a genre at a time).
class CollectionTile extends StatelessWidget {
  const CollectionTile({super.key, required this.ref});
  final CatalogRef ref;

  String? get _genre => ref.catalog.genreRequired ? ref.catalog.genres.firstOrNull : null;

  @override
  Widget build(BuildContext context) => FanTile(
    label: _genre == null ? ref.title : '${ref.title} · $_genre',
    load: () => MetaAddons.page(ref.addon, ref.catalog, genre: _genre),
    onTap: () => openCatalog(context, ref, genre: _genre),
  );
}

/// With TMDB off: the genre cards, from the first of your catalogs that lists by genre.
class AddonGenreGrid extends StatelessWidget {
  const AddonGenreGrid({super.key});

  @override
  Widget build(BuildContext context) {
    final ref = AddonHome.genreSource;
    if (ref == null) return const SizedBox.shrink();
    final genres = ref.catalog.genres.take(FanGrid.columns(context) * 2);
    return FanGrid(
      key: ValueKey('genres/${ref.key}'),
      title: 'Explore genres',
      tiles: [
        for (final g in genres)
          FanTile(
            key: ValueKey('${ref.key}/$g'),
            label: g,
            load: () => MetaAddons.page(ref.addon, ref.catalog, genre: g),
            onTap: () => openCatalog(context, ref, genre: g),
          ),
      ],
    );
  }
}

/// TMDB is off and no metadata addon is on: nothing to browse, and where to fix that.
class NoMetadata extends StatelessWidget {
  const NoMetadata({super.key, this.compact = false, this.message = 'TMDB is off and no metadata addon is on. Turn one on in Settings > Addons.'});
  final bool compact;
  final String message;

  @override
  Widget build(BuildContext context) => DpadRevealBlock(
    child: Padding(
      padding: EdgeInsets.fromLTRB(Layout.inset(context), compact ? 20 : 60, Layout.isPhone(context) ? 16 : 40, compact ? 20 : 60),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: .05)),
            child: const Icon(Icons.extension_outlined, size: 28, color: VyseColors.textDim),
          ),
          const SizedBox(height: 16),
          const Text('Nothing to browse', textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: VyseColors.textDim, fontSize: 13),
          ),
          const SizedBox(height: 18),
          Pressable(
            onTap: () => unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProfilePage(addons: true)))),
            builder: (context, hovered, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: hovered ? Colors.white : const Color(0xFFF1F1F5),
              ),
              child: const Text('Open Addons', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          ),
        ],
      ),
    ),
  );
}
