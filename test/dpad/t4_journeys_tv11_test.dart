// The eleventh round from testers (2026-11-23). docs/dpad/PLAN.md note 102 has the round.
//
// - Fire TV, on Media3: "the screen goes black around 15-20 minutes in every stream ... audio
//   carries on normally" and "It would also keep playing audio when exiting app or putting tv
//   into sleep mode."
// - Overgeared: "today's episode is already available on Stremio but I can't access it on
//   VyseTV due to the listed release date (27 November)".
// - IPTV: "No button or option available to rotate the screen between portrait and landscape".
// - "custom torrent engine settings like PlayTorrio (memory size, preloading)", and the user: "the
//   ability to add my own trackers".
// (Live TV > Portals' pencil, copy and star on a remote: t4_journeys_tv6_test.dart.)
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/platform_detector.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/live_tv/live_tv.dart';
import 'package:vyse_tv/data/phone_edit/phone_settings.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/data/sources/torrents.dart';
import 'package:vyse_tv/data/subtitles/subtitle_style.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/mpv/mpv.dart';
import 'package:vyse_tv/screens/details/episode_explorer.dart';
import 'package:vyse_tv/screens/live_tv/live_tv_player_page.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/widgets/common.dart' show Pressable;
import 'package:wakelock_plus/wakelock_plus.dart' show wakelockPlusPlatformInstance;
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'bed/phase8_pages.dart' show openSettings;
import 'harness.dart';

/// The screen's wake lock, as the plugin would keep it.
class _Lock extends WakelockPlusPlatformInterface {
  bool on = false;

  @override
  Future<void> toggle({required bool enable}) async => on = enable;

  @override
  Future<bool> get enabled async => on;
}

