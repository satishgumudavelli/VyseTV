import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme.dart';
import '../core/lean.dart';
import '../dpad/dpad_traversal.dart' show DpadLoading;
import '../dpad/focus_theme.dart';
import '../dpad/focusable_wrapper.dart';
import '../dpad/input_mode_tracker.dart';

/// Hover + press state for any tappable surface, with a pointer cursor.
///
/// It is also what a D-pad lands on: every enabled Pressable is a focus stop. In D-pad mode
/// (a remote, a controller, the keyboard's arrows) the focused one wears the app's ring, OK
/// does what a tap does, and [builder] is told it is hovered, so whatever a control shows
/// under the mouse it shows under focus too. With a mouse or a finger in charge none of this
/// is seen or does anything.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.builder,
    this.onTap,
    this.tooltip,
    this.onLongPress,
    this.focusNode,
    this.autofocus = false,
    this.autofocusFallback = false,
    this.railEntry = false,
    this.focusable = true,
    this.focusRadius,
    this.focusScale = 1,
    this.focusInset = EdgeInsets.zero,
    this.focusGlow = true,
  });

  final Widget Function(BuildContext context, bool hovered, bool pressed) builder;
  final VoidCallback? onTap;
  final String? tooltip;

  /// What holding OK, or the Menu key, does: give it whatever a long press or a right click on
  /// this control does. Keys only; pointer gestures stay with whoever handles them now.
  final VoidCallback? onLongPress;

  /// To move focus here from code. Left alone, the Pressable keeps its own.
  final FocusNode? focusNode;

  /// Take focus when first shown, if nothing else has it.
  final bool autofocus;

  /// Where a D-pad lands when the page opens and nothing on it has [autofocus]: the selected
  /// tab of a tab strip, whose content may name a better place.
  final bool autofocusFallback;

  /// Where a D-pad lands when it comes into this control's row from across it (the showing tab
  /// of a strip of tabs), on a page that starts somewhere else. Needs a DpadRail round the row.
  final bool railEntry;

  /// False for something a D-pad should pass over (a decoration that happens to take taps, a
  /// button that is on screen but hidden). With no [onTap] it is passed over anyway.
  final bool focusable;

  /// The ring's corner radius. Left out, the ring takes the shape of what [builder] draws
  /// (a pill, a circle, a card).
  final double? focusRadius;

  /// How much the control grows while focused (1 = not at all; cards use about 1.03). Paint
  /// only: nothing around it moves.
  final double focusScale;

  /// How far inside the control's edges the ring sits; negative draws it outside, for a
  /// control with no room of its own (a text link).
  final EdgeInsets focusInset;

  /// The soft glow around the ring.
  final bool focusGlow;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;
  Timer? _keyPress;

  @override
  void dispose() {
    _keyPress?.cancel();
    super.dispose();
  }

  /// OK was pressed: the pressed look for a moment, as under a finger, then the tap.
  void _select() {
    _keyPress?.cancel();
    setState(() => _pressed = true);
    _keyPress = Timer(const Duration(milliseconds: 110), () {
      if (mounted) setState(() => _pressed = false);
    });
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    // focus only shows, and only counts as hover, while a D-pad is in charge
    final keys = InputModeTracker.isKeyboardMode(context);
    final focusShown = _focused && keys;
    Widget child = FocusableWrapper(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      autofocusFallback: widget.autofocusFallback,
      railEntry: widget.railEntry,
      canRequestFocus: widget.focusable && (widget.onTap != null || widget.onLongPress != null),
      onSelect: widget.onTap == null ? null : _select,
      onLongPress: widget.onLongPress,
      enableLongPress: widget.onLongPress != null,
      onFocusChange: (focused) => setState(() => _focused = focused),
      borderRadius: widget.focusRadius ?? FocusTheme.defaultBorderRadius,
      matchChildShape: widget.focusRadius == null,
      disableScale: widget.focusScale == 1,
      focusScale: widget.focusScale,
      focusInset: widget.focusInset,
      useFocusGlow: widget.focusGlow,
      child: MouseRegion(
        cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          // While a D-pad is in charge a pointer lights nothing up. A mouse parked on the
          // screen (a remote with a touchpad, an air mouse) left the card under it lit, beside
          // the one the remote was really on: "a white border ... like a shadow".
          child: widget.builder(context, keys ? focusShown : _hovered, _pressed),
        ),
      ),
    );
    if (widget.tooltip != null) child = Tooltip(message: widget.tooltip!, child: child);
    return child;
  }
}

