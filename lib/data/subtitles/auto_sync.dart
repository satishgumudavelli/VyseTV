// Automatic subtitle sync. A downloaded subtitle file is often off for the video it plays with:
// it was timed for another release, which may start a few seconds earlier or later, run at
// another frame rate (25 against 23.976), or have a scene more or fewer. Most video files carry
// subtitles of their own, timed for that very file, and their timing is the reference: read
// from the file's index for the whole film at once (mkv_subtitle_index.dart), or heard line by
// line as the film plays (mpv keeps the video's own track on, hidden: [AutoSync]).
//
// [fitSubtitles] works out where the file's lines belong: a [SyncMap], which gives each part of
// the film a speed and a shift. Only the timing is compared (when people speak), so the two may
// be in different languages.
//
// How: a line of the video and a line of the file "start together" when they begin within
// 0.3 s of each other once the file is moved. For each speed, the shifts where many starts
// line up are found from the differences between nearby starts, and the one where the most
// lines start together wins. It is only used when it is clear: the speech lines up there (time
// spoken in both, over time spoken in either), far more lines start together there than at any
// other shift, and each part of what was heard agrees. A part of the film where another shift
// fits clearly better (a scene the file doesn't have, or has extra) gets its own. Over a long
// enough stretch, the lines that start together also give the exact speed, so a file that
// slowly slides off stays in time.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// A stretch of a film: start and end, in seconds.
typedef Span = (double, double);

enum AutoSyncKind {
  /// Not enough heard yet.
  wait,

  /// The file fits: [AutoSyncVerdict.map] says where its lines belong.
  fits,

  /// Heard plenty (or all of it) and nothing is clear: nothing should change.
  unclear,
}

/// Where a subtitle file's lines belong in the film, part by part: from a part's start until
/// the next one, a line of the file at c belongs at c × speed + shift.
class SyncMap {
  const SyncMap(this.parts);

  /// (from, speed, shift), sorted by from. The first part also covers what comes before it.
  final List<(double, double, double)> parts;

  (double, double) _at(double t) {
    var p = parts.first;
    for (final q in parts) {
      if (q.$1 > t) break;
      p = q;
    }
    return (p.$2, p.$3);
  }

  /// What the file is to be delayed by while the film is at [t] (a player's subtitle delay):
  /// the line showing then is the file's at c, with c × speed + shift = t.
  double delayAt(double t) {
    final (speed, shift) = _at(t);
    return t - (t - shift) / speed;
  }

  /// One shift for the whole film, at the file's own speed.
  bool get simple => parts.length == 1 && parts.first.$2 == 1;

  @override
  String toString() => [
    for (final p in parts)
      '${p.$1 > -1e8 ? 'from ${p.$1.round()}s ' : ''}${p.$2 == 1 ? '' : '${p.$2.toStringAsFixed(5)}x '}${p.$3 >= 0 ? '+' : ''}${p.$3.toStringAsFixed(2)}s',
  ].join(', ');
}

class AutoSyncVerdict {
  const AutoSyncVerdict(this.kind, {this.map, this.why = ''});
  final AutoSyncKind kind;
  final SyncMap? map;

  /// What was measured, for the subtitle log.
  final String why;
}

/// Lines heard before a verdict is tried, and seconds of the film they came from.
const minLines = 25;
const minKnown = 120.0;

/// How far off a file may be, either way, in seconds.
const reach = 180.0;

/// Within how many seconds two lines count as starting together.
const _together = .3;

/// Frame-rate mix-ups a release may have: 25 fps against 23.976, then (seen only over a long
/// stretch) 24 against 23.976 and 25 against 24.
const _speeds = [25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25 / 24, 24 / 25];

/// Over how much of the film the slow frame-rate mix-ups are looked for too (24 against
/// 23.976, 25 against 24): a few minutes show only 25 against 23.976.
const _long = 1200.0;

