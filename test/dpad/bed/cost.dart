// What a screen costs to draw, counted without a GPU.
//
// A weak TV chip is slow at three things: filling pixels (every translucent layer over the page
// is the whole screen blended again), blurring (soft glows, blurred shadows) and drawing into
// an off-screen buffer first (Opacity, filters, ShaderMask: "save layers"). Flutter draws the
// whole visible scene again for every frame of an animation, so what the scene holds at rest is
// paid for on each of those frames; and each frame also costs the Dart side whatever it
// rebuilds, lays out and paints again.
//
// [sceneCost] paints the screen into a canvas that only counts ([CostCanvas]); [FrameMeter]
// counts, frame by frame, the widgets rebuilt and the screen area painted again. The numbers
// compare pages with each other and a change with what was there before; they are not
// milliseconds on a TV.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// What one paint of the whole screen asks of the GPU.
class SceneCost {
  double screenArea = 1;

  /// Every draw call that fills pixels, and their area as a multiple of the screen (2.5 = each
  /// pixel drawn two and a half times on average).
  int draws = 0;
  double filled = 0;

  /// Of that: drawn with a translucent colour or a gradient, so blended with what is under it.
  double blended = 0;

  /// Gradients (a little arithmetic for every pixel, more for a radial one).
  int gradients = 0;
  double gradientArea = 0;

  /// Blurs: a mask filter on a paint (glows, soft shadows) and canvas shadows.
  int blurs = 0;
  double blurArea = 0;

  /// Off-screen buffers: Opacity over more than one thing, colour and image filters, ShaderMask,
  /// BackdropFilter, clips that ask for one.
  int saveLayers = 0;
  double saveLayerArea = 0;
  final layers = <String, int>{};

  /// Rounded and path clips (each is a mask the GPU keeps while drawing what is inside).
  int roundClips = 0;

  int images = 0;
  double imageArea = 0;
  int texts = 0;

  /// The fills that cover the most, largest first: "0.98x gradient _Glow < AppShell".
  final big = <(double, String)>[];

  String bigFills([int n = 12]) {
    final list = [...big]..sort((a, b) => b.$1.compareTo(a.$1));
    return list.take(n).map((e) => '${(e.$1 / screenArea).toStringAsFixed(2)}x ${e.$2}').join('\n      ');
  }

  double get overdraw => filled / screenArea;

  /// One number to rank pages by: pixels filled, with blurs and off-screen buffers counted at
  /// several times their area (they are several passes each).
  double get weight => (filled + blended * .5 + gradientArea * .5 + blurArea * 6 + saveLayerArea * 3) / screenArea + roundClips * .02;

  String get line =>
      'weight ${weight.toStringAsFixed(1)} · overdraw ${overdraw.toStringAsFixed(2)}x · blended ${(blended / screenArea).toStringAsFixed(2)}x · '
      'gradients $gradients (${(gradientArea / screenArea).toStringAsFixed(2)}x) · blurs $blurs (${(blurArea / screenArea).toStringAsFixed(2)}x) · '
      'save layers $saveLayers (${(saveLayerArea / screenArea).toStringAsFixed(2)}x)${layers.isEmpty ? '' : ' $layers'} · '
      'round clips $roundClips · images $images · texts $texts · draws $draws';
}

/// A canvas that draws nothing and adds up what it was asked to draw, in screen pixels (it
/// follows the transforms and the clips).
class CostCanvas implements ui.Canvas {
  CostCanvas(this.screen) : _clip = screen {
    cost.screenArea = screen.width * screen.height;
  }

  final ui.Rect screen;
  final cost = SceneCost();

  /// The render object being painted (set by the painting context), to say who filled what.
  RenderObject? painting;

  String _who(String kind) {
    final ro = painting;
    if (ro == null) return kind;
    final names = <String>[];
    final creator = ro.debugCreator;
    if (creator is DebugCreator) {
      names.add(creator.element.widget.runtimeType.toString());
      creator.element.visitAncestorElements((e) {
        final n = e.widget.runtimeType.toString();
        // the app's own widgets say where this is; skip the framework's plumbing
        if (!_plumbing.contains(n) && !n.startsWith('_Inherited') && (names.isEmpty || names.last != n)) names.add(n);
        return names.length < 5;
      });
    } else {
      names.add(ro.runtimeType.toString());
    }
    return '$kind ${names.join(' < ')}';
  }

