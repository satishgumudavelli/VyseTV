// From upstream (lib/focus/focus_theme.dart, GPL-3.0). Kept as upstream wrote it so the two can be
// compared; anything changed for VyseTV is marked "VyseTV".
import 'package:flutter/material.dart';
import '../core/accent.dart'; // VyseTV
import '../core/platform/device_performance.dart';
// VyseTV: upstream's theme tokens (theme/mono_tokens.dart) are not here; durations are fixed.
import '../core/platform/platform_detector.dart';

class FocusTheme {
  FocusTheme._();

  static const double focusScale = 1.02;
  static const double fullCardFocusScale = 1.03;

  /// Round 40px player controls: the card scale is imperceptible on a
  /// control that small, so the focused disc grows enough to be seen move.
  static const double playerControlFocusScale = 1.12;
  // VyseTV: 2 px (upstream: 2.5) and a tighter glow, to sit with VyseTV's thin outlines.
  static const double focusBorderWidth = 2;

  /// Where the ring goes for a control that is only text (a link in a line of them: a studio's
  /// name, an artist's). It has no room of its own: drawn inside its edge the ring cuts through
  /// the first and last letters, so it goes round the text, this far outside it.
  static const EdgeInsets textLinkInset = EdgeInsets.symmetric(horizontal: -5, vertical: -2);
  static const double defaultBorderRadius = 8.0;
  static const double focusGlowInnerBlurRadius = 12;
  static const double focusGlowOuterBlurRadius = 26;
  static const double focusGlowSpreadRadius = 1;

  /// VyseTV: the ring wears the colour of the theme picked in Settings > Appearance
  /// (upstream: the Material theme's primary colour).
  static Color getFocusBorderColor(BuildContext context) {
    return accentOf(context);
  }

  static Duration getAnimationDuration(BuildContext context) {
    // Reduced tier: snap focus transitions (scale/border/glow) instead of
    // animating — each animation frame re-rasterizes the focused card.
    if (DevicePerformance.isReduced) return Duration.zero;
    return const Duration(milliseconds: 150);
  }

  /// How long a TV row (or the hub list) glides after one D-pad focus step.
  ///
  /// Apple TV keeps the ~500ms ease-out measured from the native focus
  /// engine's scrollable containers (issue #2006): Siri Remote swipes chain
  /// steps into one continuous glide and users expect that inertia. D-pad
  /// platforms have no such reference: Leanback's `GridLayoutManager` prices a
  /// one-card step at roughly 100-150ms, so a 500ms glide there trails the
  /// focus border on every press and reads as input lag next to the launcher.
  /// Successive presses (including hold-repeats) retarget the animation from
  /// wherever the row currently is, so a fast series still glides continuously.
  static Duration navigationScrollDuration() =>
      PlatformDetector.isAppleTV() ? const Duration(milliseconds: 500) : const Duration(milliseconds: 150);

  /// [radii] overrides [borderRadius] when per-corner radii are needed
  /// (M3E grouped cards: large outer / small inner corners).
  static BoxDecoration focusDecoration(
    BuildContext context, {
    required bool isFocused,
    double borderRadius = defaultBorderRadius,
    BorderRadius? radii,
    double borderStrokeAlign = BorderSide.strokeAlignInside,
    Color? color,
  }) {
    final focusColor = color ?? getFocusBorderColor(context);

    return BoxDecoration(
      borderRadius: radii ?? BorderRadius.circular(borderRadius),
      border: Border.all(
        color: isFocused ? focusColor : Colors.transparent,
        width: focusBorderWidth,
        strokeAlign: borderStrokeAlign,
      ),
    );
  }

  /// The focus glow as a list of [BoxShadow]s.
  ///
  /// Rendered by [FocusGlowOverlay] in the root overlay so the glow paints
  /// above sibling cards on all four sides (an in-tree background shadow is
  /// occluded by later-painted neighbours, which produced the one-sided halo).
  static List<BoxShadow> focusGlowShadows(Color color) {
    return [
      BoxShadow(
        color: color.withValues(alpha: 0.42),
        blurRadius: focusGlowInnerBlurRadius,
        spreadRadius: focusGlowSpreadRadius,
      ),
      BoxShadow(color: color.withValues(alpha: 0.22), blurRadius: focusGlowOuterBlurRadius),
    ];
  }

  /// How far the focus glow visibly reaches beyond the card edge. Used to size
  /// the overlay paint area so the blur is not clipped.
  static double get focusGlowExtent => focusGlowOuterBlurRadius * 2 + focusGlowSpreadRadius;

  /// Translucent fill over video for on-media controls, which sit on dark
  /// frames whatever the app theme is. Pass it as the wrapper's `focusColor`
  /// together with `useBackgroundFocus`.
  static const Color onMediaFocusFill = Color(0x33FFFFFF);

  /// Build focus decoration with background color instead of border.
  ///
  /// The fill derives from the theme's `onSurface` so it reads on light and
  /// dark surfaces alike (a fixed white fill vanished on light themes, #2929).
  /// [color] overrides it; over video use [onMediaFocusFill].
  /// [radii] overrides [borderRadius] when per-corner radii are needed.
  static BoxDecoration focusBackgroundDecoration(
    BuildContext context, {
    required bool isFocused,
    double borderRadius = defaultBorderRadius,
    BorderRadius? radii,
    Color? color,
  }) {
    return BoxDecoration(
      borderRadius: radii ?? BorderRadius.circular(borderRadius),
      color: isFocused ? color ?? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2) : Colors.transparent,
    );
  }

  // VyseTV: upstream's textFillFocusDecoration (a fill taken from its theme tokens) is left out.
}
