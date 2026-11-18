import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../data/playback/audio_focus.dart';
import '../../mpv/mpv.dart';
import '../../dpad/dpad_picture.dart';
import '../../dpad/focusable_wrapper.dart';
import '../../dpad/input_mode_tracker.dart';
import '../../widgets/common.dart';
import 'party_strip.dart';
import '../../core/platform/platform_detector.dart' show PlatformDetector;

/// Live TV in the room: plays the relay's rolling window. It starts a few pieces back from the
/// newest, which is the cushion against a slow moment on anyone's connection, and keeps almost
/// nothing behind, because it's live.
class PartyLivePlayer extends StatefulWidget {
  const PartyLivePlayer({super.key, required this.url, required this.title, required this.onExpand, this.full = false});
  final String url;
  final String title;
  final VoidCallback onExpand; // tile: go full; full: back to the room
  final bool full;

  @override
  State<PartyLivePlayer> createState() => _PartyLivePlayerState();
}

class _PartyLivePlayerState extends State<PartyLivePlayer> {
  static final _touch = (Platform.isAndroid || Platform.isIOS) && !PlatformDetector.isTV(); // (a TV has no touchscreen)
  // The player; the 48 MiB demuxer budget is set in _open (demuxer-max-bytes).
  late final _player = Player();
  final _subs = <StreamSubscription<Object?>>[];
  // D-pad. In the room the tile is one stop: OK makes it fill the window, Right steps onto
  // its buttons, which show while focus is on the tile. Filling the window it has the film
  // player's two states (see DpadPicture): the picture in charge (Up and Down are volume, as
  // always; OK brings the controls up), or the controls shown (Back hides them, Back again
  // returns to the room).
  late final _picture = DpadPicture(
    debugLabel: 'room live player',
    ownsKey: (key) => key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown,
    onChanged: () {
      if (!mounted) return;
      _poke();
      setState(() {});
    },
    onKeyOnControls: () {
      if (mounted) _poke();
    },
  );
  FocusNode get _keys => _picture.node;
  final _tileNode = FocusNode(debugLabel: 'room live tile');

  /// In the room's tile, with a D-pad: focus is on the tile or one of its buttons, so they stay shown.
  bool get _held => !widget.full && DpadPicture.dpad && _picture.onControls;

  void _enterControls() {
    _poke();
    _picture.toControls(shown: () => mounted && _chrome);
  }

  void _backKey() {
    if (_chrome && _picture.backToPicture()) {
      _hide?.cancel();
      setState(() => _chrome = false);
      return;
    }
    widget.onExpand();
  }

  Timer? _retry;
  Timer? _hide;
  bool _buffering = true;
  bool _lost = false;
  bool _chrome = true;
  double _volume = 100;
  bool _paused = false; // by you

