// VyseTV addition (not in upstream).
//
// Bringing the focused control into view. Upstream's FocusableWrapper scrolls the nearest
// vertical list and leaves rows to its own row widgets; VyseTV's rows are plain horizontal
// lists, and its pages run under a window bar, a navbar and sometimes a player bar. So this
// walks every list the control sits in, innermost first, and moves each just enough:
//
// - up and down, the control (or the block it belongs to, see [DpadRevealBlock]) is brought to
//   the middle of what can be seen, so there is always something visible above and below;
// - sideways, a row moves only as far as it must;
// - "what can be seen" is the list's own box minus what the app's furniture covers
//   ([DpadInsets]), so nothing comes to rest under a bar.
//
// It never uses Scrollable.ensureVisible: that jumps every list at once (upstream's note: it
// drags neighbouring views out of place).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'focus_theme.dart';

/// What the app's own furniture covers at each edge of the window: the window bar at the top,
/// the navbar at the left or the bottom, a player bar. Whoever draws that furniture (the shell)
/// puts this above the pages; with none, the whole window counts as visible.
class DpadInsets extends InheritedWidget {
  const DpadInsets({super.key, required this.insets, required super.child});

  final EdgeInsets insets;

  /// Read when focus moves, not while building: the caller does not rebuild when it changes.
  static EdgeInsets of(BuildContext context) => context.getInheritedWidgetOfExactType<DpadInsets>()?.insets ?? EdgeInsets.zero;

  @override
  bool updateShouldNotify(DpadInsets oldWidget) => oldWidget.insets != insets;
}

