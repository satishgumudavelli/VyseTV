// VyseTV's focus ring. The ideas are upstream's (lib/focus/focus_chrome.dart,
// focus_glow_overlay.dart and the paint-only scale in focusable_wrapper.dart, GPL-3.0): the
// focused control grows without being laid out again, and its glow is lifted above its
// neighbours through a LayerLink, for the one focused control only. The drawing is VyseTV's:
//
// - The ring is painted over the control, inside its own edge. Upstream puts a border around the
//   child, which makes every control a few pixels smaller while a remote is in use; here
//   nothing is ever laid out differently, with or without a remote.
// - One render object does the scale, the ring and the link, and it is always there, so the
//   widgets under it are never rebuilt from scratch when focus arrives or the input changes
//   (a poster does not fade in again, a hover animation carries on).
// - Nothing here uses an opacity or blur layer: the glow fades by its own colour. The video is
//   a hole through to a native surface, and such layers would paint over it.
// - While a control has its focus look it paints on a layer of its own, so each frame of the
//   ring coming and going records that one control again, not the page around it. (Without it
//   every arrow press recorded the whole page some nine times over, twice: once for the control
//   left and once for the one arrived at. A TV's processor has no time for that.)
// - A control whose picture is only part of it (a cast card: the portrait, with the name and the
//   role under it) marks that part with [FocusRingTarget], and the ring goes round the part.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'focus_theme.dart';

/// Wraps a focusable control and draws its focus look. [progress] runs 0 → 1 as focus arrives;
/// null means the control has never been focused, and then this paints its child and nothing
/// else.
class FocusChrome extends SingleChildRenderObjectWidget {
  const FocusChrome({
    super.key,
    required this.progress,
    required this.color,
    required this.radius,
    this.fallbackRadius = const BorderRadius.all(Radius.circular(FocusTheme.defaultBorderRadius)),
    this.shape,
    this.scale = 1,
    this.width = FocusTheme.focusBorderWidth,
    this.inset = EdgeInsets.zero,
    this.fill = false,
    this.link,
    super.child,
  });

  final Animation<double>? progress;
  final Color color;

  /// The ring's corners. Null takes the control's own (see [ownShape]), or [fallbackRadius]
  /// when it has none to read.
  final BorderRadius? radius;
  final BorderRadius fallbackRadius;

  /// Told what shape the ring was last drawn with, so the glow can match it.
  final FocusShape? shape;

  /// How much the control grows at full focus (1 = not at all). Paint only.
  final double scale;
  final double width;

  /// How far inside the control's edges the ring sits. Negative draws it outside, for a
  /// control with no room of its own (a text link); what is outside can be clipped.
  final EdgeInsets inset;

  /// A see-through fill instead of a ring (upstream's `useBackgroundFocus`).
  final bool fill;

  /// Set while the glow is up: the glow follows this.
  final LayerLink? link;

  @override
  RenderFocusChrome createRenderObject(BuildContext context) =>
      RenderFocusChrome(progress: progress, color: color, radius: radius, fallbackRadius: fallbackRadius, shape: shape, scale: scale, width: width, inset: inset, fill: fill, link: link);

  @override
  void updateRenderObject(BuildContext context, RenderFocusChrome renderObject) {
    renderObject
      ..progress = progress
      ..color = color
      ..radius = radius
      ..fallbackRadius = fallbackRadius
      ..shape = shape
      ..scale = scale
      ..width = width
      ..inset = inset
      ..fill = fill
      ..link = link;
  }
}

class RenderFocusChrome extends RenderProxyBox {
  RenderFocusChrome({
    required this._progress,
    required this._color,
    required this._radius,
    required this._fallbackRadius,
    required this.shape,
    required this._scale,
    required this._width,
    required this._inset,
    required this._fill,
    required this._link,
  });

