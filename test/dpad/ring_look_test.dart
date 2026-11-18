// T5 for the kit: the ring itself, drawn on the kinds of control the app has, saved as a
// picture to look at (docs/dpad/pictures/phase1). It checks nothing but that it renders.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/theme.dart';
import 'package:vyse_tv/dpad/focusable_wrapper.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';

import 'harness.dart';

Widget _poster(Color a, Color b, {double w = 150, double h = 225, double r = 7}) => Container(
  width: w,
  height: h,
  decoration: BoxDecoration(borderRadius: BorderRadius.circular(r), gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [a, b])),
);

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));

  testWidgets('the ring on a card, a pill, a round button and a text link', (t) async {
    final nodes = List.generate(5, (_) => FocusNode());
    addTearDown(() {
      for (final n in nodes) {
        n.dispose();
      }
    });
    Widget row(int focused) => Padding(
      padding: const EdgeInsets.all(28),
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
        _poster(const Color(0xFF2C5BA8), const Color(0xFF1B2A4A)),
        const SizedBox(width: 10),
        FocusableWrapper(focusNode: nodes[0], borderRadius: 7, focusScale: 1.04, useFocusGlow: true, child: _poster(const Color(0xFF4FA05A), const Color(0xFF1E4A2A))),
        const SizedBox(width: 10),
        _poster(const Color(0xFFB8A23A), const Color(0xFF5A4A1A)),
        const SizedBox(width: 40),
        FocusableWrapper(
          focusNode: nodes[1],
          borderRadius: 12,
          disableScale: true,
          useFocusGlow: true,
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            alignment: Alignment.center,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.white),
            child: const Text('Play', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(width: 24),
        FocusableWrapper(
          focusNode: nodes[2],
          borderRadius: 100,
          disableScale: true,
          useFocusGlow: true,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: .1), border: Border.all(color: Colors.white.withValues(alpha: .14))),
            child: const Icon(Icons.add_rounded, size: 20),
          ),
        ),
        const SizedBox(width: 24),
        FocusableWrapper(
          focusNode: nodes[3],
          borderRadius: 6,
          focusInset: const EdgeInsets.all(-6),
          disableScale: true,
          useFocusGlow: true,
          child: const Text('Discord', style: TextStyle(fontSize: 13, color: VyseColors.textDim)),
        ),
        const SizedBox(width: 40),
        FocusableWrapper(focusNode: nodes[4], borderRadius: 7, focusScale: 1.04, useFocusGlow: true, child: _poster(const Color(0xFFFFA53A), const Color(0xFFB86A10), w: 200, h: 112)),
      ]),
    );
    await t.pumpWidget(RepaintBoundary(
      key: Bed.frame,
      child: InputModeTracker(
        child: MaterialApp(
          theme: buildVyseTheme(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < 5; i++) KeyedSubtree(key: ValueKey(i), child: const SizedBox())]))),
        ),
      ),
    ));
    // one row per focused control, so every look is in one picture
    for (var i = 0; i < 5; i++) {
      await t.pumpWidget(RepaintBoundary(
        key: Bed.frame,
        child: InputModeTracker(
          child: MaterialApp(theme: buildVyseTheme(), debugShowCheckedModeBanner: false, home: Scaffold(body: Center(child: row(i)))),
        ),
      ));
      InputModeTracker.reportNonPointerInput();
      nodes[i].requestFocus();
      await t.pumpAndSettle();
      await Bed.picture(t, 'phase1/ring_$i');
    }
  }, variant: OnScreens([const Screen('ring', Size(1100, 300))]));
}
