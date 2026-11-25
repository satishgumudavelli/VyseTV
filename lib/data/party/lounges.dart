import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../account/account.dart';
import 'chat_quote.dart';

/// Topics a lounge can have, in the order the app offers them.
const loungeTopics = {
  'talk': 'Talk',
  'films': 'Films',
  'series': 'Series',
  'anime': 'Anime',
  'music': 'Music',
  'games': 'Games',
  'help': 'Help',
  'other': 'Other',
};

/// A public chat room in Party. Official ones are pinned and hold 50 (the admin can change that);
/// ones people make hold 30. A seat is needed to read and to post.
class Lounge {
  const Lounge({
    required this.id,
    required this.name,
    this.description = '',
    this.topic = 'talk',
    this.official = false,
    this.owner = '',
    this.size = 0,
    this.limit = 30,
    this.slow = 3,
    this.here = 0,
    this.lastAt,
    this.role = '',
    this.muted = false,
    this.unread = false,
    this.replies = 0,
  });

  final String id;
  final String name;
  final String description;
  final String topic;
  final bool official;
  final String owner; // user id ('' for official ones)
  final int size; // seats taken
  final int limit; // seats
  final int slow; // seconds between one person's messages
  final int here; // people with it open right now
  final DateTime? lastAt;

  /// Yours, when you have a seat: owner, mod or member ('' without one).
  final String role;
  final bool muted;
  final bool unread;
  final int replies; // replies to you since you last read it

  bool get joined => role.isNotEmpty;
  bool get full => size >= limit;
  String get topicName => loungeTopics[topic] ?? 'Other';

  factory Lounge.fromJson(Map<String, dynamic> j) => Lounge(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    description: j['description'] as String? ?? '',
    topic: j['topic'] as String? ?? 'talk',
    official: j['official'] == true,
    owner: j['owner'] as String? ?? '',
    size: (j['size'] as num?)?.toInt() ?? 0,
    limit: (j['limit'] as num?)?.toInt() ?? 30,
    slow: (j['slow'] as num?)?.toInt() ?? 3,
    here: (j['here'] as num?)?.toInt() ?? 0,
    lastAt: _date(j['lastAt']),
    role: j['role'] as String? ?? '',
    muted: j['muted'] == true,
    unread: j['unread'] == true,
    replies: (j['replies'] as num?)?.toInt() ?? 0,
  );

  Lounge copyWith({int? replies, bool? unread, bool? muted}) => Lounge(
    id: id,
    name: name,
    description: description,
    topic: topic,
    official: official,
    owner: owner,
    size: size,
    limit: limit,
    slow: slow,
    here: here,
    lastAt: lastAt,
    role: role,
    muted: muted ?? this.muted,
    unread: unread ?? this.unread,
    replies: replies ?? this.replies,
  );
}

DateTime? _date(Object? s) => s is String && s.isNotEmpty ? DateTime.tryParse(s)?.toLocal() : null;

class LoungeMessage {
  const LoungeMessage({
    required this.id,
    required this.user,
    required this.name,
    required this.body,
    required this.created,
    this.lounge = '',
    this.avatarUrl = '',
    this.reply,
    this.hidden = false,
  });
  final String id;
  final String lounge;
  final String user;
  final String name;
  final String avatarUrl;
  final String body;
  final ChatQuote? reply;
  final bool hidden; // hidden by reports, waiting for a moderator (only moderators get these)
  final DateTime created;

  bool get mine => user == Account.user.value?.id;

  factory LoungeMessage.fromJson(Map<String, dynamic> j) => LoungeMessage(
    id: j['id'] as String? ?? '',
    lounge: j['lounge'] as String? ?? '',
    user: j['user'] as String? ?? '',
    name: j['name'] as String? ?? '',
    avatarUrl: j['avatarUrl'] as String? ?? '',
    body: j['body'] as String? ?? '',
    reply: ChatQuote.fromJson(j['reply']),
    hidden: j['hidden'] == true,
    created: _date(j['created']) ?? DateTime.now(),
  );
}

class LoungeMember {
  const LoungeMember({required this.id, required this.name, this.username = '', this.avatarUrl = '', this.presence = 'offline', this.role = 'member'});
  final String id;
  final String username;
  final String name;
  final String avatarUrl;
  final String presence;
  final String role; // owner, mod, member

  bool get isMe => id == Account.user.value?.id;

