// From upstream (lib/focus/focusable_wrapper.dart, GPL-3.0). Kept as upstream wrote it so the two
// can be compared; anything changed for VyseTV is marked "VyseTV". In short:
// - the look (scale, ring, glow) is drawn by focus_chrome.dart, which is always in the tree, so
//   nothing under this widget is rebuilt from scratch when focus or the input mode changes;
// - scrolling into view is dpad_reveal.dart (every list the control sits in, clear of the
//   app's bars), not the nearest vertical list only;
// - OK is ignored while a mouse or a finger is in charge (the focus is not shown then);
// - Upstream's click cursor and text-input diagnostics are not here.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core/platform/device_performance.dart';
import 'dpad_navigator.dart';
import 'dpad_reveal.dart';
import 'dpad_select_long_press_controller.dart';
import 'dpad_traversal.dart';
import 'focus_chrome.dart';
import 'focus_theme.dart';
import 'input_mode_tracker.dart';
import 'owned_focus_node_binding.dart';
import 'key_event_utils.dart';

/// A wrapper widget that makes its child focusable with D-pad navigation support.
///
class FocusableWrapper extends StatefulWidget {
  final Widget child;

  /// Called when the item is selected (Enter/Select/GamepadA).
  /// For short press when [enableLongPress] is true.
  final VoidCallback? onSelect;

  /// Called when long press is triggered (hold SELECT key or context menu key).
  /// Only triggered if [enableLongPress] is true.
  final VoidCallback? onLongPress;

  /// Called when focus changes.
  final ValueChanged<bool>? onFocusChange;

  /// Called when the user presses UP and there's no focusable item above.
  final VoidCallback? onNavigateUp;

  /// Called when the user presses DOWN and there's no focusable item below.
  final VoidCallback? onNavigateDown;

  /// Called when the user presses LEFT and there's no focusable item to the left.
  final VoidCallback? onNavigateLeft;

  /// Called when the user presses RIGHT and there's no focusable item to the right.
  final VoidCallback? onNavigateRight;

  /// Called when the user presses BACK.
  final VoidCallback? onBack;

  /// Whether this widget should request focus when first built.
  final bool autofocus;

  /// VyseTV: where a D-pad lands when nothing on the page is marked [autofocus] (the selected
  /// tab of a tab strip). It never takes focus by itself.
  final bool autofocusFallback;

  /// VyseTV: where focus lands when it comes into this control's rail from across it (the
  /// showing tab of a strip of tabs). Unlike [autofocusFallback] it says nothing about where
  /// the page starts.
  final bool railEntry;

  /// Optional external FocusNode for programmatic focus control.
  final FocusNode? focusNode;

  /// Border radius for the focus indicator.
  final double borderRadius;

  /// Per-corner radii for the focus indicator; overrides [borderRadius] when
  /// set (M3E grouped cards: large outer / small inner corners).
  final BorderRadius? borderRadii;

  /// Whether to scroll the widget into view when focused.
  final bool autoScroll;

  /// Alignment for auto-scroll (0.0 = start, 0.5 = center, 1.0 = end).
  final double scrollAlignment;

  /// Whether to use comfortable zone scrolling (only scroll if item is outside middle 60%).
  /// If false, always scrolls to [scrollAlignment].
  final bool useComfortableZone;

  /// Optional semantic label for accessibility.
  final String? semanticLabel;

  /// Optional current value announced after [semanticLabel].
  final String? semanticValue;

  /// Whether this wrapper replaces semantics contributed by [child].
  ///
  /// The default (`true`) replacement mode produces one operable control node for
  /// labeled wrappers. Set this to `false` only to supplement non-interactive
  /// child content; a child that already owns a role or actions would conflict
  /// with this wrapper's button and activation semantics.
  final bool excludeChildSemantics;

  /// Optional checked state for toggle-style controls.
  final bool? checked;

  /// Whether the wrapper can receive focus.
  final bool canRequestFocus;

  /// Custom key event handler. Return any non-ignored result to stop default handling.
  /// This is called before the default key handling.
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;

  /// Whether to enable long-press detection for SELECT key.
  /// When enabled, holding SELECT triggers [onLongPress] after 500ms.
  /// Short press triggers [onSelect].
  final bool enableLongPress;

  /// Whether to use a translucent background fill instead of a border for the
  /// focus indicator.
  final bool useBackgroundFocus;

