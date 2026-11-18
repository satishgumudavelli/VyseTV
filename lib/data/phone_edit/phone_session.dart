import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../account/account.dart' show accountServer;
import '../app_settings.dart';
import '../net.dart';
import '../subtitles/subtitle_style.dart';
import 'phone_code.dart';
import 'phone_settings.dart';

/// Where a phone session stands, for the TV's screen.
enum PhoneLink {
  /// Making a code and telling the server about it.
  opening,

  /// The code is up; no phone has come yet.
  waiting,

  /// A phone is on the page.
  connected,

  /// The server stopped answering for a while (the session goes on when it answers again).
  lost,

  /// The session is over: closed, or unused for too long.
  ended,

  /// The server couldn't be reached to start one.
  unavailable,
}

/// The TV's side of Edit on your phone. It opens a session on the account server under a fresh
/// [PhoneCode], then asks about once a second: with the changes the phone has sent since, and
/// with its settings again whenever something changed. Both ways the server only carries sealed
/// boxes; this is plain HTTPS asking, so any network the TV can reach the internet from works.
///
/// The server side is `pb_hooks/phone_edit.pb.js` in the account server's repository.
class PhoneSession {
  PhoneSession({String? server, http.Client? client, Random? random})
    : server = server ?? accountServer,
      _client = client ?? netClient,
      _random = random ?? Random.secure();

  /// Tests make their sessions here (with a server of their own).
  @visibleForTesting
  static PhoneSession Function()? testFactory;

  /// A session the way the app makes one.
  static PhoneSession create() => testFactory?.call() ?? PhoneSession();

  /// Whether this build has a server to go through.
  static bool get available => testFactory != null || accountServer.isNotEmpty;

  final String server;
  final http.Client _client;
  final Random _random;

  final link = ValueNotifier<PhoneLink>(PhoneLink.opening);

  /// The last thing the phone changed, in words ("Text size: 32"), for the TV's screen.
  final lastChange = ValueNotifier<String?>(null);

  late PhoneCode code;
  late String _tv;
  int _after = 0;
  bool _dirty = false;
  bool _closed = false;
  bool _ticking = false;
  int _failures = 0;
  Timer? _timer;
  List<SubtitleFontChoice> _fonts = const [SubtitleStyle.defaultFont];
  List<PhoneSection> _sections = const [];
  Listenable? _watching;
  final _notes = <String, (PhoneNote, DateTime)>{};

  /// What the phone opens: the page, with the code after the #, which never reaches a server.
  String get pageUrl => '$server/phone/#${code.code}';

  /// The page without the code, for typing in by hand: `example.org/phone`.
  String get pageShort => '${Uri.parse(server).host}/phone';

  /// Makes a code and opens a session for it. When the server can't be reached, [link] says so
  /// and [start] can be called again.
  Future<void> start() async {
    _timer?.cancel();
    _closed = false;
    link.value = PhoneLink.opening;
    lastChange.value = null;
    try {
      _fonts = await SubtitleStyle.available();
    } catch (_) {}
    code = PhoneCode.random(_random);
    _tv = String.fromCharCodes([for (var i = 0; i < 40; i++) PhoneCode.alphabet.codeUnitAt(_random.nextInt(PhoneCode.alphabet.length))]);
    _after = 0;
    _notes.clear();
    try {
      await _post('open', {'id': code.id, 'tv': _tv, 'state': _sealState()});
    } catch (_) {
      if (!_closed) link.value = PhoneLink.unavailable;
      return;
    }
    if (_closed) return;
    link.value = PhoneLink.waiting;
    _failures = 0;
    _schedule(const Duration(seconds: 1));
  }