/// Where [file]'s lines belong, judged by the video's own lines [video] (film seconds), which
/// are all known within [known] (the stretches played, or the whole film). [whole]: the
/// reference is complete (the file's index), so there is nothing to wait for.
///
/// Releases differ by more than one shift: a frame or a few at each reel change, a scene cut
/// shorter or longer. So the film is looked at a stretch at a time (40 lines; quarters of a
/// short one), each stretch's own shift is found, and stretches that agree make a part. It
/// only fits when the stretches tell a story that holds together.
AutoSyncVerdict fitSubtitles(List<Span> video, List<Span> file, List<Span> known, {bool whole = false}) {
  final no = whole ? AutoSyncKind.unclear : AutoSyncKind.wait;
  final w = _union(known);
  final f = _Fitter(video, file, w);
  final n = f.rs.length;
  final heard = '$n lines over ${_length(w).round()}s';
  if (n < minLines || _length(w) < minKnown || f.fs.isEmpty) return AutoSyncVerdict(no, why: '$heard: too few');

  // the speed: the one where the most lines start together (a frame-rate mix-up shows as many
  // more, at another speed)
  final long = _length(w) > _long;
  final mid = f.rs[n ~/ 2];
  var top = f.best(1, 0, n, -reach, reach);
  for (final s in long ? _speeds : _speeds.take(2)) {
    final c = mid * (1 - s);
    final b = f.best(s, 0, n, c - reach, c + reach);
    if (b.count >= top.count * 1.15 + 3) top = b;
  }
  final speed = top.speed;

  // the stretches, each fitted on its own
  final size = n >= 160 ? 40 : math.max(12, (n / 4).ceil());
  final stretches = <(int, int)>[];
  for (var a = 0; a < n; a += size) {
    final b = math.min(n, a + size);
    if (b - a < 8 && stretches.isNotEmpty) {
      stretches.last = (stretches.last.$1, b);
    } else {
      stretches.add((a, b));
    }
  }
  final looks = [for (final (a, b) in stretches) f.best(speed, a, b, top.shift - reach, top.shift + reach)];
  final clear = [
    for (var k = 0; k < stretches.length; k++)
      looks[k].clear(stretches[k].$2 - stretches[k].$1, f.filesIn(speed, looks[k].shift, f.rs[stretches[k].$1], f.rs[stretches[k].$2 - 1] + 1)),
  ];
  var why = '$heard: ${speed == 1 ? '' : 'speed ${speed.toStringAsFixed(4)}, '}${clear.where((c) => c).length} of ${stretches.length} stretches clear';

  // parts: clear stretches within 0.3 s of the first of them run together; a stretch that
  // isn't clear goes along with the part it is in
  var parts = <(int, int, double, int)>[]; // lines [a, b), shift, clear stretches in it
  for (var k = 0; k < stretches.length; k++) {
    final (a, b) = stretches[k];
    if (clear[k] && (parts.isEmpty || (looks[k].shift - parts.last.$3).abs() > .3)) {
      parts.add((parts.isEmpty ? 0 : a, b, looks[k].shift, 1));
    } else if (parts.isNotEmpty) {
      parts.last = (parts.last.$1, b, parts.last.$3, parts.last.$4 + (clear[k] ? 1 : 0));
    }
  }
  if (parts.isEmpty) return AutoSyncVerdict(no, why: why);
  // a lone stretch far off from the parts on both sides, which agree: a fluke
  for (var k = 1; k + 1 < parts.length; k++) {
    final (_, _, shift, clears) = parts[k];
    if (clears == 1 && (parts[k - 1].$3 - parts[k + 1].$3).abs() <= .3 && (shift - parts[k - 1].$3).abs() > 1) {
      parts[k - 1] = (parts[k - 1].$1, parts[k + 1].$2, parts[k - 1].$3, parts[k - 1].$4 + parts[k + 1].$4);
      parts = [...parts.take(k), ...parts.skip(k + 2)];
      k--;
    }
  }
  final shifts = [for (final (a, b, shift, _) in parts) f.centre(speed, shift, a, b)];

  // each stretch must agree with its part (the whole of a short one: like each half agreeing).
  // In a long one, a stretch the file has next to no lines for (a file for part of the film,
  // a scene it leaves out) has nothing to say either way.
  var agree = 0, said = 0;
  for (var k = 0; k < stretches.length; k++) {
    final (a, b) = stretches[k];
    final p = parts.lastIndexWhere((p) => p.$1 <= a);
    final shift = shifts[p < 0 ? 0 : p];
    if (long && f.filesIn(speed, shift, f.rs[a], f.rs[b - 1] + 1) < (b - a) * .3) continue;
    said++;
    final here = f.best(speed, a, b, shift - 3, shift + 3);
    if ((here.shift - shift).abs() <= .3 && f.count(speed, shift, a, b) >= (b - a) * .3) agree++;
  }
  why = '$why, $agree of $said agree with their part';
  if (said < (long ? 3 : stretches.length) || agree < said * (long ? .6 : 1)) return AutoSyncVerdict(no, why: why);

  // where one part ends and the next begins: between the last line that fits the one and the
  // first that fits the other
  final map = <(double, double, double)>[(-1e9, speed, shifts.first)];
  for (var k = 1; k < parts.length; k++) {
    final lo = parts[k - 1].$1, hi = parts[k].$2;
    var split = parts[k].$1, best = -1;
    for (var i = lo + 1; i < hi; i++) {
      final score = f.count(speed, shifts[k - 1], lo, i) + f.count(speed, shifts[k], i, hi);
      if (score > best) (split, best) = (i, score);
    }
    map.add(((f.rs[split - 1] + f.rs[split]) / 2, speed, shifts[k]));
  }
  final result = SyncMap(map);
  var together = 0;
  for (var i = 0; i < n; i++) {
    final (s, d) = result._at(f.rs[i]);
    if (f.count(s, d, i, i + 1) > 0) together++;
  }
  final speech = f.overlap(result);
  why = '$why → $result, ${(together / n * 100).round()}% of lines start together, speech ${speech.toStringAsFixed(2)}';
  // (over a long stretch the parts agreeing say more than the speech, which a file for part of
  // the film leaves short)
  if (together < n * .35 || speech < (long ? .35 : .45)) return AutoSyncVerdict(no, why: why);
  return AutoSyncVerdict(AutoSyncKind.fits, map: result, why: why);
}

