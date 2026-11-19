import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SliverConstraints, SliverGridLayout, SliverGridRegularTileLayout;

import '../core/layout.dart';
import '../core/theme.dart';
import '../core/lean.dart';
import '../dpad/dpad_root.dart' show backBindings;
import '../dpad/dpad_traversal.dart';
import '../dpad/input_mode_tracker.dart';
import 'common.dart';
import 'voice_search.dart';

/// Shared furniture for the Manga / Music / Audiobooks / Live TV tabs: the warm glow behind the
/// header, the title block, a search field, filter chips and empty states.

/// Right edge padding that matches the TMDB pages.
double pageRight(BuildContext context) => Layout.isPhone(context) ? 16 : 40;

/// Room at the bottom so the phone bar and the now-playing bar never cover the last row.
double pageBottom(BuildContext context) =>
    Layout.isPhone(context) ? 180 + MediaQuery.paddingOf(context).bottom : 110;

/// Discover's soft amber + violet haze, parked in the top-right corner so pages aren't a flat slab.
class PageGlow extends StatelessWidget {
  const PageGlow({super.key});

  // (not on the weakest TV boxes, core/lean.dart: it is a third of the screen blended through a
  // round gradient for every frame, to look at)
  @override
  Widget build(BuildContext context) => Lean.weak
      ? const SizedBox.shrink()
      : IgnorePointer(
        child: Container(
          width: 640,
          height: 640,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [Color(0x1FFF8A1A), Color(0x0F7A5CFF), Color(0x0007080F)], stops: [0, .45, 1]),
          ),
        ),
      );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, required this.subtitle, this.trailing});
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final canPop = Navigator.of(context).canPop();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (canPop) ...[
        Transform.translate(offset: const Offset(-8, 0), child: BackLink(onTap: () => Navigator.of(context).maybePop())),
        const SizedBox(height: 10),
      ],
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FadeSlideIn(
              offset: 10,
              child: Text(title,
                  style: TextStyle(fontSize: phone ? 28 : 32, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.05)),
            ),
            const SizedBox(height: 6),
            FadeSlideIn(
              delay: const Duration(milliseconds: 60),
              offset: 8,
              child: Text(subtitle, style: const TextStyle(color: VyseColors.textDim, fontSize: 13)),
            ),
          ]),
        ),
        ?trailing,
      ]),
    ]);
  }
}

class BackLink extends StatelessWidget {
  const BackLink({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: hovered ? Colors.white.withValues(alpha: .1) : Colors.transparent,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.chevron_left_rounded, size: 20, color: hovered ? VyseColors.text : VyseColors.textDim),
            Text('Back',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.textDim)),
          ]),
        ),
      );
}

/// The glowing search bar from the Search tab, sized for a section header.
class VyseSearchField extends StatefulWidget {
  const VyseSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.busy = false,
    this.onSubmit,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final bool busy;
  final ValueChanged<String>? onSubmit;
  final bool autofocus;

  @override
  State<VyseSearchField> createState() => _VyseSearchFieldState();
}

class _VyseSearchFieldState extends State<VyseSearchField> {
  final _focus = FocusNode();
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
    widget.controller.addListener(_changed);
    if (widget.autofocus) {
      Future.delayed(const Duration(milliseconds: 350), () {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _clear() {
    widget.controller.clear();
    widget.onSubmit?.call('');
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final hasText = widget.controller.text.isNotEmpty;
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _focus.requestFocus,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          height: phone ? 48 : 52,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Colors.white.withValues(alpha: _focused ? .09 : (_hovered ? .07 : .05)),
            border: Border.all(
              color: _focused ? VyseColors.accent.withValues(alpha: .55) : Colors.white.withValues(alpha: _hovered ? .14 : .08),
              width: _focused ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: _focused ? VyseColors.accent.withValues(alpha: .16) : Colors.black.withValues(alpha: .25),
                blurRadius: _focused ? 32 : 18,
                offset: Offset(0, _focused ? 0 : 6),
              ),
            ],
          ),
          child: Row(children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: widget.busy
                  ? const SizedBox.square(
                      key: ValueKey('busy'),
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.accent),
                    )
                  : Icon(Icons.search_rounded,
                      key: const ValueKey('icon'), size: 20, color: _focused ? VyseColors.accent : VyseColors.textDim),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: CallbackShortcuts(
                // Back (Escape, a remote's Back, a controller's B): clears the text, then leaves the box
                bindings: backBindings(() {
                  if (hasText) {
                    _clear();
                  } else if (InputModeTracker.currentMode != InputMode.keyboard || !Dpad.stepOut(_focus)) {
                    _focus.unfocus();
                  }
                }),
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  onSubmitted: widget.onSubmit,
                  cursorColor: VyseColors.accent,
                  cursorWidth: 2,
                  cursorRadius: const Radius.circular(2),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: VyseColors.text),
                  decoration: InputDecoration.collapsed(
                    hintText: widget.hint,
                    hintStyle: const TextStyle(fontSize: 15, color: VyseColors.textFaint),
                  ),
                ),
              ),
            ),
            AnimatedScale(
              scale: hasText ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              child: Pressable(
                onTap: _clear,
                tooltip: 'Clear (Esc)',
                // scaled to nothing while the box is empty: not a stop then
                focusable: hasText,
                builder: (context, hovered, _) => AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: hovered ? .2 : .1)),
                  child: const Icon(Icons.close_rounded, size: 15),
                ),
              ),
            ),
            // on a TV: say what to look for
            if (VoiceSearch.offered) ...[
              const SizedBox(width: 8),
              VoiceSearchButton(controller: widget.controller, onHeard: widget.onSubmit, prompt: widget.hint),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Discover's sort pill: solid white when selected, bare text that lifts on hover otherwise.
class FilterChipPill extends StatelessWidget {
  const FilterChipPill({super.key, required this.label, required this.selected, required this.onTap, this.icon, this.tab = false});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// This chip is one of a page's tabs: with a D-pad the page starts on the selected one
  /// (unless something on the page is marked as its start), and coming up into the row of
  /// tabs lands on it. Wrap the row in a `DpadRail`.
  final bool tab;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        autofocusFallback: tab && selected,
        builder: (context, hovered, pressed) {
          final fg = selected ? Colors.black : (hovered ? VyseColors.text : VyseColors.textDim);
          return AnimatedScale(
            scale: pressed ? .94 : 1,
            duration: const Duration(milliseconds: 120),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.fromLTRB(icon == null ? 14 : 11, 8, 14, 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: selected ? Colors.white : Colors.white.withValues(alpha: hovered ? .1 : 0),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 15, color: fg), const SizedBox(width: 6)],
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg),
                  child: Text(label),
                ),
              ]),
            ),
          );
        },
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) => FadeSlideIn(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: .05)),
                child: Icon(icon, size: 28, color: VyseColors.textDim),
              ),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(body, textAlign: TextAlign.center, style: const TextStyle(color: VyseColors.textDim, fontSize: 13)),
              if (action != null) ...[
                const SizedBox(height: 16),
                TextButton(onPressed: action!.$2, child: Text(action!.$1)),
              ],
            ]),
          ),
        ),
      );
}