  /// Ends the session (the server forgets it at once) and stops asking.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _unwatch();
    if (link.value == PhoneLink.opening || link.value == PhoneLink.unavailable || link.value == PhoneLink.ended) return;
    try {
      await _post('close', {'id': code.id, 'tv': _tv});
    } catch (_) {}
  }

  void _schedule(Duration after) {
    _timer?.cancel();
    if (!_closed) _timer = Timer(after, _tick);
  }

  Future<void> _tick() async {
    if (_closed || _ticking) return;
    _ticking = true;
    try {
      await _ask();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _ask() async {
    final sendState = _dirty;
    _dirty = false;
    Map<String, Object?> r;
    try {
      r = await _post('tv', {'id': code.id, 'tv': _tv, 'after': _after, if (sendState) 'state': _sealState()});
    } on _Gone {
      _unwatch();
      if (!_closed) link.value = PhoneLink.ended;
      return;
    } on _Busy {
      _dirty |= sendState;
      _schedule(const Duration(seconds: 5));
      return;
    } catch (_) {
      _dirty |= sendState;
      if (++_failures >= 4 && !_closed) link.value = PhoneLink.lost;
      _schedule(Duration(seconds: _failures < 4 ? 1 : 3));
      return;
    }
    if (_closed) return;
    _failures = 0;
    final changes = r['changes'];
    if (changes is List) {
      for (final c in changes) {
        if (c is! Map) continue;
        final seq = c['seq'];
        if (seq is! int || seq <= _after) continue;
        _after = seq;
        _dirty = true; // the phone hears back about everything it sent, even what didn't change
        Object? change;
        try {
          change = code.open('change', '${c['box']}');
        } catch (_) {
          continue; // not sealed with this code's key: not from the phone
        }
        if (change is Map<String, Object?>) await _take(change);
        if (_closed) return;
      }
    }
    final phoneMs = r['phoneMs'];
    link.value = phoneMs is int && phoneMs >= 0 && phoneMs < 15000 ? PhoneLink.connected : PhoneLink.waiting;
    _schedule(Duration(milliseconds: _dirty ? 250 : 1000));
  }

  Future<void> _take(Map<String, Object?> change) async {
    final id = change['id'];
    if (id is! String) return;
    final item = _sections.expand((s) => s.items).where((i) => i.id == id).firstOrNull;
    if (item == null) return;
    PhoneTook? took;
    try {
      took = await item.take(change);
    } catch (_) {
      took = const PhoneTook(null, PhoneNote("The TV couldn't do that.", bad: true));
    }
    if (took == null) return;
    if (took.what != null) lastChange.value = took.what;
    final note = took.note;
    note == null ? _notes.remove(id) : _notes[id] = (note, DateTime.now());
  }

  /// The settings as they are now, sealed for the phone. Also (re)starts listening to them.
  String _sealState() {
    _sections = phoneSections(fonts: _fonts);
    _watch([for (final s in _sections) for (final i in s.items) ...i.watched]);
    final now = DateTime.now();
    _notes.removeWhere((_, n) => now.difference(n.$2) > const Duration(minutes: 2));
    final state = {
      'v': 1,
      'device': 'your TV',
      'accent': cssColor(AppSettings.theme.color.toARGB32()),
      'sections': [for (final s in _sections) s.toJson()],
      'notes': {for (final e in _notes.entries) e.key: e.value.$1.toJson()},
    };
    return code.seal('state', state, _random);
  }

  void _watch(List<Listenable> all) {
    _unwatch();
    final l = Listenable.merge(all);
    l.addListener(_changed);
    _watching = l;
  }

  void _unwatch() {
    _watching?.removeListener(_changed);
    _watching = null;
  }

  void _changed() {
    if (_closed || _dirty) return;
    _dirty = true;
    // a change made on the TV goes out soon, not a whole second later (an ask under way sends it
    // when it is back)
    if (!_ticking && (link.value == PhoneLink.connected || link.value == PhoneLink.waiting)) _schedule(const Duration(milliseconds: 300));
  }

  Future<Map<String, Object?>> _post(String path, Map<String, Object?> body) async {
    final r = await _client
        .post(Uri.parse('$server/api/vyse/phone/$path'), headers: const {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 404 || r.statusCode == 403) throw _Gone();
    if (r.statusCode == 429) throw _Busy();
    if (r.statusCode != 200) throw http.ClientException('HTTP ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    return j is Map<String, Object?> ? j : const {};
  }
}

class _Gone implements Exception {}

class _Busy implements Exception {}
