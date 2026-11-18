// T6: nothing changes for mouse and touch. Every big page, as a mouse user sees it on Windows,
// compared pixel for pixel with the picture taken before the D-pad work began.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/baseline_pages.dart';
import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));

  for (final page in baselinePages.entries) {
    testWidgets('pointer mode, ${page.key}', (t) async {
      await Bed.pumpShell(t);
      await page.value(t);
      await Bed.baseline(t, page.key);
    }, variant: OnScreens(Screens.windows));
  }
}