  factory LoungeMember.fromJson(Map<String, dynamic> j) => LoungeMember(
    id: j['id'] as String? ?? '',
    username: j['username'] as String? ?? '',
    name: j['name'] as String? ?? '',
    avatarUrl: j['avatarUrl'] as String? ?? '',
    presence: (j['presence'] as String?)?.isNotEmpty == true ? j['presence'] as String : 'offline',
    role: j['role'] as String? ?? 'member',
  );
}

/// Your seat in a lounge.
class LoungeSeat {
  const LoungeSeat({this.role = 'member', this.muted = false, this.timeoutUntil, this.canPostAt, this.links = true});
  final String role;
  final bool muted;
  final DateTime? timeoutUntil; // a moderator timed you out
  final DateTime? canPostAt; // new in Party: read-only until then
  final bool links; // your account is old enough to post links

  factory LoungeSeat.fromJson(Map<String, dynamic> j) => LoungeSeat(
    role: j['role'] as String? ?? 'member',
    muted: j['muted'] == true,
    timeoutUntil: _date(j['timeoutUntil']),
    canPostAt: _date(j['canPostAt']),
    links: j['links'] != false,
  );
}

/// One lounge as you see it: your seat (null without one), and with a seat, who's in it.
class LoungeDetail {
  const LoungeDetail({required this.lounge, this.me, this.banned = false, this.rank = 0, this.members = const []});
  final Lounge lounge;
  final LoungeSeat? me;
  final bool banned;

  /// What you may do here: 1 member, 2 moderator, 3 owner, 4 moderates every lounge.
  final int rank;
  final List<LoungeMember> members;

  bool get canModerate => rank >= 2;
  bool get isOwner => rank >= 3;

  factory LoungeDetail.fromJson(Map<String, dynamic> j) => LoungeDetail(
    lounge: Lounge.fromJson(j['lounge'] as Map<String, dynamic>),
    me: j['me'] is Map<String, dynamic> ? LoungeSeat.fromJson(j['me'] as Map<String, dynamic>) : null,
    banned: j['banned'] == true,
    rank: (j['rank'] as num?)?.toInt() ?? 0,
    members: [for (final m in ((j['members'] as List?) ?? const []).cast<Map<String, dynamic>>()) LoungeMember.fromJson(m)],
  );
}

class LoungeLogEntry {
  const LoungeLogEntry({required this.action, this.actor = '', this.target = '', this.detail = '', this.created});
  final String action;
  final String actor;
  final String target;
  final String detail;
  final DateTime? created;
}

/// Whether you can make a lounge, and if not, why.
class LoungeMaking {
  const LoungeMaking({this.can = false, this.why = '', this.at});
  final bool can;
  final String why;
  final DateTime? at; // when your account is old enough
}

/// Something that happened in the lounge you have open.
class LoungeEvent {
  const LoungeEvent(this.type, {this.message, this.id = '', this.lounge, this.banned = false, this.quiet = false});

  /// message, remove, members, lounge, you (your timeout changed), removed (you were taken out),
  /// deleted (the lounge is gone).
  final String type;
  final LoungeMessage? message;
  final String id; // the message removed
  final Lounge? lounge; // its new details
  final bool banned;

  /// removed: not by a moderator, but because you sent nothing for 24 hours.
  final bool quiet;
}

/// Someone replied to you: in a lounge or in your room's chat.
class ReplyNotice {
  const ReplyNotice({required this.kind, required this.placeId, required this.placeName, required this.message});
  final String kind; // lounge, room
  final String placeId;
  final String placeName;
  final LoungeMessage message;
}

typedef LoungeApi = Future<dynamic> Function(String path, {String method, Map<String, dynamic>? body, Map<String, dynamic>? query});
typedef LoungeListen = Future<UnsubscribeFunc> Function(String topic, void Function(Map<String, dynamic> data) onData);

/// Lounges for the signed-in account: the list (official ones, yours, whether you can make one),
/// replies to you, and everything you can do in one. The list refreshes every 30 s; the lounge
/// you have open is live ([live]).
class Lounges {
  static final official = ValueNotifier<List<Lounge>>(const []);
  static final mine = ValueNotifier<List<Lounge>>(const []);
  static final making = ValueNotifier<LoungeMaking>(const LoungeMaking());

  /// Replies to you you haven't read yet, all lounges together: part of the dot on the Party tab.
  static final replies = ValueNotifier<int>(0);

  /// Someone replied to you (in a lounge, or in your room's chat).
  static Stream<ReplyNotice> get notices => _notices.stream;
  static final _notices = StreamController<ReplyNotice>.broadcast();

  /// The lounge on screen: its replies don't count as unread.
  static String? openId;

