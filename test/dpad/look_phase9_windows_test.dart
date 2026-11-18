// T5 for phase 9: see bed/look_pages.dart. Saved to docs/dpad/pictures/phase9.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bed/look_pages.dart';
import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  testWidgets('Party with focus on it', lookAtPhase9, variant: OnScreens(Screens.windows));
}
