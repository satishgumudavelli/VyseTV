import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/account/account.dart';
import '../../data/party/lounges.dart';
import '../../widgets/common.dart';
import '../../widgets/section_chrome.dart';
import 'lounge_page.dart';
import 'party_widgets.dart';
import 'rooms_view.dart' show PartyField, PartySheet;

// Lounges: public chat rooms in Party, for talking rather than watching. The list beside the
// rooms (official ones on top, then yours), the page to find others, and making one.

IconData loungeIcon(String topic) => switch (topic) {
  'films' => Icons.movie_rounded,
  'series' => Icons.tv_rounded,
  'anime' => Icons.auto_awesome_rounded,
  'music' => Icons.music_note_rounded,
  'games' => Icons.sports_esports_rounded,
  'help' => Icons.help_outline_rounded,
  'talk' => Icons.forum_rounded,
  _ => Icons.tag_rounded,
};

void _toast(BuildContext context, String text, {IconData icon = Icons.error_outline_rounded}) =>
    showToast(context, Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: icon);

/// Opens a lounge in the current tab (or stays on it when it's on top already).
Future<void> openLounge(NavigatorState nav, Lounge lounge) async {
  final name = 'lounge/${lounge.id}';
  String? top;
  nav.popUntil((r) {
    top = r.settings.name;
    return true;
  });
  if (top == name) return;
  await nav.push(
    ShellRoute(
      settings: RouteSettings(name: name),
      child: LoungePage(lounge: lounge),
    ),
  );
}

/// The page that finds lounges people made.
Future<void> openLoungeList(NavigatorState nav) => nav.push(
  ShellRoute(
    settings: const RouteSettings(name: 'lounges'),
    child: const LoungesPage(),
  ),
);

/// The lounges, one line each: official ones, then the ones you have a seat in. Unread ones are
/// bright, replies to you are counted. Shown above the rooms.
class PartyLoungesPanel extends StatelessWidget {
  const PartyLoungesPanel({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Lounges.official, Lounges.mine]),
    builder: (context, _) {
      final mine = {for (final l in Lounges.mine.value) l.id: l};
      final official = [for (final l in Lounges.official.value) mine[l.id] ?? l];
      final yours = [for (final l in Lounges.mine.value) if (!l.official) l];
      final nav = Navigator.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 0, 6),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'LOUNGES',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .7, color: VyseColors.textDim),
                  ),
                ),
                IconButton(
                  tooltip: 'Find lounges',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => openLoungeList(nav),
                  icon: const Icon(Icons.explore_outlined, size: 19, color: VyseColors.textDim),
                ),
                IconButton(
                  tooltip: 'Make a lounge',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => showMakeLoungeDialog(context),
                  icon: const Icon(Icons.add_rounded, size: 22, color: VyseColors.text),
                ),
              ],
            ),
          ),
          for (final l in official) LoungeRow(lounge: l, onTap: () => openLounge(nav, l)),
          if (yours.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final l in yours) LoungeRow(lounge: l, onTap: () => openLounge(nav, l)),
          ],
          if (official.isEmpty && yours.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text('Public chat rooms. Find one to join, or make your own.', style: TextStyle(fontSize: 12.5, height: 1.4, color: VyseColors.textFaint)),
            ),
        ],
      );
    },
  );
}

