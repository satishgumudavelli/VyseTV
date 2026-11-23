// Automatic subtitle sync by ear, for a video with no subtitles of its own (a website's stream):
// a downloaded file is lined up with when people speak in the film. A few stretches of the
// film's sound are decoded ahead of playback ([listenAt] picks them: where the file has
// dialogue, spread over the film), each is turned into speech or not 100 times a second
// (voice_activity.dart), and [fitToSpeech] slides the file's lines along until they fall where
// the speech is.
//
// Speech detection hears more than voices (music, a crowd), so no single moment is trusted:
// what counts is that the pattern of the file's lines, over minutes, matches the pattern of the
// speech much better at one shift than at any other, and that every stretch listened to says
// the same on its own.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'auto_sync.dart';

/// A stretch of the film's sound, heard: where it starts (film seconds) and, 100 times a second,
/// whether someone speaks there (1) or not.
class Heard {
  const Heard(this.start, this.speech);
  final double start;
  final Uint8List speech;
  double get end => start + speech.length / 100;
}

/// The file's lines that are someone speaking: not a sound described ("[door shuts]",
/// "(laughs)") or a song ("♪ …"), which the sound has no speech for.
List<Span> spokenLines(Iterable<(double, double, String)> cues) => [
  for (final (start, end, text) in cues)
    if (end > start && !_notSpeech(text)) (start, end),
];

bool _notSpeech(String text) {
  final t = text.replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), '').trim();
  if (t.isEmpty) return true;
  if (RegExp(r'^[\s♪♫♬♩🎵🎶#*-]*$').hasMatch(t)) return true;
  if (t.startsWith('♪') || t.endsWith('♪')) return true;
  return RegExp(r'^[\[(（【「].*[\])）】」]$', dotAll: true).hasMatch(t);
}

/// Where to listen: [count] stretches of [length] seconds of a film [duration] seconds long,
/// where [lines] (the file's, in its own seconds) have the most dialogue, spread over the film,
/// the first soon after [now] so the subtitles are in time early. Film seconds, in the order to
/// listen.
List<double> listenAt(List<Span> lines, double duration, double now, {int count = 4, double length = 45}) {
  if (duration < length * 2) return const [];
  // not the opening or the closing credits
  final first = math.max(now + 15, math.min(180.0, duration * .06));
  final last = duration - math.min(360.0, duration * .08) - length;
  if (last <= first) return [math.max(0, math.min(now + 15, duration - length))];
  double dialogue(double at) {
    var s = 0.0;
    for (final (a, b) in lines) {
      final x = math.max(a, at), y = math.min(b, at + length);
      if (y > x) s += y - x;
    }
    return s;
  }

  double bestIn(double from, double to) {
    var best = from, top = -1.0;
    for (var at = from; at <= to; at += 5) {
      final d = dialogue(at);
      if (d > top) (best, top) = (at, d);
    }
    return best;
  }

  final picked = <double>[bestIn(first, math.min(last, first + 600))];
  // the rest: one in each part of what is left, the farthest from the ones picked first
  final sections = count - 1;
  final candidates = [for (var k = 0; k < sections; k++) bestIn(first + (last - first) * k / sections, first + (last - first) * (k + 1) / sections)];
  while (picked.length < count && candidates.isNotEmpty) {
    candidates.sort((a, b) => _distance(b, picked).compareTo(_distance(a, picked)));
    final c = candidates.removeAt(0);
    if (_distance(c, picked) >= length) picked.add(c);
  }
  return picked;
}

double _distance(double at, List<double> from) => from.fold(double.infinity, (m, f) => math.min(m, (at - f).abs()));

/// [fitToSpeech] away from the screen's thread.
Future<AutoSyncVerdict> fitToSpeechInBackground(List<Heard> spots, List<Span> file) => Isolate.run(() => fitToSpeech(spots, file));

/// Frame-rate mix-ups a release may have, as in auto_sync.dart.
const _scales = [1.0, 24 / 23.976, 23.976 / 24, 25 / 23.976, 23.976 / 25, 25 / 24, 24 / 25];

/// How far off a file may be, either way, in seconds.
const _reach = 120.0;

/// Where [file]'s lines (its own seconds) belong, judged by the speech heard in [spots]. Fits
/// only when it is clear: the lines match the speech far better at that shift than anywhere
/// else, and each stretch heard (two at least) puts it in the same place on its own.
AutoSyncVerdict fitToSpeech(List<Heard> spots, List<Span> file) {
  final heard = [for (final s in spots) if (s.speech.length >= 1000 && _speechShare(s) >= .1) s];
  final seconds = heard.fold(0.0, (t, s) => t + s.speech.length / 100);
  final about = '${heard.length} of ${spots.length} stretches heard (${seconds.round()}s)';
  if (heard.length < 2 || file.isEmpty) return AutoSyncVerdict(AutoSyncKind.wait, why: '$about: too few');
  // the speech 10 times a second, as a share of each tenth
  final coarse = [for (final s in heard) _tenths(s.speech)];
  _Peak? best;
  for (final scale in _scales) {
    final p = _search(heard, coarse, file, scale);
    if (p == null) continue;
    // another speed only when it is clearly better (a 0.1% one wins on noise otherwise)
    if (best == null || (scale == 1 ? p.r > best.r : p.r > best.r + .02)) best = p;
  }
  if (best == null) return AutoSyncVerdict(AutoSyncKind.wait, why: '$about: nothing to compare');
  // to the hundredth: around the best tenth, at 10 ms
  final shift = _fine(heard, file, best.scale, best.shift);
  final why = '$about: ${best.scale == 1 ? '' : 'speed ${best.scale.toStringAsFixed(4)}, '}'
      '${shift >= 0 ? '+' : ''}${shift.toStringAsFixed(2)}s, match ${best.r.toStringAsFixed(3)}, elsewhere ${best.elsewhere.toStringAsFixed(3)}, '
      'stretches agreeing ${best.agree} of ${heard.length}';
  final clear = best.r >= .12 && best.r - best.elsewhere >= .06 && best.r >= best.elsewhere * 1.6 && best.agree == heard.length;
  if (!clear) return AutoSyncVerdict(AutoSyncKind.unclear, why: why);
  return AutoSyncVerdict(AutoSyncKind.fits, map: SyncMap([(-1e9, best.scale, shift)]), why: why);
}

