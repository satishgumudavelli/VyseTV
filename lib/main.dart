import 'dart:async';

import 'core/accent.dart';
import 'data/account/account.dart';
import 'data/account/account_sync.dart';
import 'data/sources/addons.dart' show Addons;
import 'data/sources/badges.dart' show Badges;
import 'data/audiobooks/audiobook_player.dart' show AudiobookPlayer;
import 'data/manga/manga_library.dart' show MangaFavorites, MangaHistory;
import 'data/party/alerts.dart' show PartyAlerts;
import 'data/party/dms.dart' show Dms;
import 'data/party/friends.dart' show Friends;
import 'data/party/party.dart' show PartyPresence;
import 'data/party/party_live.dart' show PartyLive;
import 'data/party/party_music.dart' show PartyMusic;
import 'data/party/lounges.dart' show Lounges;
import 'data/party/rooms.dart' show Rooms;
import 'data/party/voice.dart' show Voice;
import 'data/party/watch_party.dart' show WatchParty;
import 'data/app_settings.dart';
import 'data/catalog/tmdb.dart' show MyList;
import 'data/downloads/downloads.dart';
import 'data/sources/torrents.dart' show Torrents;
import 'data/music/music_library.dart' show MusicLibrary;
import 'data/sources/debrid/debrid.dart' show Debrid;
import 'data/playback/watch_progress.dart';
import 'data/trackers/tracker_hub.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:window_manager/window_manager.dart';

import 'core/layout.dart';
import 'core/lean.dart';
import 'core/nav.dart' show rootNavigatorKey;
import 'core/logs/perf.dart';
import 'core/theme.dart';
import 'dpad/dpad_root.dart';
import 'dpad/input_mode_tracker.dart';
import 'core/platform/device_performance.dart';
import 'core/platform/platform_detector.dart' show PlatformDetector, TvDetectionService;
import 'screens/home/up_next.dart' show UpNext;
import 'screens/shell/intro_screen.dart';
import 'services/iptv/iptv_settings.dart';

/// Phones: no status bar or navigation buttons. A swipe from the edge shows them for a moment
/// (sticky immersive); anything that brings them back for good gets them hidden again.
void _hideSystemBars() => SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