/// A lounge's line: its topic's icon, its name (bright when there's something new), replies to
/// you, and how full it is.
class LoungeRow extends StatelessWidget {
  const LoungeRow({super.key, required this.lounge, required this.onTap});
  final Lounge lounge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = lounge;
    final fresh = l.joined && l.unread && !l.muted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Pressable(
        onTap: onTap,
        tooltip: l.joined ? null : (l.full ? 'Full' : 'Take a seat to read it'),
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: hovered ? .06 : 0),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(loungeIcon(l.topic), size: 17, color: fresh || l.replies > 0 ? VyseColors.text : VyseColors.textDim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.name,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: fresh || l.replies > 0 ? FontWeight.w800 : FontWeight.w600,
                    color: fresh || l.replies > 0 || l.joined ? VyseColors.text : VyseColors.textDim,
                  ),
                ),
              ),
              if (l.replies > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(9)),
                  child: Text(
                    '@${l.replies > 9 ? '9+' : l.replies}',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.black),
                  ),
                ),
              ] else if (fresh) ...[
                const SizedBox(width: 6),
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(color: VyseColors.text, shape: BoxShape.circle),
                ),
              ],
              const SizedBox(width: 8),
              Text(
                '${l.size}/${l.limit}',
                style: TextStyle(fontSize: 11.5, color: l.full && !l.joined ? const Color(0xFFFF8A8C) : VyseColors.textFaint, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Finding lounges ─────────────────────────

/// Every lounge people made, busiest first: search by name, filter by topic, make your own.
class LoungesPage extends StatefulWidget {
  const LoungesPage({super.key});

  @override
  State<LoungesPage> createState() => _LoungesPageState();
}

class _LoungesPageState extends State<LoungesPage> {
  final _query = TextEditingController();
  String _topic = '';
  List<Lounge>? _results;
  String? _error;
  Timer? _debounce;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final n = ++_asked;
    try {
      final list = await Lounges.browse(query: _query.text, topic: _topic);
      if (mounted && n == _asked) {
        setState(() {
          _results = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && n == _asked) setState(() => _error = Account.describe(e));
    }
  }

  void _typed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final side = phone ? 16.0 : Layout.inset(context);
    final right = pageRight(context);
    final nav = Navigator.of(context);
    return Material(
      color: VyseColors.bg,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side - 8, Layout.windowChrome(context) + (phone ? 6 : 14), right, 0),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  if (nav.canPop())
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => nav.maybePop(),
                      icon: const Icon(Icons.arrow_back_rounded, color: VyseColors.textDim),
                    ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Lounges',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: phone ? 24 : 30, fontWeight: FontWeight.w900, letterSpacing: -.6),
                    ),
                  ),
                  ValueListenableBuilder<LoungeMaking>(
                    valueListenable: Lounges.making,
                    builder: (context, m, _) => PartyChipButton(
                      icon: Icons.add_rounded,
                      label: phone ? 'Make' : 'Make a lounge',
                      primary: m.can,
                      onTap: () => m.can ? showMakeLoungeDialog(context) : _toast(context, _whyNot(m), icon: Icons.info_outline_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 14, right, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _query,
                    onChanged: _typed,
                    onSubmitted: (_) => _search(),
                    onTapOutside: dismissKeyboard,
                    maxLength: 40,
                    style: const TextStyle(fontSize: 14.5),
                    cursorColor: VyseColors.accent,
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: 'Search lounges',
                      hintStyle: const TextStyle(color: VyseColors.textFaint),
                      prefixIcon: const Icon(Icons.search_rounded, color: VyseColors.textFaint),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: .05),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: Colors.white.withValues(alpha: .06)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .7), width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (id, label) in [('', 'All'), for (final e in loungeTopics.entries) (e.key, e.value)]) ...[
                          FilterChipPill(
                            label: label,
                            icon: id.isEmpty ? null : loungeIcon(id),
                            selected: _topic == id,
                            onTap: () {
                              setState(() => _topic = id);
                              _search();
                            },
                          ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
          ..._list(context, side, right),
          SliverToBoxAdapter(child: SizedBox(height: 40 + MediaQuery.paddingOf(context).bottom)),
        ],
      ),
    );
  }

  List<Widget> _list(BuildContext context, double side, double right) {
    if (_error != null && _results == null) {
      return [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 24, right, 0),
          sliver: SliverToBoxAdapter(child: Text(_error!, style: const TextStyle(color: VyseColors.textDim))),
        ),
      ];
    }
    if (_results == null) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim))),
          ),
        ),
      ];
    }
    final nav = Navigator.of(context);
    Widget section(String title, List<Lounge> list) => SliverPadding(
      padding: EdgeInsets.fromLTRB(side, 18, right, 0),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: .7, color: VyseColors.textDim)),
            ),
            LayoutBuilder(
              builder: (context, c) {
                final cols = (c.maxWidth / 330).floor().clamp(1, 4);
                final w = (c.maxWidth - (cols - 1) * 12) / cols;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final l in list) SizedBox(width: w, child: LoungeCard(lounge: l, onTap: () => openLounge(nav, l)))],
                );
              },
            ),
          ],
        ),
      ),
    );
    final mine = {for (final l in Lounges.mine.value) l.id: l};
    final searching = _query.text.trim().isNotEmpty || _topic.isNotEmpty;
    final official = [
      for (final l in Lounges.official.value)
        if (!searching || l.topic == _topic || l.name.toLowerCase().contains(_query.text.trim().toLowerCase())) mine[l.id] ?? l,
    ];
    final made = [for (final l in _results!) mine[l.id] ?? l];
    return [
      if (official.isNotEmpty) section('OFFICIAL', official),
      if (made.isNotEmpty)
        section(searching ? 'FOUND' : 'MADE BY PEOPLE', made)
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 24, right, 0),
          sliver: SliverToBoxAdapter(
            child: Text(
              searching ? 'No lounge like that. Make it yourself?' : 'Nobody has made a lounge yet. Be the first.',
              style: const TextStyle(fontSize: 13.5, color: VyseColors.textDim),
            ),
          ),
        ),
    ];
  }
}

