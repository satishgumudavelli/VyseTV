// What every page costs to draw on a TV, and what each press of the remote costs after that.
// See bed/cost.dart for what is counted and why. Run it by itself:
//
//   flutter test test/dpad/tv_cost_test.dart
//
// It prints one block per page and writes them to docs/dpad/perf/tv_cost.txt. The last test
// holds the app to the budgets a TV needs (nothing moving at rest, no off-screen buffers, a
// press that is over in a few frames).
//
// The app is measured as a TV draws it: the lean way (lib/core/lean.dart). For the full
// interface, to compare:  flutter test test/dpad/tv_cost_test.dart --dart-define=LEAN=false
// And as the weakest boxes draw it:  --dart-define=WEAK=true
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show debugSemanticsDisableAnimations;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/lean.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/screens/details/details_page.dart';

import 'bed/cost.dart';
import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

class PageReport {
  PageReport(this.name);
  final String name;
  late SceneCost scene;
  int restTickers = 0;
  int restFramesDrawn = 0; // of 30 frames at rest, how many painted anything
  String restPainters = '';
  final steps = <List<FrameCost>>[];
  String rebuilt = '';
  String painted = '';
  String boundaries = '';
  String paintedIn = '';
  String fills = '';
  double get paintedPerFrame => frames == 0 ? 0 : all.fold(0, (n, f) => n + f.painted) / frames;

  int get frames => steps.fold(0, (n, s) => n + s.length);
  double get framesPerStep => steps.isEmpty ? 0 : frames / steps.length;
  Iterable<FrameCost> get all => steps.expand((s) => s);
  double get rebuiltPerStep => steps.isEmpty ? 0 : all.fold(0, (n, f) => n + f.rebuilt) / steps.length;
  double get repaintedPerFrame => frames == 0 ? 0 : all.fold(0.0, (n, f) => n + f.repainted) / frames;
  double get worstRepaint => all.fold(0.0, (m, f) => f.repainted > m ? f.repainted : m);
  double get msPerStep => steps.isEmpty ? 0 : all.fold(0.0, (n, f) => n + f.ms) / steps.length;
  double get worstMs => all.fold(0.0, (m, f) => f.ms > m ? f.ms : m);

  String get text => [
    '== $name',
    '   scene: ${scene.line}',
    '   at rest: $restTickers ticking, $restFramesDrawn of 30 frames drew something${restPainters.isEmpty ? '' : ' ($restPainters)'}',
    '   a press: ${framesPerStep.toStringAsFixed(1)} frames, ${rebuiltPerStep.toStringAsFixed(0)} widgets rebuilt, '
        '${(repaintedPerFrame * 100).toStringAsFixed(0)}% of the screen painted per frame (worst ${(worstRepaint * 100).toStringAsFixed(0)}%), '
        '${paintedPerFrame.toStringAsFixed(0)} objects painted per frame, '
        '${msPerStep.toStringAsFixed(1)} ms of Dart per press (worst frame ${worstMs.toStringAsFixed(1)} ms)',
    if (fills.isNotEmpty) '   biggest fills:\n      $fills',
    if (boundaries.isNotEmpty) '   layers recorded again (times): $boundaries',
    if (paintedIn.isNotEmpty) '   objects painted, by layer: $paintedIn',
    if (rebuilt.isNotEmpty) '   rebuilt most: $rebuilt',
    if (painted.isNotEmpty) '   painted most: $painted',
  ].join('\n');
}

final reports = <PageReport>[];

const lean = bool.fromEnvironment('LEAN', defaultValue: true);
const weak = bool.fromEnvironment('WEAK');

/// Runs [body] with the interface drawn as a TV draws it. (The app decides that as it starts,
/// from the device; the bed is a PC, so it is told. Flutter's own switch for short animations
/// is a debug variable here, and a test must leave those as it found them.)
Future<void> asTv(Future<void> Function() body) async {
  Lean.debugOn = lean;
  Lean.debugWeak = lean && weak;
  debugSemanticsDisableAnimations = lean;
  try {
    await body();
  } finally {
    debugSemanticsDisableAnimations = null;
  }
}

/// Measures the page on screen: the scene at rest, then presses of [keys].
Future<PageReport> measure(WidgetTester t, String name, {List<LogicalKeyboardKey> keys = const []}) async {
  final r = PageReport(name);
  await Bed.settle(t, rounds: 6);
  await Bed.dpadMode(t);
  await Bed.settle(t, rounds: 3);
  r.scene = sceneCost(t);
  r.fills = r.scene.bigFills();
  final meter = FrameMeter(t)..start();
  try {
    r.restTickers = SchedulerBinding.instance.transientCallbackCount;
    for (var i = 0; i < 30; i++) {
      final f = await meter.frame();
      if (f.painted > 0) r.restFramesDrawn++;
    }
    r.restPainters = top(meter.paintedTypes, 4);
    meter.reset();
    for (final key in keys) {
      await t.sendKeyEvent(key);
      r.steps.add(await meter.untilStill());
    }
    r.rebuilt = top(meter.rebuiltTypes, 8);
    r.painted = top(meter.paintedTypes, 8);
    r.boundaries = top(meter.boundaries, 8);
    r.paintedIn = top(meter.paintedIn, 6);
  } finally {
    meter.stop();
  }
  reports.add(r);
  debugPrint(r.text);
  return r;
}

