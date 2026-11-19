import 'package:flutter/widgets.dart';

import '../data/app_settings.dart';
import 'platform/device_performance.dart';
import 'platform/platform_detector.dart' show PlatformDetector;

/// The lean way of drawing, for TVs.
///
/// A TV box has a phone chip from years back and a screen of two million pixels or more.
/// Flutter draws everything on screen again for every frame of every animation, so what the
/// app spends there is: how many frames a press sets off, how many layers of see-through
/// paint each of those frames blends over the whole screen, and how much the Dart side
/// rebuilds and records again for each. Lean cuts all three:
///
/// - **Fewer frames.** Flutter's own "reduce motion" switch is turned on ([VyseBinding]): every
///   ordinary animation (a highlight easing in, a page fading over, a picture fading up, a
///   panel sliding) finishes in one frame. What stays in motion is what carries the eye: the
///   focus ring gliding to the next control and the page scrolling under it, and countdowns
///   that are really clocks. (Those say so themselves: `AnimationBehavior.preserve`.)
/// - **Nothing moving at rest.** Placeholders don't shimmer, bars don't dance: a page that is
///   not being used draws nothing at all.
/// - **Less paint.** Stacked scrims over a backdrop become one; a second full-screen background
///   is left out; on the weakest boxes ([weak]) the ambient glow goes too.
///
/// It is on for an Android TV unless Settings > Appearance says otherwise, and off everywhere
/// else, where nothing changes.
abstract final class Lean {
  /// Whether the interface is drawn the lean way.
  static bool get on => debugOn ?? _on;
  static bool _on = false;

  /// The weakest boxes (2 GB of memory or less, or a 32-bit system): also without what merely
  /// decorates.
  static bool get weak => on && (debugWeak ?? DevicePerformance.isReduced);

  /// Tests: stands in for [on] (they run on a PC and never start the app's own binding; set
  /// `debugSemanticsDisableAnimations` with it for the motion side).
  @visibleForTesting
  static bool? debugOn;

  @visibleForTesting
  static bool? debugWeak;

  /// Tells when [on] changes (the setting was changed).
  static final changes = ValueNotifier<bool>(false);

  /// Works out [on] from the setting and the device. Called as the app starts, once it knows
  /// what it is running on, and when the setting changes.
  static void decide() {
    final was = _on;
    _on = switch (AppSettings.leanMotion.value) {
      'on' => true,
      'off' => false,
      _ => PlatformDetector.isTV(),
    };
    VyseBinding.reduceMotion = _on;
    changes.value = _on;
    if (was != _on) _buildAgain();
  }

  /// Has everything on screen build again: what is drawn the lean way is decided as it is built.
  /// (Nothing to do as the app starts: there is nothing on screen yet.)
  static void _buildAgain() {
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
  }

  /// The setting, as Settings shows it: fewer animations or all of them.
  static void choose(bool lean) {
    AppSettings.leanMotion.set(lean ? 'on' : 'off');
    decide();
  }

  /// [full] where animations run, none where the interface is lean. For the few animations
  /// that are not Flutter's to shorten (a delay before something appears).
  static Duration time(Duration full) => on ? Duration.zero : full;

  /// Starts a decoration that moves for as long as it is on screen (bars that dance, a pulse
  /// while something loads), and hands [c] back. Lean: it stays still, so a page nobody is
  /// touching draws nothing. (Spinners are not decorations: they say work is going on.)
  static AnimationController loop(AnimationController c, {bool reverse = false}) {
    if (!on) c.repeat(reverse: reverse);
    return c;
  }
}

/// Flutter's binding with its "reduce motion" switch in the app's hands as well as the
/// system's. With it on, an [AnimationController] that doesn't ask to be preserved runs at a
/// twentieth of its length, which is one frame for nearly all of them; scrolling and repeating
/// animations are left alone (that is Flutter's own rule for the switch).
class VyseBinding extends WidgetsFlutterBinding {
  /// Set by [Lean.decide].
  static bool reduceMotion = false;

  static bool _made = false;

  /// In place of `WidgetsFlutterBinding.ensureInitialized()`.
  static WidgetsBinding ensureInitialized() {
    if (!_made) {
      _made = true;
      // (never a second binding: if something made Flutter's own before this ran, that one
      // stays, and the only thing lost is the shorter animations)
      WidgetsBinding? there;
      try {
        there = WidgetsBinding.instance;
      } catch (_) {
        // none yet: the usual case, this is the first line of main()
      }
      if (there == null) VyseBinding();
    }
    return WidgetsBinding.instance;
  }

  @override
  bool get disableAnimations => reduceMotion || super.disableAnimations;
}