String _whyNot(LoungeMaking m) {
  final at = m.at;
  if (at != null) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return 'Accounts can make a lounge once they are 7 days old. Yours can from ${at.day} ${months[at.month - 1]}.';
  }
  return m.why.isEmpty ? "You can't make a lounge right now." : m.why;
}

/// A lounge in the list: name, topic, what it's about, seats and who's there now.
class LoungeCard extends StatelessWidget {
  const LoungeCard({super.key, required this.lounge, required this.onTap});
  final Lounge lounge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = lounge;
    final full = l.full && !l.joined;
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 128,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: hovered ? const Color(0xFF141725) : partyCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: l.joined ? VyseColors.accent.withValues(alpha: .45) : VyseColors.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(loungeIcon(l.topic), size: 18, color: VyseColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.name,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                ),
                if (l.replies > 0)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(9)),
                    child: Text('@${l.replies}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.black)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                l.description.isEmpty ? l.topicName : l.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, height: 1.35, color: VyseColors.textDim),
              ),
            ),
            Row(
              children: [
                Icon(Icons.event_seat_rounded, size: 13, color: full ? const Color(0xFFFF8A8C) : VyseColors.textFaint),
                const SizedBox(width: 4),
                Text(
                  full ? 'Full · ${l.size}/${l.limit}' : '${l.size}/${l.limit}',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: full ? const Color(0xFFFF8A8C) : VyseColors.textFaint),
                ),
                if (l.here > 0) ...[
                  const SizedBox(width: 12),
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: presenceColor('online'), shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text('${l.here} here', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: VyseColors.textFaint)),
                ],
                const Spacer(),
                Flexible(
                  child: Text(
                    l.joined ? 'Your seat' : l.topicName,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: l.joined ? VyseColors.accent : VyseColors.textFaint),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Making / editing ─────────────────────────

/// Makes a lounge (then opens it), or with [edit], changes one you own.
Future<void> showMakeLoungeDialog(BuildContext context, {Lounge? edit}) async {
  final nav = Navigator.of(context);
  if (edit == null && !Lounges.making.value.can) {
    await Lounges.refresh();
    if (!context.mounted) return;
    final m = Lounges.making.value;
    if (!m.can) return _toast(context, _whyNot(m), icon: Icons.info_outline_rounded);
  }
  final made = await showDialog<Lounge>(
    context: context,
    useRootNavigator: true,
    barrierColor: Colors.black.withValues(alpha: .6),
    builder: (_) => _MakeLounge(edit: edit),
  );
  if (made != null && edit == null) await openLounge(nav, made);
}

class _MakeLounge extends StatefulWidget {
  const _MakeLounge({this.edit});
  final Lounge? edit;

  @override
  State<_MakeLounge> createState() => _MakeLoungeState();
}

class _MakeLoungeState extends State<_MakeLounge> {
  late final _name = TextEditingController(text: widget.edit?.name ?? '');
  late final _about = TextEditingController(text: widget.edit?.description ?? '');
  late String _topic = widget.edit?.topic ?? '';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  bool get _ready => _name.text.trim().length >= 3 && _topic.isNotEmpty;

  Future<void> _save() async {
    if (!_ready || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final e = widget.edit;
      final l = e == null
          ? await Lounges.make(name: _name.text.trim(), description: _about.text.trim(), topic: _topic)
          : await Lounges.manage(e.id, {'name': _name.text.trim(), 'description': _about.text.trim(), 'topic': _topic});
      if (mounted) Navigator.pop(context, l);
    } catch (e) {
      if (mounted) setState(() => _error = Account.describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PartySheet(
    title: widget.edit == null ? 'Make a lounge' : 'Edit lounge',
    subtitle: widget.edit == null
        ? 'A public chat room for up to 30 people. It goes after 3 days without a message. You can have one.'
        : 'Everyone in it sees the change.',
    error: _error,
    action: widget.edit == null ? 'Make lounge' : 'Save',
    busy: _busy,
    enabled: _ready,
    onAction: _save,
    children: [
      PartyField(controller: _name, label: 'Name', hint: 'Horror club', maxLength: 32, onSubmit: _save),
      const SizedBox(height: 12),
      PartyField(controller: _about, label: 'What it is about (optional)', hint: 'Scary films, old and new', maxLength: 200, onSubmit: _save),
      const SizedBox(height: 16),
      const Padding(
        padding: EdgeInsets.only(left: 4, bottom: 8),
        child: Text('Topic', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: VyseColors.textDim)),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final e in loungeTopics.entries)
            FilterChipPill(label: e.value, icon: loungeIcon(e.key), selected: _topic == e.key, onTap: () => setState(() => _topic = e.key)),
        ],
      ),
    ],
  );
}
