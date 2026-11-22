// VyseTV addition (not in upstream).
//
// Where an arrow key takes focus. Upstream wires this per screen (a callback on each card for
// "up", locked rows that step an index, a controller per hub); VyseTV has one rule set, used
// by every page, and three small widgets that tell it about the page's structure:
//
// - [DpadRegion]: an area arrows cannot wander out of (the navbar, the page, a dialog). The
//   only way out is an exit the region names. A region remembers what was focused in it.
// - [DpadRail]: a row (or a column) of like things. Along it, focus never leaves it for
//   something that merely happens to be nearby; coming back to it lands where you were.
// - A control inside another control (the buttons on a list row): Right from the row steps
//   into them, Left steps back out, and Up or Down keeps to the same button on the next row.
//
// Between those, the choice is by position, the way Android TV does it (its FocusFinder:
// what lies in the beam of the focused control wins, then the nearest), with one tightening:
// a sideways move never jumps to another line. A column of like things (a [DpadRail] that
// runs up and down: a list of seasons, of chapters) is the way across that: sideways from any
// of its items, with nothing in line, focus goes to whatever is beside the column as a whole,
// and into a column on the item it marks (the season showing).
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';

import 'dpad_reveal.dart';
import 'focus_navigation_intent.dart';
import 'input_mode_tracker.dart';

/// What is asked of a region when focus runs off one of its edges. True: dealt with.
typedef DpadExit = bool Function(TraversalDirection direction);

/// The focus scope of a [DpadRegion]: an ordinary scope that also knows its exits.
class DpadRegionNode extends FocusScopeNode {
  DpadRegionNode({super.debugLabel, this.onExit});

  DpadExit? onExit;
}

/// An area arrows stay inside. See the top of this file.
class DpadRegion extends StatelessWidget {
  const DpadRegion({super.key, required this.node, required this.child});

  /// Owned by whoever builds the region, so it can send focus here (`node.requestFocus()`
  /// goes back to what was last focused inside) and set [DpadRegionNode.onExit].
  final DpadRegionNode node;
  final Widget child;

  @override
  Widget build(BuildContext context) => FocusScope(node: node, child: child);
}

/// A row or column of like things. See the top of this file.
class DpadRail extends StatefulWidget {
  const DpadRail({super.key, this.axis = Axis.horizontal, this.onEdge, required this.child});

  final Axis axis;

  /// Focus ran off an end of the rail (for a row: Left at its first item, Right at its last).
  /// True: dealt with. Otherwise the region's exit is asked, and failing that focus stays.
  final DpadExit? onEdge;
  final Widget child;

  @override
  State<DpadRail> createState() => DpadRailState();
}

class DpadRailState extends State<DpadRail> {
  /// The item last focused in this rail.
  FocusNode? remembered;

  /// The control focus was on when it last came into this rail from beside it: where a
  /// sideways move off the rail returns to when nothing is in line with the item left.
  FocusNode? enteredFrom;

  @override
  Widget build(BuildContext context) => _RailMarker(rail: this, child: widget.child);
}

class _RailMarker extends InheritedWidget {
  const _RailMarker({required this.rail, required super.child});
  final DpadRailState rail;

  @override
  bool updateShouldNotify(_RailMarker oldWidget) => false;
}

/// Everything the rules need to know about one control.
class _Stop {
  _Stop(this.node) : rect = node.rect;
  final FocusNode node;
  final Rect rect;

  DpadRailState? get rail {
    final found = node.context?.getInheritedWidgetOfExactType<_RailMarker>()?.rail;
    return found != null && found.mounted ? found : null;
  }
}

/// Marks the control inside it as where its page starts, for a control that is not a
/// `Pressable` (a Material button): `DpadStart(child: IconButton(...))`. A `Pressable` says
/// the same with `autofocus: true`. It is only a mark: nothing takes focus by itself.
class DpadStart extends StatefulWidget {
  const DpadStart({super.key, this.start = true, required this.child});
  final bool start;
  final Widget child;

  @override
  State<DpadStart> createState() => _DpadStartState();
}

class _DpadStartState extends State<DpadStart> {
  final _mark = FocusNode(debugLabel: 'start', canRequestFocus: false, skipTraversal: true);

  @override
  void initState() {
    super.initState();
    DpadReveal.startsPage[_mark] = widget.start;
  }

  @override
  void didUpdateWidget(DpadStart old) {
    super.didUpdateWidget(old);
    DpadReveal.startsPage[_mark] = widget.start;
  }

  @override
  void dispose() {
    _mark.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(focusNode: _mark, canRequestFocus: false, skipTraversal: true, child: widget.child);
}

/// Marks what it wraps as standing in for something still loading: a shimmer where a row, a
/// picture or the top of a page will be (the app's `Shimmer` puts one round itself). While one
/// is in view and nothing in view can take focus, a first focus nobody chose waits for the page
/// instead of going to a control further down it: a TV starting on a slow network sent the ring
/// to the genres near the foot of Home, and the page scrolled down after it.
class DpadLoading extends StatefulWidget {
  const DpadLoading({super.key, required this.child});
  final Widget child;