  Animation<double>? _progress;
  set progress(Animation<double>? value) {
    if (identical(_progress, value)) return;
    if (attached) _progress?.removeListener(_ticked);
    _progress = value;
    if (attached) value?.addListener(_ticked);
    _ticked();
  }

  /// Whether this control paints on a layer of its own right now: while it has a focus look
  /// (see the notes at the top). The page is recorded again once as that starts and once as it
  /// ends, to take the control out of its own picture and to put it back.
  bool _ownLayer = false;

  @override
  bool get isRepaintBoundary => _ownLayer;

  void _ticked() {
    final want = shown > 0;
    if (want != _ownLayer) {
      _ownLayer = want;
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (_color == value) return;
    _color = value;
    markNeedsPaint();
  }

  BorderRadius? _radius;
  set radius(BorderRadius? value) {
    if (_radius == value) return;
    _radius = value;
    markNeedsPaint();
  }

  BorderRadius _fallbackRadius;
  set fallbackRadius(BorderRadius value) {
    if (_fallbackRadius == value) return;
    _fallbackRadius = value;
    markNeedsPaint();
  }

  FocusShape? shape;

  double _scale;
  set scale(double value) {
    if (_scale == value) return;
    _scale = value;
    markNeedsPaint();
  }

  double _width;
  set width(double value) {
    if (_width == value) return;
    _width = value;
    markNeedsPaint();
  }

  EdgeInsets _inset;
  set inset(EdgeInsets value) {
    if (_inset == value) return;
    _inset = value;
    markNeedsPaint();
  }

  bool _fill;
  set fill(bool value) {
    if (_fill == value) return;
    _fill = value;
    markNeedsPaint();
  }

  LayerLink? _link;
  set link(LayerLink? value) {
    if (identical(_link, value)) return;
    final compositing = alwaysNeedsCompositing;
    _link = value;
    if (value != null && hasSize) value.leaderSize = size;
    if (compositing != alwaysNeedsCompositing) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  final _leader = LayerHandle<LeaderLayer>();

  // (not `layer`: on a layer of its own that one is the framework's)
  final _grown = LayerHandle<TransformLayer>();

  /// How far the control is into its focus look right now (0 when it has none).
  double get shown => _progress?.value ?? 0;

  /// How far past its box a focused control may draw: it grows, a ring with no room of its own
  /// goes round it on the outside, and what it draws for itself under focus (a shadow, a lift)
  /// spills too.
  static const _spill = 40.0;

  /// A layer says how far its picture reaches, and a renderer that redraws only what changed
  /// goes by that: what a layer draws past its say can be left as it was, cut off at the box.
  /// So while this is a layer of its own it says more than its box.
  @override
  Rect get paintBounds {
    final box = super.paintBounds;
    if (!_ownLayer) return box;
    return box.inflate(_spill + (_scale - 1).abs() * box.longestSide / 2);
  }

  /// Whether the control is only text: nothing drawn round it, no padding of its own.
  bool _onlyText() {
    RenderObject? node = child;
    for (var depth = 0; node != null && depth < 16; depth++) {
      if (node is! RenderBox || !node.hasSize) return false;
      if ((node.size.width - size.width).abs() > 1 || (node.size.height - size.height).abs() > 1) return false;
      if (node is RenderParagraph) return true;
      if (_shapeOf(node) != null) return false;
      RenderObject? only;
      var children = 0;
      node.visitChildren((c) {
        children++;
        only = c;
      });
      if (children != 1) return false;
      node = only;
    }
    return false;
  }

  /// How far inside the control's edges its ring sits: what the control asked for, or, for
  /// one that is only text and asked for nothing, round the text on the outside
  /// ([FocusTheme.textLinkInset]).
  EdgeInsets get _room => _inset == EdgeInsets.zero && _onlyText() ? FocusTheme.textLinkInset : _inset;

  /// Tests: where this control's ring goes.
  @visibleForTesting
  EdgeInsets get debugRoom => _room;

  @override
  bool get alwaysNeedsCompositing => _link != null;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress?.addListener(_ticked);
    final want = shown > 0;
    if (want != _ownLayer) {
      _ownLayer = want;
      markNeedsCompositingBitsUpdate();
    }
  }

  @override
  void detach() {
    _progress?.removeListener(_ticked);
    super.detach();
  }

  @override
  void dispose() {
    _leader.layer = null;
    _grown.layer = null;
    super.dispose();
  }

  @override
  void performLayout() {
    super.performLayout();
    _link?.leaderSize = size;
  }

  /// The part of the control its ring goes round, when the control marks one.
  RenderFocusRingTarget? _target() {
    RenderFocusRingTarget? found;
    var budget = 96;
    void visit(RenderObject node) {
      if (found != null || --budget < 0) return;
      if (node is RenderFocusRingTarget) {
        found = node;
        return;
      }
      if (node is RenderFocusChrome) return; // (another control's)
      node.visitChildren(visit);
    }

    final first = child;
    if (first != null) visit(first);
    return found;
  }

  void _ring(Canvas canvas, Rect bounds, double t) {
    final target = _target();
    if (target != null && target.attached && target.hasSize) {
      // round the part, where it is drawn now (it may be scaled, as a portrait grows under focus)
      final part = _inset.deflateRect(MatrixUtils.transformRect(target.getTransformTo(this), Offset.zero & target.size));
      final radius = _radius ?? ownShape(target, target.size)?.radius ?? _fallbackRadius;
      shape
        ?..radius = radius
        ..transform = null
        ..inset = EdgeInsets.fromLTRB(part.left, part.top, size.width - part.right, size.height - part.bottom);
      final outline = radius.toRRect(part.shift(bounds.topLeft));
      if (_fill) {
        canvas.drawRRect(outline, Paint()..color = _color.withValues(alpha: _color.a * t));
      } else {
        paintFocusRing(canvas, outline, _color, t, width: _width);
      }
      return;
    }
    final own = _radius == null ? ownShape(child, size) : null;
    final radius = _radius ?? own?.radius ?? _fallbackRadius;
    // A control that grows or shrinks itself (a card lifting under the pointer, a button
    // giving under a press) takes its ring with it.
    final moved = own?.transform;
    final room = own == null ? _room : _inset;
    shape
      ?..radius = radius
      ..transform = moved
      ..inset = room;
    var outline = radius.toRRect(room.deflateRect(bounds));
    if (moved != null) {
      canvas.save();
      canvas.translate(bounds.left, bounds.top);
      canvas.transform(moved.storage);
      outline = radius.toRRect(room.deflateRect(Offset.zero & bounds.size));
    }
    if (_fill) {
      canvas.drawRRect(outline, Paint()..color = _color.withValues(alpha: _color.a * t));
    } else {
      paintFocusRing(canvas, outline, _color, t, width: _width);
    }
    if (moved != null) canvas.restore();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final t = shown;
    final link = _link;
    if (t == 0 && link == null) {
      // the usual case, and the only one a mouse or a finger ever meets
      _grown.layer = null;
      _leader.layer = null;
      super.paint(context, offset);
      return;
    }

    void content(PaintingContext context, Offset offset) {
      super.paint(context, offset);
      if (t > 0) _ring(context.canvas, offset & size, t);
    }

    void linked(PaintingContext context, Offset offset) {
      if (link == null) {
        _leader.layer = null;
        content(context, offset);
        return;
      }
      final leader = _leader.layer ??= LeaderLayer(link: link, offset: offset);
      leader
        ..link = link
        ..offset = offset;
      context.pushLayer(leader, content, Offset.zero);
    }

    final s = 1 + (_scale - 1) * t;
    if (s == 1) {
      _grown.layer = null;
      linked(context, offset);
      return;
    }
    // about the centre: layout, hit testing and semantics stay where they were
    final transform = Matrix4.identity()
      ..setEntry(0, 0, s)
      ..setEntry(1, 1, s)
      ..setTranslationRaw((1 - s) * size.width / 2, (1 - s) * size.height / 2, 0);
    _grown.layer = context.pushTransform(needsCompositing, offset, transform, linked, oldLayer: _grown.layer);
  }
}

/// The glow around the focused control. It goes in an [OverlayEntry], above everything on the
/// page, and follows [link] (the control's [FocusChrome]); a glow drawn in place would be cut
/// off by the row it scrolls in and covered by the next card.
class FocusGlow extends StatelessWidget {
  const FocusGlow({super.key, required this.link, required this.progress, required this.color, required this.shape});