  /// Custom focus color: the border color, or the fill when
  /// [useBackgroundFocus] is set. Useful for filled buttons where the default
  /// primary border blends in, and for controls over video, which pass
  /// [FocusTheme.onMediaFocusFill] instead of the theme-derived fill.
  final Color? focusColor;

  /// Whether to disable the scale animation on focus.
  /// Useful for elements like sliders where scaling looks odd.
  final bool disableScale;

  final double focusScale;

  /// Whether to draw a glow around the focused widget.
  final bool useFocusGlow;

  // VyseTV: upstream's delegateFocusBorder (the card draws its own border) is left out; no
  // VyseTV card needs it.

  /// VyseTV: take the ring's corners from what the child draws (a pill, a circle, a card)
  /// instead of [borderRadius], which is then only the fallback. See `ownShape`.
  final bool matchChildShape;

  /// VyseTV: how far inside the control's edges the ring sits. Negative draws it outside, for
  /// a control with no room of its own.
  final EdgeInsets focusInset;

  /// Whether descendants can receive focus.
  /// Set to false when the child widget has its own Focus (e.g. buttons)
  /// that would compete with this wrapper's focus handling.
  final bool descendantsAreFocusable;

  /// Whether the [Focus] node contributes focusable/focused semantics.
  ///
  /// Keep this enabled unless an equivalent child semantic action remains and
  /// accessibility navigation is known to be inactive.
  final bool includeFocusSemantics;

  const FocusableWrapper({
    super.key,
    required this.child,
    this.onSelect,
    this.onLongPress,
    this.onFocusChange,
    this.onNavigateUp,
    this.onNavigateDown,
    this.onNavigateLeft,
    this.onNavigateRight,
    this.onBack,
    this.autofocus = false,
    this.autofocusFallback = false,
    this.railEntry = false,
    this.focusNode,
    this.borderRadius = FocusTheme.defaultBorderRadius,
    this.borderRadii,
    this.autoScroll = true,
    this.scrollAlignment = 0.5,
    this.useComfortableZone = false,
    this.semanticLabel,
    this.semanticValue,
    this.excludeChildSemantics = true,
    this.checked,
    this.canRequestFocus = true,
    this.onKeyEvent,
    this.enableLongPress = false,
    this.useBackgroundFocus = false,
    this.focusColor,
    this.disableScale = false,
    this.focusScale = FocusTheme.focusScale,
    this.useFocusGlow = false,
    this.matchChildShape = false,
    this.focusInset = EdgeInsets.zero,
    this.descendantsAreFocusable = true,
    this.includeFocusSemantics = true,
  });

  @override
  State<FocusableWrapper> createState() => _FocusableWrapperState();
}

class _FocusableWrapperState extends State<FocusableWrapper> with SingleTickerProviderStateMixin {
  final OwnedFocusNodeBinding _focusNodeBinding = OwnedFocusNodeBinding();
  FocusNode get _focusNode => _focusNodeBinding.node;
  bool _isFocused = false;

  // VyseTV: the focus look is for the control focus is on, not for one that focus is somewhere
  // inside. A card with buttons of its own (a portal and its star, a row and its Play) kept its
  // ring and its growth while one of its buttons had focus: two rings, and the button's drawn
  // where the card's growth had not moved it (testers: "misborder alignments"). [_isFocused]
  // still says focus is here or inside, for everything else.
  bool _primary = false;
  FocusNode? _watched;

  void _watchNode() {
    final node = _focusNode;
    if (identical(node, _watched)) return;
    _watched?.removeListener(_onNode);
    _watched = node..addListener(_onNode);
    _primary = node.hasPrimaryFocus;
  }

  void _onNode() {
    final primary = _focusNode.hasPrimaryFocus;
    if (primary == _primary || !mounted) return;
    // (built again: the first time it shows, the look's animation is made here and the
    // chrome has to be handed it)
    setState(() => _primary = primary);
    _syncChrome();
  }

  // Created lazily on first focus/keyboard-mode build: touch scrolling builds
  // hundreds of these wrappers and must not pay for a Ticker per card.
  AnimationController? _animationController;

  // VyseTV: the glow lives in an overlay entry of its own (see focus_chrome.dart), put up
  // when focus shows and taken down once it has faded.
  final LayerLink _glowLink = LayerLink();
  final FocusShape _shape = FocusShape();
  OverlayEntry? _glowEntry;
  bool _glowInserted = false;
  bool _keyboardMode = false;

