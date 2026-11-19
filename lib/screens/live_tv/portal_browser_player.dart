import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/accent.dart';
import '../../core/theme.dart';
import '../../data/playback/audio_focus.dart';
import '../../data/live_tv/live_tv.dart';
import '../../data/party/party_live.dart';
import '../../data/party/rooms.dart';
import '../../data/party/watch_party.dart';
import '../../mpv/mpv.dart';
import '../../dpad/dpad_picture.dart';
import '../../dpad/focusable_wrapper.dart';
import '../../dpad/input_mode_tracker.dart';
import '../../widgets/common.dart';
import '../../widgets/section_chrome.dart';
import '../party/rooms_view.dart' show openRoom;
import '../../core/platform/platform_detector.dart' show PlatformDetector;
import '../../core/layout.dart';

/// The channel playing inside the portal browser, the way the room plays its live tile.
///
/// One player for as long as the pane is up: picking another channel reopens it, and full screen
/// only moves this widget (the page holds it under a GlobalKey), so the stream never reconnects.
/// Space plays / pauses, ↑ ↓ change channel, F or a double click toggles full screen, M mutes.
///
/// With a D-pad. In the pane its buttons are stops like any others on the page, and they show
/// while focus is on one of them (what hover reveals, focus reveals). Full screen it has the
/// film player's two states (see DpadPicture): the picture in charge (Up and Down change
/// channel, OK brings the controls up), or the controls shown (arrows move between them, Back
/// hides them, Back again returns to the list).
///
/// The picture is mpv's surface behind the window (see VyseVideo): nothing here fades or blurs
/// above it as an ancestor, only the controls drawn over it fade.
class BrowserLivePlayer extends StatefulWidget {
  const BrowserLivePlayer({
    super.key,
    required this.item,
    required this.expanded,
    required this.onExpand,
    this.onStep,
    this.guide,
  });

  final LiveItem item;
  final bool expanded;

  /// Pane: take the whole window. Full screen: back to the browser.
  final VoidCallback onExpand;

  /// Previous (-1) or next (1) channel in the list; null when there's only one.
  final ValueChanged<int>? onStep;

  /// Now / next, shown over the picture in full screen.
  final Widget? guide;

  @override
  State<BrowserLivePlayer> createState() => _BrowserLivePlayerState();
}

class _BrowserLivePlayerState extends State<BrowserLivePlayer> {
  static final _touch = (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) && !PlatformDetector.isTV(); // (a TV has no touchscreen)

  late final _player = Player();
  final _subs = <StreamSubscription<Object?>>[];
  late final _picture = DpadPicture(
    debugLabel: 'browser player',
    // Up and Down are the picture's own: they change channel
    ownsKey: (key) => widget.onStep != null && (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown),
    onChanged: () {
      if (!mounted) return;
      _poke(); // focus came onto the pane's buttons, or left them: the idle clock starts over
      setState(() {});
    },
    onKeyOnControls: () {
      if (mounted) _poke();
    },
  );
  FocusNode get _keys => _picture.node;

  /// In the pane, with a D-pad: focus is on one of its buttons, so they stay shown.
  bool get _held => !widget.expanded && DpadPicture.dpad && _picture.onControls;

  /// Full screen, OK (or Left or Right) on the picture: the controls come up and, with a
  /// D-pad, focus goes onto them, Play first.
  void _enterControls() {
    _poke();
    _picture.toControls(shown: () => mounted && _chrome);
  }

  /// Full screen, Back by key: with a D-pad on the controls, hide them and return to the
  /// picture; otherwise back to the list, as always.
  void _backKey() {
    if (_chrome && _picture.backToPicture()) {
      _hide?.cancel();
      setState(() => _chrome = false);
      return;
    }
    widget.onExpand();
  }

  Timer? _hide;
  bool _playing = false;
  bool _buffering = true;
  bool _chrome = true;
  bool _sharing = false;

