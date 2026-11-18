// VyseTV. Sliders a D-pad can use (docs/dpad/PLAN.md, 3.7 and 3.8). A Material slider left to
// itself keeps all four arrows, so focus can get onto it and never off. Here a slider is one
// focus stop: Left and Right are its own, Up and Down move on, and the slider inside stays a
// mouse's (it is shut to focus while a D-pad is in charge).
//
// - DpadSeekStop: a seek bar. One step a press, and held, the steps grow. Every seek bar in
//   the app uses the same keys (DpadSeekKeys), so they all feel the same.
// - DpadSlider: any other slider (volume, a setting). One step a press, repeating when held.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'focusable_wrapper.dart';
import 'input_mode_tracker.dart';

class DpadSeekKeys {
  DpadSeekKeys({required this.position, required this.duration, required this.onSeek, required this.stepSeconds, this.onChanged});

  final Duration Function() position;
  final Duration Function() duration;
  final ValueChanged<Duration> onSeek;

  /// How far one press moves.
  final int Function() stepSeconds;

  /// [target] changed: the bar shows it.
  final VoidCallback? onChanged;

  int _held = 0;
  Timer? _idle;

  /// Where the last press sent playback. A player reports its new place a moment after it is
  /// asked to seek, so the next press goes on from here, not from where the player still
  /// says it is. Null again shortly after the last press.
  Duration? target;

  /// Give this to the bar's `FocusableWrapper.onKeyEvent`.
  KeyEventResult handle(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft && key != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      _held = 0;
      return KeyEventResult.handled;
    }
    _held = event is KeyRepeatEvent ? _held + 1 : 0;
    final total = duration();
    if (total <= Duration.zero) return KeyEventResult.handled;
    // one step a press; held for a while the steps grow to three, then six times as far
    final step = Duration(seconds: stepSeconds() * (_held < 8 ? 1 : (_held < 24 ? 3 : 6)));
    final from = target ?? position();
    var to = key == LogicalKeyboardKey.arrowRight ? from + step : from - step;
    if (to < Duration.zero) to = Duration.zero;
    if (to > total) to = total;
    target = to;
    _idle?.cancel();
    _idle = Timer(const Duration(milliseconds: 900), () {
      target = null;
      onChanged?.call();
    });
    onSeek(to);
    onChanged?.call();
    return KeyEventResult.handled;
  }

  /// Focus left the bar.
  void reset() {
    _idle?.cancel();
    _held = 0;
    target = null;
  }

  void dispose() => _idle?.cancel();
}

/// A seek slider as one focus stop. [builder] draws the slider; it is handed where the keys
/// last sent playback (null when they have been still for a moment) so it can show that
/// rather than the player's own, slightly late, position.
class DpadSeekStop extends StatefulWidget {
  const DpadSeekStop({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.stepSeconds,
    required this.builder,
    this.borderRadius = 10,
    this.focusInset = const EdgeInsets.symmetric(horizontal: -4, vertical: 2),
  });

  final Duration Function() position;
  final Duration Function() duration;
  final ValueChanged<Duration> onSeek;
  final int Function() stepSeconds;
  final Widget Function(BuildContext context, Duration? target) builder;
  final double borderRadius;
  final EdgeInsets focusInset;

  @override
  State<DpadSeekStop> createState() => _DpadSeekStopState();
}

class _DpadSeekStopState extends State<DpadSeekStop> {
  late final _keys = DpadSeekKeys(
    position: () => widget.position(),
    duration: () => widget.duration(),
    onSeek: (to) => widget.onSeek(to),
    stepSeconds: () => widget.stepSeconds(),
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusableWrapper(
    onKeyEvent: _keys.handle,
    onFocusChange: (focused) {
      if (!focused) _keys.reset();
    },
    disableScale: true,
    borderRadius: widget.borderRadius,
    focusInset: widget.focusInset,
    child: ExcludeFocus(excluding: InputModeTracker.isKeyboardMode(context), child: widget.builder(context, _keys.target)),
  );
}

/// Any other slider as one focus stop: Left and Right change [value] by [step] (and go on
/// doing so while held), within [min] and [max]; Up and Down move on. [child] is the slider
/// as it is drawn today.
class DpadSlider extends StatelessWidget {
  const DpadSlider({
    super.key,
    required this.value,
    this.min = 0,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.child,
    this.onSelect,
    this.borderRadius = 10,
    this.focusInset = const EdgeInsets.symmetric(horizontal: -4, vertical: 2),
  });

  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double>? onChanged;

  /// What OK does on the slider, if anything: mute, where a mute button sits beside it. (Left
  /// and Right are the slider's own, so a button beside it could never be reached past it;
  /// that button is then shut to a D-pad and OK does its work.)
  final VoidCallback? onSelect;
  final Widget child;
  final double borderRadius;
  final EdgeInsets focusInset;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft && key != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;
    if (event is KeyUpEvent || onChanged == null) return KeyEventResult.handled;
    final to = (value + (key == LogicalKeyboardKey.arrowRight ? step : -step)).clamp(min, max).toDouble();
    if (to != value) onChanged!(to);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => FocusableWrapper(
    canRequestFocus: onChanged != null,
    onKeyEvent: _onKey,
    onSelect: onSelect,
    disableScale: true,
    borderRadius: borderRadius,
    focusInset: focusInset,
    child: ExcludeFocus(excluding: InputModeTracker.isKeyboardMode(context), child: child),
  );
}