/// Every placeholder button lands here until the real screen exists.
/// VyseTV's Discord, opened in the browser (About in Settings, and the foot of Home).
const discordInvite = 'https://discord.gg/dUJTGnUhz2';

Future<void> openDiscord(BuildContext context) async {
  final ok = await launchUrl(Uri.parse(discordInvite), mode: LaunchMode.externalApplication).catchError((Object _) => false);
  if (!ok && context.mounted) {
    showToast(context, const Text("Couldn't open Discord. The invite is discord.gg/dUJTGnUhz2", style: TextStyle(fontSize: 13)), icon: Icons.error_outline);
  }
}

void comingSoon(BuildContext context, String what) => showToast(
      context,
      Text.rich(
        TextSpan(children: [
          TextSpan(text: what, style: const TextStyle(fontWeight: FontWeight.w700)),
          const TextSpan(text: '  is coming soon', style: TextStyle(color: VyseColors.textDim)),
        ]),
        style: const TextStyle(fontSize: 13, color: VyseColors.text),
      ),
    );

/// [onTap]: the toast can be pressed (a message opens its chat), and stays up longer for it.
void showToast(BuildContext context, Widget message, {IconData icon = Icons.auto_awesome_rounded, VoidCallback? onTap}) {
  // A snack bar is drawn by the page's Scaffold, and only the main pages have one: from the
  // player, a watch party or a dialog it would come up underneath, unseen. There the toast goes
  // on top of everything instead.
  final above = Scaffold.maybeOf(context) == null ? Overlay.maybeOf(context, rootOverlay: true) : null;
  if (above != null) {
    _toastAbove(above, message, icon: icon, onTap: onTap);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  // Solid, not see-through: toasts also pop up over bright video (watch party, live sports).
  final Widget panel = Glass(
    radius: 14,
    solid: true,
    borderColor: Colors.white.withValues(alpha: .14),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(children: [
      Icon(icon, size: 18, color: VyseColors.accent),
      const SizedBox(width: 10),
      // The SnackBar's own text style is dark (made for a light bar); ours is a dark panel.
      Expanded(
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
          child: message,
        ),
      ),
      if (onTap != null) const Icon(Icons.chevron_right_rounded, size: 18, color: VyseColors.textDim),
    ]),
  );
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.transparent,
      elevation: 0,
      duration: Duration(milliseconds: onTap == null ? 1600 : 4500),
      width: 340,
      content: onTap == null
          ? panel
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  messenger.hideCurrentSnackBar();
                  onTap();
                },
                child: panel,
              ),
            ),
    ),
  );
}

OverlayEntry? _toastEntry;
Timer? _toastTimer;

/// The toast for places without a Scaffold (see [showToast]): a pill at the top of the window,
/// over the player and anything else. One at a time; a new one replaces the last.
void _toastAbove(OverlayState overlay, Widget message, {required IconData icon, VoidCallback? onTap}) {
  void clear() {
    _toastTimer?.cancel();
    _toastTimer = null;
    _toastEntry?.remove();
    _toastEntry = null;
  }

  clear();
  final Widget panel = Glass(
    radius: 14,
    solid: true,
    borderColor: Colors.white.withValues(alpha: .14),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: VyseColors.accent),
      const SizedBox(width: 10),
      Flexible(
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
          child: message,
        ),
      ),
      if (onTap != null) ...[const SizedBox(width: 6), const Icon(Icons.chevron_right_rounded, size: 18, color: VyseColors.textDim)],
    ]),
  );
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      top: MediaQuery.viewPaddingOf(context).top + 18,
      left: 16,
      right: 16,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          // It slides in; nothing over the video may fade (the video is a native surface
          // behind Flutter's).
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: -1.4, end: 0),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (_, t, child) => FractionalTranslation(translation: Offset(0, t), child: child),
            child: Material(
              type: MaterialType.transparency,
              child: onTap == null
                  ? IgnorePointer(child: panel)
                  : MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          clear();
                          onTap();
                        },
                        child: panel,
                      ),
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  _toastEntry = entry;
  overlay.insert(entry);
  _toastTimer = Timer(Duration(milliseconds: onTap == null ? 2600 : 4500), () {
    if (_toastEntry == entry) clear();
  });
}

