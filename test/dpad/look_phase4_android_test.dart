// T5 for phase 4: see bed/look_pages.dart. Saved to docs/dpad/pictures/phase4.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/look_pages.dart';
import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.android));
  testWidgets('phase 4 pages with focus on them', lookAtPhase4, variant: OnScreens(Screens.android));
}
