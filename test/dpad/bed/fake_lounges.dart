// A made-up lounge server for the bed: what /api/vyse/lounges/* would answer, kept in memory, and
// the lounge's live topic as a callback a test can push events into. Signed in as the bed's
// made-up user (bed/phase9_pages.dart, id "me").
import 'package:vyse_tv/data/party/lounges.dart';

String _at(int minute) => DateTime(2026, 11, 20, 20, minute).toUtc().toIso8601String();

class FakeLounges {
  FakeLounges() {
    _add('general', 'General', 'talk', 'Say hi. Anything goes, within the Party rules.', official: true, limit: 50, size: 31, here: 9, seat: 'member');
    _add('anime', 'Anime', 'anime', 'Seasonals, classics and everything in between.', official: true, limit: 50, size: 50, here: 12);
    _add('films', 'Films & Series', 'films', "What you're watching, what to watch next.", official: true, limit: 50, size: 12, here: 2);
    _add('horror', 'Horror club', 'films', 'Scary films, old and new. Spoilers in replies only.', size: 7, here: 3, seat: 'owner');
    _add('lofi', 'Lo-fi corner', 'music', 'Beats to study to.', size: 30, here: 4);
    _add('jrpg', 'JRPG nights', 'games', 'Long games, longer talks.', size: 4, here: 0);
    messages['general'] = [
      _m('g1', 'u1', 'Mara Ellison', 'Anyone else watching Severance this week?', 1),
      _m('g2', 'me', 'Ayla Brandt', 'Yes, the last episode was something else', 2),
      _m('g3', 'u2', 'Tobias Reed', 'No spoilers please, I am one behind', 3),
      _m('g4', 'u1', 'Mara Ellison', 'Same, it keeps getting better', 4, reply: {'id': 'g2', 'user': 'me', 'name': 'Ayla Brandt', 'body': 'Yes, the last episode was something else'}),
      _m('g5', 'u3', 'Ines Calder', 'What should I start next? Something short.', 5),
      _m('g6', 'u2', 'Tobias Reed', 'Try Station Eleven, ten episodes', 6, reply: {'id': 'g5', 'user': 'u3', 'name': 'Ines Calder', 'body': 'What should I start next? Something short.'}),
    ];
    messages['horror'] = [_m('h1', 'u4', 'Kofi Mensah', 'Rewatching The Thing tonight', 1)];
  }

  final lounges = <String, Map<String, dynamic>>{};
  final seats = <String, String>{}; // lounge → your role
  final messages = <String, List<Map<String, dynamic>>>{};
  final sent = <Map<String, dynamic>>[]; // every body sent, as asked
  final calls = <String>[];

  /// The open lounge's live topic.
  void Function(Map<String, dynamic>)? live;

  void _add(String id, String name, String topic, String about, {bool official = false, int limit = 30, int size = 0, int here = 0, String? seat}) {
    lounges[id] = {
      'id': id,
      'name': name,
      'topic': topic,
      'description': about,
      'official': official,
      'owner': seat == 'owner' ? 'me' : (official ? '' : 'u5'),
      'limit': limit,
      'size': size,
      'slow': 3,
      'here': here,
      'lastAt': _at(6),
    };
    if (seat != null) seats[id] = seat;
  }

  Map<String, dynamic> _m(String id, String user, String name, String body, int minute, {Map<String, dynamic>? reply}) =>
      {'id': id, 'user': user, 'name': name, 'avatarUrl': '', 'body': body, 'reply': reply, 'hidden': false, 'created': _at(minute)};

  Map<String, dynamic> _mine(String id) => {...lounges[id]!, 'role': seats[id], 'muted': false, 'unread': id == 'general', 'replies': id == 'general' ? 1 : 0};

  /// The notifiers the Party page reads, filled as the server's list would fill them.
  void fill() {
    Lounges.official.value = [for (final l in lounges.values) if (l['official'] == true) Lounge.fromJson(seats.containsKey(l['id']) ? _mine(l['id'] as String) : l)];
    Lounges.mine.value = [for (final id in seats.keys) Lounge.fromJson(_mine(id))];
    Lounges.making.value = const LoungeMaking(can: true);
  }

  Future<dynamic> api(String path, {String method = 'GET', Map<String, dynamic>? body, Map<String, dynamic>? query}) async {
    calls.add('$method $path');
    final parts = path.replaceFirst('/api/vyse/lounges', '').split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) {
      return {
        'official': [for (final l in lounges.values) if (l['official'] == true) l],
        'mine': [for (final id in seats.keys) _mine(id)],
        'browse': [for (final l in lounges.values) if (l['official'] != true) l],
        'create': {'can': true, 'why': ''},
      };
    }
    final id = parts[0];
    final l = lounges[id]!;
    final what = parts.length > 1 ? parts[1] : '';
    switch (what) {
      case '':
        final role = seats[id];
        return {
          'lounge': l,
          'me': role == null ? null : {'role': role, 'muted': false, 'timeoutUntil': '', 'canPostAt': '2026-01-01T00:00:00.000Z', 'links': true},
          'banned': false,
          'rank': switch (role) {
            'owner' => 3,
            'mod' => 2,
            null => 0,
            _ => 1,
          },
          'members': role == null
              ? []
              : [
                  {'id': 'me', 'name': 'Ayla Brandt', 'username': 'ayla', 'presence': 'online', 'role': role},
                  for (var i = 1; i <= 5; i++)
                    {'id': 'u$i', 'name': const ['', 'Mara Ellison', 'Tobias Reed', 'Ines Calder', 'Kofi Mensah', 'Lena Roth'][i], 'username': 'p$i', 'presence': i < 4 ? 'online' : 'offline', 'role': i == 1 ? 'mod' : 'member'},
                ],
        };
      case 'messages':
        return {'items': (messages[id] ?? const []).reversed.toList(), 'more': false, 'oldest': ''};
      case 'join':
        seats[id] = 'member';
        l['size'] = (l['size'] as int) + 1;
        return {'ok': true};
      case 'leave':
        seats.remove(id);
        l['size'] = (l['size'] as int) - 1;
        return {'ok': true};
      case 'read' || 'mute':
        return {'ok': true};
      case 'send':
        sent.add({...?body});
        final to = body?['replyTo'] as String?;
        final orig = to == null ? null : (messages[id] ?? const []).where((m) => m['id'] == to).firstOrNull;
        final m = _m(
          'n${sent.length}',
          'me',
          'Ayla Brandt',
          body?['body'] as String? ?? '',
          30 + sent.length,
          reply: orig == null ? null : {'id': orig['id'], 'user': orig['user'], 'name': orig['name'], 'body': orig['body']},
        );
        (messages[id] ??= []).add(m);
        return m;
    }
    return {'ok': true};
  }

  Future<Future<void> Function()> listen(String topic, void Function(Map<String, dynamic>) onData) async {
    live = onData;
    return () async => live = null;
  }

  /// Puts this made-up server in place of the real one.
  void install() {
    _real ??= Lounges.api;
    _realListen ??= Lounges.listen;
    Lounges.api = api;
    Lounges.listen = listen;
    fill();
  }

  static void uninstall() {
    if (_real != null) Lounges.api = _real!;
    if (_realListen != null) Lounges.listen = _realListen!;
    Lounges.official.value = const [];
    Lounges.mine.value = const [];
    Lounges.making.value = const LoungeMaking();
    Lounges.openId = null;
  }

  static LoungeApi? _real;
  static LoungeListen? _realListen;
}
