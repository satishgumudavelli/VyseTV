import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme.dart';
import '../../data/phone_edit/phone_session.dart';
import '../../dpad/dpad_traversal.dart' show DpadStart;

/// Settings → Edit on your phone (on a TV): a QR code for the phone's camera, the same code to
/// type for a phone that can't scan, and how it's going. Changes from the phone apply while this
/// is open; closing it (Close, or Back) ends the session for the phone too.
Future<void> showPhoneEditDialog(BuildContext context) => showDialog<void>(
  context: context,
  useRootNavigator: true,
  barrierColor: Colors.black.withValues(alpha: .6),
  builder: (_) => const _PhoneEditDialog(),
);

class _PhoneEditDialog extends StatefulWidget {
  const _PhoneEditDialog();

  @override
  State<_PhoneEditDialog> createState() => _PhoneEditDialogState();
}

class _PhoneEditDialogState extends State<_PhoneEditDialog> {
  final _session = PhoneSession.create();

  @override
  void initState() {
    super.initState();
    _session.start();
  }

  @override
  void dispose() {
    _session.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: VyseColors.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    insetPadding: const EdgeInsets.all(24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: ListenableBuilder(
          listenable: Listenable.merge([_session.link, _session.lastChange]),
          builder: (context, _) {
            final link = _session.link.value;
            final showCode = link == PhoneLink.waiting || link == PhoneLink.connected || link == PhoneLink.lost;
            final ending = link == PhoneLink.ended || link == PhoneLink.unavailable;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _QrBox(url: showCode ? _session.pageUrl : null, busy: link == PhoneLink.opening),
                const SizedBox(width: 28),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Edit on your phone', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -.4)),
                      const SizedBox(height: 8),
                      const Text(
                        "Scan the code with your phone's camera and change any setting there. "
                        "Your phone doesn't need to be on the same Wi-Fi.",
                        style: TextStyle(fontSize: 14, color: VyseColors.textDim, height: 1.45),
                      ),
                      if (showCode) ...[
                        const SizedBox(height: 18),
                        Text.rich(
                          TextSpan(children: [
                            const TextSpan(text: 'Or open '),
                            TextSpan(text: _session.pageShort, style: const TextStyle(color: VyseColors.text, fontWeight: FontWeight.w700)),
                            const TextSpan(text: ' and type'),
                          ]),
                          style: const TextStyle(fontSize: 13.5, color: VyseColors.textDim),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _session.code.grouped,
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 2.5, fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ],
                      const SizedBox(height: 18),
                      _Status(link: link, lastChange: _session.lastChange.value),
                      const SizedBox(height: 20),
                      // The way out first, then what to do (on the right, where the remote is
                      // when a code ends: the kit puts the ring on what takes the place of the
                      // control it was on, and here that is New code).
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          DpadStart(
                            key: ValueKey('close-$ending'),
                            start: !ending,
                            child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
                          ),
                          if (ending)
                            Padding(
                              key: ValueKey(link),
                              padding: const EdgeInsets.only(left: 8),
                              child: DpadStart(
                                child: FilledButton(
                                  style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
                                  onPressed: _session.start,
                                  child: Text(link == PhoneLink.ended ? 'New code' : 'Try again', style: const TextStyle(fontWeight: FontWeight.w800)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

/// The QR code on white, the way phone cameras read best; a spinner while the code is made.
class _QrBox extends StatelessWidget {
  const _QrBox({required this.url, required this.busy});
  final String? url;
  final bool busy;

  static const _size = 210.0;

  @override
  Widget build(BuildContext context) => Container(
    width: _size,
    height: _size,
    decoration: BoxDecoration(color: url == null ? Colors.white.withValues(alpha: .06) : Colors.white, borderRadius: BorderRadius.circular(16)),
    padding: const EdgeInsets.all(12),
    child: url == null
        ? Center(
            child: busy
                ? const SizedBox.square(dimension: 26, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Icon(Icons.qr_code_2_rounded, size: 64, color: VyseColors.textFaint),
          )
        : QrImageView(
            data: url!,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            padding: EdgeInsets.zero,
            backgroundColor: Colors.white,
            semanticsLabel: 'QR code for Edit on your phone',
          ),
  );
}

class _Status extends StatelessWidget {
  const _Status({required this.link, required this.lastChange});
  final PhoneLink link;
  final String? lastChange;

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (link) {
      PhoneLink.opening => (VyseColors.textFaint, 'Making a code…'),
      PhoneLink.waiting => (VyseColors.star, 'Waiting for your phone'),
      PhoneLink.connected => (const Color(0xFF4ADE80), 'Your phone is connected. Changes show up here as you make them.'),
      PhoneLink.lost => (VyseColors.star, "Can't reach the VyseTV server. Trying again…"),
      PhoneLink.ended => (VyseColors.textFaint, 'This code has ended. Make a new one to carry on.'),
      PhoneLink.unavailable => (const Color(0xFFF87171), "Couldn't reach the VyseTV server. Check this TV's internet connection."),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 14, height: 1.4))),
          ],
        ),
        if (lastChange != null && link == PhoneLink.connected) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 18),
            child: Text('Last change: $lastChange', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: VyseColors.textDim)),
          ),
        ],
      ],
    );
  }
}