/// Network image with the app's placeholder and fallback.
class NetImage extends StatelessWidget {
  const NetImage({super.key, required this.url, this.fit = BoxFit.cover, this.fallback = Icons.image_not_supported_outlined, this.decodeWidth});
  final String? url;
  final BoxFit fit;
  final IconData fallback;

  /// How wide to decode the picture, in real pixels: about as wide as it is shown. Left out it
  /// is decoded as big as its file, which for a wall of posters from a source that sends them
  /// two or three thousand pixels tall is a great deal of memory and a long wait on a TV box.
  /// (See [decodeWidthFor].)
  final int? decodeWidth;

  /// A decode width for a picture shown [shown] logical pixels wide here: its real pixels,
  /// rounded up to a step so that a card a few pixels wider or narrower uses the same copy.
  /// (Nothing for a width that is not known yet: the picture is then decoded as it is.)
  static int? decodeWidthFor(BuildContext context, double shown) =>
      shown.isFinite && shown > 0 ? (((shown * MediaQuery.devicePixelRatioOf(context)) / 96).ceil() * 96).clamp(96, 1440) : null;

  @override
  Widget build(BuildContext context) {
    final empty = ColoredBox(
      color: VyseColors.surface,
      child: Center(child: Icon(fallback, color: VyseColors.textFaint, size: 22)),
    );
    if (url == null || url!.isEmpty) return empty;
    return CachedNetworkImage(
      imageUrl: url!,
      fit: fit,
      memCacheWidth: decodeWidth,
      fadeInDuration: const Duration(milliseconds: 300),
      placeholder: (_, _) => const ColoredBox(color: VyseColors.surface),
      errorWidget: (_, _, _) => empty,
    );
  }
}

/// Grid of art (width × [aspect]) with a fixed [caption] strip underneath. Columns are worked out
/// from [maxWidth], and the caption never shrinks with the cell, so titles can't overflow.
Widget captionedGrid({
  required double maxWidth,
  required double aspect,
  required double caption,
  required int itemCount,
  required IndexedWidgetBuilder itemBuilder,
  double spacing = 12,
  double runSpacing = 16,
}) =>
    SliverGrid.builder(
      gridDelegate: _CaptionedGridDelegate(maxWidth: maxWidth, aspect: aspect, caption: caption, spacing: spacing, runSpacing: runSpacing),
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    );

/// The layout of [captionedGrid], worked out from the width as the grid is laid out.
///
/// It used to be worked out in a SliverLayoutBuilder, which builds again whenever the sliver's
/// constraints change, and those hold the scroll offset: every cell on screen was built again
/// for every frame of a scroll. A playlist of eleven thousand channels "lagged" on a TV for it.
class _CaptionedGridDelegate extends SliverGridDelegate {
  const _CaptionedGridDelegate({required this.maxWidth, required this.aspect, required this.caption, required this.spacing, required this.runSpacing});
  final double maxWidth, aspect, caption, spacing, runSpacing;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final cross = constraints.crossAxisExtent;
    final cols = math.max(1, ((cross + spacing) / (maxWidth + spacing)).ceil());
    final w = math.max(0.0, cross - spacing * (cols - 1)) / cols;
    final h = w * aspect + caption;
    return SliverGridRegularTileLayout(
      crossAxisCount: cols,
      mainAxisStride: h + runSpacing,
      crossAxisStride: w + spacing,
      childMainAxisExtent: h,
      childCrossAxisExtent: w,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(_CaptionedGridDelegate old) =>
      old.maxWidth != maxWidth || old.aspect != aspect || old.caption != caption || old.spacing != spacing || old.runSpacing != runSpacing;
}
