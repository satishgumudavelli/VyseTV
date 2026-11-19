// The D-pad test bed. It builds the real app shell with made-up data (no network, no disk
// outside build/), at the sizes people use, and can photograph what it built.
//
// Each test file is one platform: `lightEffects` and friends are worked out once per run, so a
// file boots as Windows (desktop) or Android (phone, TV) and stays that way.
//
// Never opens lib/services or lib/models; what it needs from them it reaches through the
// screens and lib/data.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vyse_tv/core/nav.dart';
import 'package:vyse_tv/core/nav_sections.dart';
import 'package:vyse_tv/data/anime/anilist.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/audiobooks/audiobook_player.dart';
import 'package:vyse_tv/data/downloads/downloads.dart';
import 'package:vyse_tv/data/manga/manga_library.dart';
import 'package:vyse_tv/data/music/music_library.dart';
import 'package:vyse_tv/models/audiobook/audiobook_model.dart';
import 'package:vyse_tv/models/manga/manga.dart';
import 'package:vyse_tv/models/manga/manga_chapter.dart';
import 'package:vyse_tv/models/music/music_track.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/data/updates/updater.dart';
import 'package:vyse_tv/data/playback/watch_progress.dart';
import 'package:vyse_tv/main.dart' show VyseApp;
import 'package:vyse_tv/dpad/dpad_reveal.dart';
import 'package:vyse_tv/dpad/dpad_root.dart';
import 'package:vyse_tv/dpad/dpad_traversal.dart';
import 'package:vyse_tv/dpad/focusable_wrapper.dart';
import 'package:vyse_tv/dpad/input_mode_tracker.dart';
import 'package:vyse_tv/screens/player/player_page.dart';
import 'package:vyse_tv/screens/shell/shell.dart';

import 'bed/fake_anilist.dart';
import 'bed/fake_net.dart';
import 'bed/fake_tmdb.dart';
import 'bed/walker.dart';

export 'bed/fake_net.dart';
export 'bed/fake_tmdb.dart';

/// A window to test in.
class Screen {
  const Screen(this.name, this.size);
  final String name;
  final Size size;

  /// What goes into file names: `desktop_1440x900`.
  String get tag => '${name}_${size.width.toInt()}x${size.height.toInt()}';

  @override
  String toString() => tag;
}

/// The sizes the plan names. A TV is 960x540 points (1080p at 2x), which today lays out as
/// "tablet"; the phone is a tall one.
abstract final class Screens {
  static const desktop = Screen('desktop', Size(1440, 900));
  static const laptop = Screen('laptop', Size(1280, 720));
  static const tv = Screen('tv', Size(960, 540));
  static const phone = Screen('phone', Size(390, 844));

  /// For a file booted as Windows.
  static const windows = [desktop, laptop];

  /// For a file booted as Android.
  static const android = [tv, phone];
}

/// Runs a test once per screen: `testWidgets('…', (t) async {…}, variant: OnScreens(Screens.windows))`.
/// Sets the window size and the platform before the test and puts both back after.
class OnScreens extends TestVariant<Screen> {
  OnScreens(this.values);

  @override
  final List<Screen> values;

  /// The screen of the test that is running.
  static Screen current = Screens.desktop;

  @override
  String describeValue(Screen value) => value.tag;

  @override
  Future<Object?> setUp(Screen value) async {
    current = value;
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
    view.physicalSize = value.size;
    view.devicePixelRatio = 1;
    debugDefaultTargetPlatformOverride = Bed.platform;
    return null;
  }

  @override
  Future<void> tearDown(Screen value, Object? memento) async {
    debugDefaultTargetPlatformOverride = null;
    TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!.reset();
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.dir);
  final String dir;

  @override
  Future<String?> getTemporaryPath() async => dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getApplicationCachePath() async => dir;
  @override
  Future<String?> getDownloadsPath() async => dir;
}

abstract final class Bed {
  /// The platform this test file runs as. Set by [boot].
  static TargetPlatform platform = TargetPlatform.windows;