  static const _plumbing = {
    'Padding', 'Align', 'Center', 'SizedBox', 'ConstrainedBox', 'Positioned', 'Stack', 'Column', 'Row', 'Expanded', 'Flexible', 'Builder',
    'RepaintBoundary', 'Semantics', 'IgnorePointer', 'KeyedSubtree', 'MediaQuery', 'Listener', 'MouseRegion', 'GestureDetector',
    'RawGestureDetector', 'LayoutBuilder', 'ClipRect', 'Transform', 'Opacity', 'DefaultTextStyle', 'AnimatedDefaultTextStyle',
    'NotificationListener<ScrollNotification>', 'Focus', 'FocusScope', 'Actions', 'Shortcuts', 'ExcludeSemantics', 'Material',
    'AnimatedBuilder', 'ListenableBuilder', 'ValueListenableBuilder<bool>', 'DecoratedBox', 'Container', 'ColoredBox', 'Offstage', 'TickerMode',
    'SliverToBoxAdapter', 'SliverPadding', 'CustomPaint', 'Flex', 'PositionedDirectional', 'SafeArea', 'FractionallySizedBox', 'AspectRatio',
  };
  Matrix4 _m = Matrix4.identity();
  ui.Rect _clip;
  final _saved = <(Matrix4, ui.Rect)>[];

  ui.Rect _onScreen(ui.Rect local) {
    if (!local.isFinite) return _clip;
    final r = MatrixUtils.transformRect(_m, local).intersect(_clip);
    return r.width <= 0 || r.height <= 0 ? ui.Rect.zero : r;
  }

  double _area(ui.Rect local) {
    final r = _onScreen(local);
    return r.width * r.height;
  }

  void _fill(ui.Rect local, ui.Paint? p, {bool image = false}) {
    var bounds = local;
    final blur = p?.maskFilter != null;
    if (blur) bounds = local.inflate(12); // a blur reaches past the shape
    if (p != null && p.style == ui.PaintingStyle.stroke && !blur) {
      // an outline: only its line is filled
      final a = _area(bounds);
      final w = p.strokeWidth <= 0 ? 1.0 : p.strokeWidth;
      final line = a == 0 ? 0.0 : 2 * (local.width + local.height) * w * (_m.getMaxScaleOnAxis());
      cost.draws++;
      cost.filled += line < a ? line : a;
      return;
    }
    // a fully transparent colour draws nothing: the GPU side drops it
    if (p != null && p.shader == null && p.color.a == 0 && p.blendMode == ui.BlendMode.srcOver) return;
    final a = _area(bounds);
    if (a == 0) return;
    cost.draws++;
    cost.filled += a;
    if (a >= cost.screenArea * .12) {
      final kind = image ? 'image' : (blur ? 'blur' : (p?.shader != null ? 'gradient' : ((p?.color.a ?? 1) < .999 ? 'see-through' : 'solid')));
      cost.big.add((a, _who(kind)));
    }
    if (image) {
      cost.images++;
      cost.imageArea += a;
    }
    if (p == null) return;
    if (blur) {
      cost.blurs++;
      cost.blurArea += a;
    }
    if (p.shader != null) {
      cost.gradients++;
      cost.gradientArea += a;
      cost.blended += a;
    } else if (p.color.a < .999 || p.blendMode != ui.BlendMode.srcOver) {
      cost.blended += a;
    }
    // (a colour filter on a paint is part of that draw's shader: a tint over a picture costs
    // nothing more than the picture. An image filter is a buffer.)
    if (p.imageFilter != null) {
      cost.saveLayers++;
      cost.saveLayerArea += a;
    }
  }

  void _push() => _saved.add((_m.clone(), _clip));