/// Frosted panel used by the rail, bottom bar and floating controls.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding,
    this.opacity = .55,
    this.blur = 22,
    this.borderColor = VyseColors.stroke,
    this.solid = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double opacity;
  final double blur;
  final Color borderColor;

  /// The no-blur look (as on Android). For panels over the video: the player draws it on a
  /// native surface behind Flutter, where a BackdropFilter can't see it.
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final light = lightEffects || solid;
    final panel = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: r,
        // without the blur behind it, a denser tint keeps text just as readable
        color: VyseColors.surface.withValues(alpha: light ? (opacity + .35).clamp(0, .96) : opacity),
        border: Border.all(color: borderColor),
      ),
      child: child,
    );
    if (light) return panel;
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: panel),
    );
  }
}

/// Android: skip live background blurs. Re-blurring everything behind a panel on every frame is
/// cheap on a desktop GPU but one of the costliest things a phone does while scrolling.
final bool lightEffects = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// A gradient of the page's colour over a picture, from one edge, clear from its last stop on.
///
/// It is laid only as far as it reaches. A gradient over the whole picture is the whole picture
/// blended again for every frame, and most of it blends nothing: the pixels are the same, there
/// are just fewer of them.
class Scrim extends StatelessWidget {
  const Scrim.left({super.key, required this.alphas, required this.stops, this.color = VyseColors.bg})
    : _from = Alignment.centerLeft,
      _to = Alignment.centerRight;
  const Scrim.bottom({super.key, required this.alphas, required this.stops, this.color = VyseColors.bg})
    : _from = Alignment.bottomCenter,
      _to = Alignment.topCenter;
  const Scrim.top({super.key, required this.alphas, required this.stops, this.color = VyseColors.bg})
    : _from = Alignment.topCenter,
      _to = Alignment.bottomCenter;

  /// How much of [color] at each of [stops]; the last is 0.
  final List<double> alphas;

  /// Where each of [alphas] sits, as a fraction of the whole box from the scrim's edge. The
  /// last one is how far the scrim reaches.
  final List<double> stops;
  final Color color;
  final Alignment _from, _to;

  @override
  Widget build(BuildContext context) {
    assert(alphas.last == 0 && alphas.length == stops.length);
    final reach = stops.last;
    final across = _from.y == 0;
    return FractionallySizedBox(
      alignment: _from,
      widthFactor: across ? reach : null,
      heightFactor: across ? null : reach,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: _from,
            end: _to,
            colors: [for (final a in alphas) color.withValues(alpha: a)],
            stops: [for (final s in stops) s / reach],
          ),
        ),
      ),
    );
  }
}

/// A picture as a soft wash of its colours behind a page: what a heavy blur of it looks like.
///
/// A real blur (ImageFiltered) draws the picture into an off-screen buffer and blurs that again
/// for every frame the page draws, which a desktop doesn't notice and a TV box cannot afford.
/// This decodes the picture a few dozen pixels wide and lets the stretch do the blurring: one
/// draw, and a picture in memory a thousand times smaller. For the lean interface
/// (core/lean.dart).
class ArtWash extends StatelessWidget {
  const ArtWash({super.key, required this.url, this.sigma = 40, this.filter, this.alignment = Alignment.center});
  final String? url;

  /// The blur this stands in for: a heavier one is decoded smaller.
  final double sigma;

  /// Painted with the picture, in the same draw: a dim, a tint.
  final ColorFilter? filter;
  final Alignment alignment;

  /// [color] laid over the picture, as a filter for [filter]: what a see-through box of that
  /// colour over it comes to (and, over a page of that colour, the picture at 1 - alpha).
  static ColorFilter veil(Color color) => ColorFilter.mode(color, BlendMode.srcOver);