/// [fitSubtitles] away from the screen's thread: a whole film's lines take a moment on a TV.
Future<AutoSyncVerdict> fitInBackground(List<Span> video, List<Span> file, List<Span> known, {bool whole = false}) =>
    Isolate.run(() => fitSubtitles(video, file, known, whole: whole));

/// The best shift at one speed: [count] lines start together there, [elsewhere] at the best
/// other shift more than 1.5 s away.
class _Fit {
  const _Fit(this.speed, this.shift, this.count, this.elsewhere);
  final double speed;
  final double shift;
  final int count;
  final int elsewhere;

  /// Most of the lines start together, and nowhere else comes close. [videos]: lines of the
  /// video looked at; [files]: the file's lines that land among them.
  bool clear(int videos, int files) => count >= 8 && count >= math.max(videos, files) * .4 && elsewhere <= count * .6;

  @override
  String toString() =>
      '${speed == 1 ? '' : '${speed.toStringAsFixed(4)}x '}${shift >= 0 ? '+' : ''}${shift.toStringAsFixed(2)}s ($count start together, $elsewhere elsewhere)';
}

class _Fitter {
  _Fitter(List<Span> video, List<Span> file, this.known) {
    final v = [for (final l in video) if (l.$2 > l.$1 && _inside(known, l.$1)) l]..sort((a, b) => a.$1.compareTo(b.$1));
    rs = Float64List.fromList([for (final l in v) l.$1]);
    speech = _clip(_union(v), known);
    final f = [for (final l in file) if (l.$2 > l.$1) l]..sort((a, b) => a.$1.compareTo(b.$1));
    fs = Float64List.fromList([for (final l in f) l.$1]);
    fileSpeech = _union(f);
  }

  final List<Span> known;
  late final Float64List rs; // where the video's lines start
  late final List<Span> speech; // the video's speech
  late final Float64List fs; // where the file's lines start
  late final List<Span> fileSpeech;