  final LayerLink link;
  final Animation<double> progress;
  final Color color;

  /// The shape the control's ring was drawn with (its [FocusChrome] keeps it up to date).
  final FocusShape shape;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    top: 0,
    child: CompositedTransformFollower(
      link: link,
      showWhenUnlinked: false,
      child: IgnorePointer(
        child: CustomPaint(painter: _GlowPainter(link: link, progress: progress, color: color, shape: shape)),
      ),
    ),
  );
}

class _GlowPainter extends CustomPainter {
  _GlowPainter({required this.link, required this.progress, required this.color, required this.shape}) : super(repaint: progress);

  final LayerLink link;
  final Animation<double> progress;
  final Color color;
  final FocusShape shape;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final leader = link.leaderSize;
    if (t == 0 || leader == null) return;
    final moved = shape.transform;
    if (moved != null) {
      canvas.save();
      canvas.transform(moved.storage);
    }
    paintFocusGlow(canvas, shape.radius.toRRect(shape.inset.deflateRect(Offset.zero & leader)), color, t);
    if (moved != null) canvas.restore();
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.link != link || old.progress != progress || old.color != color || old.shape != shape;
}

/// The glow around [shape], at strength [t]. Outside the shape only: the control itself hides
/// the rest, and a see-through control (a glass button) would otherwise be tinted.
void paintFocusGlow(Canvas canvas, RRect shape, Color color, double t) {
  final reach = FocusTheme.focusGlowExtent;
  canvas.save();
  canvas.clipPath(Path.combine(PathOperation.difference, Path()..addRect(shape.outerRect.inflate(reach)), Path()..addRRect(shape)));
  for (final shadow in FocusTheme.focusGlowShadows(color)) {
    canvas.drawRRect(
      shape.inflate(shadow.spreadRadius),
      Paint()
        ..color = shadow.color.withValues(alpha: shadow.color.a * t)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadow.blurSigma),
    );
  }
  canvas.restore();
}

