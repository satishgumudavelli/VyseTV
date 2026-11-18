// VyseTV addition, after upstream (lib/focus/focusable_text_field.dart, its native focus bridge,
// GPL-3.0). On an Android TV, tells the app's activity (MainActivity.kt) whether a text box has
// focus. Some TVs bind their on-screen keyboard only to a view that says it is a text editor;
// the activity's stand-in view says so while this says a text box has focus. Without it the
// keyboard is drawn but nothing typed reaches the box, and the remote's arrows, meant for the
// keyboard, move focus about behind it.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/platform/platform_detector.dart';

abstract final class TvTextInput {
  static const _channel = MethodChannel('vyse/text_input');
  static bool _sent = false;

  /// Whether the app runs on an Android TV, where this matters.
  static bool get applies => !kIsWeb && defaultTargetPlatform == TargetPlatform.android && PlatformDetector.isTV();

  /// Focus is now in a text box ([typing]), or not. Said once per change.
  static void focused(bool typing) {
    if (typing == _sent || !applies) return;
    _sent = typing;
    unawaited(_tell(typing));
  }

  static Future<void> _tell(bool typing) async {
    try {
      await _channel.invokeMethod<void>('setNativeTextInputFocused', typing);
    } on MissingPluginException {
      // (no activity to tell: tests, other platforms)
    } on PlatformException {
      // a hint to the keyboard, not something to fail over
    }
  }
}