  /// How many of [a] are below [x].
  static int _below(Float64List a, double x) {
    var lo = 0, hi = a.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (a[m] < x) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    return lo;
  }

  /// The file's line nearest to starting with the video's line [i], moved by [d] after [s]:
  /// its index, and how far off it is (video minus file).
  (int, double) _nearest(double s, double d, int i) {
    final r = rs[i];
    final j = _below(fs, (r - d) / s);
    var k = -1, off = double.infinity;
    for (final c in [j - 1, j]) {
      if (c >= 0 && c < fs.length) {
        final e = r - (fs[c] * s + d);
        if (e.abs() < off.abs()) (k, off) = (c, e);
      }
    }
    return (k, off);
  }

  /// How many of the video's lines [a, b) start together with one of the file's, moved by [d]
  /// after [s].
  int count(double s, double d, int a, int b) {
    var n = 0;
    for (var i = a; i < b; i++) {
      final r = rs[i];
      final j = _below(fs, (r - _together - d) / s);
      if (j < fs.length && fs[j] * s + d <= r + _together) n++;
    }
    return n;
  }

  /// The file's lines that start, moved, among what is known (between [t0] and [t1]).
  int filesIn(double s, double d, [double t0 = -1e9, double t1 = 1e9]) {
    var n = 0;
    for (final w in known) {
      final a = math.max(w.$1, t0), b = math.min(w.$2, t1);
      if (b > a) n += _below(fs, (b - d) / s) - _below(fs, (a - d) / s);
    }
    return n;
  }

  /// The best shift for lines [a, b) at speed [s], between [lo] and [hi].
  _Fit best(double s, int a, int b, double lo, double hi) {
    // how far apart nearby starts are, in 0.1 s steps, smoothed over 0.3 s
    const bin = .1;
    final size = ((hi - lo) / bin).ceil() + 1;
    final h = Float64List(size);
    for (var i = a; i < b; i++) {
      final r = rs[i];
      for (var j = _below(fs, (r - hi) / s); j < fs.length; j++) {
        final d = r - fs[j] * s;
        if (d < lo) break;
        h[((d - lo) / bin).round()] += 1;
      }
    }
    final sm = Float64List(size);
    for (var k = 0; k < size; k++) {
      var t = 0.0;
      for (var q = -3; q <= 3; q++) {
        final x = k + q;
        if (x >= 0 && x < size) t += h[x] * (4 - q.abs());
      }
      sm[k] = t;
    }
    // the twelve highest places, a second apart at least, each looked at closely
    final order = [for (var k = 0; k < size; k++) if (sm[k] > 0) k]..sort((x, y) => sm[y].compareTo(sm[x]));
    final picked = <int>[];
    for (final k in order) {
      if (picked.every((p) => (p - k).abs() >= 10)) picked.add(k);
      if (picked.length == 12) break;
    }
    var top = _Fit(s, 0, 0, 0);
    final found = <(double, int)>[];
    for (final k in picked) {
      // (lines that start within 0.3 s count the same over a stretch of shifts: its middle)
      final counts = [for (var q = -3; q <= 3; q++) count(s, lo + (k + q) * bin, a, b)];
      final m0 = counts.reduce(math.max);
      final at = [for (var q = 0; q < 7; q++) if (counts[q] == m0) q];
      var d = lo + (k - 3 + at[at.length ~/ 2]) * bin;
      d = centre(s, d, a, b);
      final m = count(s, d, a, b);
      found.add((d, m));
      if (m > top.count) top = _Fit(s, d, m, 0);
    }
    var elsewhere = 0;
    for (final (d, m) in found) {
      if ((d - top.shift).abs() > 1.5 && m > elsewhere) elsewhere = m;
    }
    return _Fit(s, top.shift, top.count, elsewhere);
  }

  /// [d] moved to the middle of how far off the lines that start together are.
  double centre(double s, double d, int a, int b) {
    final off = <double>[];
    for (var i = a; i < b; i++) {
      final (_, e) = _nearest(s, d, i);
      if (e.abs() <= _together + .05) off.add(e);
    }
    if (off.isEmpty) return d;
    off.sort();
    return d + off[off.length ~/ 2];
  }

