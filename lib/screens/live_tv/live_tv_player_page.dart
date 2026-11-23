import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/layout.dart';
import '../../core/platform/platform_detector.dart' show PlatformDetector;
import '../../core/theme.dart';
import '../../data/playback/audio_focus.dart';
import '../../data/playback/player_engine.dart';
import '../../data/live_tv/live_tv.dart';
import '../../data/live_tv/live_favorites.dart';
import '../../data/party/party_live.dart';
import '../../data/party/rooms.dart';
import '../../data/party/watch_party.dart';
import '../../models/iptv/iptv_models.dart';
import '../../mpv/mpv.dart';
import '../../data/app_settings.dart';
import '../../dpad/dpad_picture.dart';
import '../../dpad/dpad_traversal.dart';
import '../../dpad/input_mode_tracker.dart';
import '../../widgets/audiobook_widgets.dart' show SeekBar;
import '../../widgets/common.dart';
import '../../widgets/section_chrome.dart';
import '../party/rooms_view.dart' show openRoom;
import '../shell/shell.dart' show WindowBar;

Future<void> openLivePlayer(BuildContext context, List<LiveItem> items, int index) {
  final tab = Navigator.of(context); // the room opens here, beside the rail
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => LiveTvPlayerPage(items: items, index: index, tab: tab),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
}

/// Full-screen video. Controls fade after a few idle seconds. Space plays / pauses, ↑ ↓ change
/// channel, F toggles full screen, M mutes, C shows the channel list, Esc leaves.
///
/// With a D-pad it has the film player's two states (see DpadPicture). The picture in charge:
/// Up and Down change channel as always (and a remote's channel keys do too), OK brings the
/// controls up. The controls shown: arrows move between them, Back hides them, Back again
/// leaves. The channel list opens in place and keeps the arrows while it is open.
class LiveTvPlayerPage extends StatefulWidget {
  const LiveTvPlayerPage({super.key, required this.items, required this.index, this.tab});
  final List<LiveItem> items;
  final int index;
  final NavigatorState? tab;

  @override
  State<LiveTvPlayerPage> createState() => _LiveTvPlayerPageState();
}