  @override
  State<DpadLoading> createState() => _DpadLoadingState();
}

class _DpadLoadingState extends State<DpadLoading> {
  static final live = <_DpadLoadingState>{};

  @override
  void initState() {
    super.initState();
    live.add(this);
  }

  @override
  void dispose() {
    live.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

abstract final class Dpad {
  /// Whether [node] is something focus rests on: one of the app's controls, or a control
  /// with nothing focusable inside it (a Material button, a text box). A scope, or a key
  /// handler wrapped round a whole page, is not.
  static bool isStop(FocusNode? node) {
    // (a node its owner keeps, like a navbar entry's, outlives the widget: a lazy list throws
    // the widget away and the node is left pointing at nothing)
    if (node == null || !(node.context?.mounted ?? false) || node.parent == null) return false;
    if (node is FocusScopeNode || node.skipTraversal || !node.canRequestFocus) return false;
    if (DpadReveal.ownerReveals[node] ?? false) return true;
    return node.traversalDescendants.isEmpty;
  }

  /// Whether focus may rest on [node]: a stop, or a surface that uses the arrows itself (the
  /// picture in a player, which seeks with them; see [DirectionalShortcutFocusNode]). A
  /// surface draws no ring and arrows never travel to it; it is only somewhere focus can be.
  static bool isRest(FocusNode? node) =>
      isStop(node) || (node is DirectionalShortcutFocusNode && (node.context?.mounted ?? false) && node.parent != null && node.canRequestFocus);

  /// The stops arrows can reach from inside [scope]: those whose nearest scope it is.
  static Iterable<FocusNode> stopsIn(FocusScopeNode scope) => scope.traversalDescendants.where((n) => identical(n.nearestScope, scope) && isStop(n) && !n.rect.isEmpty);

  /// Every stop under [scope], in the scopes inside it too. For choosing a first focus.
  static Iterable<FocusNode> stopsUnder(FocusScopeNode scope) => scope.traversalDescendants.where((n) => isStop(n) && !n.rect.isEmpty);

  /// The stop a page starts on when nothing says otherwise: the top-most, then left-most,
  /// that is on screen.
  static FocusNode? firstStop(FocusScopeNode scope, {Rect? window, bool Function(FocusNode stop)? where}) {
    // where the page says it starts (a control built with autofocus), if it does; else where
    // it says to start when nothing else does (its selected tab); else its top-left control
    final all = [for (final n in stopsUnder(scope)) if (where == null || where(n)) n];
    // (a mark may sit on the control itself or on a DpadStart wrapped round it)
    bool marked(FocusNode n, Expando<bool> marks) => (marks[n] ?? false) || n.ancestors.takeWhile((a) => !identical(a, scope)).any((a) => !isStop(a) && (marks[a] ?? false));
    return _topLeft(all.where((n) => marked(n, DpadReveal.startsPage)), scope, window) ??
        _topLeft(all.where((n) => marked(n, DpadReveal.startsPageElse)), scope, window) ??
        _topLeft(all, scope, window);
  }

  /// The window [node] is drawn in, in logical pixels. Null when it is not on screen.
  static Rect? windowOf(FocusNode node) {
    final context = node.context;
    final view = context == null || !context.mounted ? null : View.maybeOf(context);
    return view == null ? null : Offset.zero & (view.physicalSize / view.devicePixelRatio);
  }

  /// Whether something under [scope] is still loading where it can be seen: a placeholder
  /// ([DpadLoading]) inside [window].
  static bool loadingInView(FocusScopeNode scope, Rect window) {
    final top = scope.context;
    if (top is! Element || !top.mounted) return false;
    for (final p in _DpadLoadingState.live) {
      if (!p.mounted) continue;
      final box = p.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final rect = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
      if (rect.isEmpty || !window.overlaps(rect)) continue;
      var under = false;
      p.context.visitAncestorElements((e) {
        under = identical(e, top);
        return !under;
      });
      if (under) return true;
    }
    return false;
  }

  /// Where to start in [scope] when focus is put there with nothing chosen (a region entered,
  /// an arrow pressed with focus on nothing): [firstStop], except that while something in view
  /// is still loading only what is in view counts. Null then means: wait for the page.
  static FocusNode? firstShown(FocusScopeNode scope) {
    final window = windowOf(scope);
    if (window != null && loadingInView(scope, window)) return firstStop(scope, window: window);
    return firstStop(scope);
  }

  static FocusNode? _topLeft(Iterable<FocusNode> stops, FocusScopeNode scope, Rect? window) {
    FocusNode? best;
    for (final n in stops) {
      final r = n.rect;
      if (window != null && !window.overlaps(r)) continue;
      // a button on a card or a row is reached from the card: never where a page starts
      if (n.ancestors.takeWhile((a) => !identical(a, scope)).any(isStop)) continue;
      if (best == null) {
        best = n;
        continue;
      }
      final b = best.rect;
      // "the same line" has some give: buttons in one row are rarely pixel-aligned
      final sameLine = (r.top - b.top).abs() < math.min(r.height, b.height) / 2;
      if (sameLine ? r.left < b.left : r.top < b.top) best = n;
    }
    return best;
  }

  // ── A first focus nobody chose ──
  //
  // When a page or a menu opens, focus is put on the best stop there is at that moment. If
  // what it shows is still loading, that is often a Close or a Back button, and the control
  // the page says it starts on (`autofocus: true`) turns up a moment later. Until a key is
  // pressed the first choice is only provisional: it gives way to the start when that arrives.
  static FocusNode? _provisional;

  /// [node] was given focus by the app, not by a key: [enter] and DpadRoot's healer say so.
  static void placedFirst(FocusNode? node) => _provisional = node == null || (DpadReveal.startsPage[node] ?? false) ? null : node;

  /// A key was pressed: wherever focus is now, it is the viewer's.
  static void keyPressed() {
    _provisional = null;
    presses++;
  }

  /// How many keys have been pressed (to tell whether the viewer did anything in between).
  static int presses = 0;

  /// A control its page starts on has come on screen (FocusableWrapper calls this).
  static void startArrived(FocusNode start) {
    final held = _provisional;
    if (held == null) return;
    if (!held.hasPrimaryFocus) {
      _provisional = null;
      return;
    }
    final scope = held.nearestScope;
    if (scope == null || !isStop(start) || !start.ancestors.contains(scope)) return;
    // (a start inside another control, the Play button of a player's tile, is where stepping
    // into that control lands: never where its page starts)
    if (start.ancestors.takeWhile((a) => !identical(a, scope)).any(isStop)) return;
    _provisional = null;
    start.requestFocus();
  }

  /// Whether [node] is the start of the control it sits inside ([within]): marked itself, or
  /// through a DpadStart wrapped round it.
  static bool _startsWithin(FocusNode node, FocusNode within) =>
      (DpadReveal.startsPage[node] ?? false) || node.ancestors.takeWhile((a) => !identical(a, within)).any((a) => !isStop(a) && (DpadReveal.startsPage[a] ?? false));

  /// A control has come on screen (FocusableWrapper calls this). While the first focus nobody
  /// chose is still provisional, where the page starts is looked for again once the frame is
  /// done: the top of a page often arrives after the rest (on a TV the app is in D-pad mode
  /// before Home has loaded its hero, while Continue watching, which is on the device, is
  /// there at once), and the start is the page's top-left control or the one it marks.
  static void stopArrived(FocusNode node) {
    if (_provisional == null || _recheck) return;
    _recheck = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recheck = false;
      final held = _provisional;
      if (held == null || InputModeTracker.currentMode != InputMode.keyboard) return;
      if (!held.hasPrimaryFocus) {
        _provisional = null;
        return;
      }
      final scope = held.nearestScope;
      final first = scope == null ? null : firstStop(scope);
      if (first == null || identical(first, held)) return;
      giveFocus(first);
      placedFirst(first); // (still provisional, unless the page marks it as its start)
    });
  }