/// The ring itself: [width] of [color] just inside [shape], with a hair of shadow inside that
/// so it stays readable on a picture of its own colour.
void paintFocusRing(Canvas canvas, RRect shape, Color color, double t, {double width = FocusTheme.focusBorderWidth}) {
  canvas.drawRRect(
    shape.deflate(width + .5),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Color.fromRGBO(0, 0, 0, .35 * t),
  );
  canvas.drawRRect(
    shape.deflate(width / 2),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color.withValues(alpha: color.a * t),
  );
}

/// Marks the part of a control its focus ring goes round, when that is not all of it: the
/// portrait of a cast card, with the name and the role under it. The ring takes the part's
/// corners and follows it as it grows or shrinks; the glow goes with it. What a mouse or a
/// finger can press is the whole control, as before.
class FocusRingTarget extends SingleChildRenderObjectWidget {
  const FocusRingTarget({super.key, super.child});

  @override
  RenderFocusRingTarget createRenderObject(BuildContext context) => RenderFocusRingTarget();
}

class RenderFocusRingTarget extends RenderProxyBox {}

/// A ring's corners, and how the control has scaled itself, written by the control's
/// [FocusChrome] each time it paints and read by its glow.
class FocusShape {
  BorderRadius radius = const BorderRadius.all(Radius.circular(FocusTheme.defaultBorderRadius));
  Matrix4? transform;
  EdgeInsets inset = EdgeInsets.zero;
}

