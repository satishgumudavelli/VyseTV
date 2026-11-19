// VyseTV addition (not in upstream).
//
// What the app needs once, above every page, for a D-pad to work everywhere. It sits in
// MaterialApp's builder (lib/main.dart), under the input-mode tracker, and does five things:
//
// 1. Arrows. Every arrow key that no control used for itself ends here and is handed to the
//    rules in dpad_traversal.dart. The press that picks the remote up (the first after a mouse
//    or a finger) shows where focus is and does not also move it. A held arrow moves at a
//    steady pace, however fast the keyboard repeats.
// 2. Back (Escape, a remote's Back, a controller's B). One press, one thing: it closes what
//    is open on top if that closes by itself, and otherwise tells the app ([onBack]). Holding
//    it does nothing more.
// 3. Something always has focus. In D-pad mode, when focus is on nothing a ring can be drawn
//    on (a page just opened, the focused card was removed), it is put on the nearest sensible
//    control: the neighbour of what vanished, or the page's first.
// 4. The ring for controls that are not the app's own: a Material button, a switch, a slider
//    or a menu item can take focus but draws at most a faint tint for it. In D-pad mode this
//    draws the same ring around whichever of them is focused, and brings it into view the same
//    way. (A theme cannot do this: it cannot tell a remote from a mouse without rebuilding
//    the whole app, and it has no ring to give a switch or a slider.)
// 5. It remembers each row's place as focus moves, however it moved.
// 6. Menus that open in place (a MenuAnchor's: see dpad_traversal.dart). In D-pad mode focus
//    goes into one as it opens, and back to what opened it when it closes.
// 7. A held OK presses once, on the control it went down on. When the press moved focus (it
//    opened a menu, or the update box put Cancel where Update was), its repeats press nothing.
//
// And in debug builds a watchdog: a line in the log whenever D-pad mode has had no focus for
// more than a frame, with the page's name (rule R1 holding, or not, in the real app).
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'dpad_navigator.dart';
import 'dpad_reveal.dart';
import 'dpad_traversal.dart';
import 'focus_chrome.dart';
import 'focus_theme.dart';
import 'input_mode_tracker.dart';
import 'key_event_utils.dart';
import 'tv_text_input.dart';

class DpadRoot extends StatefulWidget {
  const DpadRoot({super.key, required this.child, this.onBack});

  final Widget child;

  /// Back was pressed and nothing on top closed by itself: the app's turn (pop the page).
  final VoidCallback? onBack;

  /// A held arrow moves focus no more often than this, so lists can keep up and the eye can
  /// follow. About twelve steps a second.
  static const moveInterval = Duration(milliseconds: 80);

  /// The watchdog: on in debug builds, off in profile and release builds.
  static bool watchdog = kDebugMode;

  /// Where the watchdog's lines go (the debug log, unless a test listens).
  static void Function(String line) watchdogLog = (line) => debugPrint(line);

  /// For tests: the control a ring is being drawn for here right now, if any.
  @visibleForTesting
  static FocusNode? get debugRinged {
    final state = _DpadRootState._live;
    return state == null || state._ring.value == 0 ? null : state._foreign;
  }

  /// For tests: where that ring was last drawn, in the window.
  @visibleForTesting
  static Rect? get debugRingRect => _DpadRootState._live?._ringRect;

  @override
  State<DpadRoot> createState() => _DpadRootState();
}

/// The bindings for Back, for a page, a box or a text box that has a Back of its own: Escape,
/// a remote's Back, the browser's Back key and a controller's B, each acting once per press
/// however long it is held. `CallbackShortcuts(bindings: {...backBindings(close), ...})`
Map<ShortcutActivator, VoidCallback> backBindings(VoidCallback action) => {
  for (final key in const [LogicalKeyboardKey.escape, LogicalKeyboardKey.goBack, LogicalKeyboardKey.browserBack, LogicalKeyboardKey.gameButtonB])
    SingleActivator(key, includeRepeats: false): action,
};

