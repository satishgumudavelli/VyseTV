// Where a control's focus ring goes when the control has no room for one, and how far a
// focused control says it draws (lib/dpad/focus_chrome.dart).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/dpad/focus_chrome.dart';
import 'package:vyse_tv/dpad/focus_theme.dart';
import 'package:vyse_tv/widgets/common.dart';

import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
  });

  Widget page() => Bed.app(Scaffold(
    body: Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // a link in a line of them: a studio's name on a film's page
          Pressable(onTap: () {}, builder: (_, _, _) => const Text('Northlight Pictures,')),
          const SizedBox(width: 40),
          Pressable(onTap: () {}, focusScale: 1.1, builder: (_, _, _) => const Padding(padding: EdgeInsets.all(10), child: Text('Play'))),
          const SizedBox(width: 40),
          Pressable(onTap: () {}, focusInset: const EdgeInsets.all(3), builder: (_, _, _) => const Text('Reset')),
        ],
      ),
    ),
  ));

  // A tester: "if a studio portion is selectable there's a border crop issue". The ring was
  // drawn inside the edge of the text's own box and cut through its first and last letters.
  testWidgets('a control that is only text wears its ring round the text, not over it', (t) async {
    await t.pumpWidget(page());
    await Bed.settle(t, rounds: 2);
    final chromes = t.renderObjectList<RenderFocusChrome>(find.byType(FocusChrome)).toList();
    expect(chromes[0].debugRoom, FocusTheme.textLinkInset);
    expect(FocusTheme.textLinkInset.left, lessThan(0), reason: 'outside the text');
    expect(chromes[1].debugRoom, EdgeInsets.zero, reason: 'it has padding of its own: the ring fits inside its edge');
    expect(chromes[2].debugRoom, const EdgeInsets.all(3), reason: 'it said where its ring goes');
  });

  // While it has its focus look a control is a layer of its own, and a layer says how far its
  // picture reaches. What it draws past that can be left as it was on a renderer that redraws
  // only what changed: a ring outside the box, or the grown edge of a card, cut off at the box.
  testWidgets('a focused control says it draws past its box, and only while focused', (t) async {
    await t.pumpWidget(page());
    await Bed.settle(t, rounds: 2);
    await Bed.dpadMode(t);
    for (final i in [0, 1]) {
      await Bed.focus(t, find.byType(Pressable).at(i));
      final chromes = t.renderObjectList<RenderFocusChrome>(find.byType(FocusChrome)).toList();
      final chrome = chromes[i];
      final box = Offset.zero & chrome.size;
      expect(chrome.isRepaintBoundary, isTrue);
      final reach = chrome.debugRoom.deflateRect(box).inflate(chrome.size.longestSide * .05 + 2);
      expect(chrome.paintBounds.contains(reach.topLeft) && chrome.paintBounds.contains(reach.bottomRight - const Offset(.01, .01)), isTrue, reason: 'control $i: ${chrome.paintBounds} holds $reach');
      final other = chromes[2];
      expect(other.isRepaintBoundary, isFalse);
      expect(other.paintBounds, Offset.zero & other.size, reason: 'not focused: its box, as ever');
    }
  });
}