  @override
  dynamic noSuchMethod(Invocation i) {
    final a = i.positionalArguments;
    switch (i.memberName) {
      case #save:
        _push();
      case #saveLayer:
        _push();
        final bounds = a[0] as ui.Rect?;
        cost.saveLayers++;
        cost.saveLayerArea += bounds == null ? _clip.width * _clip.height : _area(bounds);
      case #restore:
        if (_saved.isNotEmpty) {
          final (m, c) = _saved.removeLast();
          _m = m;
          _clip = c;
        }
      case #restoreToCount:
        final count = a[0] as int;
        while (_saved.length + 1 > count && _saved.isNotEmpty) {
          final (m, c) = _saved.removeLast();
          _m = m;
          _clip = c;
        }
      case #getSaveCount:
        return _saved.length + 1;
      case #translate:
        _m = _m.multiplied(Matrix4.translationValues(a[0] as double, a[1] as double, 0));
      case #scale:
        final sx = a[0] as double;
        _m = _m.multiplied(Matrix4.diagonal3Values(sx, a.length > 1 && a[1] != null ? a[1] as double : sx, 1));
      case #rotate:
        _m = _m.multiplied(Matrix4.rotationZ(a[0] as double));
      case #skew:
        break;
      case #transform:
        _m = _m.multiplied(Matrix4.fromFloat64List(a[0] as Float64List));
      case #getTransform:
        return Float64List.fromList(_m.storage);
      case #getLocalClipBounds:
        final inverse = Matrix4.tryInvert(_m);
        return inverse == null ? _clip : MatrixUtils.transformRect(inverse, _clip);
      case #getDestinationClipBounds:
        return _clip;
      case #clipRect:
        _clip = _onScreen(a[0] as ui.Rect);
      case #clipRRect:
        _clip = _onScreen((a[0] as ui.RRect).outerRect);
        cost.roundClips++;
      case #clipRSuperellipse:
        _clip = _onScreen((a[0] as dynamic).outerRect as ui.Rect);
        cost.roundClips++;
      case #clipPath:
        _clip = _onScreen((a[0] as ui.Path).getBounds());
        cost.roundClips++;
      case #drawColor:
        _fill(ui.Rect.largest, ui.Paint()..color = a[0] as ui.Color);
      case #drawPaint:
        _fill(ui.Rect.largest, a[0] as ui.Paint);
      case #drawRect:
        _fill(a[0] as ui.Rect, a[1] as ui.Paint);
      case #drawRRect:
        _fill((a[0] as ui.RRect).outerRect, a[1] as ui.Paint);
      case #drawDRRect:
        _fill((a[0] as ui.RRect).outerRect, a[2] as ui.Paint);
      case #drawRSuperellipse:
        _fill((a[0] as dynamic).outerRect as ui.Rect, a[1] as ui.Paint);
      case #drawOval:
        _fill(a[0] as ui.Rect, a[1] as ui.Paint);
      case #drawArc:
        _fill(a[0] as ui.Rect, a[4] as ui.Paint);
      case #drawCircle:
        _fill(ui.Rect.fromCircle(center: a[0] as ui.Offset, radius: a[1] as double), a[2] as ui.Paint);
      case #drawPath:
        _fill((a[0] as ui.Path).getBounds(), a[1] as ui.Paint);
      case #drawLine:
        cost.draws++;
      case #drawShadow:
        // a blurred copy of the shape under it
        final bounds = (a[0] as ui.Path).getBounds().inflate((a[2] as double) * 2 + 4);
        final area = _area(bounds);
        if (area > 0) {
          cost.draws++;
          cost.blurs++;
          cost.blurArea += area;
          cost.filled += area;
          cost.blended += area;
        }
      case #drawImage:
        final image = a[0] as ui.Image;
        _fill((a[1] as ui.Offset) & ui.Size(image.width.toDouble(), image.height.toDouble()), a[2] as ui.Paint, image: true);
      case #drawImageRect:
        _fill(a[2] as ui.Rect, a[3] as ui.Paint, image: true);
      case #drawImageNine:
        _fill(a[2] as ui.Rect, a[3] as ui.Paint, image: true);
      case #drawParagraph:
        final p = a[0] as ui.Paragraph;
        final area = _area((a[1] as ui.Offset) & ui.Size(p.longestLine, p.height));
        if (area > 0) {
          cost.texts++;
          cost.draws++;
          cost.filled += area * .35; // letters cover about a third of their box
        }
      default:
        // drawPicture, drawVertices, drawAtlas, drawPoints: none in this app's pages
        cost.draws++;
    }
    return null;
  }
}

class _CostContext extends TestRecordingPaintingContext {
  _CostContext(this.cost, CostCanvas super.canvas) : _canvas = canvas;
  final SceneCost cost;
  final CostCanvas _canvas;

  @override
  void paintChild(RenderObject child, Offset offset) {
    final was = _canvas.painting;
    _canvas.painting = child;
    super.paintChild(child, offset);
    _canvas.painting = was;
  }

  @override
  void pushLayer(Layer childLayer, PaintingContextCallback painter, Offset offset, {Rect? childPaintBounds}) {
    final name = childLayer.runtimeType.toString();
    if (childLayer is BackdropFilterLayer || childLayer is ImageFilterLayer || childLayer is ShaderMaskLayer || childLayer is ColorFilterLayer) {
      cost.layers[name] = (cost.layers[name] ?? 0) + 1;
      canvas.saveLayer(childPaintBounds, ui.Paint());
      painter(this, offset);
      canvas.restore();
      return;
    }
    painter(this, offset);
  }
}