  /// Speech that lines up, over all the speech, inside what is known: the video's against the
  /// file's, placed by [m] part by part.
  double overlap(SyncMap m) {
    var inter = 0.0, union = 0.0;
    for (var k = 0; k < m.parts.length; k++) {
      final (from, s, d) = m.parts[k];
      final part = _clip(known, [(k == 0 ? -1e9 : from, k + 1 < m.parts.length ? m.parts[k + 1].$1 : 1e9)]);
      final moved = _clip(_union([for (final l in fileSpeech) (l.$1 * s + d, l.$2 * s + d)]), part);
      final mine = _clip(speech, part);
      final both = _length(_clip(mine, moved));
      inter += both;
      union += _length(mine) + _length(moved) - both;
    }
    return union <= 0 ? 0 : inter / union;
  }
}

/// Collects the video's own lines as the film plays (mpv's hidden second track) and the
/// stretches of the film played, for [fitSubtitles].
class AutoSync {
  /// [file]: the downloaded file's lines, in its own seconds.
  AutoSync(Iterable<Span> file) : file = [for (final s in file) if (s.$2 > s.$1) s];

  /// With this many lines heard and nothing clear, it gives up.
  static const maxLines = 220;

  final List<Span> file;
  final _heard = <double, double>{}; // the video's own lines: start -> end
  final _played = <Span>[];
  Span? _now; // the stretch playing now

  /// Lines of the video's own track heard so far.
  int get lineCount => _heard.length;

  /// Seconds of the film played while listening.
  double get playedSeconds => _length(played);

  /// The stretches of the film played.
  List<Span> get played => _union([..._played, ?_now].where((s) => s.$2 > s.$1));

  /// The video's lines heard, in film seconds.
  List<Span> get heard => [for (final e in _heard.entries) (e.key, e.value)];

  /// A line of the video's own track, in seconds of the film.
  void line(double start, double end) {
    if (end > start) _heard[(start * 1000).roundToDouble() / 1000] = end;
  }

  /// Where the film is now: a steady clock grows the stretch being played, a jump (a seek)
  /// starts another.
  void position(double at) {
    final n = _now;
    if (n != null && at >= n.$1 && at <= n.$2 + 3) {
      if (at > n.$2) _now = (n.$1, at);
      return;
    }
    if (n != null && n.$2 > n.$1) _played.add(n);
    _now = (at, at);
  }

  /// Where the file fits, from what was heard so far. After [maxLines] lines with nothing
  /// clear, it says so.
  AutoSyncVerdict verdict() {
    final v = fitSubtitles(heard, file, played);
    if (v.kind == AutoSyncKind.wait && _heard.length >= maxLines) return AutoSyncVerdict(AutoSyncKind.unclear, why: v.why);
    return v;
  }
}

bool _inside(List<Span> w, double t) => w.any((s) => t >= s.$1 && t < s.$2);

double _length(List<Span> spans) => spans.fold(0.0, (sum, s) => sum + s.$2 - s.$1);

/// [spans] sorted, with the ones that overlap joined.
List<Span> _union(Iterable<Span> spans) {
  final sorted = [for (final s in spans) if (s.$2 > s.$1) s]..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <Span>[];
  for (final s in sorted) {
    if (out.isNotEmpty && s.$1 <= out.last.$2) {
      if (s.$2 > out.last.$2) out[out.length - 1] = (out.last.$1, s.$2);
    } else {
      out.add(s);
    }
  }
  return out;
}

/// The parts of [a] inside [b] (both sorted, none overlapping).
List<Span> _clip(List<Span> a, List<Span> b) {
  final out = <Span>[];
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    final s = math.max(a[i].$1, b[j].$1), e = math.min(a[i].$2, b[j].$2);
    if (e > s) out.add((s, e));
    if (a[i].$2 < b[j].$2) {
      i++;
    } else {
      j++;
    }
  }
  return out;
}