  @override
  void initState() {
    super.initState();
    _subs
      ..add(_player.streams.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }))
      ..add(_player.streams.playing.listen((v) {
        if (v && _lost && mounted) setState(() => _lost = false);
      }))
      ..add(_player.streams.error.listen((_) => _again()))
      ..add(_player.streams.completed.listen((done) {
        if (done) _again();
      }));
    _picture.attach();
    _open();
    _poke();
  }

  @override
  void didUpdateWidget(PartyLivePlayer old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _paused = false;
      _open();
    }
    // Back in the room from filling the window: with a D-pad, the ring is on the tile again.
    if (old.full && !widget.full && DpadPicture.dpad && _keys.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.full) _tileNode.requestFocus();
      });
    }
  }

  /// OK on the tile: it fills the window, and focus rests on the picture there (OK then brings
  /// the controls up). Focus moves first: the tile stops being a control as the window fills.
  void _expandFromTile() {
    _keys.requestFocus();
    widget.onExpand();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _hide?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _picture.dispose();
    _tileNode.dispose();
    AudioFocus.release(this);
    _player.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    AudioFocus.claim(this, _pause);
    try {
      final mpv = _player;
      await mpv.setProperty('demuxer-lavf-o', 'live_start_index=-4');
      await mpv.setProperty('cache', 'yes');
      await mpv.setProperty('demuxer-readahead-secs', '12');
      await mpv.setProperty('demuxer-max-bytes', '48MiB');
      await mpv.setProperty('demuxer-max-back-bytes', '2MiB');
      await _player.setVolume(_volume);
      await _player.open(Media(widget.url));
    } catch (_) {
      _again();
    }
  }

  /// The stream hiccuped, or isn't there yet: keep trying for as long as the room says it's on.
  void _again() {
    if (!mounted || _paused || (_retry?.isActive ?? false)) return;
    setState(() => _lost = true);
    _retry = Timer(const Duration(seconds: 3), () {
      if (mounted) _open();
    });
  }

  void _poke() {
    _hide?.cancel();
    if (!_chrome && mounted) setState(() => _chrome = true);
    _hide = Timer(const Duration(seconds: 4), () {
      // paused: the controls stay. So do they while a D-pad has focus on the tile.
      if (mounted && !_paused && !_held) {
        setState(() => _chrome = false);
        if (widget.full) _picture.toPicture(); // a control that is no longer shown must not keep focus
      }
    });
  }

  void _setVolume(double v) {
    setState(() => _volume = v.clamp(0, 100));
    _player.setVolume(_volume);
    _poke();
  }

  /// Pauses just for you (the room carries on). Playing again jumps back to live.
  void _togglePause() {
    _poke();
    if (_paused) {
      setState(() => _paused = false);
      _open();
    } else {
      _pause();
    }
  }

  void _pause() {
    if (mounted) setState(() => _paused = true);
    _retry?.cancel();
    _player.pause();
  }

  Widget _button(IconData icon, String tooltip, VoidCallback onTap, {bool start = false}) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    autofocus: start,
    builder: (context, hovered, _) => Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: hovered ? .72 : .5)),
      child: Icon(icon, size: 19),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final top = widget.full ? Layout.windowChrome(context) : 0.0;
    final side = phone ? 14.0 : 24.0;
    return CallbackShortcuts(
      bindings: {
        // Back: Escape, a remote's Back, a controller's B. Held, it is still one Back.
        if (widget.full) ...{
          const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): _backKey,
          const SingleActivator(LogicalKeyboardKey.goBack, includeRepeats: false): _backKey,
          const SingleActivator(LogicalKeyboardKey.browserBack, includeRepeats: false): _backKey,
          const SingleActivator(LogicalKeyboardKey.gameButtonB, includeRepeats: false): _backKey,
        },
        const SingleActivator(LogicalKeyboardKey.keyF): widget.onExpand,
        const SingleActivator(LogicalKeyboardKey.keyM): () => _setVolume(_volume == 0 ? 100 : 0),
        const SingleActivator(LogicalKeyboardKey.space): _togglePause,
        const SingleActivator(LogicalKeyboardKey.keyK): _togglePause,
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause, includeRepeats: false): _togglePause,
        // With focus on the picture Up and Down are volume, as always. With focus on one of
        // the buttons they move focus instead.
        if (_picture.onPicture) ...{
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _setVolume(_volume + 10),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _setVolume(_volume - 10),
          if (widget.full) ...{
            const SingleActivator(LogicalKeyboardKey.arrowLeft, includeRepeats: false): _enterControls,
            const SingleActivator(LogicalKeyboardKey.arrowRight, includeRepeats: false): _enterControls,
            const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false): _enterControls,
            const SingleActivator(LogicalKeyboardKey.numpadEnter, includeRepeats: false): _enterControls,
            const SingleActivator(LogicalKeyboardKey.select, includeRepeats: false): _enterControls,
            const SingleActivator(LogicalKeyboardKey.gameButtonA, includeRepeats: false): _enterControls,
          },
        },
      },
      child: Focus(
        focusNode: _keys,
        autofocus: widget.full,
        child: MouseRegion(
          cursor: _chrome ? MouseCursor.defer : SystemMouseCursors.none,
          onHover: (_) => _poke(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _keys.requestFocus();
              _chrome ? setState(() => _chrome = false) : _poke();
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                VyseVideo(player: _player),
                if ((_buffering || _lost) && !_paused)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox.square(dimension: 34, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)),
                        if (_lost) ...[
                          const SizedBox(height: 12),
                          const Text('Catching the stream…', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: VyseColors.textDim)),
                        ],
                      ],
                    ),
                  ),
                // To a D-pad the tile in the room is one stop (OK fills the window, Right
                // steps onto its buttons); filling the window it is nothing, and focus rests
                // on the picture. A pointer never meets it.
                FocusableWrapper(
                 focusNode: _tileNode,
                 canRequestFocus: !widget.full,
                 onSelect: _expandFromTile,
                 disableScale: true,
                 borderRadius: 4,
                 child: IgnorePointer(
                  ignoring: !_chrome,
                  // filling the window, hidden controls are shut to focus as well
                  child: ExcludeFocus(
                   excluding: widget.full && !_chrome,
                   child: AnimatedOpacity(
                    opacity: _chrome ? 1 : 0,
                    duration: Duration(milliseconds: _chrome ? 110 : 280),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(side, top + (widget.full ? 12 : 8), side, widget.full ? 16 : 8),
                      child: Column(
                        children: [
                          if (widget.full)
                            Row(
                              children: [
                                GlassIconButton(icon: Icons.arrow_back_rounded, label: 'Back to the room (Esc)', size: 40, onTap: widget.onExpand),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 8, color: Colors.black)]),
                                  ),
                                ),
                              ],
                            ),
                          const Spacer(),
                          Row(
                            children: [
                              _button(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded, _paused ? 'Play (Space)' : 'Pause (Space)', _togglePause, start: widget.full),
                              // (on a TV the remote sets the volume)
                              if (playersHaveVolume) ...[
                              const SizedBox(width: 8),
                              _button(_volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, 'Mute (M)', () => _setVolume(_volume == 0 ? 100 : 0)),
                              SizedBox(
                                width: phone ? 100 : 130,
                                // a mouse's slider; a D-pad passes it over (Mute is beside it)
                                child: ExcludeFocus(
                                  excluding: InputModeTracker.isKeyboardMode(context),
                                  child: Slider(value: _volume.clamp(0, 100), max: 100, activeColor: Colors.white, inactiveColor: Colors.white24, onChanged: _setVolume),
                                ),
                              ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                   ),
                  ),
                 ),
                ),
                if (widget.full)
                  Positioned(
                    left: side,
                    top: top + 66,
                    child: PartyStrip(controlsUp: _chrome, touch: _touch, compact: phone, onDone: _keys.requestFocus),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
