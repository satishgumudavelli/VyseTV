// T5 for phase 5: see bed/look_pages.dart. Saved to docs/dpad/pictures/phase5.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/look_pages.dart';
import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.android));
  testWidgets('the player with focus on it', lookAtPhase5, variant: OnScreens(Screens.android));
}