/// For a navigator inside a page (Music's, beside its sidebar): a page opened from a control
/// outside that navigator (a row of the sidebar) gives focus back to that control when it
/// closes (R6). Opened from inside, the navigator's own restore already does that. D-pad mode
/// only: with a mouse in charge focus is left where Flutter puts it, as before.
class DpadReturnObserver extends NavigatorObserver {
  final _from = Expando<FocusNode>('opened from');

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final focus = FocusManager.instance.primaryFocus;
    final nav = navigator;
    if (focus == null || nav == null || !Dpad.isStop(focus)) return;
    if (focus.ancestors.contains(nav.focusNode)) return; // opened from inside
    _from[route] = focus;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final from = _from[route];
    if (from == null) return;
    // The page underneath takes focus as this one starts to close, and again once it has gone
    // (a route does that whenever its state changes and focus is anywhere above its
    // navigator). Both times focus goes back to the opener, in the same frame, so no ring
    // shows on the page underneath; the second time only if no key was pressed meanwhile.
    void restore() {
      if (InputModeTracker.currentMode == InputMode.keyboard && Dpad.isStop(from)) Dpad.giveFocus(from);
    }

    scheduleMicrotask(restore);
    final presses = Dpad.presses;
    if (route is TransitionRoute) {
      route.completed.then((_) {
        if (Dpad.presses == presses) restore();
      });
    }
  }
}

/// A page that has pages of its own inside it (Music, beside its sidebar) answers Back before
/// its section does: `DpadBackScope(onBack: ..., child: ...)`. [onBack] says true when it went
/// back a page, false when it had nowhere to go (Back is then the section's). Whoever handles
/// Back for the app asks [handle] first.
class DpadBackScope extends StatefulWidget {
  const DpadBackScope({super.key, required this.onBack, required this.child});
  final bool Function() onBack;
  final Widget child;

  static final _live = <_DpadBackScopeState>[];

  /// True when a scope on screen took this Back.
  static bool handle() {
    for (final scope in _live.reversed.toList()) {
      if (!scope.mounted) continue;
      if (!(ModalRoute.of(scope.context)?.isCurrent ?? true) || !TickerMode.valuesOf(scope.context).enabled) continue;
      if (scope.widget.onBack()) return true;
    }
    return false;
  }

  @override
  State<DpadBackScope> createState() => _DpadBackScopeState();
}

class _DpadBackScopeState extends State<DpadBackScope> {
  @override
  void initState() {
    super.initState();
    DpadBackScope._live.add(this);
  }

  @override
  void dispose() {
    DpadBackScope._live.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DpadRootState extends State<DpadRoot> with TickerProviderStateMixin {
  static _DpadRootState? _live;

  final _policy = DpadTraversalPolicy();
  late final _actions = <Type, Action<Intent>>{DirectionalFocusIntent: _MoveAction(this)};

  // (kept at its length where animations are cut short, core/lean.dart: the ring is what the eye follows)
  late final AnimationController _ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 150), animationBehavior: AnimationBehavior.preserve);

  /// Ticks while the focused control may be moving (a list scrolling under it), so the ring
  /// follows it; idle otherwise, so a still screen costs nothing.
  late final Ticker _follow = createTicker(_onFollowTick);
  final _moved = ValueNotifier<int>(0);
  Duration _followUntil = Duration.zero;
  Duration _followNow = Duration.zero;

  // Where the ring was last drawn, and whether a look after the next frame is booked: a control
  // can move with no scroll and no focus change (the box it is in grows), and the ring follows
  // it then too. The look runs only after frames that happen anyway, so a still screen costs
  // nothing.
  Rect? _ringRect;
  bool _ringLook = false;

  /// The focused control that draws no ring of its own, while it has one drawn here.
  FocusNode? _foreign;
  bool _keyboardMode = false;