  /// The colour matrix [m] (as for ColorFilter.matrix) and then a veil of [color], as one filter.
  static ColorFilter matrixThenVeil(List<double> m, Color color) {
    final a = color.a, k = 1 - a;
    final add = [color.r, color.g, color.b];
    return ColorFilter.matrix([
      for (var row = 0; row < 3; row++) ...[
        for (var col = 0; col < 4; col++) m[row * 5 + col] * k,
        m[row * 5 + 4] * k + add[row] * 255 * a,
      ],
      ...m.sublist(15),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null || u.isEmpty) return const SizedBox.expand();
    return DecoratedBox(
      decoration: BoxDecoration(
        image: DecorationImage(
          image: ResizeImage(CachedNetworkImageProvider(u), width: (1600 / sigma).round().clamp(16, 48)),
          fit: BoxFit.cover,
          alignment: alignment,
          colorFilter: filter,
          onError: (_, _) {},
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// The dim over a backdrop picture, as one colour to paint the picture with (its colour
/// filter): [base] with the page at its top.
///
/// Lean (a TV, core/lean.dart): it also deepens as [scroll] moves down, where the page used to
/// lay a see-through box over the whole screen: that box was the whole screen blended again
/// for every frame the page stood scrolled, which on a TV is most of the time. (Veils of one
/// colour come to the same picture in any order, so nothing looks different.) It deepens in
/// steps too small to see, so the picture is built again a few dozen times over the first
/// stretch of a scroll and not for every pixel of it.
///
/// Elsewhere it stays at [base] and the page lays its box as before.
class ScrollVeil extends StatefulWidget {
  const ScrollVeil({super.key, required this.scroll, required this.base, required this.builder});
  final ScrollController scroll;
  final double base;
  final Widget Function(BuildContext context, Color veil) builder;

  // (as the pages' own darkening box: up to .55 more, over the first 500 pixels)
  static const _deepen = .55, _over = 500.0, _steps = 32;

  @override
  State<ScrollVeil> createState() => _ScrollVeilState();
}

class _ScrollVeilState extends State<ScrollVeil> {
  int _step = 0;

  int _read() {
    final s = widget.scroll;
    if (!Lean.on || !s.hasClients) return 0;
    return ((s.offset / ScrollVeil._over).clamp(0.0, 1.0) * ScrollVeil._steps).round();
  }

  void _moved() {
    final step = _read();
    if (step != _step && mounted) setState(() => _step = step);
  }

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_moved);
    _step = _read();
  }

  @override
  void didUpdateWidget(ScrollVeil old) {
    super.didUpdateWidget(old);
    if (old.scroll == widget.scroll) return;
    old.scroll.removeListener(_moved);
    widget.scroll.addListener(_moved);
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_moved);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final more = Lean.on ? ScrollVeil._deepen * _step / ScrollVeil._steps : 0.0;
    return widget.builder(context, VyseColors.bg.withValues(alpha: 1 - (1 - widget.base) * (1 - more)));
  }
}

/// A scrolling list that melts away at its ends rather than being cut, through [shader].
///
/// The melt is an off-screen copy of the whole list, drawn again for every frame. Lean (a TV,
/// core/lean.dart): the list alone, cut at its edge.
class EdgeFade extends StatelessWidget {
  const EdgeFade({super.key, required this.shader, required this.child});
  final ShaderCallback shader;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Lean.on ? child : ShaderMask(blendMode: BlendMode.dstIn, shaderCallback: shader, child: child);
}

class VyseMark extends StatelessWidget {
  const VyseMark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset('assets/brand/vyse_mark.svg', width: size, height: size);
}

class VyseWordmark extends StatelessWidget {
  const VyseWordmark({super.key, this.fontSize = 20});
  final double fontSize;

  @override
  Widget build(BuildContext context) => Text.rich(
        TextSpan(children: const [
          TextSpan(text: 'Vyse'),
          TextSpan(text: 'TV', style: TextStyle(color: VyseColors.accent)),
        ]),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w900, letterSpacing: -.6),
      );
}

/// Fades and lifts its child in once, after [delay]. Used for staggered row entrances.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero, this.offset = 18, this.dx = 0});
  final Widget child;
  final Duration delay;
  final double offset;

  /// Horizontal travel, for panels that slide in from the side.
  final double dx;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  late final _t = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  Timer? _timer;

  // Lean (a TV): it is simply there. A row fading up is its whole width drawn through an
  // off-screen buffer for forty frames, and a page of rows did that one after the other.
  final _plain = Lean.on;

  @override
  void initState() {
    super.initState();
    if (_plain) return;
    _timer = Timer(widget.delay, () => mounted ? _c.forward() : null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _plain
      ? widget.child
      : AnimatedBuilder(
        animation: _t,
        child: widget.child,
        builder: (_, child) => Opacity(
          opacity: _t.value,
          child: Transform.translate(
            offset: Offset(widget.dx * (1 - _t.value), widget.offset * (1 - _t.value)),
            child: child,
          ),
        ),
      );
}

/// Moving sheen over skeleton blocks while rows load.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  // Lean (a TV): the blocks stand still. The sheen is an off-screen buffer redrawn for every
  // frame for as long as anything is loading, and on a slow network that is most of the time.
  late final AnimationController? _c = Lean.on ? null : (AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat());

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  // (marked as loading for a D-pad: a first focus waits for what this stands in for, rather
  // than going to a control further down the page)
  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return DpadLoading(child: widget.child);
    return _sheen(c);
  }

  Widget _sheen(AnimationController c) => DpadLoading(
        child: AnimatedBuilder(
          animation: c,
          child: widget.child,
          builder: (_, child) => ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) {
              final dx = bounds.width * 3 * c.value - bounds.width;
              return LinearGradient(
                colors: const [VyseColors.surface, VyseColors.surfaceHi, VyseColors.surface],
                stops: const [.35, .5, .65],
                transform: _Slide(dx),
              ).createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height));
            },
            child: child,
          ),
        ),
      );
}