  static bool _recheck = false;

  /// The stop nearest to where [was] used to be: for when the focused thing is gone.
  static FocusNode? nearestStop(FocusScopeNode scope, Rect was) {
    FocusNode? best;
    var bestD = double.infinity;
    for (final n in stopsUnder(scope)) {
      final d = (n.rect.center - was.center).distanceSquared;
      if (d < bestD) {
        bestD = d;
        best = n;
      }
    }
    return best;
  }

  /// Sends focus into [scope]: to [prefer] if it can take it, else back to what was last
  /// focused in there, else to its first stop. With nothing in it to focus yet (a page still
  /// loading) the scope itself holds focus and DpadRoot moves it on when something appears.
  /// False when [scope] is not on screen.
  static bool enter(FocusScopeNode scope, {FocusNode? prefer}) {
    // (a region its owner keeps outlives its widget: taken off the screen, it still has the
    // context it had, unmounted, and no parent)
    if (!(scope.context?.mounted ?? false) || scope.parent == null || !scope.canRequestFocus) return false;
    if (prefer != null && isStop(prefer)) {
      giveFocus(prefer);
      return true;
    }
    var inner = scope;
    while (inner.focusedChild is FocusScopeNode && inner.focusedChild!.canRequestFocus) {
      inner = inner.focusedChild! as FocusScopeNode;
    }
    final was = inner.focusedChild;
    if (was != null && isStop(was)) {
      giveFocus(was);
    } else {
      // (a page still loading has nothing in view yet: the scope holds focus until it has)
      final first = firstShown(inner) ?? firstShown(scope);
      giveFocus(first ?? scope);
      placedFirst(first);
    }
    return true;
  }