const down = LogicalKeyboardKey.arrowDown, up = LogicalKeyboardKey.arrowUp, left = LogicalKeyboardKey.arrowLeft, right = LogicalKeyboardKey.arrowRight;

/// A walk that crosses rows and moves along them, as a person browsing does.
const walk = [down, right, right, right, down, right, right, down, down, left, left, up, up, right, down, down, down, up];

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await TvDetectionService.getInstance(forceTv: true);
    await Bed.withContent();
  });
  tearDownAll(() {
    final out = File('docs/dpad/perf/tv_cost${lean ? (weak ? '_weak' : '') : '_full'}.txt')..createSync(recursive: true);
    out.writeAsStringSync('${reports.map((r) => r.text).join('\n\n')}\n');
  });
  final tv = OnScreens([Screens.tv]);

  for (final id in const ['home', 'discover', 'search', 'movies', 'tv', 'top', 'list', 'history', 'anime', 'live', 'downloads', 'servers', 'manga', 'music', 'audiobooks', 'party']) {
    testWidgets('cost: $id', (t) => asTv(() async {
      await Bed.pumpShell(t);
      if (id != 'home') await Bed.openSection(t, id);
      await measure(t, id, keys: walk);
    }), variant: tv);
  }

  testWidgets('cost: a film\'s page', (t) => asTv(() async {
    await Bed.pumpShell(t);
    await Bed.push(t, DetailsPage(media: Bed.freshTitle()));
    await measure(t, 'details, a film', keys: walk);
  }), variant: tv);

  testWidgets('cost: a series\' page', (t) => asTv(() async {
    await Bed.pumpShell(t);
    await Bed.push(t, DetailsPage(media: Bed.freshTitle(series: true)));
    await measure(t, 'details, a series', keys: walk);
  }), variant: tv);

  for (final tab in const ['Appearance', 'Playback', 'Subtitles']) {
    testWidgets('cost: Settings, $tab', (t) => asTv(() async {
      await openSettings(t, tab);
      await measure(t, 'settings, $tab', keys: const [right, down, down, down, down, up, up, left]);
    }), variant: tv);
  }

  // What a TV can afford, held for every page measured above (they run first: this file is
  // meant to be run whole). Not for the full interface, which is not what a TV draws.
  test('budgets: every page, as a TV draws it', () {
    if (!lean) return;
    expect(reports, isNotEmpty, reason: 'run the whole file: the pages are measured by the tests above');
    // On the bed the next page of a grid never arrives, so its "loading more" spinner never
    // stops. A spinner is allowed to turn; nothing else is.
    const spinning = {'discover', 'movies', 'tv', 'top', 'anime'};
    // Off-screen buffers still there, as a multiple of the screen: the gradient on service
    // logos (Servers) and the soft end of the season list (a series' page, counted here at a
    // whole screen because the layer has no size of its own until it is drawn).
    const buffers = {'servers': 2.0, 'details, a series': 1.0};
    final over = <String>[];
    for (final r in reports) {
      final s = r.scene;
      if (r.restFramesDrawn > 0) over.add('${r.name}: draws while nobody touches it (${r.restPainters})');
      if (r.restTickers > 0 && !spinning.contains(r.name)) over.add('${r.name}: ${r.restTickers} animation(s) running at rest');
      if (!spinning.contains(r.name) && r.framesPerStep > 22) over.add('${r.name}: a press takes ${r.framesPerStep.toStringAsFixed(1)} frames');
      if (s.saveLayerArea / s.screenArea > (buffers[r.name] ?? 0) + .01) over.add('${r.name}: off-screen buffers over ${(s.saveLayerArea / s.screenArea).toStringAsFixed(2)}x of the screen ${s.layers}');
      if (s.blurArea / s.screenArea > .5) over.add('${r.name}: blurs over ${(s.blurArea / s.screenArea).toStringAsFixed(2)}x of the screen');
      if (s.overdraw > 6.5) over.add('${r.name}: every pixel drawn ${s.overdraw.toStringAsFixed(2)} times');
      if (s.blended / s.screenArea > 3) over.add('${r.name}: ${(s.blended / s.screenArea).toStringAsFixed(2)}x of the screen blended');
    }
    expect(over, isEmpty, reason: over.join('\n'));
  });
}