  static late FakeHttp http;
  static late FakeImages images;

  /// Around the whole app: what [golden] and [picture] photograph.
  static final frame = GlobalKey(debugLabel: 'bed frame');

  /// Where pictures meant for looking at go (ignored by git, like the rest of docs/).
  static const pictureDir = 'docs/dpad/pictures';

  /// What the D-pad watchdog said (lib/dpad/dpad_root.dart): each time D-pad mode had
  /// no focus for more than a frame, for how long and on which page.
  static final watchdog = <String>[];

  /// Call from `setUpAll`. [route] answers requests the made-up TMDB doesn't.
  ///
  /// [warm] false leaves Home's answers unasked, so the first test to open Home waits for them
  /// as an app that has just started does (with [FakeHttp.delay], as long as a slow TV or a slow
  /// network makes it). Only the first such test in a file: the answers are then kept for the run.
  /// [returning] false is a fresh install: nothing in progress, nothing on My List.
  static Future<void> boot({required TargetPlatform as, FakeRoute? route, bool warm = true, bool returning = true}) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    platform = as;
    DpadRoot.watchdogLog = watchdog.add;
    HttpOverrides.global = http = FakeHttp((method, uri) => route?.call(method, uri) ?? fakeTmdb(method, uri) ?? _other(method, uri));
    CachedNetworkImageProvider.defaultCacheManager = images = FakeImages();

    // a folder of its own for anything that asks where to keep files
    final dir = Directory('build/dpad_bed')..createSync(recursive: true);
    // a fresh install: no download list left over from another run
    final stale = File('${dir.path}/downloads.json');
    if (stale.existsSync()) stale.deleteSync();
    PathProviderPlatform.instance = _Paths(dir.absolute.path);
    _quietPlugins();

    await _fonts(dir);

    SharedPreferences.setMockInitialValues(returning ? _savedState() : {});
    await AppSettings.initialize();
    await WatchProgress.initialize();
    await MyList.initialize();

