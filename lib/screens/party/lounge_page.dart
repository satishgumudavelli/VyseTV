import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketbase/pocketbase.dart' show UnsubscribeFunc;

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../data/account/account.dart';
import '../../data/party/chat_quote.dart';
import '../../data/party/friends.dart';
import '../../data/party/lounges.dart';
import '../../widgets/common.dart';
import '../../widgets/section_chrome.dart';
import 'chat_view.dart';
import 'lounges_view.dart' show loungeIcon, showMakeLoungeDialog;
import 'party_widgets.dart';

const _red = Color(0xFFFF8A8C);

void _toast(BuildContext context, String text, {IconData icon = Icons.error_outline_rounded}) =>
    showToast(context, Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: icon);

ChatLine _line(LoungeMessage m) =>
    ChatLine.message(id: m.id, user: m.user, name: m.name, avatarUrl: m.avatarUrl, body: m.body, created: m.created, quote: m.reply, hidden: m.hidden);

int _roleRank(String role) => switch (role) {
  'owner' => 3,
  'mod' => 2,
  _ => 1,
};

/// A lounge: its chat for the people with a seat, otherwise what it is and Join. Live while it's
/// open; opening it, and every few new messages, counts as reading it (which keeps your seat).
class LoungePage extends StatefulWidget {
  const LoungePage({super.key, required this.lounge});

  /// What the list knew about it; the page fetches the rest.
  final Lounge lounge;

  @override
  State<LoungePage> createState() => _LoungePageState();
}

class _LoungePageState extends State<LoungePage> {
  late Lounge _lounge = widget.lounge;
  LoungeDetail? _detail;
  String? _error;
  final _lines = <ChatLine>[]; // oldest first
  bool _more = false;
  String _oldest = '';
  bool _loadingOlder = false;
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;
  bool _joining = false;
  ChatQuote? _replying;
  UnsubscribeFunc? _unsub;
  Timer? _soon;
  Timer? _tick;
  Timer? _readTimer;
  DateTime _readAt = DateTime(2000);
  bool _showMembers = true; // the column beside the chat on wide screens

  String get _id => widget.lounge.id;
  bool get _seated => _detail?.me != null;