  /// The server, and its live topics. Tests put made-up ones in.
  static LoungeApi api = _send;
  static LoungeListen listen = _listen;

  static String? _uid;
  static Timer? _poll;
  static UnsubscribeFunc? _replySub;

  static Future<dynamic> _send(String path, {String method = 'GET', Map<String, dynamic>? body, Map<String, dynamic>? query}) =>
      Account.pb.send(path, method: method, body: body ?? const {}, query: query ?? const {});

  static Future<UnsubscribeFunc> _listen(String topic, void Function(Map<String, dynamic>) onData) => Account.pb.realtime.subscribe(topic, (e) {
    try {
      final d = jsonDecode(e.data);
      if (d is Map<String, dynamic>) onData(d);
    } catch (_) {}
  });

  static void start() {
    Account.user.addListener(_userChanged);
    _userChanged();
  }

  static void _userChanged() {
    final u = Account.user.value;
    final id = u != null && u.termsAt != null ? u.id : null;
    if (id == _uid) return;
    _uid = id;
    _poll?.cancel();
    _replySub?.call().catchError((Object _) {});
    _replySub = null;
    official.value = const [];
    mine.value = const [];
    making.value = const LoungeMaking();
    replies.value = 0;
    if (id == null) return;
    refresh();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    listen('vyse_reply', _reply).then((u) {
      if (_uid == id) {
        _replySub = u;
      } else {
        u().catchError((Object _) {});
      }
    }, onError: (Object _) {});
  }

  static void _reply(Map<String, dynamic> d) {
    final kind = d['kind'] as String? ?? '';
    final place = (d[kind] as Map?)?.cast<String, dynamic>() ?? const {};
    final m = d['message'];
    if (m is! Map<String, dynamic>) return;
    final notice = ReplyNotice(kind: kind, placeId: place['id'] as String? ?? '', placeName: place['name'] as String? ?? '', message: LoungeMessage.fromJson(m));
    if (kind == 'lounge' && notice.placeId != openId) {
      mine.value = [for (final l in mine.value) l.id == notice.placeId ? l.copyWith(replies: l.replies + 1, unread: true) : l];
      _count();
    }
    _notices.add(notice);
  }

  static void _count() => replies.value = mine.value.fold(0, (n, l) => n + l.replies);

  static List<Lounge> _list(Object? v) => [for (final l in ((v as List?) ?? const []).cast<Map<String, dynamic>>()) Lounge.fromJson(l)];

  static void _take(Map<String, dynamic> j) {
    official.value = _list(j['official']);
    // the open one stays read
    mine.value = [for (final l in _list(j['mine'])) l.id == openId ? l.copyWith(unread: false, replies: 0) : l];
    final c = (j['create'] as Map?)?.cast<String, dynamic>() ?? const {};
    making.value = LoungeMaking(can: c['can'] == true, why: c['why'] as String? ?? '', at: _date(c['at']));
    _count();
  }

  /// The list again (official, yours, whether you can make one).
  static Future<void> refresh() async {
    if (_uid == null) return;
    try {
      _take(await api('/api/vyse/lounges') as Map<String, dynamic>);
    } catch (_) {}
  }

  /// Lounges people made: busiest first, or those matching [query] and [topic].
  static Future<List<Lounge>> browse({String query = '', String topic = ''}) async {
    final j = await api('/api/vyse/lounges', query: {if (query.trim().isNotEmpty) 'q': query.trim(), if (topic.isNotEmpty) 'topic': topic}) as Map<String, dynamic>;
    _take(j);
    return _list(j['browse']);
  }

  static Future<LoungeDetail> detail(String id) async => LoungeDetail.fromJson(await api('/api/vyse/lounges/$id') as Map<String, dynamic>);

  /// Messages newest first, 50 at a time; [before] is the `oldest` of the page before.
  static Future<({List<LoungeMessage> items, bool more, String oldest})> messages(String id, {String? before}) async {
    final j = await api('/api/vyse/lounges/$id/messages', query: {'before': ?before}) as Map<String, dynamic>;
    return (
      items: [for (final m in ((j['items'] as List?) ?? const []).cast<Map<String, dynamic>>()) LoungeMessage.fromJson(m)],
      more: j['more'] == true,
      oldest: j['oldest'] as String? ?? '',
    );
  }

  static Future<void> join(String id) async {
    await api('/api/vyse/lounges/$id/join', method: 'POST');
    await refresh();
  }

