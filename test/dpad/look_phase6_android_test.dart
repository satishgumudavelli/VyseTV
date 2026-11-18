// T5 for phase 6: see bed/look_pages.dart. Saved to docs/dpad/pictures/phase6.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/look_pages.dart';
import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
    await Bed.withContent();
  });
  testWidgets('phase 6 pages with focus on them', lookAtPhase6, variant: OnScreens(Screens.android));
}
