// VyseTV. The two states every player and reader has (docs/dpad/PLAN.md, 3.7), in one place:
//
// - The picture in charge. Focus rests on the picture itself (the controls are hidden, or a
//   mouse is in use). The picture has keys of its own (seek, change channel, turn the page);
//   those neither move focus nor start D-pad mode.
// - The controls shown. Focus is on a control and arrows move between controls. Back hides
//   the controls and returns to the picture; Back again leaves.
//
// A menu that opens over the picture is a region: it takes focus while it is open and gives it
// back to the control it was opened from.
//
// The page owns what is on screen (its controls, its idle timer, its menus). This owns where
// focus goes.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'dpad_traversal.dart';
import 'focus_navigation_intent.dart';
import 'input_mode_tracker.dart';

class DpadPicture {
  DpadPicture({String debugLabel = 'picture', required this.ownsKey, this.onChanged, this.onKeyOnControls, this.controlsAlwaysShown = false}) {
    node = DirectionalShortcutFocusNode(debugLabel: debugLabel, consumesDirectionalKeys: (key) => node.hasPrimaryFocus && ownsKey(key));
  }

  /// Which arrow keys the picture uses itself while it holds focus.
  final bool Function(LogicalKeyboardKey key) ownsKey;

  /// Focus moved onto the picture or off it: the page's key bindings depend on which.
  final VoidCallback? onChanged;

  /// A key was pressed with focus on one of the controls, whoever goes on to use it (a seek
  /// bar keeps Left and Right, a button keeps OK): the page restarts its idle timer. Held
  /// keys count too.
  final VoidCallback? onKeyOnControls;

  /// The page has no picture to rest on: its controls are always on show (an audio player).
  /// Its own keys still work while a mouse is in charge (Left and Right skip), but with a
  /// D-pad focus never stays on the page itself: it goes straight onto the controls.
  final bool controlsAlwaysShown;

  /// The picture's focus node: give it to the `Focus` that wraps the page.
  late final DirectionalShortcutFocusNode node;

  /// The window's own buttons (on a desktop, out of full screen) are a place apart, as in the
  /// rest of the app: wrap the page's `WindowBar` in a `DpadRegion` with this node, and give
  /// [toWindowBar] to the `DpadRail` round the page's top bar. Right from the end of the top
  /// bar then leads to them and Left or Down leads back; a held Up never ends on Close.
  late final DpadRegionNode windowBar = DpadRegionNode(debugLabel: 'window buttons', onExit: _leaveWindowBar);
  FocusNode? _beforeWindow;

  DpadRegionNode? _menu;
  FocusNode? _opener;
  bool _attached = false;

  /// Call from `initState`.
  void attach() {
    if (_attached) return;
    _attached = true;
    node.addListener(_nodeChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_anyKey);
  }

  void _nodeChanged() {
    onChanged?.call();
    if (controlsAlwaysShown && dpad && node.hasPrimaryFocus) toControls();
  }

  /// For a page whose controls are always on show: call from `build`. It is how the page
  /// hears that a D-pad has taken over while focus was resting on the page itself (a remote
  /// picked up after the mouse), and moves focus onto the controls then.
  void watchMode(BuildContext context) {
    if (controlsAlwaysShown && InputModeTracker.isKeyboardMode(context) && node.hasPrimaryFocus) toControls();
  }

  /// Call from `dispose`.
  void dispose() {
    if (_attached) FocusManager.instance.removeEarlyKeyEventHandler(_anyKey);
    node.dispose();
    windowBar.dispose();
  }

  static bool get dpad => InputModeTracker.currentMode == InputMode.keyboard;
  static bool get typing => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

  bool get onPicture => node.hasPrimaryFocus;
  bool get onControls => node.hasFocus && !node.hasPrimaryFocus;

  /// The menu open over the picture, as last told to [menuIs].
  DpadRegionNode? get menu => _menu;

  KeyEventResult _anyKey(KeyEvent event) {
    if (event is! KeyUpEvent && onControls) onKeyOnControls?.call();
    return KeyEventResult.ignored;
  }

  /// Focus back onto the picture, if it is on one of the controls: for when they hide.
  void toPicture() {
    if (onControls && !typing) node.requestFocus();
  }

  /// The controls were just asked to show. With a D-pad, focus goes onto them after this
  /// frame: into the menu that is open, if one is, else onto where the page says it starts
  /// (Play). [shown] is asked then, in case the controls did not come up after all.
  void toControls({bool Function()? shown}) {
    if (!dpad) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (node.context == null || !node.hasPrimaryFocus) return;
      final open = _menu;
      if (open != null && open.context != null) {
        Dpad.enter(open);
        return;
      }
      if (shown != null && !shown()) return;
      final scope = node.nearestScope;
      // (the window's own buttons are a place apart: never where the controls start)
      (scope == null ? null : Dpad.firstStop(scope, where: (stop) => !stop.ancestors.contains(windowBar)))?.requestFocus();
    });
    // (the controls may be up already, in which case nothing else asks for a frame)
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Back, with a D-pad, focus on the controls and no menu open: focus returns to the picture
  /// and this answers true, for the page to hide its controls. Otherwise false: Back is the
  /// page's, to do what it always did.
  bool backToPicture() {
    if (_menu != null || !dpad || !onControls) return false;
    node.requestFocus();
    return true;
  }

  /// Tell it, from `build`, which menu is open over the picture (null for none). With a
  /// D-pad, focus follows: into the menu when it opens; back to the control it was opened
  /// from when the last one closes ([returned] is then called, for the page to restart its
  /// idle timer), or to the picture if it was opened from there.
  void menuIs(DpadRegionNode? now, {VoidCallback? returned}) {
    if (identical(now, _menu)) return;
    final was = _menu;
    _menu = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (node.context == null || !dpad || !node.hasFocus) return;
      if (now != null) {
        if (was == null) {
          final from = FocusManager.instance.primaryFocus;
          _opener = identical(from, node) ? null : from;
        }
        if (identical(_menu, now)) Dpad.enter(now);
      } else if (_menu == null) {
        final back = _opener;
        _opener = null;
        if (back != null && Dpad.isStop(back)) {
          back.requestFocus();
          returned?.call();
        } else {
          node.requestFocus();
        }
      }
    });
  }

  /// For the `DpadRail` round the top bar: `onEdge: picture.toWindowBar`.
  bool toWindowBar(TraversalDirection direction) {
    if (direction != TraversalDirection.right || windowBar.context == null) return false;
    _beforeWindow = FocusManager.instance.primaryFocus;
    return Dpad.enter(windowBar);
  }

  bool _leaveWindowBar(TraversalDirection direction) {
    if (direction != TraversalDirection.left && direction != TraversalDirection.down) return false;
    final back = _beforeWindow;
    _beforeWindow = null;
    (back != null && Dpad.isStop(back) ? back : node).requestFocus();
    return true;
  }
}