  static Future<void> leave(String id) async {
    await api('/api/vyse/lounges/$id/leave', method: 'POST');
    mine.value = [for (final l in mine.value) if (l.id != id) l];
    _count();
    unawaited(refresh());
  }

  /// You've read it up to now (also what keeps your seat).
  static Future<void> read(String id) async {
    if (mine.value.any((l) => l.id == id && (l.unread || l.replies > 0))) {
      mine.value = [for (final l in mine.value) l.id == id ? l.copyWith(unread: false, replies: 0) : l];
      _count();
    }
    try {
      await api('/api/vyse/lounges/$id/read', method: 'POST');
    } catch (_) {}
  }

  static Future<void> mute(String id, bool muted) async {
    await api('/api/vyse/lounges/$id/mute', method: 'POST', body: {'muted': muted});
    mine.value = [for (final l in mine.value) l.id == id ? l.copyWith(muted: muted) : l];
  }

  static Future<LoungeMessage> send(String id, String body, {String? replyTo}) async =>
      LoungeMessage.fromJson(await api('/api/vyse/lounges/$id/send', method: 'POST', body: {'body': body, 'replyTo': ?replyTo}) as Map<String, dynamic>);

  /// Your own message, or anyone's for a moderator.
  static Future<void> remove(String id, String message) => api('/api/vyse/lounges/$id/delete-message', method: 'POST', body: {'message': message});

  /// Moderators: brings back a message reports hid.
  static Future<void> restore(String id, String message) =>
      api('/api/vyse/lounges/$id/delete-message', method: 'POST', body: {'message': message, 'restore': true});

  /// Moderators: [minutes] times someone out (10, 60, 1440; 0 lifts it), or [kick], [ban], [unban].
  static Future<void> moderate(String id, String user, {int? minutes, bool kick = false, bool ban = false, bool unban = false}) => api(
    '/api/vyse/lounges/$id/moderate',
    method: 'POST',
    body: {'user': user, 'minutes': ?minutes, if (kick) 'kick': true, if (ban) 'ban': true, if (unban) 'unban': true},
  );

  static Future<List<LoungeMember>> bans(String id) async {
    final j = await api('/api/vyse/lounges/$id/bans') as Map<String, dynamic>;
    return [for (final m in ((j['items'] as List?) ?? const []).cast<Map<String, dynamic>>()) LoungeMember.fromJson(m)];
  }

  static Future<List<LoungeLogEntry>> log(String id) async {
    final j = await api('/api/vyse/lounges/$id/log') as Map<String, dynamic>;
    return [
      for (final e in ((j['items'] as List?) ?? const []).cast<Map<String, dynamic>>())
        LoungeLogEntry(
          action: e['action'] as String? ?? '',
          actor: e['actor'] as String? ?? '',
          target: e['target'] as String? ?? '',
          detail: e['detail'] as String? ?? '',
          created: _date(e['created']),
        ),
    ];
  }

  /// The owner: name, description, topic, slow (seconds), mod / unmod / owner (a user id).
  static Future<Lounge> manage(String id, Map<String, dynamic> body) async {
    final l = Lounge.fromJson(await api('/api/vyse/lounges/$id/manage', method: 'POST', body: body) as Map<String, dynamic>);
    unawaited(refresh());
    return l;
  }

  static Future<void> delete(String id) async {
    await api('/api/vyse/lounges/$id/delete', method: 'POST');
    mine.value = [for (final l in mine.value) if (l.id != id) l];
    _count();
    unawaited(refresh());
  }

  /// Makes a lounge with you as its owner.
  static Future<Lounge> make({required String name, String description = '', required String topic}) async {
    final l = Lounge.fromJson(await api('/api/vyse/lounges/create', method: 'POST', body: {'name': name, 'description': description, 'topic': topic}) as Map<String, dynamic>);
    await refresh();
    return l;
  }

  /// Live updates for the lounge you have open. Call the result to stop.
  static Future<UnsubscribeFunc> live(String id, void Function(LoungeEvent e) onEvent) => listen('vyse_lounge_$id', (d) {
    final type = d['type'] as String? ?? '';
    onEvent(
      LoungeEvent(
        type,
        message: d['message'] is Map<String, dynamic> ? LoungeMessage.fromJson(d['message'] as Map<String, dynamic>) : null,
        id: d['id'] as String? ?? '',
        lounge: d['detail'] is Map<String, dynamic> ? Lounge.fromJson(d['detail'] as Map<String, dynamic>) : null,
        banned: d['banned'] == true,
        quiet: d['quiet'] == true,
      ),
    );
  });
}
