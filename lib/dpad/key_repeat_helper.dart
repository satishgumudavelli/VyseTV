// From upstream (lib/focus/key_repeat_helper.dart, GPL-3.0). Kept as upstream wrote it so the two can be
// compared; anything changed for VyseTV is marked "VyseTV".
import 'dart:async';

import 'package:flutter/widgets.dart';

mixin KeyRepeatHelper<T extends StatefulWidget> on State<T> {
  static const _initialDelay = Duration(milliseconds: 400);
  static const _repeatInterval = Duration(milliseconds: 100);

  Timer? _repeatTimer;

  void startRepeat(VoidCallback action) {
    action();
    _repeatTimer?.cancel();
    _repeatTimer = Timer(_initialDelay, () {
      _repeatTimer = Timer.periodic(_repeatInterval, (_) => action());
    });
  }

  void stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }
}