class _LiveTvPlayerPageState extends State<LiveTvPlayerPage> with WidgetsBindingObserver {
  /// Android stopped the app (Home, the TV going to sleep): the channel stops playing, as a
  /// film does. (Not in picture-in-picture, where the app is only paused.)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused || defaultTargetPlatform != TargetPlatform.android) return;
    if (Pip.active.value || !_playing) return;
    unawaited(_player.pause());
  }

  // On an Android TV: Media3 unless Settings says mpv (PlayerEngine). A channel it can't play
  // is handed to mpv by its plugin.
  late final _player = Player(useExoPlayer: PlayerEngine.forFullScreen);
  final _subs = <StreamSubscription<Object?>>[];
  final _position = ValueNotifier(Duration.zero);
  final _duration = ValueNotifier(Duration.zero);

  late int _index = widget.index;
  bool _playing = false;
  bool _buffering = true;
  bool _chrome = true;
  bool _list = false;
  bool _fullscreen = false;
  bool _sharing = false;
  double _volume = 100;
  double _lastVolume = 100;
  String? _error;
  Future<List<EpgEntry>>? _epg;
  Timer? _hide;

  LiveItem get _item => widget.items[_index];

  late final _picture = DpadPicture(
    debugLabel: 'live player',
    // Up and Down are the picture's own (they change channel), and for something that is
    // not live so are Left and Right (they seek)
    ownsKey: (key) => key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown || !_item.live,
    onChanged: () {
      if (mounted) setState(() {});
    },
    onKeyOnControls: () {
      if (mounted && _chrome) _poke();
    },
  );
  final _listRegion = DpadRegionNode(debugLabel: 'channels');

  /// OK (and for a live channel Left or Right) on the picture: the controls come up and,
  /// with a D-pad, focus goes onto them, Play first, or into the channel list if it is open.
  void _enterControls() {
    _poke();
    _picture.toControls(shown: () => mounted && _chrome);
  }

  void _seekBy(int seconds) {
    final to = _position.value + Duration(seconds: seconds);
    _player.seek(to < Duration.zero ? Duration.zero : to);
    _poke();
  }

  /// Back by key. One thing per press. With a D-pad: close the channel list if it is open,
  /// else hide the controls and return to the picture; otherwise what Back always did.
  void _backKey() {
    if (_list && DpadPicture.dpad) return setState(() => _list = false);
    if (_chrome && _picture.backToPicture()) {
      _hide?.cancel();
      setState(() => _chrome = false);
      return;
    }
    _back();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subs
      ..add(_player.streams.playing.listen((v) => setState(() => _playing = v)))
      ..add(_player.streams.buffering.listen((v) => setState(() => _buffering = v)))
      ..add(_player.streams.position.listen((p) {
        // per-frame updates would rebuild the seek bar 60 times a second
        if ((p - _position.value).abs() >= const Duration(milliseconds: 200)) _position.value = p;
      }))
      ..add(_player.streams.duration.listen((d) => _duration.value = d))
      ..add(_player.streams.error.listen((e) => setState(() => _error = e.message)));
    LiveFavorites.load();
    // After the first frame: claiming focus updates the shell's mini player.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open();
    });
    _picture.attach();
    _poke();
  }

  // ── turning the screen (a phone or a tablet in the hand), as the film player does ──

  bool _turned = false;

  bool get _turnable => (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) && !PlatformDetector.isTV();

  /// The screen turns the other way and stays so while the channel is open, even with the
  /// phone's rotation lock on.
  void _turn() {
    final size = MediaQuery.sizeOf(context);
    _turned = true;
    unawaited(SystemChrome.setPreferredOrientations(
      size.width > size.height ? const [DeviceOrientation.portraitUp] : const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    ));
    _poke();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hide?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    // the phone follows its own rotation setting again
    if (_turned) unawaited(SystemChrome.setPreferredOrientations(const []));
    if (_fullscreen && isDesktopNative) windowManager.setFullScreen(false);
    AudioFocus.release(this);
    _picture.dispose();
    _listRegion.dispose();
    _player.dispose();
    _position.dispose();
    _duration.dispose();
    super.dispose();
  }

  /// Everyone in your room watches this channel through one connection, on the relay. This player
  /// lets go of it first: most providers allow one at a time, and some take a while to free the
  /// slot, so the relay keeps trying for about half a minute. If it can't get in, this device
  /// opens the channel and sends it to the relay instead.
  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final nav = Navigator.of(context);
    final item = _item;
    showToast(context, const Text('Freeing the channel for your room. This can take up to a minute.', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.groups_rounded);
    try {
      await _player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await PartyLive.host(
        url: item.url,
        title: item.title,
        logo: item.logo,
        onUploading: () {
          if (!mounted) return;
          showToast(context, const Text("Our server couldn't open this channel. Sending it from your device instead.", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.upload_rounded);
        },
      );
    } on LiveShareError catch (e) {
      if (!mounted) return;
      setState(() => _sharing = false);
      showToast(context, Text(e.message, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.error_outline_rounded);
      unawaited(_open());
      return;
    }
    if (!mounted) return; // they left while it opened: the room has it anyway
    nav.pop();
    await openRoom(widget.tab ?? nav, theater: true);
  }

  Future<void> _open() async {
    AudioFocus.claim(this, _player.pause);
    setState(() {
      _error = null;
      _buffering = true;
      _epg = _item.epg?.call();
    });
    try {
      // (Media3 introduces itself to the provider the way mpv does, so a line that plays on one
      // plays on the other)
      await _player.open(Media(_item.url, headers: _player.playerType == 'exoplayer' ? const {'User-Agent': 'libmpv'} : null));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _zap(int dir) {
    if (widget.items.length < 2) return;
    _index = (_index + dir) % widget.items.length;
    _open();
    _poke();
  }

  void _toggle() {
    if (!_playing) AudioFocus.claim(this, _player.pause);
    _player.playOrPause();
    _poke();
  }

  void _setVolume(double v) {
    setState(() => _volume = v);
    _player.setVolume(v);
  }

  void _mute() {
    if (_volume > 0) {
      _lastVolume = _volume;
      _setVolume(0);
    } else {
      _setVolume(_lastVolume == 0 ? 100 : _lastVolume);
    }
  }

  Future<void> _toggleFullscreen() async {
    if (!isDesktopNative) return;
    _fullscreen = !_fullscreen;
    await windowManager.setFullScreen(_fullscreen);
    setState(() {});
  }

  void _back() {
    if (_fullscreen) {
      _toggleFullscreen();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// Double-click is worked out by hand: a GestureDetector onDoubleTap holds every click on the
  /// screen (buttons included) for ~300ms while it waits for a second one.
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
    if (!_chrome) setState(() => _chrome = true);
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing && !_list) {
        setState(() => _chrome = false);
        _picture.toPicture(); // a control that is no longer shown must not keep focus
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final top = _fullscreen ? 0.0 : Layout.windowChrome(context);
    final seek = AppSettings.seekSeconds.value;
    // the channel list opened or closed since the last build: focus follows it
    _picture.menuIs(_list ? _listRegion : null, returned: _poke);
    return CallbackShortcuts(
      bindings: {
        // Back: Escape, a remote's Back, a controller's B. Held, it is still one Back.
        const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): _backKey,
        const SingleActivator(LogicalKeyboardKey.goBack, includeRepeats: false): _backKey,
        const SingleActivator(LogicalKeyboardKey.browserBack, includeRepeats: false): _backKey,
        const SingleActivator(LogicalKeyboardKey.gameButtonB, includeRepeats: false): _backKey,
        const SingleActivator(LogicalKeyboardKey.space): _toggle,
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.keyM): _mute,
        const SingleActivator(LogicalKeyboardKey.keyC): () => setState(() => _list = !_list),
        // a remote's own keys, wherever focus is
        const SingleActivator(LogicalKeyboardKey.channelUp, includeRepeats: false): () => _zap(1),
        const SingleActivator(LogicalKeyboardKey.channelDown, includeRepeats: false): () => _zap(-1),
        const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious, includeRepeats: false): () => _zap(-1),
        const SingleActivator(LogicalKeyboardKey.mediaTrackNext, includeRepeats: false): () => _zap(1),
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause, includeRepeats: false): _toggle,
        const SingleActivator(LogicalKeyboardKey.mediaPlay, includeRepeats: false): () {
          if (!_playing) _toggle();
        },
        const SingleActivator(LogicalKeyboardKey.mediaPause, includeRepeats: false): () {
          if (_playing) _toggle();
        },
        // With focus on the picture (the controls hidden, or a mouse in charge) Up and Down
        // change channel, as always. With focus on a control they move between controls.
        if (_picture.onPicture) ...{
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _zap(-1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _zap(1),
          if (_item.live) ...{
            const SingleActivator(LogicalKeyboardKey.arrowLeft, includeRepeats: false): _enterControls,
            const SingleActivator(LogicalKeyboardKey.arrowRight, includeRepeats: false): _enterControls,
          } else ...{
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seekBy(-seek),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seekBy(seek),
          },
          const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false): _enterControls,
          const SingleActivator(LogicalKeyboardKey.numpadEnter, includeRepeats: false): _enterControls,
          const SingleActivator(LogicalKeyboardKey.select, includeRepeats: false): _enterControls,
          const SingleActivator(LogicalKeyboardKey.gameButtonA, includeRepeats: false): _enterControls,
        },
      },
      child: Focus(
        focusNode: _picture.node,
        autofocus: true,
        child: Scaffold(
          // Transparent: the video is a native surface *behind* Flutter (the player).
          backgroundColor: Colors.transparent,
          body: MouseRegion(
            cursor: _chrome ? MouseCursor.defer : SystemMouseCursors.none,
            onHover: (_) => _poke(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_isDoubleTap()) {
                  _toggleFullscreen();
                } else if (_chrome) {
                  setState(() => _chrome = false);
                } else {
                  _poke();
                }
              },
              child: Stack(children: [
                Positioned.fill(child: VyseVideo(player: _player)),
                if (_buffering && _error == null)
                  const Center(child: SizedBox.square(dimension: 36, child: CircularProgressIndicator(strokeWidth: 2.6, color: VyseColors.accent))),
                if (_error != null) Center(child: _errorCard()),
                // Top: back, title, LIVE.
                _fade(
                  Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      padding: EdgeInsets.fromLTRB(phone ? 12 : 24, top + 12, phone ? 12 : 24, 40),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xCC000000), Color(0x00000000)],
                        ),
                      ),
                      child: DpadRail(onEdge: _picture.toWindowBar, child: Row(children: [
                        GlassIconButton(icon: Icons.arrow_back_rounded, label: 'Back (Esc)', size: 40, onTap: _back),
                        const SizedBox(width: 14),
                        if (_item.logo != null && _item.logo!.isNotEmpty) ...[
                          SizedBox(width: 44, height: 32, child: NetImage(url: _item.logo, fit: BoxFit.contain, fallback: Icons.live_tv_rounded, decodeWidth: NetImage.decodeWidthFor(context, 44))),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(_item.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                            if (_item.subtitle != null)
                              Text(_item.subtitle!,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: VyseColors.textDim)),
                          ]),
                        ),
                        if (_item.live) const _LiveBadge(),
                        // Its star, for a channel from a portal, a playlist or the Favorites list.
                        // (Only a portal's had one, and only in the portal's own list.)
                        if (_item.favoriteKey case final key?) ...[
                          const SizedBox(width: 10),
                          ValueListenableBuilder<Set<String>>(
                            valueListenable: LiveFavorites.ids,
                            builder: (context, ids, _) {
                              final on = ids.contains(key);
                              return GlassIconButton(
                                icon: on ? Icons.star_rounded : Icons.star_border_rounded,
                                label: on ? 'Remove from favorites' : 'Add to favorites',
                                size: 40,
                                onTap: () => LiveFavorites.toggleChannel(FavoriteChannel(key: key, title: _item.title, url: _item.url, logo: _item.logo, from: _item.subtitle)),
                              );
                            },
                          ),
                        ],
                        if (_item.live && Rooms.mine.value != null && WatchParty.canControl) ...[
                          const SizedBox(width: 10),
                          _sharing
                              ? const SizedBox.square(dimension: 40, child: Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white)))
                              : GlassIconButton(icon: Icons.groups_rounded, label: 'Watch with my room', size: 40, onTap: _share),
                        ],
                        if (_turnable) ...[
                          const SizedBox(width: 10),
                          Builder(builder: (context) {
                            final sideways = MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
                            return GlassIconButton(
                              icon: sideways ? Icons.stay_current_portrait_rounded : Icons.screen_rotation_rounded,
                              label: sideways ? 'Turn upright' : 'Turn sideways',
                              size: 40,
                              onTap: _turn,
                            );
                          }),
                        ],
                        if (widget.items.length > 1) ...[
                          const SizedBox(width: 10),
                          GlassIconButton(
                            icon: Icons.list_rounded,
                            label: 'Channels (C)',
                            size: 40,
                            onTap: () => setState(() => _list = !_list),
                          ),
                        ],
                      ])),
                    ),
                  ),
                ),
                // Bottom: EPG / seek, transport, volume, fullscreen.
                _fade(
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      padding: EdgeInsets.fromLTRB(phone ? 12 : 24, 50, phone ? 12 : 24, 18 + MediaQuery.paddingOf(context).bottom),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xE6000000), Color(0x00000000)],
                        ),
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        if (_item.live && _epg != null) _EpgStrip(future: _epg!),
                        if (!_item.live) SeekBar(position: _position, duration: _duration, onSeek: _player.seek),
                        const SizedBox(height: 6),
                        Row(children: [
                          if (widget.items.length > 1)
                            IconButton(tooltip: 'Previous channel (↑)', onPressed: () => _zap(-1), icon: const Icon(Icons.skip_previous_rounded)),
                          // with a D-pad, the controls start here when they come up
                          DpadStart(
                            child: IconButton(
                              tooltip: _playing ? 'Pause' : 'Play',
                              iconSize: 34,
                              onPressed: _toggle,
                              icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                            ),
                          ),
                          if (widget.items.length > 1)
                            IconButton(tooltip: 'Next channel (↓)', onPressed: () => _zap(1), icon: const Icon(Icons.skip_next_rounded)),
                          const SizedBox(width: 8),
                          // (on a TV the remote sets the volume)
                          if (playersHaveVolume)
                          IconButton(
                            tooltip: 'Mute (M)',
                            onPressed: _mute,
                            icon: Icon(_volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded),
                          ),
                          if (!phone && playersHaveVolume)
                            SizedBox(
                              width: 120,
                              child: SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: 3,
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Colors.white.withValues(alpha: .2),
                                  thumbColor: Colors.white,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                                ),
                                // a mouse's slider; a D-pad passes it over (Mute is beside it)
                                child: ExcludeFocus(
                                  excluding: InputModeTracker.isKeyboardMode(context),
                                  child: Slider(value: _volume, max: 100, onChanged: _setVolume),
                                ),
                              ),
                            ),
                          const Spacer(),
                          if (isDesktopNative)
                            IconButton(
                              tooltip: 'Full screen (F)',
                              onPressed: _toggleFullscreen,
                              icon: Icon(_fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
                            ),
                        ]),
                      ]),
                    ),
                  ),
                ),
                // Channel list for zapping.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  top: top + 70,
                  bottom: 110,
                  right: _list ? 16 : -360,
                  width: phone ? 280 : 340,
                  // shut to focus while it is off screen; a region while it is open
                  child: ExcludeFocus(excluding: !_list, child: DpadRegion(node: _listRegion, child: _channelList())),
                ),
                if (isDesktopNative && !_fullscreen)
                  Positioned(top: 0, left: 0, right: 0, child: DpadRegion(node: _picture.windowBar, child: const WindowBar())),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fade(Widget child) => IgnorePointer(
        ignoring: !_chrome,
        // hidden controls are shut to focus as well as to the pointer
        child: ExcludeFocus(
          excluding: !_chrome,
          child: AnimatedOpacity(opacity: _chrome ? 1 : 0, duration: Duration(milliseconds: _chrome ? 110 : 280), child: RepaintBoundary(child: child)),
        ),
      );

  Widget _errorCard() => Glass(
        radius: 18,
        opacity: .8,
        padding: const EdgeInsets.all(22),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.signal_wifi_connected_no_internet_4_rounded, size: 32, color: VyseColors.accentHot),
          const SizedBox(height: 10),
          const Text("This stream isn't playing", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('The source may be offline or busy.', style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
          const SizedBox(height: 14),
          Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton(onPressed: _open, child: const Text('Retry')),
            if (widget.items.length > 1) TextButton(onPressed: () => _zap(1), child: const Text('Next channel')),
          ]),
        ]),
      );

  Widget _channelList() => Glass(
        radius: 18,
        opacity: .82,
        child: ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: widget.items.length,
          itemBuilder: (context, i) {
            final it = widget.items[i];
            final current = i == _index;
            return Pressable(
              autofocus: current, // with a D-pad the list opens on the channel that is on
              onTap: () {
                _index = i;
                _open();
              },
              builder: (context, hovered, _) => Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: current ? VyseColors.accent.withValues(alpha: .16) : Colors.white.withValues(alpha: hovered ? .07 : 0),
                ),
                child: Row(children: [
                  SizedBox(width: 40, height: 28, child: NetImage(url: it.logo, fit: BoxFit.contain, fallback: Icons.live_tv_rounded, decodeWidth: NetImage.decodeWidthFor(context, 40))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(it.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                          color: current ? VyseColors.accent : VyseColors.text,
                        )),
                  ),
                ]),
              ),
            );
          },
        ),
      );
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFE5383B), borderRadius: BorderRadius.circular(5)),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle, size: 7, color: Colors.white),
          SizedBox(width: 5),
          Text('LIVE', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, letterSpacing: .6, color: Colors.white)),
        ]),
      );
}