/// The text on the control that has the ring, for Material buttons (a dialog's).
String? _materialFocus() {
  final node = DpadRoot.debugRinged;
  if (node?.context == null) return null;
  String? text;
  void visit(Element e) {
    if (text != null) return;
    if (e.widget is Text) text = (e.widget as Text).data;
    e.visitChildren(visit);
  }

  (node!.context! as Element).visitChildren(visit);
  return text;
}

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
  });
  final tv = OnScreens([Screens.tv]);
  final phone = OnScreens([Screens.phone]);

  group('a film on Media3', () {
    late FakeRoute route;
    late _Lock lock;
    final was = wakelockPlusPlatformInstance;
    setUp(() {
      PlayerEngine.debugOffered = true;
      Player.debugExoOnAnyPlatform = true;
      AppSettings.playerEngine.set('');
      wakelockPlusPlatformInstance = lock = _Lock();
      debugFilmSources = [
        FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/film.mkv', type: 'mkv')]),
      ];
      route = Bed.http.route;
      Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
    });
    tearDown(() {
      PlayerEngine.debugOffered = null;
      Player.debugExoOnAnyPlatform = false;
      wakelockPlusPlatformInstance = was;
      debugFilmSources = null;
      Bed.http.route = route;
    });

    Future<void> playing(WidgetTester t) async {
      await TvDetectionService.getInstance(forceTv: true);
      Bed.exoCalls.clear();
      await Bed.openPlayer(t);
      await Bed.exoProperty(t, 'duration', 5400.0);
      await Bed.exoProperty(t, 'pause', false);
      await t.pump(const Duration(milliseconds: 100));
    }

    testWidgets('the screen stays awake through a stop to load more (Media3 says "not playing" then), and sleeps 30 s after a real pause', (t) async {
      await playing(t);
      expect(lock.on, isTrue, reason: 'playing: awake');
      // a stop to load more, as Media3 tells it: loading, then not playing, for a while
      await Bed.exoProperty(t, 'paused-for-cache', true);
      await Bed.exoProperty(t, 'pause', true);
      await t.pump(const Duration(minutes: 2));
      expect(lock.on, isTrue, reason: 'still loading: the screen saver must not start over the film');
      await Bed.exoProperty(t, 'paused-for-cache', false);
      await Bed.exoProperty(t, 'pause', false);
      expect(lock.on, isTrue);
      // paused for good: a moment's grace, then the TV may sleep
      await Bed.exoProperty(t, 'pause', true);
      await t.pump(const Duration(seconds: 20));
      expect(lock.on, isTrue);
      await t.pump(const Duration(seconds: 15));
      expect(lock.on, isFalse, reason: 'paused 30 s: the screen may sleep again');
      await Bed.closePlayer(t);
      await t.pump(const Duration(seconds: 31)); // (the film sources' timers)
    }, variant: tv);

    testWidgets('the app stopped (Home, the TV going to sleep) pauses the film; the player is there to carry on', (t) async {
      await playing(t);
      Bed.exoCalls.clear();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      expect(Bed.exoCalls.where((c) => c.startsWith('pause')), isNotEmpty, reason: '${Bed.exoCalls}');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(find.byType(PlayerPage), findsOneWidget);
      await Bed.closePlayer(t);
      await t.pump(const Duration(seconds: 31));
    }, variant: tv);
  });

  testWidgets('an episode listed for a later date can still be tried: Try E2, and OK plays it', (t) async {
    final played = <int>[];
    final past = DateTime(2026, 11, 1), later = DateTime.now().add(const Duration(days: 4));
    await t.pumpWidget(Bed.app(Scaffold(
      body: SingleChildScrollView(
        child: EpisodeExplorer.list(
          episodes: Future.value([
            ExplorerEpisode(1, 'The Arrival', 'One.', null, null, past, 24, 0),
            ExplorerEpisode(2, 'The Forge', 'Two.', null, null, later, 24, 0, notOut: true),
          ]),
          onPlay: (e) => played.add(e.number),
        ),
      ),
    )));
    await Bed.settle(t, rounds: 2);
    await Bed.dpadMode(t);
    await Bed.focus(t, find.ancestor(of: find.text('Play E1'), matching: find.byType(Pressable)).first);
    await Bed.right(t);
    await Bed.settle(t, rounds: 2);
    expect(find.text('Try E2'), findsOneWidget, reason: 'listed for later: a try, not a wall');
    expect(Bed.focused(), contains('Try E2'), reason: 'and it takes the ring');
    await Bed.ok(t);
    expect(played, [2]);
    await t.pumpWidget(const SizedBox());
  }, variant: tv);

  testWidgets('a live channel on a phone: Turn sideways turns the screen, whatever the rotation lock says, and it is let go on leaving', (t) async {
    final turns = <Object?>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') turns.add(call.arguments);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    // a phone, not a TV (the tests above ran as one)
    TvDetectionService.debugReset();
    await t.runAsync(() => TvDetectionService.getInstance(forceTv: false));
    addTearDown(TvDetectionService.debugReset);
    await Bed.pumpShell(t);
    const channel = LiveItem(title: 'Harbour News', subtitle: 'Buddy  ·  News', url: 'http://list.test/news.m3u8');
    unawaited(Bed.sectionNavigator(t).push(MaterialPageRoute<void>(builder: (_) => const LiveTvPlayerPage(items: [channel], index: 0))));
    await Bed.settle(t, rounds: 4);
    final turn = find.byWidgetPredicate((w) => w is Pressable && w.tooltip == 'Turn sideways');
    expect(turn, findsOneWidget);
    await Bed.dpadMode(t);
    await Bed.focus(t, turn);
    await Bed.ok(t);
    expect(turns.single, ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
    for (var i = 0; i < 4 && find.byType(LiveTvPlayerPage).evaluate().isNotEmpty; i++) {
      await Bed.back(t);
    }
    expect(find.byType(LiveTvPlayerPage), findsNothing);
    expect(turns.last, isEmpty, reason: 'the phone follows its own setting again');
  }, variant: phone);

  group('Settings > Playback > Torrents', () {
    setUp(() {
      // (a phone, not a TV: the tests above ran as one)
      TvDetectionService.debugReset();
    });
    tearDown(() {
      AppSettings.torrentMemory.value = 0;
      AppSettings.torrentPreload.value = 0;
      AppSettings.torrentConnections.value = 0;
      AppSettings.torrentUpload.value = true;
      AppSettings.publicTrackers.value = true;
      AppSettings.torrentTrackers.value = '';
      TvDetectionService.debugReset();
    });

    testWidgets('memory, what loads before playing, uploading and your trackers, all with a remote; the engine and magnet links take them', (t) async {
      await t.runAsync(() => TvDetectionService.getInstance(forceTv: OnScreens.current == Screens.tv));
      await openSettings(t, 'Playback');
      await Bed.dpadMode(t);
      final memory = Torrents.memoryChoices;
      String size(int mb) => mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB';
      // the default is picked to begin with
      await Bed.focus(t, find.widgetWithText(Pressable, size(Torrents.defaultMemory)).first);
      expect(Bed.focusInView(), isTrue);
      await Bed.picture(t, 'torrents/settings');
      await Bed.right(t);
      final bigger = memory[memory.indexOf(Torrents.defaultMemory) + 1];
      expect(Bed.focused(), contains(size(bigger)));
      await Bed.ok(t);
      expect(AppSettings.torrentMemory.value, bigger);
      expect(Torrents.debugEngineSettings['CacheSize'], bigger << 20, reason: 'the engine is given that much');

      await Bed.down(t);
      expect(Bed.focused(), contains(' MB'), reason: 'Load before playing, under Memory');
      await Bed.right(t);
      await Bed.ok(t);
      expect(AppSettings.torrentPreload.value, greaterThan(Torrents.defaultPreload));
      expect(Torrents.preload, AppSettings.torrentPreload.value);

      // Connections, then the two switches: Upload while watching, Public trackers
      await Bed.down(t);
      await Bed.down(t);
      expect(Bed.focused(), contains('_Switch'));
      await Bed.ok(t);
      expect(AppSettings.torrentUpload.value, isFalse);
      expect(Torrents.debugEngineSettings['DisableUpload'], isTrue);
      await Bed.down(t);
      await Bed.ok(t);
      expect(AppSettings.publicTrackers.value, isFalse);
      expect(Torrents.debugEngineSettings['RetrackersMode'], 0);

      // Your trackers: Add, type them, Down out of the box, Save
      await Bed.down(t);
      expect(Bed.focused(), contains('Add'));
      expect(Bed.focusInView(), isTrue);
      await Bed.ok(t);
      await Bed.settle(t, rounds: 3);
      final box = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
      expect(box, findsOneWidget);
      await t.enterText(box, 'udp://tracker.example.org:1337/announce\nnonsense\nhttp://open.example.net/announce');
      await Bed.settle(t);
      await Bed.picture(t, 'torrents/your_trackers');
      await Bed.down(t);
      if (_materialFocus() != 'Save') await Bed.right(t);
      expect(_materialFocus(), 'Save');
      // (OK by hand: the toast is up for under 2 s, and Bed.ok waits longer than that)
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Left out 1'), findsOneWidget, reason: 'what was not a tracker is said, not saved');
      await Bed.settle(t, rounds: 3);
      expect(find.byType(AlertDialog), findsNothing);
      expect(AppSettings.torrentTrackers.value, 'udp://tracker.example.org:1337/announce\nhttp://open.example.net/announce');
      expect(find.text('2 added to every torrent'), findsOneWidget);
      expect(Bed.focused(), contains('Edit'), reason: 'the ring is back on the button, which now edits');

      final magnet = Torrents.magnet('0123456789abcdef0123456789abcdef01234567');
      expect(magnet, contains('tr=${Uri.encodeQueryComponent('udp://tracker.example.org:1337/announce')}'));
      expect(magnet, contains('tr=${Uri.encodeQueryComponent('http://open.example.net/announce')}'));
      expect(magnet, isNot(contains('opentrackr')), reason: 'public trackers are off');
      await t.pump(const Duration(seconds: 4)); // (the toast)
    }, variant: OnScreens([Screens.tv, Screens.phone, Screens.laptop]));

    test('trackers from the phone: split by spaces, commas or lines; anything else left out; empty clears them', () async {
      final item = phoneSections(fonts: const [SubtitleStyle.defaultFont]).expand((s) => s.items).firstWhere((i) => i.id == 'play.trackers');
      await item.take({'v': 'udp://a.example:6969/announce, junk wss://b.example/announce'});
      expect(AppSettings.torrentTrackers.value, 'udp://a.example:6969/announce\nwss://b.example/announce');
      expect(Torrents.yourTrackers, hasLength(2));
      await item.take({'v': ''});
      expect(AppSettings.torrentTrackers.value, '');
      // the memory choice is offered as this device's options, the default picked
      final mem = phoneSections(fonts: const [SubtitleStyle.defaultFont]).expand((s) => s.items).firstWhere((i) => i.id == 'device.torrent.memory');
      expect(mem.toJson()['value'], Torrents.defaultMemory);
    });
  });
}
