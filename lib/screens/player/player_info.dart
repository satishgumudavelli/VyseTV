import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../data/playback/playback_report.dart';
import '../../dpad/dpad_traversal.dart' show DpadStart;
import '../../widgets/common.dart' show Pressable;
import 'player_menus.dart';
import 'tv_menus.dart';

/// Stream info, and the report card.
///
/// What is playing (its source, the engine, the picture, the sound, the subtitle) and a card
/// to photograph when something won't play: what the device has, what was decided about Dolby
/// Vision, and how it went. Both are read from one [PlaybackReport].
///
/// On a TV it is one of the player's full-screen menus (tv_menus.dart): a column of the two
/// views, and the view the ring is on beside it, in columns. On a desktop and a phone it is a
/// list in the menu's card, opened from More.

/// The two views.
enum _View { stream, card }

class InfoPane extends StatefulWidget {
  const InfoPane({super.key, required this.report, this.onRefresh, this.onBack});

  /// The report of what is playing. Null: nothing has been opened yet.
  final ValueListenable<PlaybackReport?> report;

  /// Asked every couple of seconds while this shows: read the player again.
  final VoidCallback? onRefresh;

  /// In the card: back to More.
  final VoidCallback? onBack;

  @override
  State<InfoPane> createState() => _InfoPaneState();
}

class _InfoPaneState extends State<InfoPane> {
  var _view = _View.stream;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.onRefresh?.call();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => widget.onRefresh?.call());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _show(_View v) {
    if (_view != v) setState(() => _view = v);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.report,
    builder: (context, report, _) => TvMenuScope.isIn(context) ? _tv(report) : _list(report),
  );

  // ── On a TV: the views, and the one the ring is on in columns beside them ──

  /// Tells when the ring comes onto [child].
  static Widget _onRing(VoidCallback arrived, Widget child) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (has) {
      if (has) arrived();
    },
    child: child,
  );

  Widget _tv(PlaybackReport? report) => TvRails([
    TvRail(
      title: 'Show',
      width: 158,
      children: [
        _onRing(() => _show(_View.stream), MenuRow(title: 'Stream', selected: _view == _View.stream, onTap: () => _show(_View.stream))),
        _onRing(() => _show(_View.card), MenuRow(title: 'Report card', selected: _view == _View.card, start: false, onTap: () => _show(_View.card))),
        if (_view == _View.card) const TvNote('Take a photo of this screen when you report a problem.'),
      ],
    ),
    if (report == null)
      const SizedBox(width: 300, child: TvNote('Nothing has been opened yet.'))
    else if (_view == _View.stream) ...[
      for (final (i, sections) in _streamColumns(report).indexed) FactColumn(sections: sections, width: const [252.0, 200.0, 208.0][i]),
    ] else ...[
      for (final (i, section) in report.card.indexed) FactColumn(sections: [section], width: const [252.0, 190.0, 218.0][i]),
    ],
  ]);

  /// Stream info in three columns: where it is from and what plays it, the picture, the sound
  /// and the subtitle.
  static List<List<ReportSection>> _streamColumns(PlaybackReport r) {
    final s = r.stream;
    return [
      [s[0], s[1]],
      [s[2]],
      [s[3], s[4]],
    ];
  }

  // ── In the card (a desktop, a phone): a list ──

  Widget _list(PlaybackReport? report) => MenuScroll(
    children: [
      if (widget.onBack != null)
        MenuRow(
          title: 'Stream info',
          detail: report?.title,
          leading: const Icon(Icons.arrow_back_rounded, size: 18, color: MenuInk.body),
          start: true,
          onTap: widget.onBack,
        ),
      if (report == null)
        const Padding(
          padding: EdgeInsets.all(14),
          child: Text('Nothing has been opened yet.', style: TextStyle(fontSize: 12.5, color: MenuInk.dim)),
        )
      else ...[
        for (final section in [...report.stream, ...report.card])
          if (section.facts.isNotEmpty)
            // A stop for the arrow keys, so the list can be read down with them (there is
            // nothing to press: OK does nothing here, and a pointer sees plain text).
            Pressable(
              onLongPress: () {},
              focusRadius: 13,
              builder: (context, _, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MenuCaption(section.title.toUpperCase()),
                  for (final f in section.facts) _FactLine(f),
                  const SizedBox(height: 4),
                ],
              ),
            ),
        const MenuCaption('REPORT A PROBLEM'),
        MenuRow(
          title: 'Copy report',
          detail: 'All of the above as text, to paste into a message. No link is in it',
          start: false,
          onTap: () => Clipboard.setData(ClipboardData(text: report.text)),
        ),
      ],
    ],
  );
}

