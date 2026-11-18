// The account server's side of Edit on your phone, kept in memory: the same five routes and the
// same rules as pb_hooks/phone_edit.pb.js, so the TV's session can be tested against it, and a
// stand-in phone that does what the phone page does.
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vyse_tv/data/phone_edit/phone_code.dart';

class _Session {
  _Session(this.tvHash, this.state);
  final String tvHash;
  String state;
  int rev = 1;
  final changes = <Map<String, Object?>>[];
  int seq = 0;
  int acked = 0;
  DateTime? phoneSeen;
  bool get phoneHere => phoneSeen != null;
}

class FakeRelay {
  final sessions = <String, _Session>{};

  /// Off: every request fails the way an unreachable server does.
  bool up = true;

  /// Every route asked, oldest first.
  final asked = <String>[];

  http.Client get client => MockClient(_handle);

  static String _hash(String s) => sha256.convert(utf8.encode(s)).toString();

  Future<http.Response> _handle(http.Request r) async {
    if (!up) throw http.ClientException('no route to host');
    final route = r.url.pathSegments.last;
    asked.add(route);
    final b = jsonDecode(r.body) as Map<String, dynamic>;
    http.Response json(int status, Object body) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
    final s = sessions[b['id']];
    switch (route) {
      case 'open':
        if (s != null) return json(409, {'message': 'That code is taken. Make a new one.'});
        sessions[b['id'] as String] = _Session(_hash(b['tv'] as String), b['state'] as String);
        return json(200, {'ok': true});
      case 'tv':
        if (s == null) return json(404, {'gone': true});
        if (s.tvHash != _hash('${b['tv']}')) return json(403, {'message': 'This session belongs to another TV.'});
        final after = (b['after'] as num).toInt();
        s.changes.removeWhere((c) => (c['seq'] as int) <= after);
        s.acked = after > s.acked ? (after < s.seq ? after : s.seq) : s.acked;
        if (b['state'] != null) {
          s.state = b['state'] as String;
          s.rev++;
        }
        return json(200, {'changes': s.changes, 'phoneMs': s.phoneHere ? 100 : -1});
      case 'phone':
        if (s == null) return json(404, {'gone': true});
        s.phoneSeen = DateTime.now();
        final known = (b['rev'] as num).toInt();
        return json(200, {'rev': s.rev, 'state': s.rev != known ? s.state : null, 'seq': s.seq, 'acked': s.acked, 'tvMs': 100});
      case 'change':
        if (s == null) return json(404, {'gone': true});
        if (s.changes.length >= 32) return json(429, {'message': "The TV hasn't caught up yet. Wait a moment."});
        s.changes.add({'seq': ++s.seq, 'box': b['box']});
        s.phoneSeen = DateTime.now();
        return json(200, {'seq': s.seq});
      case 'close':
        if (s != null && s.tvHash == _hash('${b['tv']}')) sessions.remove(b['id']);
        return json(200, {'ok': true});
    }
    return json(404, {});
  }
}

/// What the phone page does, from a code: ask for the TV's settings, send changes.
class FakePhone {
  FakePhone(this.relay, String code) : key = PhoneCode.of(code);
  final FakeRelay relay;
  final PhoneCode key;
  int rev = 0;
  int acked = 0;
  Map<String, dynamic>? state;

  /// False when the session is gone.
  Future<bool> poll() async {
    final r = await relay.client.post(Uri.parse('https://relay.test/api/vyse/phone/phone'), body: jsonEncode({'id': key.id, 'rev': rev}));
    if (r.statusCode == 404) return false;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    acked = j['acked'] as int;
    if (j['state'] != null) {
      state = key.open('state', j['state'] as String) as Map<String, dynamic>;
      rev = j['rev'] as int;
    }
    return true;
  }

  Future<int> send(Map<String, Object?> change) async {
    final r = await relay.client.post(Uri.parse('https://relay.test/api/vyse/phone/change'), body: jsonEncode({'id': key.id, 'box': key.seal('change', change)}));
    return (jsonDecode(r.body) as Map<String, dynamic>)['seq'] as int;
  }

  /// A setting as the TV last described it.
  Map<String, dynamic> item(String id) =>
      (state!['sections'] as List).expand((s) => (s as Map<String, dynamic>)['items'] as List).cast<Map<String, dynamic>>().firstWhere((i) => i['id'] == id);
}
