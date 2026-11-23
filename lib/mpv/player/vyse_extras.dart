// VyseTV additions to the player (not in upstream).
//
// VyseTV's player page reads three things upstream's streams don't carry: the
// current subtitle line as text (the subtitle sync panel and the optional
// Flutter subtitle overlay), the displayed video size, and when each line of
// the second subtitle track shows (automatic subtitle sync keeps the video's
// own subtitles on there, hidden). All come from plain mpv properties
// observed next to upstream's own (`sub-text`, `dwidth`/`dheight`,
// `secondary-sub-start`/`-end`). Kept in this one file so merges of
// upstream's player only ever touch the three hook lines marked "VyseTV" in
// player_base.dart.

import 'dart:async';

mixin VyseExtrasMixin {
  final _subTextController = StreamController<String>.broadcast();
  final _videoSizeController = StreamController<(int, int)>.broadcast();
  final _secondaryController = StreamController<(double, double)>.broadcast();

  String _subText = '';
  int _videoWidth = 0;
  int _videoHeight = 0;
  double? _secStart, _secEnd, _secSent;

  /// The subtitle line mpv is showing right now ('' when none).
  String get currentSubText => _subText;

  /// Every change of [currentSubText].
  Stream<String> get subText => _subTextController.stream;

  /// Displayed video size in pixels (after aspect correction), (0, 0) before
  /// the first frame.
  (int, int) get currentVideoSize => (_videoWidth, _videoHeight);

  /// Every change of [currentVideoSize].
  Stream<(int, int)> get videoSize => _videoSizeController.stream;

  /// Each line of the second subtitle track as it starts showing: its start
  /// and end, in seconds on mpv's clock (the line's own times: sub-delay
  /// doesn't move them). Nothing comes while no second track is on.
  Stream<(double, double)> get secondaryLines => _secondaryController.stream;

  /// mpv properties these streams need, registered with the core ones.
  /// (Media3 keeps the names and never sends the secondary ones: it has no
  /// second subtitle track.)
  static const List<(String, String)> vyseObservations = [
    ('sub-text', 'string'),
    ('dwidth', 'int64'),
    ('dheight', 'int64'),
    ('secondary-sub-start', 'double'),
    ('secondary-sub-end', 'double'),
  ];

  /// Returns true when [name] was one of ours (the caller can stop there).
  bool vyseHandleProperty(String name, dynamic value) {
    switch (name) {
      case 'sub-text':
        final text = value is String ? value : '';
        if (text != _subText) {
          _subText = text;
          if (!_subTextController.isClosed) _subTextController.add(text);
        }
        return true;
      case 'dwidth':
      case 'dheight':
        final v = value is num ? value.toInt() : 0;
        final w = name == 'dwidth' ? v : _videoWidth;
        final h = name == 'dheight' ? v : _videoHeight;
        if (w != _videoWidth || h != _videoHeight) {
          _videoWidth = w;
          _videoHeight = h;
          if (!_videoSizeController.isClosed) _videoSizeController.add((w, h));
        }
        return true;
      case 'secondary-sub-start':
      case 'secondary-sub-end':
        // mpv gives the earliest start and the latest end of what shows; the
        // two arrive one after the other, so a line is sent once both say it
        final v = value is num ? value.toDouble() : null;
        if (name == 'secondary-sub-start') {
          _secStart = v;
          if (v == null) _secSent = null;
        } else {
          _secEnd = v;
        }
        final s = _secStart, e = _secEnd;
        if (s != null && e != null && e > s && s != _secSent) {
          _secSent = s;
          if (!_secondaryController.isClosed) _secondaryController.add((s, e));
        }
        return true;
    }
    return false;
  }

  /// Clears per-file values when a new source opens.
  void vyseResetForNewFile() {
    _subText = '';
    if (!_subTextController.isClosed) _subTextController.add('');
  }

  Future<void> closeVyseExtras() async {
    await _subTextController.close();
    await _videoSizeController.close();
    await _secondaryController.close();
  }
}