/// A column of facts under their captions: each fact's name, small, over what it says.
class FactColumn extends StatelessWidget {
  const FactColumn({super.key, required this.sections, required this.width});
  final List<ReportSection> sections;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    // (a TV shows it whole; anything smaller can scroll it by touch)
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, section) in sections.indexed)
            if (section.facts.isNotEmpty) ...[
              Padding(
                // (level with the columns' own names beside it)
                padding: EdgeInsets.fromLTRB(13, i == 0 ? 0 : 8, 12, 6),
                child: Text(
                  section.title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.3, color: MenuInk.faint),
                ),
              ),
              for (final f in section.facts) _Fact(f),
            ],
        ],
      ),
    ),
  );
}

/// One fact in a column: its name over what it says.
class _Fact extends StatelessWidget {
  const _Fact(this.fact);
  final ReportFact fact;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(13, 0, 12, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(fact.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, height: 1.3, fontWeight: FontWeight.w600, color: MenuInk.dim)),
        Text(
          fact.value,
          maxLines: 7,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, height: 1.3, fontWeight: FontWeight.w600, letterSpacing: -.1, color: _ink(fact), fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ],
    ),
  );
}

/// The result's colour says how it went, as the rest of the app's notices do.
Color _ink(ReportFact f) {
  if (f.label != 'Result') return MenuInk.title;
  if (f.value.startsWith('Played')) return const Color(0xFF6EDC8C);
  if (f.value.startsWith('Did not play') || f.value.startsWith('Stopped')) return const Color(0xFFFF8A80);
  return VyseColors.accent;
}

/// One fact in the card's list: its name on the left, what it says on the right.
class _FactLine extends StatelessWidget {
  const _FactLine(this.fact);
  final ReportFact fact;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 118, child: Text(fact.label, style: const TextStyle(fontSize: 12, height: 1.35, color: MenuInk.dim))),
        const SizedBox(width: 10),
        Expanded(
          child: Text(fact.value, style: TextStyle(fontSize: 12.5, height: 1.35, fontWeight: FontWeight.w600, color: _ink(fact), fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ],
    ),
  );
}

/// The report card by itself, in a box over the page: Settings shows the last playback's with
/// it, after the player has closed (a film that never started can still be reported).
Future<void> showReportCard(BuildContext context, PlaybackReport report) => showDialog<void>(
  context: context,
  useRootNavigator: true,
  barrierColor: Colors.black.withValues(alpha: .6),
  builder: (context) => Dialog(
    backgroundColor: VyseColors.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    insetPadding: const EdgeInsets.all(20),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 860),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(13, 20, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(report.title.isEmpty ? 'Last playback' : report.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -.4)),
                  const SizedBox(height: 4),
                  const Text('Take a photo of this card when you report a problem.', style: TextStyle(fontSize: 13, color: VyseColors.textDim)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: LayoutBuilder(
                builder: (context, box) {
                  final card = report.card;
                  // side by side where there is room for three columns; one under another on a phone
                  if (box.maxWidth < 560) {
                    return SingleChildScrollView(child: FactColumn(sections: card, width: box.maxWidth));
                  }
                  final each = (box.maxWidth - 2 * TvRails.gap) / 3;
                  return TvRails([for (final section in card) FactColumn(sections: [section], width: each)]);
                },
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: DpadStart(child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))),
            ),
          ],
        ),
      ),
    ),
  ),
);
