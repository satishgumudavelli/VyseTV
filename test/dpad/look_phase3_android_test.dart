// T5 for phase 3 at a TV's size and on a phone: see bed/look_pages.dart. Saved to docs/dpad/pictures/phase3.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/look_pages.dart';
import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.android));
  testWidgets('phase 3 pages with focus on them', lookAtPhase3, variant: OnScreens(Screens.android));
}