  /// Let go of the stream: another page covers the browser, or the room has the channel now.
  /// Providers mostly allow one connection, so a hidden player must not keep it.
  bool _stopped = false;
  double _volume = 100;
  double _lastVolume = 100;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subs
      ..add(_player.streams.playing.listen((v) {
        if (mounted) setState(() => _playing = v);
      }))
      ..add(_player.streams.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }))
      ..add(_player.streams.error.listen((e) {
        if (mounted && !_stopped) setState(() => _error = e.message);
      }));
    // After the first frame: claiming focus updates the shell's mini player.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_stopped) _open();
    });
    _picture.attach();
    _poke();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A page opened over the browser (a room, a series): the picture can't be seen, so stop.
    if (!(ModalRoute.of(context)?.isCurrent ?? true) && !_stopped) {
      _stopped = true;
      _hide?.cancel();
      _chrome = true;
      unawaited(_player.stop().catchError((Object _) {}));
    }
  }

  @override
  void didUpdateWidget(BrowserLivePlayer old) {
    super.didUpdateWidget(old);
    if (old.item.url != widget.item.url) {
      // after this frame, like the first open: it tells the shell who is playing
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open();
      });
    }
    if (old.expanded != widget.expanded) {
      // (with a D-pad on its full screen button, focus stays on that button)
      if (widget.expanded && !(DpadPicture.dpad && _picture.onControls)) _keys.requestFocus();
      _poke();
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _picture.dispose();
    AudioFocus.release(this);
    _player.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    AudioFocus.claim(this, _player.pause);
    setState(() {
      _error = null;
      _buffering = true;
      _stopped = false;
    });
    _poke();
    try {
      await _player.setVolume(_volume);
      await _player.open(Media(widget.item.url));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _toggle() {
    if (_stopped) {
      _open();
      return;
    }
    if (!_playing) AudioFocus.claim(this, _player.pause);
    _player.playOrPause();
    _poke();
  }

  void _setVolume(double v) {
    setState(() => _volume = v.clamp(0, 100));
    _player.setVolume(_volume);
    _poke();
  }

  void _mute() {
    if (_volume > 0) {
      _lastVolume = _volume;
      _setVolume(0);
    } else {
      _setVolume(_lastVolume == 0 ? 100 : _lastVolume);
    }
  }

  void _step(int dir) {
    widget.onStep?.call(dir);
    _poke();
  }

  /// Hands the channel to your room, the same way the full player does: this player lets go
  /// first, because most providers allow one connection and the relay needs it.
  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final nav = Navigator.of(context); // the tab: the room opens here, beside the rail
    final item = widget.item;
    const style = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    showToast(context, const Text('Freeing the channel for your room. This can take up to a minute.', style: style), icon: Icons.groups_rounded);
    try {
      await _player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await PartyLive.host(
        url: item.url,
        title: item.title,
        logo: item.logo,
        onUploading: () {
          if (!mounted) return;
          showToast(context, const Text("Our server couldn't open this channel. Sending it from your device instead.", style: style), icon: Icons.upload_rounded);
        },
      );
    } on LiveShareError catch (e) {
      if (!mounted) return;
      setState(() => _sharing = false);
      showToast(context, Text(e.message, style: style), icon: Icons.error_outline_rounded);
      unawaited(_open());
      return;
    }
    if (!mounted) return; // they left while it opened: the room has it anyway
    setState(() {
      _sharing = false;
      _stopped = true;
    });
    if (widget.expanded) widget.onExpand(); // the room takes the window itself
    await openRoom(nav, theater: true);
  }

  /// Worked out by hand: a GestureDetector onDoubleTap holds every tap for ~300ms.
  DateTime? _lastTap;
  bool _isDoubleTap() {
    final now = DateTime.now();
    final hit = _lastTap != null && now.difference(_lastTap!) < const Duration(milliseconds: 300);
    _lastTap = hit ? null : now;
    return hit;
  }

  /// Shows the controls and restarts the idle timer.
  void _poke() {
    _hide?.cancel();
    if (!_chrome && mounted) setState(() => _chrome = true);
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing && !_stopped && _error == null && !_held) {
        setState(() => _chrome = false);
        if (widget.expanded) _picture.toPicture(); // a control that is no longer shown must not keep focus
      }
    });
  }

  Widget _button(IconData icon, String tooltip, VoidCallback onTap, {double? size, bool start = false}) {
    final d = size ?? (_touch ? 44.0 : 36.0);
    return Pressable(
      tooltip: tooltip,
      onTap: onTap,
      autofocus: start,
      builder: (context, hovered, _) => Container(
        width: d,
        height: d,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: hovered ? .74 : .5)),
        child: Icon(icon, size: d * .52, color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final full = widget.expanded;
    final accent = accentOf(context);
    final safe = full ? MediaQuery.paddingOf(context) : EdgeInsets.zero;
    final side = full ? 22.0 : 10.0;
    return CallbackShortcuts(
      bindings: {
        // Back: Escape, a remote's Back, a controller's B. Held, it is still one Back.
        if (full) ...{
          const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): _backKey,
          const SingleActivator(LogicalKeyboardKey.goBack, includeRepeats: false): _backKey,
          const SingleActivator(LogicalKeyboardKey.browserBack, includeRepeats: false): _backKey,
          const SingleActivator(LogicalKeyboardKey.gameButtonB, includeRepeats: false): _backKey,
        },
        const SingleActivator(LogicalKeyboardKey.keyF): widget.onExpand,
        const SingleActivator(LogicalKeyboardKey.space): _toggle,
        const SingleActivator(LogicalKeyboardKey.keyK): _toggle,
        const SingleActivator(LogicalKeyboardKey.keyM): _mute,
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause, includeRepeats: false): _toggle,
        // a remote's channel keys, wherever focus is in the player
        if (widget.onStep != null) ...{
          const SingleActivator(LogicalKeyboardKey.channelUp, includeRepeats: false): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.channelDown, includeRepeats: false): () => _step(-1),
        },
        // With focus on the picture Up and Down change channel, as always. With focus on one
        // of the buttons they move focus instead.
        if (_picture.onPicture) ...{
          if (widget.onStep != null) const SingleActivator(LogicalKeyboardKey.arrowUp): () => _step(-1),
          if (widget.onStep != null) const SingleActivator(LogicalKeyboardKey.arrowDown): () => _step(1),
          if (full) ...{
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
        autofocus: full,
        child: MouseRegion(
          cursor: _chrome || !full ? MouseCursor.defer : SystemMouseCursors.none,
          onHover: (_) => _poke(),
          onExit: (_) {
            // in the pane the controls leave with the mouse
            if (!full && _playing && _chrome && _error == null && !_stopped && !_held) setState(() => _chrome = false);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _keys.requestFocus();
              if (_isDoubleTap()) {
                widget.onExpand();
              } else if (_chrome && _playing) {
                setState(() => _chrome = false);
              } else {
                _poke();
              }
            },
            child: LayoutBuilder(
              builder: (context, box) {
                final roomy = box.maxWidth >= 470;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_stopped) const ColoredBox(color: Colors.black) else VyseVideo(player: _player),
                    if (_buffering && _error == null && !_stopped)
                      Center(child: SizedBox.square(dimension: full ? 36 : 28, child: CircularProgressIndicator(strokeWidth: 2.4, color: accent))),
                    if (_error != null && !_stopped) Center(child: _errorCard()),
                    if (_stopped) Center(child: _sharing ? const SizedBox.shrink() : _button(Icons.play_arrow_rounded, 'Play', _open, size: full ? 64 : 52)),
                    // In the pane, to a D-pad, the pane is one stop: arrows from the list land
                    // on it, OK is full screen, and its buttons are inside it (Right steps
                    // onto them, Left steps back out). Full screen it is nothing: focus rests
                    // on the picture. A pointer never meets it.
                    FocusableWrapper(
                     canRequestFocus: !full,
                     onSelect: widget.onExpand,
                     disableScale: true,
                     borderRadius: 4,
                     child: IgnorePointer(
                      ignoring: !_chrome,
                      // Full screen, hidden controls are shut to focus too. In the pane they
                      // stay reachable, and show as soon as focus is on the pane.
                      child: ExcludeFocus(
                        excluding: full && !_chrome,
                        child: AnimatedOpacity(
                          opacity: _chrome ? 1 : 0,
                          duration: Duration(milliseconds: _chrome ? 110 : 280),
                          child: RepaintBoundary(
                            child: Column(
                              children: [
                                if (full) _topBar(safe, side) else const SizedBox.shrink(),
                                const Spacer(),
                                _bottomBar(safe, side, full: full, roomy: roomy),
                              ],
                            ),
                          ),
                        ),
                      ),
                     ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(EdgeInsets safe, double side) {
    final item = widget.item;
    return Container(
      padding: EdgeInsets.fromLTRB(side + safe.left, safe.top + 14, side + safe.right, 40),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC000000), Color(0x00000000)]),
      ),
      child: Row(
        children: [
          GlassIconButton(icon: Icons.arrow_back_rounded, label: 'Back to the list (Esc)', size: 40, onTap: widget.onExpand),
          const SizedBox(width: 14),
          if (item.logo != null && item.logo!.isNotEmpty) ...[
            SizedBox(
              width: 44,
              height: 32,
              child: NetImage(url: item.logo, fit: BoxFit.contain, fallback: Icons.live_tv_rounded, decodeWidth: NetImage.decodeWidthFor(context, 44)),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                if (item.subtitle != null)
                  Text(item.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: VyseColors.textDim)),
              ],
            ),
          ),
          const _LiveBadge(),
        ],
      ),
    );
  }

  Widget _bottomBar(EdgeInsets safe, double side, {required bool full, required bool roomy}) {
    final stepping = widget.onStep != null;
    return Container(
      padding: EdgeInsets.fromLTRB(side + safe.left, full ? 50 : 26, side + safe.right, (full ? 18 : 10) + safe.bottom),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xD9000000), Color(0x00000000)]),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (full && widget.guide != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: widget.guide),
          Row(
            children: [
              if (stepping && (full || roomy)) ...[
                _button(Icons.skip_previous_rounded, 'Previous channel (↑)', () => _step(-1)),
                const SizedBox(width: 6),
              ],
              _button(
                _stopped || !_playing ? Icons.play_arrow_rounded : Icons.pause_rounded,
                _stopped || !_playing ? 'Play (Space)' : 'Pause (Space)',
                _toggle,
                start: full, // full screen, a D-pad's controls start here; in the pane the page starts on its list
              ),
              if (stepping) ...[
                const SizedBox(width: 6),
                _button(Icons.skip_next_rounded, 'Next channel (↓)', () => _step(1)),
              ],
              const SizedBox(width: 6),
              // (on a TV the remote sets the volume)
              if (playersHaveVolume) _button(_volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, 'Mute (M)', _mute),
              if (roomy && !_touch && playersHaveVolume)
                SizedBox(
                  width: full ? 130 : 96,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white.withValues(alpha: .22),
                      thumbColor: Colors.white,
                      overlayShape: SliderComponentShape.noOverlay,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      // a mouse's slider; a D-pad passes it over (Mute is beside it)
                      child: ExcludeFocus(
                        excluding: InputModeTracker.isKeyboardMode(context),
                        child: Slider(value: _volume.clamp(0, 100), max: 100, onChanged: _setVolume),
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              ValueListenableBuilder(
                valueListenable: Rooms.mine,
                builder: (context, room, _) {
                  if (room == null || !WatchParty.canControl) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _sharing
                        ? const SizedBox.square(
                            dimension: 36,
                            child: Padding(padding: EdgeInsets.all(9), child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white)),
                          )
                        : _button(Icons.groups_rounded, 'Watch with my room', _share),
                  );
                },
              ),
              _button(
                full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                full ? 'Back to the list (Esc)' : 'Full screen (F)',
                widget.onExpand,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _errorCard() => FittedBox(
        fit: BoxFit.scaleDown,
        child: Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
          decoration: BoxDecoration(
            color: VyseColors.surface.withValues(alpha: .94),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: VyseColors.strokeHi),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.signal_wifi_connected_no_internet_4_rounded, size: 28, color: accentHotOf(context)),
              const SizedBox(height: 8),
              const Text("This stream isn't playing", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              const Text('The source may be offline or busy.', style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(onPressed: _open, child: Text('Retry', style: TextStyle(color: accentOf(context)))),
                  if (widget.onStep != null) TextButton(onPressed: () => _step(1), child: Text('Next channel', style: TextStyle(color: accentOf(context)))),
                ],
              ),
            ],
          ),
        ),
      );
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        // the same red as the full player's badge: "on air", not the theme
        decoration: BoxDecoration(color: const Color(0xFFE5383B), borderRadius: BorderRadius.circular(5)),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle, size: 7, color: Colors.white),
          SizedBox(width: 5),
          Text('LIVE', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, letterSpacing: .6, color: Colors.white)),
        ]),
      );
}