  // where focus last rested, for finding the neighbour of something that vanished
  FocusNode? _lastStop;
  Rect? _lastRect;
  FocusScopeNode? _lastScope;
  Timer? _healLater;
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);

  // how many times in a row the healer found nothing in view to focus (see _heal)
  int _healTries = 0;

  // the arrow being held down, and since when (see _move)
  LogicalKeyboardKey? _heldArrow;
  DateTime _heldSince = DateTime.fromMillisecondsSinceEpoch(0);

  // the control the OK being held went down on (see _anyKey)
  FocusNode? _okOn;

  // the menu that opens in place the last resting focus was in, if any (see _focusChanged)
  FocusScopeNode? _lastMenu;
  bool _menuCheckDue = false;

  @override
  void initState() {
    super.initState();
    _live = this;
    FocusManager.instance.addListener(_focusChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_anyKey);
  }

  /// Every key press, before anything uses it: from here on focus is where the viewer put it.
  KeyEventResult _anyKey(KeyEvent event) {
    if (event is KeyDownEvent) Dpad.keyPressed();
    final key = event.logicalKey;
    if (key.isSelectKey) {
      // A held OK sends repeats. They belong to the control the press went down on: when the
      // press moved focus (OK on a menu's button puts focus in the menu; Update gives way to
      // Cancel as the download starts), a repeat must not press what focus landed on.
      if (event is KeyDownEvent) {
        _okOn = FocusManager.instance.primaryFocus;
      } else if (event is KeyRepeatEvent) {
        final on = _okOn;
        if (on != null && !identical(FocusManager.instance.primaryFocus, on)) return KeyEventResult.handled;
      } else {
        _okOn = null;
      }
    }
    // OK, a held OK or the Menu key may have opened a menu: once it is built, focus goes in
    if ((key.isSelectKey || key.isContextMenuKey) && event is! KeyRepeatEvent) _enterMenuSoon();
    if (key.isDpadDirection) {
      if (event is KeyDownEvent) {
        _heldArrow = event.logicalKey;
        _heldSince = clock.now();
      } else if (event is KeyUpEvent && event.logicalKey == _heldArrow) {
        _heldArrow = null;
      }
    }
    // OK on a text box that focus came to with an arrow: the on-screen keyboard, not the key
    // (Enter would otherwise send what is in the box, empty)
    if (event is KeyDownEvent && event.logicalKey.isSelectKey && _keyboardMode && Dpad.openKeyboard()) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final was = _keyboardMode;
    _keyboardMode = InputModeTracker.isKeyboardMode(context);
    _syncRing();
    if (_keyboardMode && !was) _healSoon();
    _watch();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    FocusManager.instance.removeEarlyKeyEventHandler(_anyKey);
    if (identical(_live, this)) _live = null;
    _healLater?.cancel();
    _follow.dispose();
    _ring.dispose();
    _moved.dispose();
    super.dispose();
  }

  // ───────────────────────── Arrows ─────────────────────────

  void _move(TraversalDirection direction) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return;
    // A menu open in place takes the first arrow, even the one that picks the remote up (a
    // click opened it and left focus where it was): the menu is what is on top.
    final menu = Dpad.menuToEnter(node);
    if (menu != null) {
      _lastMove = clock.now();
      Dpad.enterMenu(node, menu);
      return;
    }
    final typing = node.context?.findAncestorStateOfType<EditableTextState>() != null;
    // _keyboardMode is as of the last build, so it is still false for the press that turned
    // D-pad mode on: that press shows the ring where focus already is.
    if (!_keyboardMode && Dpad.isRest(node) && !typing) {
      final context = node.context;
      if (context != null && !(DpadReveal.ownerReveals[node] ?? false)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) DpadReveal.reveal(context);
        });
      }
      return;
    }
    final now = clock.now();
    // A held arrow speeds up, or a long list (a portal's thousands of channels) would take an
    // age: the steady pace for the first second, then twice as fast, and from three seconds on
    // three items a step.
    final held = _heldArrow == null ? Duration.zero : now.difference(_heldSince);
    final interval = held < const Duration(milliseconds: 1200) ? DpadRoot.moveInterval : DpadRoot.moveInterval ~/ 2;
    if (now.difference(_lastMove) < interval) return;
    _lastMove = now;
    if (held < const Duration(seconds: 3)) {
      node.focusInDirection(direction);
    } else {
      Dpad.moveBy(node, direction, 3);
    }
  }

  // ───────────────────────── Back ─────────────────────────

  /// A text box uses the arrows itself, to move its caret, and would hold focus for ever. So
  /// an arrow that has nothing left to do in the box leaves it: Up and Down always (in a box
  /// of one line), Left with the caret at the start, Right with it at the end. Keys reach
  /// this handler before they reach the text editing shortcuts, so every text box in the app
  /// gets this without being touched.
  KeyEventResult _leaveTextBox(KeyEvent event) {
    final node = FocusManager.instance.primaryFocus;
    final editable = node?.context?.findAncestorStateOfType<EditableTextState>();
    if (node == null || editable == null) return KeyEventResult.ignored;
    // On a TV, while its on-screen keyboard is up, the arrows are the keyboard's: it moves between
    // its keys with them, and takes them before the app does. One that reaches the app anyway
    // (some TVs' keyboards come up without a typing session: see tv_text_input.dart) is dropped,
    // or focus would walk off the box behind the keyboard. Back puts the keyboard away first.
    if (TvTextInput.applies && (View.maybeOf(context)?.viewInsets.bottom ?? 0) > 0) return KeyEventResult.handled;
    final value = editable.textEditingValue;
    final caret = value.selection;
    final oneLine = editable.widget.maxLines == 1;
    final atStart = !caret.isValid || (caret.isCollapsed && caret.baseOffset <= 0);
    final atEnd = !caret.isValid || (caret.isCollapsed && caret.baseOffset >= value.text.length);
    final key = event.logicalKey;
    final leaves = switch (key) {
      LogicalKeyboardKey.arrowLeft => atStart,
      LogicalKeyboardKey.arrowRight => atEnd,
      LogicalKeyboardKey.arrowUp => oneLine || atStart,
      _ => oneLine || atEnd,
    };
    if (!leaves) return KeyEventResult.ignored;
    final now = clock.now();
    if (now.difference(_lastMove) < DpadRoot.moveInterval) return KeyEventResult.handled;
    final direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      _ => TraversalDirection.down,
    };
    // nowhere to go that way: the box keeps the key (the caret jumps to the end, as before)
    if (!Dpad.move(node, direction)) return KeyEventResult.ignored;
    _lastMove = now;
    return KeyEventResult.handled;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey.isDpadDirection && event.isActionable) return _leaveTextBox(event);
    // a remote's OK or a controller's A on a text box no one else took (its keyboard was put
    // away with Back): the keyboard comes back
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.gameButtonA) &&
        _keyboardMode &&
        Dpad.openKeyboard(force: true)) {
      return KeyEventResult.handled;
    }
    if (!event.logicalKey.isBackKey) return KeyEventResult.ignored;
    // Only the press acts. Its repeats and its release end here too, so a held Back, or a
    // release arriving on the page underneath, is never a second Back.
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    BackKeyCoordinator.markHandled();
    final focused = FocusManager.instance.primaryFocus;
    final context = focused?.context;
    // In a text box, Back first stops the typing: focus steps off the box and the page stays.
    if (_keyboardMode && focused != null && context?.findAncestorStateOfType<EditableTextState>() != null && Dpad.stepOut(focused)) {
      return KeyEventResult.handled;
    }
    if (context != null) {
      // a menu, a dropdown, a dialog that closes on Escape: let it
      final dismiss = Actions.maybeFind<DismissIntent>(context);
      if (dismiss != null && dismiss.isEnabled(const DismissIntent())) {
        Actions.invoke(context, const DismissIntent());
        return KeyEventResult.handled;
      }
    }
    widget.onBack?.call();
    return KeyEventResult.handled;
  }

  // ───────────────────────── Something always has focus ─────────────────────────

  void _focusChanged() {
    _syncRing();
    _watch();
    final node = FocusManager.instance.primaryFocus;
    TvTextInput.focused(node?.context?.findAncestorStateOfType<EditableTextState>() != null);
    // Out of a menu that has closed (a choice was made, or Back): Flutter hands focus to whatever
    // was focused on the page before, which can be far from the menu; it goes back to the
    // control that opened the menu instead, so the page stays where it was.
    final menu = _lastMenu;
    if (menu != null && (node == null || !(identical(node, menu) || node.ancestors.contains(menu)))) {
      _lastMenu = null;
      final stillOpen = (menu.context?.mounted ?? false) && menu.parent != null && menu.canRequestFocus;
      final back = _keyboardMode && !stillOpen ? Dpad.menuReturn(menu) : null;
      if (back != null && !identical(back, node)) {
        Dpad.giveFocus(back);
        return;
      }
    }
    // (focus given on purpose stays where it was given: see Dpad.takeChosen)
    final chosen = Dpad.takeChosen(node);
    if (node != null && Dpad.isRest(node)) {
      final was = _lastStop;
      final vanished = !chosen && was != null && !identical(was, node) && !(was.context?.mounted ?? false);
      if (_keyboardMode && vanished && identical(node.nearestScope, _lastScope) && _lastRect != null) {
        // What was focused is gone (a card removed, a list reloaded) and Flutter fell back to
        // whatever was focused before it. The neighbour that took its place is the better
        // answer: you stay where you were looking.
        final near = Dpad.nearestStop(node.nearestScope!, _lastRect!);
        if (near != null && !identical(near, node)) {
          _lastStop = near;
          Dpad.giveFocus(near);
          return;
        }
      }
      Dpad.noteFocused(node);
      _healTries = 0;
      _lastStop = node;
      _lastRect = node.rect;
      _lastScope = node.nearestScope;
      _lastMenu = Dpad.menuOf(node);
      _healLater?.cancel();
      return;
    }
    if (_keyboardMode) _healSoon();
  }

  /// After a key that may have opened a menu (OK on its button): once the frame has built it,
  /// focus goes into it, in D-pad mode. With a mouse or a finger nothing changes.
  void _enterMenuSoon() {
    if (_menuCheckDue) return;
    _menuCheckDue = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _menuCheckDue = false;
      if (!mounted || InputModeTracker.currentMode != InputMode.keyboard) return;
      final node = FocusManager.instance.primaryFocus;
      final menu = node == null ? null : Dpad.menuToEnter(node);
      if (menu != null) Dpad.enterMenu(node!, menu);
    });
  }

  void _healSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _heal());
    WidgetsBinding.instance.scheduleFrame();
  }

  void _heal() {
    _healLater?.cancel();
    if (!mounted || !_keyboardMode) return;
    final node = FocusManager.instance.primaryFocus;
    if (node != null && Dpad.isRest(node)) return;
    // the innermost area that last had focus: the page on top, not the whole app
    var scope = node is FocusScopeNode ? node : (node?.nearestScope ?? FocusManager.instance.rootScope);
    while (scope.focusedChild is FocusScopeNode) {
      scope = scope.focusedChild! as FocusScopeNode;
    }
    final view = View.maybeOf(context);
    final window = view == null ? null : Offset.zero & (view.physicalSize / view.devicePixelRatio);
    final was = _lastStop;
    FocusNode? target;
    if (was != null && !(was.context?.mounted ?? false) && identical(scope, _lastScope) && _lastRect != null) {
      target = Dpad.nearestStop(scope, _lastRect!);
    }
    final replaced = target != null;
    // Something in view first. A page still loading may have nothing in view yet but a control
    // far below it (its footer, the genres on Home), and going there would carry the page down
    // after it. So while something in view is still loading (a placeholder: DpadLoading) focus
    // waits for it, however long that takes; a TV starting on a slow network took longer than
    // any fixed wait. With nothing loading, a control further down is taken once the page has
    // had a moment (a page whose controls start below a tall heading).
    target ??= Dpad.firstStop(scope, window: window);
    if (target == null && _healTries >= 12 && !(window != null && Dpad.loadingInView(scope, window))) target = Dpad.firstStop(scope);
    if (target == null) _healTries++;
    if (target != null) {
      _healTries = 0;
      Dpad.giveFocus(target);
      if (!replaced) Dpad.placedFirst(target);
    } else {
      // nothing to focus yet (the page is still loading): look again shortly
      _healLater = Timer(const Duration(milliseconds: 120), _heal);
    }
  }

  // ───────────────────────── The watchdog (debug builds) ─────────────────────────
  //
  // The healer above puts focus back as soon as there is something to put it on. This notices
  // when there was not, for longer than a frame (a page with nothing to focus while it loads,
  // a control that vanished with nothing near it), and says for how long and on which page.

  Stopwatch? _lostFor;
  int _lostFrames = 0;
  String _lostOn = '';

  void _watch() {
    if (!DpadRoot.watchdog || !mounted) return;
    final node = FocusManager.instance.primaryFocus;
    final lost = _keyboardMode && (node == null || !Dpad.isRest(node));
    if (lost && _lostFor == null) {
      _lostFor = Stopwatch()..start();
      _lostFrames = 0;
      _lostOn = ''; // named after the frame, when the tree is settled
      _countLostFrame();
    } else if (!lost && _lostFor != null) {
      if (_lostFrames > 1) DpadRoot.watchdogLog('D-pad: no focus for $_lostFrames frames (${_lostFor!.elapsedMilliseconds} ms) on $_lostOn');
      _lostFor = null;
    }
  }

  void _countLostFrame() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_lostFor == null || !mounted) return;
      if (_lostOn.isEmpty) _lostOn = _pageOf(FocusManager.instance.primaryFocus);
      _lostFrames++;
      // past thirty frames it is said once, and the counting stops asking for frames
      if (_lostFrames == 30) {
        DpadRoot.watchdogLog('D-pad: no focus for 30 frames and counting, on $_lostOn');
        return;
      }
      _countLostFrame();
      SchedulerBinding.instance.scheduleFrame();
    });
  }

  /// The page [node] is on, for the watchdog's line: the first widget named like a page
  /// (DetailsPage, MusicShell, a sheet, a dialog) inside it when it is a page's own scope,
  /// else above it.
  static String _pageOf(FocusNode? node) {
    final context = node?.context;
    if (node == null || context == null) return 'no page (focus is on nothing at all)';
    if (context is! Element || !context.mounted) return "a page that has gone (focus is on '${node.debugLabel}')";
    bool named(Widget w) => RegExp(r'(Page|Shell|Screen|Sheet|Dialog|Panel|Menu|Picker)$').hasMatch(w.runtimeType.toString());
    String? found;
    if (node is FocusScopeNode) {
      var budget = 3000;
      void down(Element e) {
        if (found != null || --budget < 0) return;
        if (named(e.widget)) {
          found = e.widget.runtimeType.toString();
          return;
        }
        e.visitChildren(down);
      }

      context.visitChildren(down);
    }
    if (found == null) {
      context.visitAncestorElements((e) {
        if (named(e.widget)) found = e.widget.runtimeType.toString();
        return found == null;
      });
    }
    final label = node.debugLabel;
    return '${found ?? 'a page with no name'}${label == null ? '' : " (focus is on '$label')"}';
  }

  // ───────────────────────── The ring for other controls ─────────────────────────

  /// Whether [node] is a control with no ring of its own: something focus stops on (not a
  /// page-wide key handler, not a scope), that the kit's wrapper does not own, and that is
  /// not a text box (those show their own caret and border).
  static bool _needsRing(FocusNode node) {
    final context = node.context;
    if (context == null || node is FocusScopeNode || node.skipTraversal) return false;
    if (DpadReveal.ownerReveals[node] ?? false) return false;
    if (node.traversalDescendants.isNotEmpty) return false;
    if (context.findAncestorStateOfType<EditableTextState>() != null) return false;
    return true;
  }

  void _syncRing() {
    final node = FocusManager.instance.primaryFocus;
    final show = _keyboardMode && node != null && _needsRing(node);
    if (show) {
      final arrived = !identical(_foreign, node);
      _foreign = node;
      _ring.forward();
      _keepFollowing();
      _lookAfterFrame();
      if (arrived) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final context = node.context;
          if (mounted && identical(_foreign, node) && node.hasPrimaryFocus && context != null) DpadReveal.reveal(context);
        });
        WidgetsBinding.instance.scheduleFrame();
      }
    } else if (_foreign != null) {
      if (node != null && _keyboardMode) {
        // focus went to a control with its own ring: no lingering second ring
        _ring.value = 0;
        _foreign = null;
      } else {
        _ring.reverse().whenCompleteOrCancel(() {
          if (_ring.isDismissed) _foreign = null;
        });
      }
    }
  }

  void _keepFollowing() {
    _followUntil = _followNow + const Duration(milliseconds: 400);
    if (!_follow.isActive) {
      _followNow = Duration.zero;
      _followUntil = const Duration(milliseconds: 400);
      _follow.start();
    }
  }

  void _lookAfterFrame() {
    if (_ringLook) return;
    _ringLook = true;
    WidgetsBinding.instance.addPostFrameCallback(_lookAtRing);
  }

  /// After a frame: if the ringed control is not where its ring was drawn, draw it again there.
  void _lookAtRing(Duration _) {
    _ringLook = false;
    final node = _foreign;
    if (!mounted || node == null) return;
    final context = node.context;
    final object = context is Element && context.mounted ? context.renderObject : null;
    if (object is RenderBox && object.attached && object.hasSize) {
      final rect = MatrixUtils.transformRect(object.getTransformTo(null), Offset.zero & object.size);
      if (rect != _ringRect) _moved.value++;
    }
    _lookAfterFrame();
  }

  void _onFollowTick(Duration elapsed) {
    _followNow = elapsed;
    _moved.value++;
    if (elapsed > _followUntil || _foreign == null) _follow.stop();
  }

  bool _onScroll(ScrollNotification notification) {
    if (_foreign != null) _keepFollowing();
    return false;
  }

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    policy: _policy,
    child: Actions(
      actions: _actions,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: CustomPaint(
            foregroundPainter: _ForeignRing(this, FocusTheme.getFocusBorderColor(context)),
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}

class _MoveAction extends Action<DirectionalFocusIntent> {
  _MoveAction(this.root);
  final _DpadRootState root;

  @override
  void invoke(DirectionalFocusIntent intent) => root._move(intent.direction);
}

class _ForeignRing extends CustomPainter {
  _ForeignRing(this.state, this.color) : super(repaint: Listenable.merge([state._ring, state._moved]));

  final _DpadRootState state;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeOutCubic.transform(state._ring.value);
    final node = state._foreign;
    // The control may be on a page that has just closed: its ring is still fading out, but
    // the control itself is on its way out of the tree. Its render object is asked for in
    // the way that does not object to that, and is only used while it is still in the tree.
    final context = node?.context;
    final object = context is Element && context.mounted ? context.renderObject : null;
    if (t == 0 || object is! RenderBox || !object.attached || !object.hasSize) return;
    // this painter covers the window, so the control's place in the window is its place here
    final rect = MatrixUtils.transformRect(object.getTransformTo(null), Offset.zero & object.size);
    state._ringRect = rect;
    final radius = shapeAround(object) ?? const BorderRadius.all(Radius.circular(FocusTheme.defaultBorderRadius));
    final shape = radius.toRRect(rect);
    paintFocusGlow(canvas, shape, color, t);
    paintFocusRing(canvas, shape, color, t);
  }

  @override
  bool shouldRepaint(_ForeignRing old) => old.color != color;
}
