import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../data/updates/updater.dart';
import '../../dpad/dpad_traversal.dart' show DpadStart;
import '../../core/platform/platform_detector.dart';
import 'torrent_file_dialog.dart' show bytesLabel;

/// The update box: what's new, then the download and what happens after it. Sits over the whole
/// app and fits a phone as well as a desktop window.
///
/// There is only ever one: asked for while it's already up (Settings' own button and the
/// automatic check can both want it at the same moment), the second request does nothing.
///
/// With a remote (a TV) it takes focus the moment it comes up, on the button that moves things
/// on (Update, Try again, Done); Left and Right go between its buttons and never out of it; Up
/// and Down scroll the release notes when there is more of them than fits; Back is Later while
/// nothing is under way. Nothing behind it moves, and when it closes focus is where it was.
/// test/dpad/t4_journeys_update_test.dart holds it to all of that.
Future<void> showUpdateDialog(BuildContext context) async {
  if (_open) return;
  _open = true;
  Updater.instance.shownThisRun = true;
  try {
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: .6),
      builder: (_) => const _UpdateDialog(),
    );
  } finally {
    _open = false;
  }
}

bool _open = false;

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog();

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  final _notes = ScrollController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  /// Up and Down scroll the release notes when there is more of them than fits: with a remote
  /// there is no other way to read the rest. The buttons share one line, so the two keys mean
  /// nothing else here; with the notes at that end (or none), they go on as usual.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent || (key != LogicalKeyboardKey.arrowDown && key != LogicalKeyboardKey.arrowUp) || !_notes.hasClients) {
      return KeyEventResult.ignored;
    }
    final p = _notes.position;
    final to = (p.pixels + p.viewportDimension * .6 * (key == LogicalKeyboardKey.arrowDown ? 1 : -1)).clamp(p.minScrollExtent, p.maxScrollExtent);
    if ((to - p.pixels).abs() < 1) return KeyEventResult.ignored;
    _notes.animateTo(to, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final tv = PlatformDetector.isTV();
    return ListenableBuilder(
      listenable: Updater.instance,
      builder: (context, _) {
        final up = Updater.instance;
        final u = up.info;
        final stage = up.stage;
        void close() => Navigator.of(context, rootNavigator: true).pop();

        final String title;
        final List<Widget> body;
        final List<Widget> actions;
        switch (stage) {
          case UpdateStage.downloading || UpdateStage.verifying:
            title = stage == UpdateStage.verifying ? 'Checking the download' : 'Downloading VyseTV ${u?.version ?? ''}';
            final total = up.file?.size ?? 0;
            body = [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: stage == UpdateStage.verifying ? null : up.progress,
                  minHeight: 6,
                  backgroundColor: Colors.white.withValues(alpha: .08),
                  color: VyseColors.accent,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                stage == UpdateStage.verifying
                    ? 'Making sure it is exactly the release.'
                    : [
                        if (total > 0) '${bytesLabel(up.received)} of ${bytesLabel(total)}' else bytesLabel(up.received),
                        if (up.progress != null) '${(up.progress! * 100).floor()}%',
                      ].where((s) => s.isNotEmpty).join('  ·  '),
                style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ];
            actions = [if (stage == UpdateStage.downloading) TextButton(key: const ValueKey('cancel'), onPressed: up.cancel, child: const Text('Cancel'))];
          case UpdateStage.installing:
            title = Platform.isWindows || Platform.isLinux ? 'Restarting VyseTV' : 'Installing';
            body = [
              const Row(
                children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: VyseColors.accent)),
                  SizedBox(width: 14),
                  Expanded(child: Text('Putting the new version in place. VyseTV closes and opens again by itself.', style: TextStyle(color: VyseColors.textDim, height: 1.45))),
                ],
              ),
            ];
            actions = const [];
          case UpdateStage.handedOver:
            title = 'Almost there';
            body = [
              Text(
                Platform.isAndroid && tv
                    ? 'Android is asking whether to install the update: choose Install. If it first asks to allow installs from VyseTV, turn that on, then press Back.'
                    : Platform.isAndroid
                    ? 'Android is asking whether to install the update. Tap Install there. If it asks to allow installs from VyseTV first, allow it and come back.'
                    : Platform.isMacOS
                    ? 'The disk image is open. Close VyseTV, drag the new VyseTV to Applications, then open it again.'
                    : 'The download opened in your browser. Install it from there.',
                style: const TextStyle(color: VyseColors.textDim, height: 1.5),
              ),
            ];
            actions = [_primary('Done', close)];
          case UpdateStage.failed:
            title = "The update didn't go through";
            body = [Text(up.error ?? 'Something went wrong.', style: const TextStyle(color: VyseColors.textDim, height: 1.5))];
            actions = [
              TextButton(key: const ValueKey('close'), onPressed: close, child: const Text('Close')),
              if (up.newer != null) _primary('Try again', up.update),
            ];
          case UpdateStage.available when u != null:
            title = 'VyseTV ${u.version} is ready';
            body = [
              Text(
                ['You have ${up.current}', if (u.date.isNotEmpty) 'released ${u.date}', if ((up.file?.size ?? 0) > 0) bytesLabel(up.file!.size)].join('  ·  '),
                style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim),
              ),
              if (u.notes.isNotEmpty) ...[
                const SizedBox(height: 14),
                Flexible(
                  child: Container(
                    constraints: BoxConstraints(maxHeight: (size.height * .34).clamp(90, 280)),
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .04), borderRadius: BorderRadius.circular(10)),
                    child: _scrollbarOnTv(
                      tv,
                      SingleChildScrollView(
                        controller: _notes,
                        child: Text(u.notes, style: const TextStyle(fontSize: 13.5, height: 1.5, color: Color(0xFFD5D8E6))),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text('${up.how}.', style: const TextStyle(fontSize: 12.5, color: VyseColors.textFaint)),
            ];
            actions = [
              TextButton(
                key: const ValueKey('skip'),
                onPressed: () {
                  up.skip(u.version);
                  close();
                },
                child: const Text('Skip this version'),
              ),
              TextButton(key: const ValueKey('later'), onPressed: close, child: const Text('Later')),
              _primary('Update', up.update),
            ];
          default:
            title = up.stage == UpdateStage.checking ? 'Checking for updates' : "You're up to date";
            body = [
              Text(
                up.stage == UpdateStage.checking ? 'One moment.' : 'VyseTV ${up.current} is the newest version.',
                style: const TextStyle(color: VyseColors.textDim, height: 1.5),
              ),
            ];
            actions = [TextButton(key: const ValueKey('close'), onPressed: close, child: const Text('Close'))];
        }

        return PopScope(
          // while it's fetching or installing there's nothing behind the box to go back to
          canPop: !up.busy || stage == UpdateStage.checking,
          child: Dialog(
            backgroundColor: VyseColors.surface,
            insetPadding: EdgeInsets.symmetric(horizontal: size.width < 520 ? 16 : 24, vertical: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: VyseColors.stroke)),
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onKey,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: VyseColors.accent.withValues(alpha: .14)),
                            child: Icon(stage == UpdateStage.failed ? Icons.error_outline_rounded : Icons.system_update_alt_rounded, color: VyseColors.accent, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, height: 1.2))),
                        ],
                      ),
                      const SizedBox(height: 14),
                      ...body,
                      const SizedBox(height: 14),
                      if (actions.isNotEmpty)
                        Align(
                          alignment: Alignment.centerRight,
                          child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 4, children: actions),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The button that moves things on. A remote lands on it when the box comes up, and when the
  /// box changes (each button has a key of its own, so the ring never stays on a slot that has
  /// become another button: Cancel turning into "Skip this version").
  static Widget _primary(String label, VoidCallback onTap) => Padding(
    key: ValueKey(label),
    padding: const EdgeInsets.only(left: 4),
    child: DpadStart(
      child: FilledButton(
        style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    ),
  );

  /// On a TV the notes show a scrollbar when there is more of them than fits (a remote can't
  /// feel for it); a phone and a desktop are left as they were.
  Widget _scrollbarOnTv(bool tv, Widget notes) => tv ? Scrollbar(controller: _notes, thumbVisibility: true, child: notes) : notes;
}