  @override
  void initState() {
    super.initState();
    Lounges.openId = _id;
    hideBottomBar.value++; // phones: the chat gets the whole screen
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.extentAfter < 400) _loadOlder();
    });
    _load();
    // who's here and the seats, now and then; also ends a timeout on time
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _refreshDetail());
  }

  @override
  void dispose() {
    if (Lounges.openId == _id) Lounges.openId = null;
    hideBottomBar.value--;
    _unsub?.call().catchError((Object _) {});
    _soon?.cancel();
    _tick?.cancel();
    _readTimer?.cancel();
    if (_seated) unawaited(Lounges.read(_id));
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await Lounges.detail(_id);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _lounge = d.lounge;
        _error = null;
      });
      if (d.me != null) {
        _listen();
        await _loadMessages();
        unawaited(Lounges.read(_id));
        _readAt = DateTime.now();
      }
    } catch (e) {
      if (mounted) setState(() => _error = Account.describe(e));
    }
  }

  Future<void> _refreshDetail() async {
    try {
      final d = await Lounges.detail(_id);
      if (!mounted) return;
      final wasSeated = _seated;
      setState(() {
        _detail = d;
        _lounge = d.lounge;
      });
      if (d.me != null && !wasSeated) {
        _listen();
        await _loadMessages();
      } else if (d.me == null && wasSeated) {
        _stopListening();
      }
    } catch (_) {}
  }

  bool _blocked(String user) => Friends.lists.value.blockedIds.contains(user);

  Future<void> _loadMessages() async {
    try {
      final r = await Lounges.messages(_id);
      if (!mounted) return;
      setState(() {
        _lines
          ..clear()
          ..addAll(r.items.reversed.where((m) => !_blocked(m.user)).map(_line));
        _more = r.more;
        _oldest = r.oldest;
      });
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
    }
  }

  Future<void> _loadOlder() async {
    if (!_more || _loadingOlder || _oldest.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final r = await Lounges.messages(_id, before: _oldest);
      if (!mounted) return;
      setState(() {
        final have = {for (final l in _lines) l.id};
        _lines.insertAll(0, r.items.reversed.where((m) => !have.contains(m.id) && !_blocked(m.user)).map(_line));
        _more = r.more;
        _oldest = r.oldest;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _listen() {
    if (_unsub != null) return;
    Lounges.live(_id, _event).then((u) {
      if (!mounted || !_seated) {
        u().catchError((Object _) {});
        return;
      }
      _unsub = u;
    }, onError: (Object _) {});
  }

  void _stopListening() {
    _unsub?.call().catchError((Object _) {});
    _unsub = null;
  }

  void _event(LoungeEvent e) {
    if (!mounted) return;
    switch (e.type) {
      case 'message':
        final m = e.message;
        if (m == null || _blocked(m.user)) return;
        setState(() {
          final i = _lines.indexWhere((l) => l.id == m.id);
          if (i >= 0) {
            _lines[i] = _line(m); // brought back by a moderator
          } else {
            _lines.add(_line(m));
          }
        });
        _readSoon();
      case 'remove':
        setState(() => _lines.removeWhere((l) => l.id == e.id));
      case 'lounge':
        final l = e.lounge;
        if (l != null) setState(() => _lounge = l);
      case 'members':
      case 'you':
        _soon?.cancel();
        _soon = Timer(const Duration(milliseconds: 400), _refreshDetail);
      case 'removed':
        _toast(context, e.banned ? 'You were banned from this lounge.' : 'A moderator took your seat.', icon: Icons.block_rounded);
        _stopListening();
        setState(() => _lines.clear());
        unawaited(Lounges.refresh());
        _refreshDetail();
      case 'deleted':
        _toast(context, 'This lounge was deleted.', icon: Icons.info_outline_rounded);
        unawaited(Lounges.refresh());
        Navigator.of(context).maybePop();
    }
  }

  /// Reading as messages come in, at most every few seconds.
  void _readSoon() {
    final wait = const Duration(seconds: 5) - DateTime.now().difference(_readAt);
    if (_readTimer?.isActive ?? false) return;
    _readTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _readAt = DateTime.now();
      if (mounted && _seated) unawaited(Lounges.read(_id));
    });
  }

  Future<void> _join() async {
    if (_joining) return;
    setState(() => _joining = true);
    try {
      await Lounges.join(_id);
      await _load();
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
      unawaited(_refreshDetail());
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _leave() async {
    final owner = _detail?.me?.role == 'owner';
    final ok = await _confirm(
      'Leave ${_lounge.name}?',
      owner
          ? 'You own it: it passes to a moderator, or to whoever has been in it longest. With nobody left, it goes.'
          : 'Your seat goes to whoever comes next. You can come back while there are seats.',
      'Leave',
    );
    if (!ok || !mounted) return;
    try {
      await Lounges.leave(_id);
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final m = await Lounges.send(_id, text, replyTo: _replying?.id);
      _input.clear();
      if (!mounted) return;
      setState(() {
        _replying = null;
        if (!_lines.any((l) => l.id == m.id)) _lines.add(_line(m));
      });
      if (_scroll.hasClients) unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
    } finally {
      if (mounted) setState(() => _sending = false);
      _focus.requestFocus();
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        barrierColor: Colors.black.withValues(alpha: .6),
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF0B0D16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: VyseColors.stroke)),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          content: Text(body, style: const TextStyle(color: VyseColors.textDim, height: 1.4)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel', style: TextStyle(color: VyseColors.textDim))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _red, foregroundColor: Colors.black),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action, style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ) ??
      false;

  // ── moderation ──

  /// Your rank over [user] lets you act on them (the server checks again).
  bool _over(String user) {
    final d = _detail;
    if (d == null || !d.canModerate || user == Account.user.value?.id) return false;
    final them = d.members.where((m) => m.id == user).firstOrNull;
    return d.rank > _roleRank(them?.role ?? 'member');
  }

  Future<void> _moderate(String user, String name, {int? minutes, bool kick = false, bool ban = false}) async {
    if (ban && !await _confirm('Ban $name?', 'They lose their seat and can\'t come back until a moderator lets them.', 'Ban')) return;
    try {
      await Lounges.moderate(_id, user, minutes: minutes, kick: kick, ban: ban);
      if (!mounted) return;
      final done = ban
          ? '$name is banned.'
          : kick
          ? '$name lost their seat.'
          : minutes == 0
          ? '$name can post again.'
          : '$name is timed out for ${minutes! >= 60 ? '${minutes ~/ 60} h' : '$minutes min'}.';
      _toast(context, done, icon: Icons.shield_outlined);
      unawaited(_refreshDetail());
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
    }
  }

  List<(String, String, bool)> _modItems(String user) => [
    if (_over(user)) ...[
      ('t10', 'Time out 10 minutes', false),
      ('t60', 'Time out 1 hour', false),
      ('t1440', 'Time out 1 day', false),
      ('t0', 'Lift a timeout', false),
      ('kick', 'Take their seat', true),
      ('ban', 'Ban from the lounge', true),
    ],
  ];

  Future<void> _modAction(String v, String user, String name) async {
    if (v.startsWith('t')) return _moderate(user, name, minutes: int.parse(v.substring(1)));
    if (v == 'kick') return _moderate(user, name, kick: true);
    if (v == 'ban') return _moderate(user, name, ban: true);
  }

  Future<void> _messageMenu(BuildContext context, ChatLine m, Offset at) async {
    final mod = _detail?.canModerate ?? false;
    final v = await showChatMenu(context, at, [
      if (!m.hidden && _notice == null) ('reply', 'Reply', false),
      ('copy', 'Copy text', false),
      ('profile', 'View profile', false),
      if (mod && m.hidden) ('restore', 'Show it again', false),
      if (!m.mine) ('report', 'Report', true),
      if (m.mine || mod) ('delete', 'Delete message', true),
      if (!m.mine) ..._modItems(m.user),
    ]);
    if (!mounted || v == null) return;
    switch (v) {
      case 'reply':
        setState(() => _replying = m.asQuote);
        focusAfterMenu(_focus);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.body));
      case 'profile':
        await showPartyProfile(this.context, m.user);
      case 'report':
        await showReportDialog(this.context, userId: m.user, name: m.name, kind: 'lounge_message', ref: m.id);
      case 'restore':
        try {
          await Lounges.restore(_id, m.id!);
        } catch (e) {
          if (mounted) _toast(this.context, Account.describe(e));
        }
      case 'delete':
        try {
          await Lounges.remove(_id, m.id!);
          if (mounted) setState(() => _lines.removeWhere((l) => l.id == m.id));
        } catch (e) {
          if (mounted) _toast(this.context, Account.describe(e));
        }
      default:
        await _modAction(v, m.user, m.name);
    }
  }

  Future<void> _memberMenu(BuildContext context, LoungeMember m, Offset at) async {
    final d = _detail;
    if (d == null) return;
    final owner = d.isOwner && !_lounge.official;
    final v = await showChatMenu(context, at, [
      ('profile', 'View profile', false),
      if (!m.isMe && d.isOwner && m.role == 'member') ('mod', 'Make a moderator', false),
      if (!m.isMe && d.isOwner && m.role == 'mod') ('unmod', 'Stop as moderator', false),
      if (!m.isMe && owner && m.role != 'owner') ('owner', 'Hand the lounge over', false),
      if (!m.isMe) ..._modItems(m.id),
    ]);
    if (!mounted || v == null) return;
    switch (v) {
      case 'profile':
        await showPartyProfile(this.context, m.id);
      case 'mod' || 'unmod':
        try {
          await Lounges.manage(_id, {v: m.id});
          if (mounted) _toast(this.context, v == 'mod' ? '${m.name} is a moderator.' : '${m.name} is not a moderator any more.', icon: Icons.shield_outlined);
          unawaited(_refreshDetail());
        } catch (e) {
          if (mounted) _toast(this.context, Account.describe(e));
        }
      case 'owner':
        if (!await _confirm('Hand ${_lounge.name} to ${m.name}?', 'They become its owner and you become a moderator.', 'Hand over')) return;
        try {
          await Lounges.manage(_id, {'owner': m.id});
          unawaited(_refreshDetail());
        } catch (e) {
          if (mounted) _toast(this.context, Account.describe(e));
        }
      default:
        await _modAction(v, m.id, m.name);
    }
  }

  Future<void> _moreMenu(Offset at) async {
    final d = _detail;
    final seat = d?.me;
    final v = await showChatMenu(context, at, [
      if (seat != null) ('mute', seat.muted ? 'Unmute: show new messages' : 'Mute: no unread dot', false),
      if (d?.isOwner ?? false) ...[('edit', 'Edit lounge', false), ('slow', 'Slow mode', false)],
      if (d?.canModerate ?? false) ...[('bans', 'Banned people', false), ('log', 'Moderation log', false)],
      if (!_lounge.official && !(d?.isOwner ?? false)) ('report', 'Report this lounge', true),
      if (seat != null) ('leave', 'Leave lounge', true),
      if ((d?.isOwner ?? false) && !_lounge.official) ('delete', 'Delete lounge', true),
    ]);
    if (!mounted || v == null) return;
    switch (v) {
      case 'mute':
        try {
          await Lounges.mute(_id, !(seat?.muted ?? false));
          unawaited(_refreshDetail());
        } catch (e) {
          if (mounted) _toast(context, Account.describe(e));
        }
      case 'edit':
        await showMakeLoungeDialog(context, edit: _lounge);
        unawaited(_refreshDetail());
      case 'slow':
        await _slowMode();
      case 'bans':
        await _bans();
      case 'log':
        await _log();
      case 'report':
        await showReportDialog(context, userId: _lounge.owner, name: _lounge.name, kind: 'lounge', ref: _id);
      case 'leave':
        await _leave();
      case 'delete':
        if (!await _confirm('Delete ${_lounge.name}?', 'Everyone loses their seat and the messages are gone. This can\'t be undone.', 'Delete')) return;
        try {
          await Lounges.delete(_id);
          if (mounted) Navigator.of(context).maybePop();
        } catch (e) {
          if (mounted) _toast(context, Account.describe(e));
        }
    }
  }

  Future<void> _slowMode() async {
    final s = await showDialog<int>(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: .6),
      builder: (context) => SimpleDialog(
        backgroundColor: const Color(0xFF0B0D16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: VyseColors.stroke)),
        title: const Text('Slow mode', style: TextStyle(fontWeight: FontWeight.w800)),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('How long each person waits between messages. Moderators don\'t wait.', style: TextStyle(color: VyseColors.textDim, fontSize: 13)),
          ),
          for (final n in const [2, 3, 5, 10, 30, 60, 120])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, n),
              child: Row(
                children: [
                  Expanded(child: Text(n < 60 ? '$n seconds' : (n == 60 ? '1 minute' : '2 minutes'))),
                  if (_lounge.slow == n) const Icon(Icons.check_rounded, size: 18, color: VyseColors.accent),
                ],
              ),
            ),
        ],
      ),
    );
    if (s == null || !mounted) return;
    try {
      final l = await Lounges.manage(_id, {'slow': s});
      if (mounted) setState(() => _lounge = l);
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
    }
  }

  Future<void> _bans() async {
    List<LoungeMember> list;
    try {
      list = await Lounges.bans(_id);
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: .6),
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          backgroundColor: const Color(0xFF0B0D16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: VyseColors.stroke)),
          title: const Text('Banned people', style: TextStyle(fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: 380,
            child: list.isEmpty
                ? const Text('Nobody is banned.', style: TextStyle(color: VyseColors.textDim))
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final b in list)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              PartyAvatar(url: b.avatarUrl, name: b.name, size: 30),
                              const SizedBox(width: 10),
                              Expanded(child: Text(b.name, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
                              PartyChipButton(
                                icon: Icons.lock_open_rounded,
                                label: 'Unban',
                                onTap: () async {
                                  try {
                                    await Lounges.moderate(_id, b.id, unban: true);
                                    set(() => list = [for (final x in list) if (x.id != b.id) x]);
                                  } catch (e) {
                                    if (context.mounted) _toast(context, Account.describe(e));
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
        ),
      ),
    );
  }

  Future<void> _log() async {
    List<LoungeLogEntry> list;
    try {
      list = await Lounges.log(_id);
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
      return;
    }
    if (!mounted) return;
    const words = {
      'delete': 'removed a message from',
      'timeout': 'timed out',
      'untimeout': 'lifted the timeout of',
      'kick': 'took the seat of',
      'ban': 'banned',
      'unban': 'unbanned',
      'mod': 'made a moderator:',
      'unmod': 'stopped as moderator:',
      'owner': 'handed the lounge to',
      'edit': 'changed',
      'hidden': 'reports hid a message from',
      'restore': 'brought back a message from',
    };
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: .6),
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0B0D16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: VyseColors.stroke)),
        title: const Text('Moderation log', style: TextStyle(fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 420,
          child: list.isEmpty
              ? const Text('Nothing this week.', style: TextStyle(color: VyseColors.textDim))
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final e in list)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: e.actor.isEmpty ? 'VyseTV' : e.actor, style: const TextStyle(fontWeight: FontWeight.w800)),
                              TextSpan(text: ' ${words[e.action] ?? e.action} '),
                              if (e.target.isNotEmpty) TextSpan(text: e.target, style: const TextStyle(fontWeight: FontWeight.w800)),
                              if (e.detail.isNotEmpty) TextSpan(text: '  ${e.detail}', style: const TextStyle(color: VyseColors.textFaint)),
                              if (e.created != null) TextSpan(text: '  ${chatClock(e.created!)}', style: const TextStyle(color: VyseColors.textFaint)),
                            ],
                          ),
                          style: const TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.35),
                        ),
                      ),
                  ],
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  void _membersSheet() {
    final d = _detail;
    if (d == null) return;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: const Color(0xFF0B0D16),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .7),
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(context).bottom),
          child: _Members(detail: d, onMenu: _memberMenu),
        ),
      ),
    );
  }

  // ── layout ──

  String? get _notice {
    final me = _detail?.me;
    if (me == null) return null;
    final now = DateTime.now();
    if (me.timeoutUntil != null && me.timeoutUntil!.isAfter(now)) return 'A moderator timed you out until ${chatClock(me.timeoutUntil!)}. You can still read.';
    if (me.canPostAt != null && me.canPostAt!.isAfter(now)) return 'New in Party: you can post from ${chatClock(me.canPostAt!)}. Read along until then.';
    return null;
  }

  Widget _header(BuildContext context, bool phone, bool wide) {
    final side = phone ? 12.0 : Layout.inset(context);
    final right = pageRight(context);
    final l = _lounge;
    final nav = Navigator.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(side - 8, Layout.windowChrome(context) + (phone ? 6 : 14), right - 8, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: VyseColors.stroke)),
      ),
      child: Row(
        children: [
          if (nav.canPop())
            IconButton(
              tooltip: 'Back',
              onPressed: () => nav.maybePop(),
              icon: const Icon(Icons.arrow_back_rounded, color: VyseColors.textDim),
            ),
          const SizedBox(width: 4),
          Icon(loungeIcon(l.topic), size: phone ? 20 : 24, color: VyseColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l.name,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: phone ? 16 : 18, fontWeight: FontWeight.w900),
                ),
                Text(
                  [
                    '${l.size}/${l.limit} seats',
                    if (l.here > 0) '${l.here} here',
                    if (l.slow > 3) 'slow mode ${l.slow} s',
                    if (!phone && l.official) 'official',
                  ].join(' · '),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: VyseColors.textDim, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          if (_seated)
            IconButton(
              tooltip: wide ? (_showMembers ? 'Hide who is here' : 'Show who is here') : 'Who is here',
              onPressed: wide ? () => setState(() => _showMembers = !_showMembers) : _membersSheet,
              icon: Icon(Icons.groups_rounded, color: wide && _showMembers ? VyseColors.text : VyseColors.textDim),
            ),
          if (_detail != null)
            Builder(
              builder: (context) => IconButton(
                tooltip: 'More',
                onPressed: () {
                  final box = context.findRenderObject() as RenderBox?;
                  _moreMenu(box == null ? Offset.zero : box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                },
                icon: const Icon(Icons.more_vert_rounded, color: VyseColors.textDim),
              ),
            ),
        ],
      ),
    );
  }

  /// No seat: what the lounge is, and Join (or why not).
  Widget _preview(BuildContext context) {
    final l = _lounge;
    final d = _detail;
    final full = l.full;
    final banned = d?.banned ?? false;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
            decoration: BoxDecoration(
              color: partyCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: VyseColors.stroke),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: VyseColors.accent.withValues(alpha: .14), borderRadius: BorderRadius.circular(16)),
                  child: Icon(loungeIcon(l.topic), color: VyseColors.accent, size: 26),
                ),
                const SizedBox(height: 16),
                Text(l.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: -.4)),
                const SizedBox(height: 4),
                Text(
                  '${l.official ? 'Official · ' : ''}${l.topicName} · ${l.size}/${l.limit} seats${l.here > 0 ? ' · ${l.here} here' : ''}',
                  style: const TextStyle(fontSize: 13, color: VyseColors.textDim, fontWeight: FontWeight.w600),
                ),
                if (l.description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(l.description, style: const TextStyle(fontSize: 14, height: 1.45)),
                ],
                const SizedBox(height: 14),
                const Text(
                  'Take a seat to read and post. Messages go after 24 hours. A seat you don\'t use for 3 days goes to someone else.',
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: VyseColors.textFaint),
                ),
                const SizedBox(height: 18),
                if (_error != null && d == null)
                  Text(_error!, style: const TextStyle(color: _red, fontWeight: FontWeight.w600))
                else if (banned)
                  const Text('You were banned from this lounge.', style: TextStyle(color: _red, fontWeight: FontWeight.w700))
                else if (full)
                  Text('Full: all ${l.limit} seats are taken. Try again later.', style: const TextStyle(color: _red, fontWeight: FontWeight.w700))
                else
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: d == null || _joining ? null : _join,
                      child: _joining || d == null
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.black))
                          : const Text('Take a seat', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chat(BuildContext context) {
    final notice = _notice;
    final about = _lounge.description.isEmpty ? '' : '${_lounge.description}  ';
    return Column(
      children: [
        Expanded(
          child: PartyChatList(
            lines: _lines,
            scroll: _scroll,
            intro: '${about}Messages go after 24 hours. Only people with a seat can read them.',
            onMenu: _messageMenu,
            loadingOlder: _loadingOlder,
          ),
        ),
        PartyChatInput(
          input: _input,
          focus: _focus,
          sending: _sending,
          onSend: _send,
          hint: 'Message ${_lounge.name}',
          maxLength: 500,
          replying: _replying,
          onCancelReply: () => setState(() => _replying = null),
          notice: notice,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    return Material(
      color: VyseColors.bg,
      child: LayoutBuilder(
        builder: (context, page) {
          // who's here beside the chat when there's width for both (a TV's 960 keeps the chat whole)
          final wide = page.maxWidth >= 1000;
          // clear of the navigation rail, as every page is (the chat's own padding is 14)
          final left = phone ? 0.0 : (Layout.inset(context) - 14).clamp(0.0, 400.0);
          // hardly any height left (a phone on its side with the keyboard up): the chat alone
          final cramped = page.maxHeight < 260;
          final body = _detail == null && _error == null
              ? const Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim)))
              : !_seated
              ? _preview(context)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Padding(padding: EdgeInsets.only(left: left), child: _chat(context)),
                    ),
                    if (wide && _showMembers)
                      Container(
                        width: 250,
                        decoration: const BoxDecoration(
                          color: Color(0xFF0A0B13),
                          border: Border(left: BorderSide(color: VyseColors.stroke)),
                        ),
                        child: _Members(detail: _detail!, onMenu: _memberMenu),
                      ),
                  ],
                );
          if (cramped && _seated) return SafeArea(bottom: false, child: body);
          return Column(
            children: [
              _header(context, phone, wide),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }
}

/// Who has a seat: the owner and moderators first, then whoever's online.
class _Members extends StatelessWidget {
  const _Members({required this.detail, required this.onMenu});
  final LoungeDetail detail;
  final Future<void> Function(BuildContext context, LoungeMember m, Offset at) onMenu;

  @override
  Widget build(BuildContext context) {
    final list = [...detail.members]
      ..sort((a, b) {
        final r = _roleRank(b.role).compareTo(_roleRank(a.role));
        if (r != 0) return r;
        final ao = a.presence != 'offline', bo = b.presence != 'offline';
        if (ao != bo) return ao ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final l = detail.lounge;
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 20),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            'IN THE LOUNGE — ${l.size}/${l.limit}',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .7, color: VyseColors.textDim),
          ),
        ),
        for (final m in list)
          Builder(
            builder: (context) => Pressable(
              onTap: () {
                final box = context.findRenderObject() as RenderBox?;
                onMenu(context, m, box == null ? Offset.zero : box.localToGlobal(box.size.centerLeft(Offset.zero)));
              },
              builder: (context, hovered, _) => AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: hovered ? .06 : 0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    PartyAvatar(url: m.avatarUrl, name: m.name, size: 30, presence: m.presence, ring: const Color(0xFF0A0B13)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        m.isMe ? '${m.name} (you)' : m.name,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: m.presence == 'offline' ? VyseColors.textDim : VyseColors.text,
                        ),
                      ),
                    ),
                    if (m.role == 'owner')
                      const Tooltip(message: 'Owner', child: Icon(Icons.workspace_premium_rounded, size: 15, color: VyseColors.star))
                    else if (m.role == 'mod')
                      const Tooltip(message: 'Moderator', child: Icon(Icons.shield_rounded, size: 14, color: VyseColors.accent)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