/// What [ownShape] found.
class OwnShape {
  const OwnShape(this.radius, this.transform);
  final BorderRadius radius;

  /// The transforms between the control's edge and the shape (a hover scale, a press scale),
  /// or null when there are none.
  final Matrix4? transform;
}

/// The corners of what a control draws: those of the first box under [root] that fills
/// [size] and has a shape of its own (a decoration, a clip, a Material shape). Null when
/// there is nothing to read. This is how a ring matches a pill, a circle or a card without
/// every one of the app's buttons having to say what it is.
OwnShape? ownShape(RenderObject? root, Size size) {
  var node = root;
  Matrix4? transform;
  for (var depth = 0; node != null && depth < 16; depth++) {
    if (node is! RenderBox || !node.hasSize) return null;
    // only boxes that fill the control: a smaller one is something inside it
    if ((node.size.width - size.width).abs() > 1 || (node.size.height - size.height).abs() > 1) return null;
    final found = _shapeOf(node);
    if (found != null) return OwnShape(found, transform);
    RenderObject? only;
    var children = 0;
    node.visitChildren((child) {
      children++;
      only = child;
    });
    if (children != 1) return null;
    if (node is RenderTransform) node.applyPaintTransform(only! as RenderBox, transform ??= Matrix4.identity());
    node = only;
  }
  return null;
}

/// The same for a control this kit does not wrap (a Material button): its shape is drawn by
/// what it sits in (the button's Material), so look outwards first, as far as boxes of the
/// same size go, then inwards.
BorderRadius? shapeAround(RenderBox box) {
  RenderObject? node = box.parent;
  for (var depth = 0; node is RenderBox && node.hasSize && depth < 10; depth++) {
    if ((node.size.width - box.size.width).abs() > 1 || (node.size.height - box.size.height).abs() > 1) break;
    final found = _shapeOf(node);
    if (found != null) return found;
    node = node.parent;
  }
  return ownShape(box, box.size)?.radius;
}

BorderRadius? _shapeOf(RenderBox box) {
  BorderRadius round() => BorderRadius.circular(box.size.shortestSide / 2);
  BorderRadius? ofBorder(ShapeBorder shape) => switch (shape) {
    RoundedRectangleBorder(:final borderRadius) => borderRadius.resolve(TextDirection.ltr),
    ContinuousRectangleBorder(:final borderRadius) => borderRadius.resolve(TextDirection.ltr),
    BeveledRectangleBorder(:final borderRadius) => borderRadius.resolve(TextDirection.ltr),
    StadiumBorder() || CircleBorder() => round(),
    _ => null,
  };
  if (box is RenderDecoratedBox) {
    final d = box.decoration;
    if (d is BoxDecoration) {
      if (d.shape == BoxShape.circle) return round();
      final r = d.borderRadius;
      if (r != null) return r.resolve(TextDirection.ltr);
      // painted, with square corners
      if (d.color != null || d.border != null || d.gradient != null || d.image != null) return BorderRadius.zero;
    } else if (d is ShapeDecoration) {
      return ofBorder(d.shape);
    }
  }
  if (box is RenderClipRRect) return box.borderRadius.resolve(TextDirection.ltr);
  if (box is RenderClipOval) return round();
  if (box is RenderClipPath) {
    // Container with a clip, and Material's see-through kind, clip to their shape this way
    final clipper = box.clipper;
    if (clipper is ShapeBorderClipper) return ofBorder(clipper.shape);
  }
  if (box is RenderPhysicalModel) return box.shape == BoxShape.circle ? round() : (box.borderRadius ?? BorderRadius.zero);
  if (box is RenderPhysicalShape) {
    final clipper = box.clipper;
    if (clipper is ShapeBorderClipper) return ofBorder(clipper.shape);
  }
  return null;
}
