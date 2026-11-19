import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/platform/platform_detector.dart' show PlatformDetector;
import '../app_settings.dart';

/// Which engine plays video on this device (Settings → Playback → Player engine).
///
/// Android TV has two: Media3 (Android's own player, ExoPlayer) and mpv. Media3 is the one used
/// unless you pick mpv. Both draw on a SurfaceView under the interface, and a video Media3 can't
/// play is handed to mpv by itself, at the same spot (the native plugin does that).
///
/// Everywhere else there is only mpv, and nothing here changes anything.
///
/// A few things only mpv can do (upscaling, ambient lighting, the 5.1 channel limit, some of the
/// subtitle look). Menus and Settings ask [isMedia3] and leave those out while it is the engine;
/// they are back when you switch to mpv.
abstract final class PlayerEngine {
  static const media3 = 'media3';
  static const mpv = 'mpv';

  /// Whether this device has the choice: an Android TV.
  static bool get offered => debugOffered ?? (!kIsWeb && Platform.isAndroid && PlatformDetector.isTV());

  /// Tests run on a PC: this stands in for "an Android TV" (with Player.debugExoOnAnyPlatform).
  @visibleForTesting
  static bool? debugOffered;

  /// The engine in use. Nothing chosen yet: Media3 where it is offered.
  static String get current {
    if (!offered) return mpv;
    return AppSettings.playerEngine.value == mpv ? mpv : media3;
  }

  static bool get isMedia3 => current == media3;

  static void choose(String engine) => AppSettings.playerEngine.set(engine == mpv ? mpv : media3);

  /// Tells when the choice changes.
  static Listenable get changes => AppSettings.playerEngine;

  /// Whether a player that fills the screen should be a Media3 one. Video in a tile (a
  /// watch-party room, the Live TV browser's preview) stays on mpv: only its side can place the
  /// picture in a rectangle.
  static bool get forFullScreen => isMedia3;

  /// What the player says when Media3 gives a video to mpv: which part of it Media3 could not
  /// play, so that "it said it can't play this one" from a TV tells what happened there. [why]
  /// is the player's own account of it (Player.handOver).
  static String handOverNote(({String kind, String reason})? why) {
    final codecs = _codecs(why?.reason ?? '');
    final named = codecs.isEmpty ? '' : ' (${codecs.join(', ')})';
    return switch (why?.kind) {
      'audio' => "Media3 can't play this sound$named · using mpv",
      'video' => "Media3 can't play this picture$named · using mpv",
      // not about Media3 at all: the address stopped sending. mpv asks for it again.
      'stream' => 'The stream stalled on Media3 · trying mpv',
      'format' => "Media3 can't read this file · using mpv",
      'stuck' => 'Media3 got stuck · using mpv',
      _ => "Media3 can't play this one · using mpv",
    };
  }

  static const _codecNames = {
    'audio/true-hd': 'TrueHD',
    'audio/vnd.dts': 'DTS',
    'audio/vnd.dts.hd': 'DTS-HD',
    'audio/vnd.dts.hd;profile=lbr': 'DTS Express',
    'audio/vnd.dts.uhd;profile=p2': 'DTS:X',
    'audio/ac3': 'Dolby Digital',
    'audio/eac3': 'Dolby Digital Plus',
    'audio/eac3-joc': 'Dolby Atmos',
    'audio/ac4': 'AC-4',
    'audio/mp4a-latm': 'AAC',
    'audio/mpeg': 'MP3',
    'audio/mpeg-l2': 'MP2',
    'audio/flac': 'FLAC',
    'audio/opus': 'Opus',
    'audio/vorbis': 'Vorbis',
    'audio/alac': 'ALAC',
    'audio/raw': 'PCM',
    'video/hevc': 'HEVC',
    'video/avc': 'H.264',
    'video/dolby-vision': 'Dolby Vision',
    'video/av01': 'AV1',
    'video/x-vnd.on2.vp9': 'VP9',
    'video/x-vnd.on2.vp8': 'VP8',
    'video/mpeg2': 'MPEG-2',
    'video/mp4v-es': 'MPEG-4',
    'video/wvc1': 'VC-1',
  };

  /// The codecs the plugin named ("... (audio/true-hd, audio/ac3)"), in plain names; ones with
  /// no plain name are left out, and at most two are said.
  static List<String> _codecs(String reason) {
    final out = <String>[];
    for (final m in RegExp(r'(?:audio|video)/[A-Za-z0-9.+\-]+(?:;profile=[a-z0-9]+)?').allMatches(reason)) {
      final name = _codecNames[m[0]!.toLowerCase()];
      if (name != null && !out.contains(name)) out.add(name);
    }
    return out.take(2).toList();
  }
}