class _Slide extends GradientTransform {
  const _Slide(this.dx);
  final double dx;
  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) => Matrix4.translationValues(dx, 0, 0);
}

class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, required this.width, required this.height, this.radius = 12});
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: VyseColors.surface, borderRadius: BorderRadius.circular(radius)),
      );
}

/// Small round icon button on glass, used in the hero and top bar.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({super.key, required this.icon, required this.label, this.onTap, this.size = 44});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Pressable(
        tooltip: label,
        onTap: onTap ?? () => comingSoon(context, label),
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .92 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: hovered ? .2 : .1),
              border: Border.all(color: Colors.white.withValues(alpha: hovered ? .35 : .14)),
            ),
            child: Icon(icon, size: size * .45, color: VyseColors.text),
          ),
        ),
      );
}

/// Pill button: solid white for primary, glass for secondary.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.icon,
    this.primary = false,
    this.onTap,
    this.expand = false,
    this.accent,
  });

  final String label;
  final IconData icon;
  final bool primary;
  final bool expand;

  /// A primary pill in this colour instead of white (Music follows the Appearance theme).
  final Color? accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap ?? () => comingSoon(context, label),
        builder: (context, hovered, pressed) {
          final a = primary ? accent : null;
          final fg = a != null ? (a.computeLuminance() > .3 ? Colors.black : Colors.white) : (primary ? Colors.black : VyseColors.text);
          return AnimatedScale(
            scale: pressed ? .95 : (hovered ? 1.03 : 1),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: a != null
                    ? (hovered ? Color.lerp(a, Colors.white, .15) : a)
                    : primary
                    ? (hovered ? Colors.white : const Color(0xFFF1F1F5))
                    : Colors.white.withValues(alpha: hovered ? .2 : .1),
                border: primary ? null : Border.all(color: Colors.white.withValues(alpha: .14)),
                boxShadow: primary && hovered
                    ? [BoxShadow(color: (a ?? Colors.white).withValues(alpha: a != null ? .45 : .25), blurRadius: 24)]
                    : null,
              ),
              child: Row(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: fg),
                  const SizedBox(width: 8),
                  Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 14)),
                ],
              ),
            ),
          );
        },
      );
}