/// A block that comes into view as a whole when focus lands anywhere inside it: a row with its
/// heading, a card with its caption. Only for moving up and down; a block taller than what can
/// be seen is ignored and the control itself is used.
class DpadRevealBlock extends StatelessWidget {
  const DpadRevealBlock({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

abstract final class DpadReveal {
  /// Room kept around the control for its ring, glow and growth.
  static const double margin = 12;

  /// A list this close to one of its ends goes all the way there, so a row comes back to rest
  /// exactly where it started and a page shows its heading again.
  static const double snapToEnd = 72;

  /// Focus nodes whose owner reveals them itself (FocusableWrapper does, with its own
  /// settings), so the app-wide fallback leaves them alone.
  static final ownerReveals = Expando<bool>('ownerReveals');

  /// Focus nodes their page starts on (a control built with `autofocus`): where a D-pad
  /// lands when the page opens, ahead of whatever happens to be top-left.
  static final startsPage = Expando<bool>('startsPage');

  /// Focus nodes their page starts on when nothing on it is marked as the start (the
  /// selected tab of a tab strip: the tab's own content may name a better place).
  static final startsPageElse = Expando<bool>('startsPageElse');

  /// Focus nodes their rail is entered on when focus comes into it from across (the showing
  /// tab of a strip of tabs), on a page that starts somewhere else.
  static final entersRail = Expando<bool>('entersRail');

  static Rect? _globalRect(RenderObject? object) {
    if (object is! RenderBox || !object.attached || !object.hasSize) return null;
    return MatrixUtils.transformRect(object.getTransformTo(null), Offset.zero & object.size);
  }

  /// Whether the list drawn by [list] carries [object] (it is drawn inside it). A control shown
  /// in the overlay, as a menu that opens in place is, sits below its page's lists in the widget
  /// tree but is not drawn inside them: scrolling them would not bring it into view, and a menu
  /// closes when its page scrolls.
  static bool _carries(RenderObject? list, RenderObject? object) {
    for (RenderObject? r = object; r != null; r = r.parent) {
      if (identical(r, list)) return true;
    }
    return false;
  }

  static Rect _window(BuildContext context) {
    final view = View.maybeOf(context);
    if (view == null) return Rect.largest;
    final size = view.physicalSize / view.devicePixelRatio;
    return DpadInsets.of(context).deflateRect(Offset.zero & size);
  }

  /// The part of the window in which a control at [context] can be seen in full: inside every
  /// list it scrolls in, and clear of the app's furniture. Tests use it to check rule R4.
  static Rect visibleArea(BuildContext context) {
    final object = context.findRenderObject();
    var area = _window(context);
    var scrollable = Scrollable.maybeOf(context);
    while (scrollable != null) {
      final list = scrollable.context.findRenderObject();
      final box = _globalRect(list);
      if (box != null && _carries(list, object)) area = area.intersect(box);
      scrollable = Scrollable.maybeOf(scrollable.context);
    }
    return area;
  }

  /// Scrolls whatever needs scrolling so the control at [context] can be seen in full.
  ///
  /// [alignment] is where it should sit between the top (0) and the bottom (1) of what can be
  /// seen. With [comfortable], a control already in the middle 60% is left where it is.
  static void reveal(BuildContext context, {double alignment = 0.5, bool comfortable = false}) {
    if (!context.mounted) return;
    final object = context.findRenderObject();
    var item = _globalRect(object);
    if (item == null) return;
    final window = _window(context);

    Element? blockElement;
    context.visitAncestorElements((element) {
      if (element.widget is DpadRevealBlock) {
        blockElement = element;
        return false;
      }
      return true;
    });
    var block = _globalRect(blockElement?.findRenderObject());

    var scrollable = Scrollable.maybeOf(context);
    while (scrollable != null) {
      final position = scrollable.position;
      final list = scrollable.context.findRenderObject();
      final box = _globalRect(list);
      if (box != null && _carries(list, object) && position.hasContentDimensions && position.maxScrollExtent.isFinite && position.maxScrollExtent > position.minScrollExtent) {
        final seen = box.intersect(window);
        final vertical = position.axis == Axis.vertical;
        double delta;
        if (vertical) {
          // the block, when it is this list that scrolls it and it fits
          final inThisList = blockElement != null && Scrollable.maybeOf(blockElement!) == scrollable;
          final target = inThisList && block != null && block.height + margin * 2 <= seen.height ? block : item!;
          delta = _towards(target.top, target.bottom, seen.top, seen.bottom, alignment, comfortable);
        } else {
          delta = _justEnough(item!.left, item.right, seen.left, seen.right);
        }
        if (axisDirectionIsReversed(position.axisDirection)) delta = -delta;

        var to = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
        // nearly back at an end, and heading for it: go all the way
        if (to < position.pixels && to - position.minScrollExtent < snapToEnd) to = position.minScrollExtent;
        if (to > position.pixels && position.maxScrollExtent - to < snapToEnd) to = position.maxScrollExtent;
        final moved = to - position.pixels;
        if (moved.abs() > 0.5) {
          position.animateTo(
            to,
            duration: vertical ? const Duration(milliseconds: 200) : FocusTheme.navigationScrollDuration(),
            curve: Curves.easeOutCubic,
          );
          // where things will be once this list has moved, for the lists outside it
          final shift = axisDirectionIsReversed(position.axisDirection) ? moved : -moved;
          final by = vertical ? Offset(0, shift) : Offset(shift, 0);
          item = item!.shift(by);
          block = block?.shift(by);
        }
      }
      scrollable = Scrollable.maybeOf(scrollable.context);
    }
  }

  /// How far to scroll so [lo]..[hi] sits at [alignment] within [from]..[to]; nothing when it
  /// is close enough already (moving sideways along a row must not nudge the page).
  static double _towards(double lo, double hi, double from, double to, double alignment, bool comfortable) {
    final size = hi - lo, room = to - from;
    final inView = lo >= from + margin && hi <= to - margin;
    if (size + margin * 2 > room) return _justEnough(lo, hi, from, to);
    if (comfortable && lo >= from + room * 0.2 && hi <= to - room * 0.2) return 0;
    final delta = lo - (from + (room - size) * alignment);
    if (inView && delta.abs() < math.max(size / 2, margin)) return 0;
    return delta;
  }

  /// The least scrolling that puts [lo]..[hi], and the room around it, inside [from]..[to].
  static double _justEnough(double lo, double hi, double from, double to) {
    final a = lo - margin, b = hi + margin;
    if (b - a > to - from) return a - from; // too big to fit: show where it starts
    if (a < from) return a - from;
    if (b > to) return b - to;
    return 0;
  }
}
