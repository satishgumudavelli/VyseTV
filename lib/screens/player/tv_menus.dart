import 'package:flutter/material.dart';

import 'dart:math' as math;

import '../../core/theme.dart';
import '../../dpad/dpad_traversal.dart';
import '../../widgets/common.dart' show EdgeFade;
import 'player_menus.dart' show MenuInk, MenuScroll;

/// A TV's player menus.
///
/// On a TV a menu is the whole screen. The picture stays where it is and shows through a shade
/// that is darkest at the left, and the menu stands on the bottom left as columns side by side:
/// languages, then that language's subtitles, then how they look. Left and Right go between the
/// columns, Up and Down along one, Back closes the menu. (It was a panel down the right edge
/// with a list of menus to go through first; the user asked for menus like NuvioTV's, whose
/// subtitle menu this follows.)
///
/// These are the parts every menu is made of: the shade ([TvMenuShade]), the frame that holds
/// the title and the columns ([TvMenuFrame]), a column ([TvRail]) and a few of them side by
/// side ([TvRails]). What goes in the columns is the menus' own rows (MenuRow and its kin), the
/// same ones the desktop's card and a phone's sheet are made of.

/// Told to everything inside a TV menu: that it is in one, and whether the menu starts in
/// this part of it (a screen of several menus opens with the ring in the one that was asked
/// for: Settings opened from Speed starts on the speed in use).
class TvMenuScope extends InheritedWidget {
  const TvMenuScope({super.key, this.start = true, required super.child});

  /// Whether rows here may be where the menu starts.
  final bool start;

  static TvMenuScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TvMenuScope>();

  /// Whether [context] is inside a TV menu.
  static bool isIn(BuildContext context) => maybeOf(context) != null;

  @override
  bool updateShouldNotify(TvMenuScope old) => old.start != start;
}

/// The shade a TV menu stands on: the picture shows through, most of all at the right.
///
/// One layer, drawn once (a TV pays for every see-through layer the size of its screen, see
/// core/lean.dart): black at 92% under the first column, about two thirds in the middle of the
/// screen and 42% at the far edge, which is NuvioTV's shade (a gradient from the left over a
/// flat tint) folded into one.
class TvMenuShade extends StatelessWidget {
  const TvMenuShade({super.key});

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [Color(0xEB000000), Color(0xD1000000), Color(0xA8000000), Color(0x6B000000)],
        stops: [0, .3, .62, 1],
      ),
    ),
  );
}

/// A TV menu's screen: the shade over the picture, and [child] on it. A click on the menu's own
/// background goes no further (it would reach the picture behind, where a click closes menus);
/// there is nothing there to press.
class TvMenuScreen extends StatelessWidget {
  const TvMenuScreen({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const TvMenuShade(),
      Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {}, child: child)),
    ],
  );
}

/// A TV menu's title and its columns, standing on the bottom left of the screen.
class TvMenuFrame extends StatelessWidget {
  const TvMenuFrame({super.key, required this.title, this.detail, required this.child});

  /// The menu's name ("Subtitles").
  final String title;

  /// What it has in use, beside its name ("English").
  final String? detail;

  /// The columns: a [TvRail], or [TvRails].
  final Widget child;

  /// How far the menu keeps from the screen's edges (a TV may cut its picture's edge off). More
  /// at the bottom: that strip is where the film's subtitles are, and they show through.
  static const edge = EdgeInsets.fromLTRB(48, 28, 48, 72);

  @override
  Widget build(BuildContext context) {
    final detail = this.detail?.trim() ?? '';
    return Padding(
      padding: edge + MediaQuery.paddingOf(context),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 13, bottom: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(title, style: const TextStyle(fontSize: 26, height: 1.1, fontWeight: FontWeight.w800, letterSpacing: -.6, color: MenuInk.title)),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(width: 14),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: MenuInk.dim)),
                    ),
                  ],
                ],
              ),
            ),
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}

/// Columns side by side, their tops level.
class TvRails extends StatelessWidget {
  const TvRails(this.rails, {super.key});
  final List<Widget> rails;

  /// The space between two columns.
  static const gap = 14.0;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < rails.length; i++) ...[
        if (i > 0) const SizedBox(width: gap),
        rails[i],
      ],
    ],
  );
}