/// Now / next from the EPG, with a progress bar through the current programme.
class _EpgStrip extends StatelessWidget {
  const _EpgStrip({required this.future});
  final Future<List<EpgEntry>> future;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<EpgEntry>>(
        future: future,
        builder: (context, snap) {
          final now = DateTime.now();
          final list = snap.data ?? const <EpgEntry>[];
          final i = list.indexWhere((e) => !e.start.isAfter(now) && e.stop.isAfter(now));
          if (i < 0) return const SizedBox.shrink();
          final cur = list[i];
          final next = i + 1 < list.length ? list[i + 1] : null;
          final span = cur.stop.difference(cur.start).inSeconds;
          final f = span <= 0 ? 0.0 : (now.difference(cur.start).inSeconds / span).clamp(0.0, 1.0);
          String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('NOW  ', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: VyseColors.accent, letterSpacing: .6)),
                Expanded(
                  child: Text(cur.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                Text('${hm(cur.start)} – ${hm(cur.stop)}', style: const TextStyle(fontSize: 12, color: VyseColors.textDim)),
              ]),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: f,
                  minHeight: 3,
                  backgroundColor: Colors.white.withValues(alpha: .15),
                  color: VyseColors.accent,
                ),
              ),
              if (next != null) ...[
                const SizedBox(height: 6),
                Text('Next  ${hm(next.start)}  ${next.title}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: VyseColors.textDim)),
              ],
            ]),
          );
        },
      );
}