  /// Moves focus off [node] to whatever is next to it: below, else above, else beside. For
  /// Back in a text box (stop typing, stay on the page). False when it is alone.
  static bool stepOut(FocusNode node) {
    for (final d in const [TraversalDirection.down, TraversalDirection.up, TraversalDirection.right, TraversalDirection.left]) {
      final scope = node.nearestScope;
      final target = scope == null ? null : _target(node, d, scope);
      if (target != null) {
        _focus(target);
        return true;
      }
    }
    return false;
  }

  static bool _isAncestor(FocusNode a, FocusNode of) {
    for (FocusNode? p = of.parent; p != null; p = p.parent) {
      if (identical(p, a)) return true;
    }
    return false;
  }

  /// The control [node] sits inside, if any (a button on a list row sits inside the row).
  static FocusNode? _container(FocusNode node, FocusScopeNode scope) {
    for (FocusNode? p = node.parent; p != null && !identical(p, scope); p = p.parent) {
      if (isStop(p)) return p;
    }
    return null;
  }

  // ── Menus that open in place ──
  //
  // A MenuAnchor's menu (Home's "If you like" title picker, My List's sort) is not a page or a
  // dialog: it opens in the overlay, focus stays on the control that opened it, and an arrow
  // from there went on across the page, which scrolled, and a menu closes when its page
  // scrolls. So, for every such menu: while it is open, an arrow from outside it goes into it
  // (OK on its button leaves focus on the button, a click leaves focus wherever it was); inside
  // it, arrows never leave it; DpadRoot puts focus into it as it opens and back on what opened
  // it when it closes.

  /// The menu [node] is in, if any: the focus scope of a menu that opens in place.
  static FocusScopeNode? menuOf(FocusNode node) {
    for (FocusNode? n = node; n != null; n = n.parent) {
      if (n is FocusScopeNode && isMenu(n)) return n;
    }
    return null;
  }

  /// Whether [scope] is the panel of a menu that opens in place (a MenuAnchor's): a scope arrows
  /// pass over, whose MenuController is not the one the area around it answers to.
  static bool isMenu(FocusScopeNode scope) {
    final context = scope.context;
    if (!scope.skipTraversal || context == null || !context.mounted) return false;
    final controller = MenuController.maybeOf(context);
    if (controller == null) return false;
    final outer = scope.enclosingScope?.context;
    return outer == null || !outer.mounted || !identical(MenuController.maybeOf(outer), controller);
  }

  /// The menu that keys from [from] go into: one that is open in place while focus is outside
  /// it. OK on its button leaves focus on the button; a click leaves focus wherever it was.
  static FocusScopeNode? menuToEnter(FocusNode from) {
    if (menuOf(from) != null) return null;
    for (final n in FocusManager.instance.rootScope.descendants) {
      if (n is FocusScopeNode && n.canRequestFocus && isMenu(n) && (MenuController.maybeOf(n.context!)?.isOpen ?? false)) return n;
    }
    return null;
  }

  /// Where focus came into each menu from, and where that was: it goes back there.
  static final _openers = Expando<(FocusNode, Rect, FocusScopeNode?)>('menu opened from');

  /// Puts focus into [menu] from [from] (the button that opened it, as a rule): on the item it
  /// marks as its start (the choice in use, through DpadStart), else on its first.
  static bool enterMenu(FocusNode from, FocusScopeNode menu) {
    // back to [from] when it closes; when focus was on nothing (a click opened the menu), back
    // to the menu's own button
    var back = isStop(from) ? from : null;
    if (back == null) {
      final controller = MenuController.maybeOf(menu.context!);
      for (final n in FocusManager.instance.rootScope.descendants) {
        if (isStop(n) && menuOf(n) == null && identical(MenuController.maybeOf(n.context!), controller)) {
          back = n;
          break;
        }
      }
    }
    _openers[menu] = back == null ? null : (back, back.rect, back.nearestScope);
    return enter(menu);
  }

  /// Where focus goes when [menu] has closed with focus in it: the control that opened it, or,
  /// when that was built anew (a choice can rebuild what opened the menu: Home's row changes
  /// title), whatever now stands where it stood. Null when nothing there can take focus (the
  /// page is covered by something else).
  static FocusNode? menuReturn(FocusScopeNode menu) {
    final from = _openers[menu];
    if (from == null) return null;
    final (opener, rect, scope) = from;
    if (isStop(opener)) return opener;
    if (scope == null || !(scope.context?.mounted ?? false) || scope.parent == null) return null;
    return nearestStop(scope, rect);
  }

