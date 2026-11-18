// T5 for phase 8: see bed/look_pages.dart. Saved to docs/dpad/pictures/phase8.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/look_pages.dart';
import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  testWidgets('settings with focus on them', lookAtPhase8, variant: OnScreens(Screens.windows));
}