    // The updater starts timers the first time the shell asks for it. Started here, outside any
    // test, they belong to no test (a test may not end with a timer still running), and with
    // the automatic check off for that moment nothing goes looking for a new version.
    PackageInfo.setMockInitialValues(appName: 'VyseTV', packageName: 'com.vyse.vyse_tv', version: '1.0.0', buildNumber: '3', buildSignature: '');
    final auto = AppSettings.updateAuto.value;
    AppSettings.updateAuto.value = false;
    await Updater.instance.initialize();
    AppSettings.updateAuto.value = auto;
    if (warm) await _warm();
  }

  /// Every title in the made-up catalogue.
  static final catalogue = <Media>[
    for (final tv in const [false, true])
      for (var n = 0; n < 80; n++) Media.fromJson(fakeTitle(n, tv: tv), tv: tv),
  ];

  static int _handedOut = 0;

  /// A title no test in this run has played yet. The source lookups remember each title's
  /// answer for the whole run, and an answer first asked for in one test never arrives in the
  /// next (it belongs to that test's clock), so every player a test opens gets its own title.
  static Media freshTitle({bool series = false}) => catalogue[(series ? 80 : 0) + 20 + (_handedOut++ % 60)];

  /// Asks for everything the app keeps (HomeFeed remembers each answer for the whole run) now,
  /// outside any test. An answer first asked for inside a test belongs to that test's clock and
  /// would never arrive in the next one; asked for here, it is simply there.
  static Future<void> _warm() async {
    final f = HomeFeed.instance;
    await Future.wait<Object?>([
      f.hero(), f.topMoviesToday(), f.providers(), f.popularTv(), f.nowPlaying(), f.topTvToday(), f.anime(), f.topRated(), f.upcoming(), f.trendingToday(),
      for (final g in homeGenres) f.genre(g.id),
      for (final m in catalogue) ...[f.details(m), f.logo(m), f.phoneArt(m), f.because(m)],
      for (var id = 500; id < 512; id++) f.person(id),
    ]);
  }

  /// Calls to native code nobody is there to take: the channel's name, and for the app's own
  /// method channels what was asked of it ("vyse/text_input setNativeTextInputFocused true").
  static final nativeCalls = <String>[];

  /// What the player asked of the video engine, oldest first ("seek {…}"): how a test sees a
  /// seek or a pause, with no video there to watch.
  static final videoCalls = <String>[];

  /// The same for the Media3 engine, which has a channel of its own: what an Android TV's
  /// player asks of it ("open {…}", "setSubtitleStyle {…}").
  static final exoCalls = <String>[];

  /// What the Media3 plugin answers when the app asks it something, by the call's name
  /// ('getStats': what it says of the video). Anything not listed gets "done, nothing to say".
  static final exoAnswers = <String, Object?>{};

  /// The same for the device channel ('getPlaybackCapabilities': what the TV can do with HDR).
  static final deviceAnswers = <String, Object?>{};

  /// What the Media3 plugin tells the app by itself, as it arrives from Android: an event
  /// ('backend-switched', once it has handed the video to mpv, with what for).
  static Future<void> exoEvent(WidgetTester t, String name, [Map<String, Object?>? data]) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'vyse/exo_player/events',
      const StandardMethodCodec().encodeSuccessEnvelope(<String, Object?>{'type': 'event', 'name': name, 'data': ?data}),
      (_) {},
    );
    await t.pump();
  }

  /// The same for mpv's own channel (a phone's or a desktop's player): an event as mpv sends it
  /// ('file-loaded', once the file is open).
  static Future<void> videoEvent(WidgetTester t, String name, [Map<String, Object?>? data]) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'vyse/mpv_player/events',
      const StandardMethodCodec().encodeSuccessEnvelope(<String, Object?>{'type': 'event', 'name': name, 'data': ?data}),
      (_) {},
    );
    await t.pump();
  }

  /// A property the plugin reports ('duration', in seconds: the video has been opened), under
  /// the number the player asked to hear of it by (so: after the player is open, and with
  /// [exoCalls] not cleared since).
  static Future<void> exoProperty(WidgetTester t, String name, Object? value) async {
    final asked = exoCalls.lastWhere((c) => c.startsWith('observeProperty ') && c.contains('name: $name,'));
    final id = int.parse(RegExp(r'id: (\d+)').firstMatch(asked)![1]!);
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'vyse/exo_player/events',
      const StandardMethodCodec().encodeSuccessEnvelope(<Object?>[id, value]),
      (_) {},
    );
    await t.pump();
  }

  /// The same for the two audio engines (music, and audiobooks on the second): each call starts
  /// with its channel's last part ("mpv_audio_player_2 stop").
  static final audioCalls = <String>[];

  /// The app's plugins (players, the window, notifications) have no native side in a test. Every
  /// call to one gets "done, nothing to say" instead of a missing-plugin error, and is noted in
  /// [nativeCalls]. Flutter's own channels and anything a test mocks itself are left alone.
  static void _quietPlugins() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const methods = StandardMethodCodec();
    const messages = StandardMessageCodec();
    messenger.allMessagesHandler = (channel, handler, message) {
      if (handler != null) return handler(message);
      if (channel.startsWith('flutter/')) return messenger.delegate.send(channel, message);
      if (channel.startsWith('vyse/') && message != null) {
        try {
          final call = methods.decodeMethodCall(message);
          nativeCalls.add('$channel ${call.method} ${call.arguments ?? ''}'.trim());
        } catch (_) {
          nativeCalls.add(channel);
        }
      } else {
        nativeCalls.add(channel);
      }
      // pigeon channels answer with a list holding the result; method channels with an envelope
      if (channel.startsWith('dev.flutter.pigeon.')) return Future.value(messages.encodeMessage(<Object?>[null]));
      // The stand-in for the video: mpv's native side is not here, so its channel says "yes,
      // started" and then takes every command without doing anything. The player page builds
      // and behaves as it does while a title is still loading.
      if ((channel.startsWith('vyse/mpv') || channel.startsWith('vyse/exo_player')) && message != null) {
        try {
          final call = methods.decodeMethodCall(message);
          if (channel == 'vyse/mpv_player') videoCalls.add('${call.method} ${call.arguments ?? ''}'.trim());
          // (the Media3 engine's own channel: an Android TV's player, unless Settings says mpv)
          if (channel == 'vyse/exo_player') exoCalls.add('${call.method} ${call.arguments ?? ''}'.trim());
          if (channel.startsWith('vyse/mpv_audio_player')) audioCalls.add('${channel.substring('vyse/'.length)} ${call.method} ${call.arguments ?? ''}'.trim());
          if (call.method == 'initialize') return Future.value(methods.encodeSuccessEnvelope(true));
          if (channel == 'vyse/exo_player' && exoAnswers.containsKey(call.method)) return Future.value(methods.encodeSuccessEnvelope(exoAnswers[call.method]));
        } catch (_) {}
      }
      if (channel == 'vyse/device' && message != null && deviceAnswers.isNotEmpty) {
        try {
          final call = methods.decodeMethodCall(message);
          if (deviceAnswers.containsKey(call.method)) return Future.value(methods.encodeSuccessEnvelope(deviceAnswers[call.method]));
        } catch (_) {}
      }
      return Future.value(methods.encodeSuccessEnvelope(null));
    };
  }

  /// Whether AniList answers (see [withContent]). Off, the Anime page shows "Couldn't reach
  /// AniList", which is what the pointer-mode baseline pictures were taken with.
  static bool _anilist = false;

  /// Fills the pages that are empty on a fresh install, for the tests that walk them: AniList
  /// answers with a made-up catalogue, and Downloads holds one finished, one paused and one
  /// failed download. Call it once, after [boot], in `setUpAll`. (The baseline pictures are
  /// taken without it.)
  static Future<void> withContent() async {
    _anilist = true;
    // lists the app asks for once and keeps: asked for here, outside any test (see _warm)
    await Future.wait<Object?>([AniList.genres(), AniList.tags(), AniList.streamingSites()]);

    // In a folder of this run's own: the bed's usual folder is shared by every test file, and
    // a download list left there would turn up on the fresh install the baseline pictures need.
    final dir = Directory.systemTemp.createTempSync('vyse_dpad_');
    final film = File('${dir.path}/Far Country.mkv')..writeAsBytesSync(const [0, 1, 2, 3]);
    Map<String, Object?> item(String id, String title, String state, {String? error, int received = 0, int total = 0, String? path}) => {
      'id': id,
      'title': title,
      'detail': '1080p',
      'poster': 'https://image.tmdb.org/t/p/w342/p$id.jpg',
      'kind': 'file',
      'url': 'https://files.example/$id.mkv',
      'path': path ?? '${dir.absolute.path}${Platform.pathSeparator}$title.mkv',
      'added': DateTime(2026, 11, 1).toIso8601String(),
      'state': state,
      'received': received,
      'total': total,
      'error': error,
    };
    File('${dir.path}/downloads.json').writeAsStringSync(jsonEncode([
      item('d1', 'Far Country', 'done', received: 4, total: 4, path: film.absolute.path),
      item('d2', 'Kite Season', 'paused', received: 300 << 20, total: 900 << 20),
      item('d3', 'The Lamplighter', 'failed', error: 'The file is no longer there', received: 10 << 20, total: 700 << 20),
    ]));
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.absolute.path);
    await Downloads.instance.initialize();
    PathProviderPlatform.instance = paths;

    // Music: liked songs, a playlist of your own and some history. Manga: three favourites.
    // Audiobooks: two books in progress. All kept on the device, so no made-up server.
    await MusicLibrary.initialize();
    for (final t in tracks.take(8)) {
      MusicLibrary.setLiked(t, true);
    }
    MusicLibrary.createPlaylist('Road trip', description: 'Made up for the tests', tracks: tracks.skip(4).take(10).toList());
    MusicLibrary.history.value = [for (final t in tracks.skip(10).take(6)) LikedSong(t, DateTime(2026, 11, 10))];
    await MangaFavorites.load();
    MangaFavorites.items.value = manga;
    AudiobookPlayer.instance.recents.value = [
      for (var i = 0; i < 2; i++) BookProgress(books[i], i, Duration(minutes: 12 + i * 9), 'Chapter ${i + 1}'),
    ];
  }

  /// Made-up songs, manga and audiobooks for the pages that take one.
  static final tracks = <MusicTrack>[
    for (var i = 0; i < 120; i++)
      MusicTrack(
        id: 'song$i',
        title: const ['Kite Season', 'Blue Hour', 'Far Country', 'Marrow', 'Ninety East', 'Greywater', 'Last Light', 'Stillwater', 'The Fold', 'Glasshouse'][i % 10] + (i < 10 ? '' : ' (take ${i ~/ 10})'),
        artist: const ['The Lamplighters', 'Mara Ellison', 'Old Harbour'][i % 3],
        album: const ['Understory', 'Borrowed Time'][i % 2],
        coverUrl: 'https://img.music.example/cover$i.jpg',
        durationSeconds: 180 + i * 7,
      ),
  ];
  static final manga = <Manga>[
    for (var i = 0; i < 3; i++) Manga(id: 'manga$i', title: const ['Paper Lanterns', 'Iron Sparrow', 'Glass Orchard'][i], url: 'https://manga.example/series/$i'),
  ];
  static final chapters = <MangaChapter>[
    for (var i = 1; i <= 4; i++) MangaChapter(id: 'ch$i', rawName: 'Chapter $i', url: 'https://manga.example/series/0/chapter/$i'),
  ];
  static final bookChapters = <AudiobookChapter>[
    for (var i = 1; i <= 6; i++) AudiobookChapter(title: 'Chapter $i', url: 'https://books.example/0/chapter$i.mp3'),
  ];
  static final books = <Audiobook>[
    for (var i = 0; i < 3; i++)
      Audiobook(
        audioBookId: 'book$i',
        coverImage: 'https://img.books.example/cover$i.jpg',
        dynamicSlugId: 'slug$i',
        pageUrl: 'https://books.example/$i',
        source: 'made-up',
        title: const ['The Weather Station', 'Borrowed Time', 'Harbor of Stars'][i],
        uuid: 'uuid$i',
      ),
  ];

  static FakeReply? _other(String method, Uri uri) {
    if (uri.host == 'graphql.anilist.co' && _anilist) return FakeReply.json(fakeAniList());
    // the app's font, asked for by google_fonts when it isn't on disk yet
    if (uri.host == 'fonts.gstatic.com') return FakeReply(200, File('test/dpad/fonts/Inter-Regular.ttf').readAsBytesSync(), type: 'font/ttf');
    final path = uri.path.toLowerCase();
    if (path.endsWith('.jpg') || path.endsWith('.jpeg') || path.endsWith('.png') || path.endsWith('.webp')) {
      return FakeReply(200, fakePicture('$uri'), type: 'image/png');
    }
    return null;
  }

  /// The app's own font (Inter, as google_fonts would fetch it) and the icon font. Without
  /// them text is boxes and far too wide.
  static Future<void> _fonts(Directory dir) async {
    final inter = File('test/dpad/fonts/Inter-Regular.ttf').readAsBytesSync();
    // where google_fonts looks before it goes to the network: <support dir>/<family>_<hash>.ttf
    File('${dir.path}/Inter_regular_${sha256.convert(inter)}.ttf').writeAsBytesSync(inter);
    GoogleFonts.inter();
    await GoogleFonts.pendingFonts();
    final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    // Known limit: a few labels replace the theme's text style outright and so name no font.
    // The real app draws them in the system font (Segoe UI on Windows); a test has no system
    // fonts and draws them as boxes. The engine offers no way to name a font for that case.
  }

  /// What a returning user has on this device: a few titles in progress and a list.
  static Map<String, Object> _savedState() {
    final now = DateTime.now();
    Media title(int n, {required bool tv}) => Media.fromJson(fakeTitle(n, tv: tv), tv: tv);
    final watching = [
      for (var i = 0; i < 6; i++)
        WatchEntry(
          media: title(30 + i, tv: i.isOdd),
          position: Duration(minutes: 12 + i * 7),
          duration: const Duration(minutes: 96),
          updated: now.subtract(Duration(days: i, hours: 2)),
          season: i.isOdd ? 1 : null,
          episode: i.isOdd ? 2 + i : null,
          episodeName: i.isOdd ? 'Chapter ${2 + i}' : null,
        ),
    ];
    final list = [
      for (var i = 0; i < 14; i++)
        {
          'm': {...fakeTitle(10 + i, tv: i % 3 == 0), 'title': fakeTitle(10 + i, tv: i % 3 == 0)[i % 3 == 0 ? 'name' : 'title'], 'tv': i % 3 == 0, 'date': '${2012 + i}-05-01'},
          'a': now.subtract(Duration(days: i * 3)).millisecondsSinceEpoch,
        },
    ];
    return {
      'watch.progress': jsonEncode([for (final e in watching) e.toJson()]),
      'mylist.items': jsonEncode(list),
    };
  }

  // ───────────────────────── Building ─────────────────────────

  /// The app around [home], exactly as lib/main.dart builds it.
  static Widget app(Widget home) => RepaintBoundary(key: frame, child: VyseApp(home: home));

  /// The whole app from the shell down, on its first section (Home), loaded and at rest.
  static Future<void> pumpShell(WidgetTester t) async {
    await t.pumpWidget(app(const AppShell()));
    await settle(t);
  }

  /// Switches to a navbar section the way a user does: by pressing it.
  /// Lets real input and output finish, then the frames after it. The bed's clock is fake but
  /// the network is not: Servers and its Jellyfin box look for servers on the local network
  /// with real sockets as they open, and on a busy machine a test could otherwise catch the
  /// page before or after the answer.
  /// Only real time passes: the bed's clock stands still, so anything animating is drawn where
  /// it would have been (a page's picture is compared with the one taken before any of this).
  /// With [until], real time passes in steps until it holds (a busy machine takes longer).
  static Future<void> realIo(WidgetTester t, {bool Function()? until, Duration wait = const Duration(milliseconds: 400)}) async {
    if (until == null) {
      await t.runAsync(() => Future<void>.delayed(wait));
      await t.pump(); // what came back, drawn
      return;
    }
    for (var i = 0; i < 50 && !until(); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump();
    }
  }

  /// Servers and its Jellyfin box show "Looking for servers on your network" while they look.
  static bool get lookedForServers => find.textContaining('Looking for servers').evaluate().isEmpty;

  static Future<void> openSection(WidgetTester t, String id) async {
    final Finder item;
    if (OnScreens.current.size.width < 640) {
      item = find.descendant(of: find.byType(BottomBar), matching: find.text(navItem(id).label));
      await t.scrollUntilVisible(item, 120, scrollable: find.descendant(of: find.byType(BottomBar), matching: find.byType(Scrollable)));
    } else {
      item = find.descendant(of: find.byType(SideRail), matching: find.byKey(ValueKey(id)));
    }
    // the rail scrolls when the window is short
    await t.ensureVisible(item);
    await t.pump();
    expect(item.hitTestable(), findsOneWidget, reason: 'the navbar entry for "$id" cannot be pressed');
    await t.tap(item);
    await settle(t);
    if (id == 'servers') await realIo(t, until: () => lookedForServers);
  }

  /// The navigator of the section on screen (pages inside the shell are pushed on it).
  static NavigatorState sectionNavigator(WidgetTester t) {
    final all = t.stateList<NavigatorState>(find.byType(Navigator)).toList();
    return all.lastWhere((n) => n != rootNavigatorKey.currentState);
  }

  /// Opens [page] inside the section on screen, as a card or a link would.
  static Future<void> push(WidgetTester t, Widget page) async {
    unawaited(sectionNavigator(t).push(ShellRoute<void>(child: page)));
    await settle(t);
  }

  /// Opens the video player over the app, on a title of its own (see [freshTitle]). The video
  /// engine is a stand-in that answers "started" and plays nothing, so the page stays as it
  /// is while sources are looked for: every control and menu is there.
  static Future<void> openPlayer(WidgetTester t, {bool series = false}) async {
    await pumpShell(t);
    unawaited(rootNavigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => PlayerPage(media: freshTitle(series: series), episode: series ? const PlayerEpisode(season: 1, number: 1) : null),
    )));
    await settle(t, rounds: 6);
    expect(find.byType(PlayerPage), findsOneWidget);
  }

  /// Leaves the player the way a person does (Back until its page is gone), if the test has
  /// not already. A player torn down in mid-flight goes on talking to a video engine that is
  /// gone, and the stand-in's silence then surfaces as an error in whichever test runs next.
  static Future<void> closePlayer(WidgetTester t) async {
    for (var i = 0; i < 5 && find.byType(PlayerPage).evaluate().isNotEmpty; i++) {
      await back(t);
    }
    expect(find.byType(PlayerPage), findsNothing);
    await settle(t, rounds: 4);
  }

  /// Lets the page finish what it started: requests answer, pictures decode, entrances play.
  /// The test clock moves by exactly [rounds] x [step] however long the decoding really took,
  /// so two runs give the same frame.
  static Future<void> settle(WidgetTester t, {int rounds = 8, Duration step = const Duration(milliseconds: 250)}) async {
    for (var i = 0; i < rounds; i++) {
      await _decode(t);
      await t.pump(step);
    }
    await _decode(t);
  }

  /// Real time passes here, the test clock does not. Two things only ever finish in real time:
  /// decoding a picture, and an answer that was already in hand before the test began (see
  /// [_warm]); it is delivered on the real event loop, which a test only reaches through
  /// `runAsync`. So: a few real turns, a frame after each, until no picture is still loading.
  static Future<void> _decode(WidgetTester t) async {
    for (var i = 0; i < 80; i++) {
      await t.runAsync(() => Future<void>.delayed(i < 3 ? Duration.zero : const Duration(milliseconds: 3)));
      await t.pump();
      if (i >= 2 && imageCache.pendingImageCount == 0) return;
    }
  }

  // ───────────────────────── D-pad ─────────────────────────

  /// Puts the app in D-pad mode the way a controller announces itself (no key is pressed, so
  /// nothing moves).
  static Future<void> dpadMode(WidgetTester t) async {
    InputModeTracker.reportNonPointerInput();
    await t.pump();
    await t.pump(const Duration(milliseconds: 250));
  }

  /// The focus node of the app control (a Pressable) at or under [finder].
  static FocusNode nodeOf(WidgetTester t, Finder finder) {
    final wrapper = find.descendant(of: finder, matching: find.byType(FocusableWrapper), matchRoot: true).first;
    return t.widget<Focus>(find.descendant(of: wrapper, matching: find.byType(Focus)).first).focusNode!;
  }

  /// Gives focus to the control at or under [finder] from code, and lets the page follow.
  static Future<void> focus(WidgetTester t, Finder finder) async {
    nodeOf(t, finder).requestFocus();
    await settle(t, rounds: 3);
  }

  /// Presses [key] the way a person does, [times] times, giving the app the frames it would
  /// have had between presses (focus arrives, the page starts to scroll, the scroll ends).
  static Future<void> press(WidgetTester t, LogicalKeyboardKey key, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await t.sendKeyEvent(key);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 20));
      await t.pump(const Duration(milliseconds: 300));
    }
  }

  static Future<void> down(WidgetTester t, {int times = 1}) => press(t, LogicalKeyboardKey.arrowDown, times: times);
  static Future<void> up(WidgetTester t, {int times = 1}) => press(t, LogicalKeyboardKey.arrowUp, times: times);
  static Future<void> left(WidgetTester t, {int times = 1}) => press(t, LogicalKeyboardKey.arrowLeft, times: times);
  static Future<void> right(WidgetTester t, {int times = 1}) => press(t, LogicalKeyboardKey.arrowRight, times: times);

  /// OK, then time for whatever it opened to load.
  static Future<void> ok(WidgetTester t) async {
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(t);
  }

  /// Back (Escape on a keyboard), then time for the page underneath to come back.
  static Future<void> back(WidgetTester t) async {
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t, rounds: 4);
  }

  /// What has focus, in words: "PosterCard under "Hot right now" 'The Long Night' (file)".
  /// "nothing" when focus is on no control.
  static String focused() {
    final node = FocusManager.instance.primaryFocus;
    return node != null && Dpad.isStop(node) ? describeStop(node).$2 : 'nothing';
  }

  /// Whether the focused control is fully in view (rule R4).
  static bool focusInView() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || !Dpad.isStop(node)) return false;
    final seen = DpadReveal.visibleArea(node.context!).inflate(1);
    final r = node.rect;
    return r.left >= seen.left && r.top >= seen.top && r.right <= seen.right && r.bottom <= seen.bottom;
  }

  // ───────────────────────── Pictures ─────────────────────────

  /// Where the pointer-mode baseline lives. Not in git: a picture is about half a megabyte and
  /// there are dozens, so they stay on the machine that took them, with the rest of docs/.
  static const baselineDir = 'docs/dpad/baseline';

  /// Compares the screen, pixel for pixel, with the picture saved under [baselineDir] before
  /// the D-pad work began (`flutter test --update-goldens` saves it afresh). This is what shows
  /// that nothing changed for touch and mouse. On a machine with no baseline it says so and
  /// passes: there is nothing to compare with.
  static Future<void> baseline(WidgetTester t, String name) async {
    final file = File('$baselineDir/${name}_${OnScreens.current.tag}.png');
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(frame));
    String? problem;
    await t.runAsync(() async {
      final image = await boundary.toImage();
      if (autoUpdateGoldenFiles) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        file
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
        image.dispose();
        return;
      }
      if (!file.existsSync()) {
        debugPrint('no baseline for ${file.path}: nothing to compare with');
        image.dispose();
        return;
      }
      final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
      final was = (await codec.getNextFrame()).image;
      if (was.width != image.width || was.height != image.height) {
        problem = '${file.path}: size is ${image.width}x${image.height}, the baseline is ${was.width}x${was.height}';
      } else {
        final a = (await image.toByteData())!.buffer.asUint8List(), b = (await was.toByteData())!.buffer.asUint8List();
        var changed = 0;
        for (var i = 0; i < a.length; i += 4) {
          if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] || a[i + 3] != b[i + 3]) changed++;
        }
        if (changed > 0) {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final now = File('$baselineDir/_changed/${file.uri.pathSegments.last}')
            ..createSync(recursive: true)
            ..writeAsBytesSync(png!.buffer.asUint8List());
          problem = '${file.path}: $changed pixels differ from the baseline (what it looks like now: ${now.path})';
        }
      }
      was.dispose();
      image.dispose();
    });
    if (problem != null) fail(problem!);
  }

  /// Saves the screen as a PNG under [pictureDir], for a person to look at.
  static Future<void> picture(WidgetTester t, String name) async {
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(frame));
    await t.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('$pictureDir/${name}_${OnScreens.current.tag}.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  // ───────────────────────── Errors ─────────────────────────

  /// Runs [body] and hands back the layout overflows it caused instead of failing on the first
  /// one, each as "file:line: message". Anything else still fails the test.
  static Future<List<String>> overflows(Future<void> Function() body) async {
    final found = <String>[];
    final was = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exceptionAsString();
      if (text.contains('overflowed')) {
        final where = RegExp(r'file:///[^\s]+').firstMatch(details.toString())?.group(0) ?? '';
        found.add('$where: ${text.split('\n').first}');
      } else {
        was?.call(details);
      }
    };
    try {
      await body();
    } finally {
      FlutterError.onError = was;
    }
    return found;
  }
}