  /// Moves focus from [from] in [direction] by the rules at the top of this file. False when
  /// there was nowhere to go (focus stays put).
  static bool move(FocusNode from, TraversalDirection direction) {
    // a menu is open in place, and focus is not in it yet: the arrow goes into it
    final menu = menuToEnter(from);
    if (menu != null) return enterMenu(from, menu);
    final scope = from.nearestScope;
    if (scope == null) return false;
    final target = _target(from, direction, scope);
    if (target != null) {
      _focus(target);
      return true;
    }
    return _exit(from, direction, scope);
  }

  /// [steps] stops on from [from] in [direction] at once (a held arrow, after a while): as far
  /// as there is to go. With nowhere at all to go it is an ordinary [move].
  static bool moveBy(FocusNode from, TraversalDirection direction, int steps) {
    if (menuToEnter(from) != null) return move(from, direction);
    final scope = from.nearestScope;
    if (scope == null) return false;
    var at = from;
    for (var i = 0; i < steps; i++) {
      final next = _target(at, direction, scope);
      if (next == null) break;
      at = next;
    }
    if (identical(at, from)) return move(from, direction);
    _focus(at);
    return true;
  }

  static void _focus(FocusNode target) {
    final rail = _Stop(target).rail;
    if (rail != null) rail.remembered = target;
    giveFocus(target);
  }

  // ── The on-screen keyboard ──
  //
  // On a phone, a tablet or a TV a text box brings the on-screen keyboard up as it gets focus.
  // Passing over one with the arrows must not: on a TV the keyboard covers the screen and takes
  // the arrows for itself. So when the kit puts focus on a text box in D-pad mode, the box's
  // keyboard token (FocusNode.consumeKeyboardToken) is spent before the box can use it, and
  // OK brings the keyboard up (DpadRoot). A box that opens to be typed in (Search, a name box)
  // still brings it up, as it does with a finger.
  static bool get _softKeyboard => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
  static FocusNode? _quietBox;

  // the control last given focus on purpose (see [giveFocus] and [takeChosen])
  static FocusNode? _chosen;

  /// Whether focus has just been given to [node] on purpose ([giveFocus]): DpadRoot then leaves
  /// it there, rather than handing it to the neighbour of a control that vanished (that stands
  /// in only when Flutter chose where focus went: a side panel going from one of its menus back
  /// to its list put the ring on the menu just left, and it was moved to the row level with the
  /// choice that had gone). Asked once.
  static bool takeChosen(FocusNode? node) {
    final was = node != null && identical(_chosen, node);
    _chosen = null;
    return was;
  }

  // a control about to be given focus by another way than [giveFocus] ([choose]), and since when
  static FocusNode? _coming;
  static DateTime _comingAt = DateTime(2000);

  /// A control marked with [choose] is on its way to focus (for two seconds at most).
  static bool get choosing {
    final c = _coming;
    if (c == null) return false;
    if (c.hasPrimaryFocus || !c.canRequestFocus || !(c.context?.mounted ?? false) || clock.now().difference(_comingAt) > const Duration(seconds: 2)) {
      _coming = null;
      return false;
    }
    return true;
  }

  /// [node] is about to be given focus on purpose by another way than [giveFocus] (a request
  /// held until a covered page is uncovered): heal leaves it alone meanwhile ([choosing]), and
  /// when it lands it counts as given on purpose.
  static void choose(FocusNode node) {
    _chosen = node;
    _coming = node;
    _comingAt = clock.now();
  }

  /// Gives [node] focus as the kit does: a text box gets it with the on-screen keyboard down.
  static void giveFocus(FocusNode node) {
    _chosen = node;
    final editable = _softKeyboard && InputModeTracker.currentMode == InputMode.keyboard ? node.context?.findAncestorStateOfType<EditableTextState>() : null;
    if (editable != null) {
      // (a box whose caret was never placed places it as focus arrives, and that asks for the
      // keyboard as well: so it is placed here first, at the end, where it would have gone)
      final text = editable.widget.controller;
      if (!text.selection.isValid) text.selection = TextSelection.collapsed(offset: text.text.length);
    }
    node.requestFocus();
    if (editable == null) return;
    node.consumeKeyboardToken();
    _quietBox = node;
  }

  /// OK on a text box: its on-screen keyboard. True when that is what OK did (the box had
  /// focus without its keyboard; [force] for any text box, as when the keyboard was put away).
  static bool openKeyboard({bool force = false}) {
    final node = FocusManager.instance.primaryFocus;
    if (!_softKeyboard || node == null) return false;
    if (!force && !identical(node, _quietBox)) return false;
    final editable = node.context?.findAncestorStateOfType<EditableTextState>();
    if (editable == null) return false;
    _quietBox = null;
    editable.requestKeyboard();
    return true;
  }