  final _selectLongPress = DpadSelectLongPressController();

  @override
  void initState() {
    super.initState();
    _bindFocusNode();
    if (widget.autofocus) {
      _announceStart();
    } else {
      Dpad.stopArrived(_focusNode); // (VyseTV: see Dpad.stopArrived)
    }
  }

  /// VyseTV: whether this control sits inside another one that focus can rest on.
  static bool _insideAControl(BuildContext context) {
    var at = context;
    for (var i = 0; i < 64; i++) {
      final node = Focus.maybeOf(at, scopeOk: true, createDependency: false);
      final next = node?.context;
      if (node == null || next == null || node is FocusScopeNode) return false;
      if ((DpadReveal.ownerReveals[node] ?? false) && node.canRequestFocus && !node.skipTraversal) return true;
      at = next;
    }
    return false;
  }

  // VyseTV: a page's start that comes on screen after the page did (see Dpad.startArrived)
  void _announceStart() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && widget.autofocus && InputModeTracker.currentMode == InputMode.keyboard) Dpad.startArrived(_focusNode);
  });

  void _bindFocusNode() {
    _focusNodeBinding.bind(externalNode: widget.focusNode, debugLabel: widget.semanticLabel ?? 'FocusableWrapper');
    _focusNode.canRequestFocus = widget.canRequestFocus;
    // VyseTV: this widget brings its node into view itself (see dpad_reveal.dart)
    DpadReveal.ownerReveals[_focusNode] = true;
    DpadReveal.startsPage[_focusNode] = widget.autofocus;
    DpadReveal.startsPageElse[_focusNode] = widget.autofocusFallback;
    DpadReveal.entersRail[_focusNode] = widget.railEntry;
    _watchNode();
  }

  AnimationController _ensureAnimationController() {
    final existing = _animationController;
    if (existing != null) return existing;
    // (kept at its length where animations are cut short, core/lean.dart: the ring is what the eye follows)
    final controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 150), animationBehavior: AnimationBehavior.preserve);
    controller.addStatusListener(_onChromeStatus);
    _animationController = controller;
    return controller;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // VyseTV: the one place this widget subscribes to the input mode. A flip rebuilds it, and
    // the look follows from here rather than from a different widget tree per mode.
    _keyboardMode = InputModeTracker.isKeyboardMode(context);
    _syncChrome();
  }

  @override
  void didUpdateWidget(FocusableWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      _bindFocusNode();
    }

    if (widget.canRequestFocus != oldWidget.canRequestFocus) {
      _focusNode.canRequestFocus = widget.canRequestFocus;
      _syncChrome(); // (its ring goes or comes with it)
    }

    if (widget.autofocus != oldWidget.autofocus) {
      DpadReveal.startsPage[_focusNode] = widget.autofocus;
      if (widget.autofocus) _announceStart();
    }
    if (widget.autofocusFallback != oldWidget.autofocusFallback) {
      DpadReveal.startsPageElse[_focusNode] = widget.autofocusFallback;
    }
    if (widget.railEntry != oldWidget.railEntry) {
      DpadReveal.entersRail[_focusNode] = widget.railEntry;
    }
  }

  @override
  void dispose() {
    _selectLongPress.dispose();
    _removeGlow();
    _animationController?.dispose();
    _watched?.removeListener(_onNode);
    _focusNodeBinding.dispose();
    super.dispose();
  }

  // VyseTV: a wrapper that cannot take focus itself is not a control (a player's tile once the
  // player fills the window): focus on something inside it draws nothing round it.
  bool get _showFocus => _primary && _keyboardMode && widget.canRequestFocus;

  /// VyseTV: runs the look in or out to match [_showFocus], and the glow with it.
  void _syncChrome() {
    if (_showFocus) {
      final controller = _ensureAnimationController();
      final duration = FocusTheme.getAnimationDuration(context);
      if (controller.duration != duration) controller.duration = duration;
      controller.forward();
      if (widget.useFocusGlow && !DevicePerformance.isReduced) _showGlow();
    } else {
      final controller = _animationController;
      if (controller == null) return;
      if (controller.isDismissed) {
        _removeGlow();
      } else {
        controller.reverse();
      }
    }
  }

  void _onChromeStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) _removeGlow();
  }

  void _showGlow() {
    if (_glowEntry != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final color = widget.focusColor ?? FocusTheme.getFocusBorderColor(context);
    final progress = CurvedAnimation(parent: _animationController!, curve: Curves.easeOutCubic);
    final entry = _glowEntry = OverlayEntry(
      builder: (_) => FocusGlow(link: _glowLink, progress: progress, color: color, shape: _shape),
    );
    void insert() {
      if (!mounted || !identical(_glowEntry, entry) || !overlay.mounted) return;
      overlay.insert(entry);
      _glowInserted = true;
      setState(() {}); // the chrome starts leading the glow
    }

    // An overlay cannot take an entry while the frame is being built (a mode flip rebuilds us).
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => insert());
    } else {
      insert();
    }
  }

  void _removeGlow() {
    final entry = _glowEntry;
    if (entry == null) return;
    _glowEntry = null;
    if (_glowInserted) entry.remove();
    _glowInserted = false;
    entry.dispose();
    if (mounted && SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) setState(() {});
  }

  BorderRadius get _radius => widget.borderRadii ?? BorderRadius.circular(widget.borderRadius);

  void _handleFocusChange(bool hasFocus) {
    if (_isFocused != hasFocus) {
      setState(() {
        _isFocused = hasFocus;
      });

      // Reset long press state when focus is lost
      if (!hasFocus) {
        _selectLongPress.reset();
      }

      // Animate scale (VyseTV: and the ring and the glow, which share the controller)
      _syncChrome();

      // Auto-scroll into view. Keyboard/D-pad sessions only: pointer-mode
      // focus is invisible and only ever parked or restored programmatically
      // (entry focus targets, a context menu re-focusing its trigger on
      // close), so revealing it would yank the viewport away from wherever
      // the user scrolled (issue #2031).
      if (hasFocus && widget.autoScroll && InputModeTracker.currentMode == InputMode.keyboard) {
        _scrollIntoView();
      }

      // Notify listener
      widget.onFocusChange?.call(hasFocus);
    }
  }

  void _scrollIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isFocused) return;
      // VyseTV: every list the control sits in, and clear of the app's bars (dpad_reveal.dart).
      // Upstream scrolls the nearest vertical list only.
      DpadReveal.reveal(context, alignment: widget.scrollAlignment, comfortable: widget.useComfortableZone);
    });
    // addPostFrameCallback does not ask for a frame; focus arriving by a key press may not
    // otherwise produce one.
    WidgetsBinding.instance.scheduleFrame();
  }

  // Runs the same activation sequence as FocusableChipStateMixin.handleChipKeyEvent
  // but is deliberately kept separate: a wrapper always consumes the context-menu
  // key (even with no onLongPress, so a card never leaks it upward) and passes
  // every unmapped arrow through to framework traversal, where a chip does the
  // opposite on both counts.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    // VyseTV: upstream logs each step through its text-input diagnostics; the steps are kept, the
    // logging is not.
    KeyEventResult finish(KeyEventResult result, String reason) => result;

    if (SelectKeyUpSuppressor.consumeIfSuppressed(event)) {
      if (event is KeyUpEvent && key.isSelectKey) {
        _selectLongPress.reset();
      }
      return finish(KeyEventResult.handled, 'select-key-up-suppressed');
    }

    // Call custom key handler first
    if (widget.onKeyEvent != null) {
      final result = widget.onKeyEvent!(node, event);
      if (result != KeyEventResult.ignored) {
        return finish(result, 'custom-onKeyEvent');
      }
    }

    if (widget.onBack != null) {
      final backResult = handleBackKeyAction(event, widget.onBack!);
      if (backResult != KeyEventResult.ignored) {
        return finish(backResult, 'onBack');
      }
    }

    if (key.isSelectKey) {
      // VyseTV: OK presses the control that has the ring. When that is a button inside this one
      // (a card's own Material buttons: a portal's rename, copy and star), the key only passes
      // through here on its way up to Flutter's shortcuts, which press that button; this one
      // must not answer for it. (A text field inside keeps the old way: OK there is the field's.)
      if (!node.hasPrimaryFocus && !isTextEditingFocused()) {
        _selectLongPress.reset();
        return finish(KeyEventResult.ignored, 'select-belongs-to-a-control-inside');
      }
      // VyseTV: with a mouse or a finger in charge the focus is not drawn, so OK must not
      // press something the user cannot see. An arrow brings the ring back first.
      if (InputModeTracker.currentMode != InputMode.keyboard) {
        _selectLongPress.reset();
        return finish(KeyEventResult.ignored, 'select-in-pointer-mode');
      }
      if (widget.enableLongPress) {
        final result = _selectLongPress.handleKeyEvent(
          event,
          isOwnerActive: () => mounted,
          onShortPress: () => widget.onSelect?.call(),
          onLongPress: () => widget.onLongPress?.call(),
        );
        if (result != KeyEventResult.ignored) {
          return finish(result, 'select-long-press');
        }
      } else if (widget.onSelect != null) {
        return finish(handleOneShotSelect(event, widget.onSelect!), 'one-shot-select');
      }
    }

    // Ignore key up events for other keys
    if (!event.isActionable) {
      return finish(KeyEventResult.ignored, 'non-actionable');
    }

    // Context menu key
    if (key.isContextMenuKey) {
      _selectLongPress.reset();
      widget.onLongPress?.call();
      return finish(KeyEventResult.handled, 'context-menu');
    }

    // UP arrow - if callback provided, navigate up
    if (key == LogicalKeyboardKey.arrowUp && widget.onNavigateUp != null) {
      widget.onNavigateUp!();
      return finish(KeyEventResult.handled, 'onNavigateUp');
    }

    // DOWN arrow - if callback provided, navigate down
    if (key == LogicalKeyboardKey.arrowDown && widget.onNavigateDown != null) {
      widget.onNavigateDown!();
      return finish(KeyEventResult.handled, 'onNavigateDown');
    }

    // LEFT arrow - if callback provided, navigate left (caller is responsible
    // for only providing this callback when the item is at the left edge)
    if (key == LogicalKeyboardKey.arrowLeft && widget.onNavigateLeft != null) {
      widget.onNavigateLeft!();
      return finish(KeyEventResult.handled, 'onNavigateLeft');
    }

    // RIGHT arrow - if callback provided, navigate right (caller is responsible
    // for only providing this callback when the item is at the right edge)
    if (key == LogicalKeyboardKey.arrowRight && widget.onNavigateRight != null) {
      widget.onNavigateRight!();
      return finish(KeyEventResult.handled, 'onNavigateRight');
    }

    return finish(KeyEventResult.ignored, 'fall-through');
  }

  @override
  Widget build(BuildContext context) {
    // Only show focus effects during keyboard/d-pad navigation.
    // VyseTV: upstream builds a different subtree per input mode. Here the chrome is always the
    // child of the Focus; with no focus it paints its child and nothing more, so a mouse or a
    // finger pays for one extra render object and the child keeps its state when a remote is
    // picked up.
    final controller = _animationController;
    // VyseTV: inside a region (a menu drawn over its page, a bar) the start is only a mark.
    // The region is entered by the kit, which honours the mark; Flutter's own autofocus
    // would pull focus into a menu the moment it is built, mouse in charge or not, and off
    // whatever was using the keys (the picture in a player).
    // The same inside another control (the Play button of a player's tile in a room): the
    // mark says where stepping into the tile lands, and the page's keyboard stays where it is.
    final markOnly = widget.autofocus && (FocusScope.of(context) is DpadRegionNode || _insideAControl(context));
    Widget result = Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus && !markOnly,
      includeSemantics: widget.includeFocusSemantics,
      descendantsAreFocusable: widget.descendantsAreFocusable,
      onFocusChange: _handleFocusChange,
      onKeyEvent: _handleKeyEvent,
      child: FocusChrome(
        progress: controller,
        color: widget.focusColor ?? (controller == null ? const Color(0x00000000) : FocusTheme.getFocusBorderColor(context)),
        radius: widget.matchChildShape && widget.borderRadii == null ? null : _radius,
        fallbackRadius: _radius,
        shape: _shape,
        scale: widget.disableScale ? 1 : widget.focusScale,
        inset: widget.focusInset,
        fill: widget.useBackgroundFocus,
        link: _glowInserted ? _glowLink : null,
        child: widget.child,
      ),
    );

    // Add semantics if label provided
    if (widget.semanticLabel != null) {
      result = Semantics(
        label: widget.semanticLabel,
        value: widget.semanticValue,
        button: true,
        enabled: widget.onSelect != null,
        checked: widget.checked,
        onTap: widget.onSelect,
        onLongPress: widget.onLongPress,
        excludeSemantics: widget.excludeChildSemantics,
        child: result,
      );
    }

    // VyseTV: upstream wraps this in its click cursor here; VyseTV's Pressable sets the cursor.

    return result;
  }
}
