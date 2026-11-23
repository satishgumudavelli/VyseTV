// Hears stretches of a video's sound for subtitle sync by ear (sound_sync.dart). mpv's listener
// core, an audio-only player of its own that plays nothing out loud, decodes each stretch to a
// file (16 kHz mono, far faster than real time: it doesn't wait for the clock), starting and
// stopping exactly where asked; the voice detector then marks where people speak.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../../mpv/mpv.dart' as pz;
import 'sound_sync.dart';
import 'voice_activity.dart';

/// One for each player, which [stop]s it when its video or subtitles change and when it closes.
class SoundListener {
  pz.Player? _core;
  Future<void> _queue = Future.value();
  int _run = 0;
  Completer<void>? _stopped; // completed by [stop], for the stretch being decoded

  /// Lets go of anything being heard or waiting to be (another video, the player closed, or
  /// nothing more to hear): the stretch being decoded is dropped at once, so it never holds up
  /// the next video's, and the core goes (a new one is made when next needed; one left idle
  /// would keep an iPhone's sound session on after the film).
  void stop() {
    _run++;
    _queue = Future.value();
    _stopped?.complete();
    _stopped = null;
    final core = _core;
    _core = null;
    if (core != null) unawaited(core.dispose().catchError((Object _) {}));
  }

  /// The speech in [length] seconds of [url] (opened with [headers]) from [at] seconds; null
  /// when the sound could not be had (the host refused, no sound track, too slow) or [stop]
  /// came first. One stretch at a time.
  Future<Heard?> hear(String url, Map<String, String> headers, double at, {double length = 45}) {
    final run = _run;
    final done = Completer<Heard?>();
    _queue = _queue.then((_) async {
      if (run != _run) return done.complete(null);
      try {
        done.complete(await _hear(url, headers, at, length, run));
      } catch (_) {
        done.complete(null);
      }
    });
    return done.future;
  }

  Future<Heard?> _hear(String url, Map<String, String> headers, double at, double length, int run) async {
    final stopped = (_stopped ??= Completer<void>()).future;
    final core = _core ??= pz.Player.audio(listener: true);
    final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}vyse_sound')..createSync(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.pcm');
    try {
      // to the file, never the speakers: an output that can't be had plays nothing at all
      for (final (name, value) in [
        ('ao', 'pcm'),
        ('ao-pcm-file', file.path),
        ('ao-pcm-waveheader', 'no'),
        ('audio-format', 's16'),
        ('audio-samplerate', '16000'),
        ('audio-channels', 'mono'),
        ('hr-seek', 'yes'),
        ('end', (at + length).toStringAsFixed(3)),
        ('volume', '100'),
        ('mute', 'no'),
        ('vid', 'no'),
        ('sid', 'no'),
      ]) {
        if (run != _run) return null;
        await core.setProperty(name, value);
      }
      if (run != _run) return null;
      final end = core.streams.completed.firstWhere((c) => c);
      await core.open(pz.Media(url, headers: headers, start: Duration(milliseconds: (at * 1000).round())));
      await Future.any([end, stopped]).timeout(const Duration(seconds: 90));
      if (run != _run) return null; // (stopped, the core with it: it may be another video's now)
      await core.stop();
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 16000 * 2 * 10) return null; // under ten seconds of sound
      final speech = await Isolate.run(() {
        final pcm = Int16List(bytes.length ~/ 2);
        final data = ByteData.sublistView(bytes);
        for (var i = 0; i < pcm.length; i++) {
          pcm[i] = data.getInt16(i * 2, Endian.little);
        }
        return detectSpeech(pcm);
      });
      return Heard(at, speech);
    } on TimeoutException {
      if (run == _run) await core.stop();
      return null;
    } finally {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }
}