  /// Notes [node] as its rail's place, however focus got there (a mouse-free jump from code,
  /// a restore). Called for every focus change by DpadRoot.
  static void noteFocused(FocusNode node) {
    if (!isStop(node)) return;
    final rail = _Stop(node).rail;
    if (rail != null) rail.remembered = node;
  }

  static bool _exit(FocusNode from, TraversalDirection direction, FocusScopeNode scope) {
    final rail = _Stop(from).rail;
    final along = rail != null && _isAlong(rail.widget.axis, direction);
    if (along && (rail.widget.onEdge?.call(direction) ?? false)) return true;
    for (FocusScopeNode? s = scope; s != null; s = s.enclosingScope) {
      // a menu has no way out by arrows: it is left by choosing, or by Back
      if (isMenu(s)) return false;
      if (s is DpadRegionNode && (s.onExit?.call(direction) ?? false)) return true;
    }
    return false;
  }

  static bool _isAlong(Axis axis, TraversalDirection d) =>
      axis == Axis.horizontal ? (d == TraversalDirection.left || d == TraversalDirection.right) : (d == TraversalDirection.up || d == TraversalDirection.down);

  static FocusNode? _target(FocusNode from, TraversalDirection direction, FocusScopeNode scope, {bool stepIn = true}) {
    final here = _Stop(from);
    final horizontal = direction == TraversalDirection.left || direction == TraversalDirection.right;
    final all = [for (final n in stopsIn(scope)) if (!identical(n, from)) _Stop(n)];
    final outer = _container(from, scope);
    final rail = here.rail;

    // Into the controls inside this one: Right from a list row steps onto its first button
    // (or onto the one it says it starts on: the Play button of a player's tile).
    if (stepIn && direction == TraversalDirection.right) {
      final inside = [for (final s in all) if (identical(_container(s.node, scope), from)) s];
      if (inside.isNotEmpty) {
        for (final s in inside) {
          if (_startsWithin(s.node, from)) return s.node;
        }
        inside.sort((a, b) => a.rect.left.compareTo(b.rect.left));
        return inside.first.node;
      }
    }

    // Inside a control: sideways among its own, and Left off the first one is back out to it.
    if (outer != null && horizontal) {
      final siblings = [for (final s in all) if (identical(_container(s.node, scope), outer)) s];
      final best = _best(here.rect, siblings, direction, beamOnly: true);
      if (best != null) return best.node;
      if (direction == TraversalDirection.left) return outer;
      // off the last one: carry on from the control we are inside (and not back into it)
      return _target(outer, direction, scope, stepIn: false);
    }

    // Inside a control whose own controls stand on more than one line (a player's tile: its
    // seek bar above its buttons): up and down among its own lines before anything outside.
    if (outer != null) {
      final lines = [for (final s in all) if (identical(_container(s.node, scope), outer) && !_sameLine(here.rect, s.rect, Axis.horizontal)) s];
      final best = _best(here.rect, lines, direction, beamOnly: false);
      if (best != null) return best.node;
    }

    Iterable<_Stop> candidates = all.where((s) => !_isAncestor(from, s.node) && !_isAncestor(s.node, from));
    if (outer != null) {
      // up or down from a button on a row: not onto our own row
      candidates = candidates.where((s) => !identical(s.node, outer) && !_isAncestor(outer, s.node));
    }

    if (rail != null && _isAlong(rail.widget.axis, direction)) {
      // along a rail: its own items first, and never another rail's
      final own = [for (final s in candidates) if (identical(s.rail, rail)) s];
      final best = _best(here.rect, own, direction, beamOnly: false);
      if (best != null) return best.node;
      // off the end of a row: only something truly beside it (in line with this item)
      if (horizontal) {
        final beside = [for (final s in candidates) if (s.rail == null) s];
        return _best(here.rect, beside, direction, beamOnly: true)?.node;
      }
      // Off the top or the foot of a column: on to what is above or below it, found as Up and
      // Down find it from anything else (below), and a row there is entered as any row is.
      // Taking only what was in line left a column of seasons stuck under the tabs over it.
    }

    // Across: leaving this rail (if any). Its other items are not "above" or "below" it,
    // unless the rail has wrapped onto more lines (a row of tabs on a narrow screen): then
    // the items on its other lines are.
    if (rail != null) candidates = candidates.where((s) => !identical(s.rail, rail) || !_sameLine(here.rect, s.rect, rail.widget.axis));

    // From a control inside another, prefer the same kind on the next line (the delete button
    // of the next row), and only then the lines themselves.
    // (Up or Down goes into a list that runs up and down only from its own column: such a
    // list beside us is entered sideways, as a whole, not by being nearest overall. Its column
    // is the list's own box, not just its rows: an anime's episode, a picture with its Play
    // and mark buttons at the right, lies straight under the tabs, and Down from the tabs
    // passed it by because its buttons did not.)
    bool listBeside(_Stop s) =>
        !horizontal &&
        s.rail != null &&
        !identical(s.rail, rail) &&
        _isAlong(s.rail!.widget.axis, direction) &&
        !_beamsOverlap(here.rect, s.rect, direction) &&
        !_beamsOverlap(here.rect, _railBox(s.rail!) ?? s.rect, direction);
    final top = [for (final s in candidates) if (_container(s.node, scope) == null && !listBeside(s)) s];
    final nested = [for (final s in candidates) if (_container(s.node, scope) != null) s];
    _Stop? best;
    if (outer != null && !horizontal) best = _best(here.rect, nested, direction, beamOnly: true);
    best ??= _best(here.rect, top, direction, beamOnly: horizontal);
    // Sideways with nothing in line: a list beside us is entered as a whole. Its rows may all
    // be higher or lower than where we are (a chapter list beside a player's buttons), but
    // the list itself is beside us.
    if (best == null && horizontal) best = _listBeside(here, top, direction, rail);
    // Sideways off a list with nothing in line with this row (the buttons beside a chapter
    // list are all lower than its first rows): back to the control the list was entered
    // from, if that is on this side; else whatever is beside the list as a whole.
    if (best == null && horizontal && rail != null && !_isAlong(rail.widget.axis, direction)) {
      final back = rail.enteredFrom;
      if (back != null && isStop(back) && identical(back.nearestScope, scope) && _isCandidate(here.rect, back.rect, direction)) return back;
      final box = rail.context.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        best = _best(MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size), top, direction, beamOnly: true);
      }
    }
    if (best == null) return null;

