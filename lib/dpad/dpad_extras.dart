// VyseTV. Two things a pointer does that a D-pad needs a focus stop for (docs/dpad/PLAN.md, 3.8).
// Neither changes what a mouse or a finger does: they only add a place for focus and keys.
//
// - DpadMenuStop: something whose menu opens on a right click or a long press (a chat
//   message). With a D-pad it is a stop, and OK (or holding OK, or the Menu key) opens the
//   same menu, over the middle of it.
// - DpadHoldStop: something that works for as long as it is held (push to talk). With a
//   D-pad it is a stop, and it works for as long as OK is held.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'dpad_navigator.dart';
import 'focusable_wrapper.dart';
import 'input_mode_tracker.dart';

class DpadMenuStop extends StatelessWidget {
  const DpadMenuStop({super.key, required this.onMenu, required this.child, this.borderRadius = 10});

  /// Opens the menu at this point of the screen (where a right click would have been).
  final void Function(Offset at) onMenu;
  final Widget child;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    void open() {
      final box = context.findRenderObject();
      if (box is RenderBox && box.hasSize) onMenu(box.localToGlobal(box.size.center(Offset.zero)));
    }

    return FocusableWrapper(
      onSelect: open,
      onLongPress: open,
      enableLongPress: true,
      disableScale: true,
      borderRadius: borderRadius,
      child: child,
    );
  }
}

class DpadHoldStop extends StatefulWidget {
  const DpadHoldStop({super.key, required this.onHold, required this.child, this.borderRadius = 20});

  /// True when OK goes down on it, false when OK comes up (or focus leaves while it is held).
  final ValueChanged<bool> onHold;
  final Widget child;
  final double borderRadius;

  @override
  State<DpadHoldStop> createState() => _DpadHoldStopState();
}

class _DpadHoldStopState extends State<DpadHoldStop> {
  bool _held = false;

  void _set(bool held) {
    if (held == _held) return;
    _held = held;
    widget.onHold(held);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!event.logicalKey.isSelectKey) return KeyEventResult.ignored;
    // (only while a D-pad is in charge: with a mouse the button is held with the mouse)
    if (InputModeTracker.currentMode != InputMode.keyboard) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _set(true);
    if (event is KeyUpEvent) _set(false);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    if (_held) widget.onHold(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusableWrapper(
    onKeyEvent: _onKey,
    onFocusChange: (focused) {
      if (!focused) _set(false);
    },
    disableScale: true,
    borderRadius: widget.borderRadius,
    child: widget.child,
  );
}