double _speechShare(Heard s) {
  var n = 0;
  for (final v in s.speech) {
    n += v;
  }
  return n / s.speech.length;
}

Float64List _tenths(Uint8List speech) {
  final out = Float64List(speech.length ~/ 10);
  for (var b = 0; b < out.length; b++) {
    var n = 0;
    for (var k = 0; k < 10; k++) {
      n += speech[b * 10 + k];
    }
    out[b] = n / 10;
  }
  return out;
}

class _Peak {
  const _Peak(this.scale, this.shift, this.r, this.elsewhere, this.agree);
  final double scale;
  final double shift; // seconds
  final double r; // how well the lines and the speech go together there (Pearson's r)
  final double elsewhere; // the best r more than 2.5 s away
  final int agree; // stretches whose own best is within 0.5 s of it
}

/// Where the file's line-or-not, 10 times a second, goes best with the speech heard, at one
/// speed: every shift within the reach, 0.1 s apart.
_Peak? _search(List<Heard> heard, List<Float64List> coarse, List<Span> file, double scale) {
  final reach = (_reach * 10).round();
  final r = Float64List(2 * reach + 1);
  final own = <Float64List>[];
  for (var k = 0; k < heard.length; k++) {
    final v = coarse[k];
    final n = v.length;
    final b0 = (heard[k].start * 10).round();
    // the file's lines, as line or not for each tenth from b0 - reach to b0 + n + reach
    final lines = _covered(file, scale, (b0 - reach) / 10, n + 2 * reach, 10);
    var sv = 0.0, svv = 0.0;
    for (final x in v) {
      sv += x;
      svv += x * x;
    }
    final varV = svv - sv * sv / n;
    // prefix sums of the lines, for each shift's mean and spread
    final pre = Float64List(lines.length + 1);
    for (var i = 0; i < lines.length; i++) {
      pre[i + 1] = pre[i] + lines[i];
    }
    final mine = Float64List(2 * reach + 1);
    for (var lag = -reach; lag <= reach; lag++) {
      // the speech at b0 + i goes with the lines at b0 + i - lag
      final from = reach - lag;
      final ss = pre[from + n] - pre[from];
      var svs = 0.0;
      for (var i = 0; i < n; i++) {
        svs += v[i] * lines[from + i];
      }
      final varS = ss - ss * ss / n; // (lines are 0 or 1: their squares are themselves)
      final cov = svs - sv * ss / n;
      final c = varV <= 0 || varS <= 0 ? 0.0 : cov / math.sqrt(varV * varS);
      mine[lag + reach] = c;
      r[lag + reach] += c / heard.length;
    }
    own.add(mine);
  }
  var top = 0;
  for (var i = 1; i < r.length; i++) {
    if (r[i] > r[top]) top = i;
  }
  var elsewhere = -1.0;
  for (var i = 0; i < r.length; i++) {
    if ((i - top).abs() > 25 && r[i] > elsewhere) elsewhere = r[i];
  }
  var agree = 0;
  for (final mine in own) {
    var at = math.max(0, top - 30);
    for (var i = math.max(0, top - 30); i <= math.min(r.length - 1, top + 30); i++) {
      if (mine[i] > mine[at]) at = i;
    }
    if ((at - top).abs() <= 5) agree++;
  }
  return _Peak(scale, (top - reach) / 10, r[top], elsewhere, agree);
}

/// The shift to the hundredth of a second: within 0.3 s of [around], at 10 ms.
double _fine(List<Heard> heard, List<Span> file, double scale, double around) {
  var best = around, top = -2.0;
  for (var k = -30; k <= 30; k++) {
    final shift = around + k / 100;
    var r = 0.0;
    for (final s in heard) {
      final n = s.speech.length;
      final lines = _covered(file, scale, s.start - shift, n, 100);
      var sv = 0, ss = 0, svs = 0;
      for (var i = 0; i < n; i++) {
        sv += s.speech[i];
        ss += lines[i].round();
        svs += s.speech[i] * lines[i].round();
      }
      final varV = sv - sv * sv / n, varS = ss - ss * ss / n;
      r += varV <= 0 || varS <= 0 ? 0 : (svs - sv * ss / n) / math.sqrt(varV * varS);
    }
    if (r > top) (best, top) = (shift, r);
  }
  return best;
}

/// Line (1) or not (0) for [count] steps of 1/[rate] s from film time [from], with the file's
/// lines at their times × [scale].
Float64List _covered(List<Span> file, double scale, double from, int count, int rate) {
  final out = Float64List(count);
  for (final (a, b) in file) {
    final i0 = ((a * scale - from) * rate).ceil(), i1 = ((b * scale - from) * rate).ceil();
    for (var i = math.max(0, i0); i < math.min(count, i1); i++) {
      out[i] = 1;
    }
  }
  return out;
}