    // Arriving in a rail: on the item it marks (a tab strip's selected tab: the one whose
    // content you are coming from), else where you were in it last time, if that is still there.
    final into = best.rail;
    if (into != null && !identical(into, rail) && !_isAlong(into.widget.axis, direction)) {
      into.enteredFrom = from;
      for (final s in top) {
        if (identical(s.rail, into) && ((DpadReveal.startsPageElse[s.node] ?? false) || (DpadReveal.entersRail[s.node] ?? false))) return s.node;
      }
      final was = into.remembered;
      if (was != null && was.context != null && isStop(was) && identical(was.nearestScope, scope)) return was;
    }
    return best.node;
  }

  /// The nearest item of a rail (not [own]) whose whole span lies in line with [from], going
  /// [direction]. Only rails that run across that direction count: a column of rows beside us.
  static _Stop? _listBeside(_Stop from, List<_Stop> stops, TraversalDirection direction, DpadRailState? own) {
    final spans = <DpadRailState, Rect>{};
    for (final s in stops) {
      final r = s.rail;
      if (r == null || identical(r, own) || _isAlong(r.widget.axis, direction) || spans.containsKey(r)) continue;
      // the list's own box (a short list still fills its panel), not just the rows it has
      spans[r] = _railBox(r) ?? s.rect;
    }
    DpadRailState? list;
    // a list level with us first; failing that, one further up or down the page on that side
    // (the tabs of a long settings page, scrolled away above the row we are on)
    for (final level in const [true, false]) {
      for (final e in spans.entries) {
        if (!_isCandidate(from.rect, e.value, direction) || (level && !_beamsOverlap(from.rect, e.value, direction))) continue;
        if (list == null || _isBetter(from.rect, e.value, spans[list]!, direction)) list = e.key;
      }
      if (list != null) break;
    }
    if (list == null) return null;
    _Stop? best;
    var bestD = double.infinity;
    for (final s in stops) {
      if (!identical(s.rail, list)) continue;
      final d = (s.rect.center - from.rect.center).distanceSquared;
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    return best;
  }

  /// Where [rail]'s own box is on screen. Null while it has no size.
  static Rect? _railBox(DpadRailState rail) {
    final box = rail.context.findRenderObject();
    return box is RenderBox && box.hasSize && box.attached ? MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size) : null;
  }

  /// Whether [a] and [b] sit on one line of a rail that runs along [axis].
  static bool _sameLine(Rect a, Rect b, Axis axis) {
    final overlap = axis == Axis.horizontal ? math.min(a.bottom, b.bottom) - math.max(a.top, b.top) : math.min(a.right, b.right) - math.max(a.left, b.left);
    final least = axis == Axis.horizontal ? math.min(a.height, b.height) : math.min(a.width, b.width);
    return overlap > least / 2;
  }

  // ── Choosing by position (after Android's FocusFinder) ──

  static _Stop? _best(Rect from, Iterable<_Stop> stops, TraversalDirection d, {required bool beamOnly}) {
    _Stop? best;
    for (final s in stops) {
      if (!_isCandidate(from, s.rect, d)) continue;
      if (beamOnly && !_beamsOverlap(from, s.rect, d)) continue;
      if (best == null || _isBetter(from, s.rect, best.rect, d)) best = s;
    }
    return best;
  }

  static bool _horizontal(TraversalDirection d) => d == TraversalDirection.left || d == TraversalDirection.right;

  /// Whether [to] lies in direction [d] of [from] at all.
  static bool _isCandidate(Rect from, Rect to, TraversalDirection d) => switch (d) {
    TraversalDirection.left => (from.right > to.right || from.left >= to.right) && from.left > to.left,
    TraversalDirection.right => (from.left < to.left || from.right <= to.left) && from.right < to.right,
    TraversalDirection.up => (from.bottom > to.bottom || from.top >= to.bottom) && from.top > to.top,
    TraversalDirection.down => (from.top < to.top || from.bottom <= to.top) && from.bottom < to.bottom,
  };

  /// Whether [to] is in the beam of [from]: the band it would sweep moving in [d].
  static bool _beamsOverlap(Rect from, Rect to, TraversalDirection d) =>
      _horizontal(d) ? (to.bottom > from.top && to.top < from.bottom) : (to.right > from.left && to.left < from.right);

  static bool _isBeyond(Rect from, Rect to, TraversalDirection d) => switch (d) {
    TraversalDirection.left => from.left >= to.right,
    TraversalDirection.right => from.right <= to.left,
    TraversalDirection.up => from.top >= to.bottom,
    TraversalDirection.down => from.bottom <= to.top,
  };

  static double _major(Rect from, Rect to, TraversalDirection d) => math.max(0, switch (d) {
    TraversalDirection.left => from.left - to.right,
    TraversalDirection.right => to.left - from.right,
    TraversalDirection.up => from.top - to.bottom,
    TraversalDirection.down => to.top - from.bottom,
  });

  static double _majorToFarEdge(Rect from, Rect to, TraversalDirection d) => math.max(1, switch (d) {
    TraversalDirection.left => from.left - to.left,
    TraversalDirection.right => to.right - from.right,
    TraversalDirection.up => from.top - to.top,
    TraversalDirection.down => to.bottom - from.bottom,
  });

  /// How far off the line of travel [to] is. Nothing, when the line through the middle of
  /// [from] runs through [to] at all: a wide control straight ahead (a TV player's seek bar
  /// over its Play key, the bar running the width of the screen) is not counted as far off
  /// because its own middle is. Measured middle to middle, Up from Play passed over the seek
  /// bar to the small source line above it.
  static double _minor(Rect from, Rect to, TraversalDirection d) => _horizontal(d)
      ? (from.center.dy >= to.top && from.center.dy <= to.bottom ? 0 : (from.center.dy - to.center.dy).abs())
      : (from.center.dx >= to.left && from.center.dx <= to.right ? 0 : (from.center.dx - to.center.dx).abs());

  static bool _beamBeats(Rect from, Rect a, Rect b, TraversalDirection d) {
    final aIn = _beamsOverlap(from, a, d), bIn = _beamsOverlap(from, b, d);
    if (bIn || !aIn) return false;
    if (!_isBeyond(from, b, d)) return true;
    if (_horizontal(d)) return true;
    return _major(from, a, d) < _majorToFarEdge(from, b, d);
  }

  /// Whether [a] is a better place to go than [b].
  static bool _isBetter(Rect from, Rect a, Rect b, TraversalDirection d) {
    if (_beamBeats(from, a, b, d)) return true;
    if (_beamBeats(from, b, a, d)) return false;
    double weighed(Rect r) {
      final major = _major(from, r, d), minor = _minor(from, r, d);
      return 13 * major * major + minor * minor;
    }

    return weighed(a) < weighed(b);
  }
}

/// The traversal policy that puts [Dpad.move] behind Flutter's arrow-key handling. Tab order
/// stays reading order.
class DpadTraversalPolicy extends ReadingOrderTraversalPolicy {
  DpadTraversalPolicy() : super(requestFocusCallback: _plainRequest);

  // Flutter's own callback also jumps every list to show the node; the kit scrolls instead.
  static void _plainRequest(FocusNode node, {ScrollPositionAlignmentPolicy? alignmentPolicy, double? alignment, Duration? duration, Curve? curve}) => node.requestFocus();

  // Flutter's own rules for an arrow key are replaced outright, not added to.
  @override
  // ignore: must_call_super
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (!Dpad.isStop(currentNode)) {
      // nothing is focused that focus could move from: start the page off (while it is still
      // loading, on what is in view only; with nothing there yet, an arrow that leads out of
      // the page still does, so Left reaches the navbar)
      final scope = currentNode is FocusScopeNode ? currentNode : currentNode.nearestScope;
      if (scope == null) return false;
      final first = Dpad.firstShown(scope);
      if (first == null) return Dpad._exit(currentNode, direction, scope);
      first.requestFocus();
      return true;
    }
    return Dpad.move(currentNode, direction);
  }
}