/// Paints everything on screen into a [CostCanvas].
SceneCost sceneCost(WidgetTester t) {
  final view = t.binding.renderViews.first;
  final size = view.size;
  final canvas = CostCanvas(Offset.zero & size);
  final context = _CostContext(canvas.cost, canvas);
  final child = view.child;
  if (child != null) context.paintChild(child, Offset.zero);
  context.dispose();
  return canvas.cost;
}

/// One frame, as the Dart side paid for it.
class FrameCost {
  int rebuilt = 0;
  int painted = 0;

  /// Screen area recorded again, as a part of the screen (1 = all of it).
  double repainted = 0;
  double ms = 0;
}

/// Counts what each frame rebuilds and paints again. [start] before, [stop] after (the test
/// framework checks that the debug hooks are put back).
class FrameMeter {
  FrameMeter(this.t);
  final WidgetTester t;
  final rebuiltTypes = <String, int>{};
  final paintedTypes = <String, int>{};

  /// The repaint boundaries painted again, by the widget that owns each: what an animation
  /// frame really redraws.
  final boundaries = <String, int>{};
  FrameCost _now = FrameCost();
  final _areas = <RenderObject>{};

  void start() {
    debugOnRebuildDirtyWidget = (e, builtOnce) {
      _now.rebuilt++;
      final name = e.widget.runtimeType.toString();
      rebuiltTypes[name] = (rebuiltTypes[name] ?? 0) + 1;
    };
    debugOnProfilePaint = (ro) {
      // (Flutter reports every child a parent comes to, also a layer it keeps as it is and
      // only places again: that one is not painted, and nothing under it is)
      if (ro.isRepaintBoundary && !ro.debugNeedsPaint) return;
      _now.painted++;
      // the layer this goes into is being recorded again: the nearest boundary at or above it
      RenderObject? layer = ro;
      while (layer != null && !layer.isRepaintBoundary) {
        layer = layer.parent;
      }
      if (layer != null) {
        final name = _names[layer] ??= _layerName(layer);
        if (_areas.add(layer)) boundaries[name] = (boundaries[name] ?? 0) + 1;
        paintedIn[name] = (paintedIn[name] ?? 0) + 1;
      }
      final name = ro.runtimeType.toString();
      paintedTypes[name] = (paintedTypes[name] ?? 0) + 1;
    };
  }

  /// How many objects were recorded again in each layer: where a frame's painting goes.
  final paintedIn = <String, int>{};
  final _names = Map<RenderObject, String>.identity();

  static String _layerName(RenderObject layer) {
    final creator = layer.debugCreator;
    if (creator is! DebugCreator) return layer.runtimeType.toString();
    final names = <String>[];
    creator.element.visitAncestorElements((e) {
      final n = e.widget.runtimeType.toString();
      if (!CostCanvas._plumbing.contains(n) && !n.startsWith('_Inherited') && (names.isEmpty || names.last != n)) names.add(n);
      return names.length < 3;
    });
    return '${creator.element.widget.runtimeType} < ${names.join(' < ')}';
  }

  void stop() {
    debugOnRebuildDirtyWidget = null;
    debugOnProfilePaint = null;
  }

  void reset() {
    rebuiltTypes.clear();
    paintedTypes.clear();
    boundaries.clear();
    paintedIn.clear();
  }

  /// Runs one frame [step] later and says what it cost.
  Future<FrameCost> frame([Duration step = const Duration(milliseconds: 16)]) async {
    _now = FrameCost();
    _areas.clear();
    final clock = Stopwatch()..start();
    await t.pump(step);
    clock.stop();
    final cost = _now..ms = clock.elapsedMicroseconds / 1000;
    final screen = t.binding.renderViews.first.size;
    var area = 0.0;
    for (final ro in _areas) {
      if (!ro.attached) continue;
      try {
        final r = MatrixUtils.transformRect(ro.getTransformTo(null), ro.paintBounds).intersect(Offset.zero & screen);
        if (r.width > 0 && r.height > 0) area += r.width * r.height;
      } catch (_) {}
    }
    cost.repainted = (area / (screen.width * screen.height)).clamp(0, 9);
    return cost;
  }

  /// Frames until nothing is scheduled any more (an animation over), [most] at the most.
  Future<List<FrameCost>> untilStill({int most = 90}) async {
    final out = <FrameCost>[];
    for (var i = 0; i < most; i++) {
      if (!t.binding.hasScheduledFrame && SchedulerBinding.instance.transientCallbackCount == 0) break;
      out.add(await frame());
    }
    return out;
  }
}

String top(Map<String, int> counts, [int n = 6]) {
  final list = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return list.take(n).map((e) => '${e.key} ${e.value}').join(', ');
}