Future<void> main() async {
  VyseBinding.ensureInitialized(); // (Flutter's own, with reduce-motion in the app's hands: core/lean.dart)
  // Android TV and Google TV: known before anything is drawn, so the app opens in D-pad mode
  // there, with the ring on its first control
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      await TvDetectionService.getInstance();
    } catch (_) {}
    // Upstream's lighter tier for weak boxes (a 32-bit system, or about 2 GB of memory): no glow
    // round the focused control, focus moves at once instead of animating, smaller caches.
    // It was in the app but never asked, so every TV got the full tier.
    try {
      await DevicePerformance.getInstance();
    } catch (_) {}
  }
  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
    _hideSystemBars();
    SystemChrome.setSystemUIChangeCallback((barsShowing) async {
      if (barsShowing) Future.delayed(const Duration(seconds: 3), _hideSystemBars);
    });
    AppLifecycleListener(onResume: _hideSystemBars); // registers itself for the app's lifetime
    // 90/120 Hz screens: Android otherwise keeps Flutter apps at 60 Hz. (Not on a TV: asking
    // for its fastest mode can switch the TV's picture mode as the app starts.)
    if (defaultTargetPlatform == TargetPlatform.android && !PlatformDetector.isTV()) {
      try {
        await FlutterDisplayMode.setHighRefreshRate();
      } catch (_) {}
    }
  }
  await IptvSettings.initialize();
  await AppSettings.initialize();
  // On a TV the interface is drawn the lean way (fewer frames, less paint), unless Settings says not
  Lean.decide();
  await Torrents.initialize(); // iPhone and iPad: is the engine in this build (instant elsewhere)
  unawaited(Downloads.instance.initialize()); // the saved list; nothing starts by itself
  Addons.start();
  Badges.start();
  await WatchProgress.initialize();
  await UpNext.initialize(); // Continue watching's next episodes, as last found
  await MyList.initialize();
  await MusicLibrary.initialize();
  await Debrid.initialize();
  await Account.initialize();
  PartyPresence.start();
  Friends.start();
  Dms.start();
  Rooms.start();
  Lounges.start();
  Voice.start();
  WatchParty.start();
  PartyMusic.start();
  PartyLive.start();
  unawaited(PartyAlerts.start());
  await AccountSync.initialize([
    SyncSource(
      kind: 'progress',
      snapshot: WatchProgress.syncSnapshot,
      apply: WatchProgress.syncApply,
      changes: WatchProgress.entries,
      timeOf: (d) => (d['u'] as num?)?.toInt(),
      merge: WatchProgress.syncMerge,
    ),
    SyncSource(
      kind: 'mylist',
      snapshot: MyList.syncSnapshot,
      apply: MyList.syncApply,
      changes: MyList.items,
      timeOf: (d) => (d['a'] as num?)?.toInt(),
    ),
    SyncSource(
      kind: 'settings',
      snapshot: AppSettings.syncSnapshot,
      apply: AppSettings.syncApply,
      changes: AppSettings.anySynced,
      remoteWinsFirst: true,
    ),
    SyncSource(kind: 'manga_fav', snapshot: MangaFavorites.syncSnapshot, apply: MangaFavorites.syncApply, changes: MangaFavorites.items),
    SyncSource(
      kind: 'manga_read',
      snapshot: MangaHistory.syncSnapshot,
      apply: MangaHistory.syncApply,
      changes: MangaHistory.revision,
      timeOf: (d) => (d['t'] as num?)?.toInt(),
    ),
    SyncSource(
      kind: 'audiobooks',
      snapshot: AudiobookPlayer.syncSnapshot,
      apply: AudiobookPlayer.syncApply,
      changes: AudiobookPlayer.syncRevision,
    ),
    ...MusicLibrary.syncSources,
  ]);
  // Trakt, Simkl, AniList: sign-ins on this device, and updates still waiting to go out
  unawaited(TrackerHub.initialize());

  // Full-screen backdrops are ~15 MB each at 1440p. With Flutter's default 100 MB cache, flipping
  // in and out of the spotlight evicted and re-decoded them (and the posters) mid-animation,
  // which measured as 200-800 ms stalls. Desktops have the memory to keep them.
  final cache = PaintingBinding.instance.imageCache;
  if (isDesktopNative || kIsWeb) {
    cache.maximumSizeBytes = 768 << 20;
    cache.maximumSize = 3000;
    // The GPU-side texture cache is sized from the screen (~175 MB at 1440p), so the same
    // images were being evicted from VRAM and re-uploaded on every spotlight transition.
    if (isDesktopNative) {
      SystemChannels.skia.invokeMethod<void>('Skia.setResourceCacheMaxBytes', 1024 << 20);
    }
  } else if (DevicePerformance.isReduced) {
    // a weak box (see above): upstream's figure for them
    cache.maximumSize = 400;
    cache.maximumSizeBytes = 64 << 20;
  } else if (PlatformDetector.isTV()) {
    // TV boxes share little memory with the video decoder's 4K buffers. Upstream, which runs on
    // them, keeps 64 to 128 MB; half of a phone's here.
    cache.maximumSize = 500;
    cache.maximumSizeBytes = 128 << 20;
  } else {
    cache.maximumSizeBytes = 256 << 20;
  }

  if (isDesktopNative) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      title: 'VyseTV',
      size: Size(1440, 900),
      minimumSize: Size(400, 640),
      center: true,
      backgroundColor: VyseColors.bg,
      titleBarStyle: TitleBarStyle.hidden,
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
      if (isMacNative) macFullScreen.value = await windowManager.isFullScreen();
    });
    if (isMacNative) windowManager.addListener(_MacFullScreenWatch());
  }

  runApp(const VyseApp());
  startPerfLog();
}

class VyseApp extends StatelessWidget {
  const VyseApp({super.key, this.home = const IntroScreen()});

  /// The first page: the intro, which leads to the shell. Tests start further in.
  final Widget home;

  // InputModeTracker knows whether a remote (or the keyboard's arrows) or a pointer is in
  // charge. Focus is only ever drawn for the first; a mouse or a finger sees no change.
  @override
  Widget build(BuildContext context) => InputModeTracker(
        child: MaterialApp(
          title: 'VyseTV',
          navigatorKey: rootNavigatorKey,
          debugShowCheckedModeBanner: false,
          theme: buildVyseTheme(),
          scrollBehavior: const VyseScrollBehavior(),
          home: home,
          builder: (context, child) => MacFullScreenScope(child: withThemeAccent(DpadRoot(onBack: () => rootNavigatorKey.currentState?.maybePop(), child: child ?? const SizedBox.shrink()))),
        ),
      );
}

/// Keeps [macFullScreen] in step with the Mac window.
class _MacFullScreenWatch with WindowListener {
  @override
  void onWindowEnterFullScreen() => macFullScreen.value = true;

  @override
  void onWindowLeaveFullScreen() => macFullScreen.value = false;
}