/// One column of a TV menu: its name, and under it a list that scrolls when it is taller than
/// the room it has. To a D-pad it is a column of like things (a [DpadRail] running up and
/// down): Left or Right from any row goes to the column beside it, onto the row that column
/// marks (the choice in use).
class TvRail extends StatelessWidget {
  const TvRail({super.key, required this.title, required this.width, required this.children, this.count})
    : itemCount = null,
      itemBuilder = null,
      itemExtent = null,
      startAt = 0;

  /// A column of many rows of one height (a long season's episodes: an anime's can run to
  /// hundreds, each with a picture). Only the rows on screen are built, and it opens with row
  /// [startAt] at its top.
  const TvRail.lazy({
    super.key,
    required this.title,
    required this.width,
    required int this.itemCount,
    required NullableIndexedWidgetBuilder this.itemBuilder,
    required double this.itemExtent,
    this.startAt = 0,
    this.count,
  }) : children = const [];

  final String title;
  final double width;
  final List<Widget> children;
  final int? itemCount;
  final NullableIndexedWidgetBuilder? itemBuilder;
  final double? itemExtent;
  final int startAt;

  /// How many it holds, beside its name.
  final int? count;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 0, 12, 6),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.3, color: MenuInk.faint),
                ),
              ),
              if (count != null) ...[const SizedBox(width: 8), TvCount(count!)],
            ],
          ),
        ),
        Flexible(
          child: DpadRail(
            axis: Axis.vertical,
            child: itemBuilder == null
                ? MenuScroll(padding: const EdgeInsets.fromLTRB(0, 0, 0, 10), children: children)
                : _LazyRows(count: itemCount!, extent: itemExtent!, startAt: startAt, builder: itemBuilder!),
          ),
        ),
      ],
    ),
  );
}

/// [TvRail.lazy]'s list.
class _LazyRows extends StatefulWidget {
  const _LazyRows({required this.count, required this.extent, required this.startAt, required this.builder});
  final int count;
  final double extent;
  final int startAt;
  final NullableIndexedWidgetBuilder builder;

  @override
  State<_LazyRows> createState() => _LazyRowsState();
}

class _LazyRowsState extends State<_LazyRows> {
  // (in place before the first row is built, so the rows built first are the ones wanted)
  late final _scroll = ScrollController(initialScrollOffset: math.max(0, widget.startAt) * widget.extent);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EdgeFade(
    // (the same soft edges as MenuScroll's)
    shader: (r) => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: const [Color(0x00FFFFFF), Colors.white, Colors.white, Color(0x00FFFFFF)],
      stops: [0, math.min(.2, 8 / r.height), math.max(.8, 1 - 20 / r.height), 1],
    ).createShader(r),
    child: ListView.builder(
      controller: _scroll,
      shrinkWrap: true, // as tall as its rows, up to the room there is
      padding: const EdgeInsets.only(bottom: 10),
      itemExtent: widget.extent,
      itemCount: widget.count,
      itemBuilder: widget.builder,
    ),
  );
}

/// A count in a small pill: how many subtitles a language has, how many links a source.
class TvCount extends StatelessWidget {
  const TvCount(this.count, {super.key, this.lit = false});
  final int count;

  /// On the row in use.
  final bool lit;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
    decoration: BoxDecoration(
      color: lit ? VyseColors.accent.withValues(alpha: .22) : const Color(0x1FFFFFFF),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      '$count',
      style: TextStyle(fontSize: 10.5, height: 1.35, fontWeight: FontWeight.w700, color: lit ? VyseColors.accent : MenuInk.dim, fontFeatures: const [FontFeature.tabularFigures()]),
    ),
  );
}

/// A line of plain words in a column: nothing here yet, or why.
class TvNote extends StatelessWidget {
  const TvNote(this.text, {super.key, this.busy = false});
  final String text;

  /// Still looking: a small spinner before the words.
  final bool busy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(13, 8, 12, 10),
    child: Row(
      children: [
        if (busy) ...[
          const SizedBox.square(dimension: 13, child: CircularProgressIndicator(strokeWidth: 1.6, color: MenuInk.body)),
          const SizedBox(width: 11),
        ],
        Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.35, color: MenuInk.dim))),
      ],
    ),
  );
}
