// Voice search on a TV. Testers: "the option to hit mic and say the name of what you are looking
// for", on the Search page, Music, Anime, "whatever has a search section", and "just one button".
// So every search box has a microphone at its end on an Android TV: one press and the TV listens
// at once, with Android's own "Speak now" (MainActivity.kt, the vyse/voice channel); what it heard
// goes into the box and is searched for, with no other button to press.
//
// Only on Android TV: phones and tablets have a microphone on their keyboard already, and the
// desktop apps have nothing to listen with. Nothing changes there.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../core/platform/platform_detector.dart';
import 'common.dart';

abstract final class VoiceSearch {
  static const _channel = MethodChannel('vyse/voice');

  /// Whether search boxes offer the microphone here.
  static bool get offered => !kIsWeb && defaultTargetPlatform == TargetPlatform.android && PlatformDetector.isTV();

  /// Listens once. What was heard, or null when nothing was (Back, or silence). Throws
  /// [VoiceSearchUnavailable] when nothing on this TV can listen.
  static Future<String?> listen({String? prompt}) async {
    try {
      final heard = await _channel.invokeMethod<String>('listen', {'prompt': prompt});
      final text = heard?.trim();
      return text == null || text.isEmpty ? null : text;
    } on PlatformException catch (e) {
      if (e.code == 'UNAVAILABLE') throw const VoiceSearchUnavailable();
      rethrow;
    } on MissingPluginException {
      throw const VoiceSearchUnavailable();
    }
  }
}

class VoiceSearchUnavailable implements Exception {
  const VoiceSearchUnavailable();
}

/// The microphone at the end of a search box (on an Android TV; elsewhere it takes no room).
/// What is heard is put in [controller] and handed to [onHeard], which searches for it (the
/// box's own submit, or its on-change when it searches as you type).
class VoiceSearchButton extends StatefulWidget {
  const VoiceSearchButton({super.key, required this.controller, this.onHeard, this.prompt, this.size = 30});

  final TextEditingController controller;
  final ValueChanged<String>? onHeard;

  /// What the TV's listening screen says (the box's hint, as a rule).
  final String? prompt;
  final double size;

  @override
  State<VoiceSearchButton> createState() => _VoiceSearchButtonState();
}

class _VoiceSearchButtonState extends State<VoiceSearchButton> {
  bool _listening = false;

  Future<void> _listen() async {
    if (_listening) return;
    setState(() => _listening = true);
    try {
      final heard = await VoiceSearch.listen(prompt: widget.prompt);
      if (!mounted || heard == null) return;
      widget.controller.value = TextEditingValue(text: heard, selection: TextSelection.collapsed(offset: heard.length));
      widget.onHeard?.call(heard);
    } on VoiceSearchUnavailable {
      if (mounted) showToast(context, const Text("This TV has no voice search. The keyboard's microphone may work instead.", style: TextStyle(fontSize: 13)), icon: Icons.mic_off_rounded);
    } catch (_) {
      if (mounted) showToast(context, const Text("Couldn't listen just now. Try again.", style: TextStyle(fontSize: 13)), icon: Icons.mic_off_rounded);
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!VoiceSearch.offered) return const SizedBox.shrink();
    final s = widget.size;
    return Pressable(
      onTap: _listen,
      tooltip: 'Search by voice',
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _listening ? VyseColors.accent : Colors.white.withValues(alpha: hovered ? .2 : .1),
        ),
        child: Icon(Icons.mic_rounded, size: s * .56, color: _listening ? Colors.black : VyseColors.text),
      ),
    );
  }
}

/// A text box's end, with the microphone after whatever it already had there (its clear
/// button), for boxes that put their buttons in the decoration's suffix. Elsewhere than a TV
/// this is [suffix] itself.
Widget? withVoiceSearch(Widget? suffix, {required TextEditingController controller, ValueChanged<String>? onHeard, String? prompt}) {
  if (!VoiceSearch.offered) return suffix;
  return Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      ?suffix,
      VoiceSearchButton(controller: controller, onHeard: onHeard, prompt: prompt, size: 28),
    ]),
  );
}
