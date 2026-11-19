// The picture's shape and a phone's rotate button (2026-11-19). The user: "the users want
// aspect ratio controls. and a rotate button on the phone ... they all want a fullscreen/rotate
// button because they dont wanna ... unlock their orientation lock". docs/dpad/PLAN.md note 96.
//
// The real player page, booted as Android: on a phone (mpv, the bed's channel stands in for it:
// Bed.videoCalls) and on a TV (Media3: Bed.exoCalls, in t4_journeys_picture_tv_test.dart). What each shape tells the engines was
// checked against the app's own libmpv (16:9 to 4:3 on a 640 by 360 picture: 640 by 480, playing
// or paused); here it is what the page asks of them.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/screens/player/picture_shape.dart';

import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.android));
  late FakeRoute route;
  setUp(() {
    AppSettings.pictureShape.set('fit');
    // a made-up film source with one link that answers, so the player gets past "No sources"
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/first.mkv', type: 'mkv')]),
    ];
    route = Bed.http.route;
    Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
  });
  tearDown(() {
    AppSettings.pictureShape.set('fit');
    debugFilmSources = null;
    Bed.http.route = route;
  });

  // A phone on its side. (The bed runs on a PC, where the page can't tell a touch screen: it
  // lays a screen out as a phone's only when it is under 640 wide, which a small phone turned
  // sideways is. A real phone keeps the phone's controls whatever its width.)
  const sideways = Size(568, 320);
  final phone = OnScreens([Screens.phone]);

  /// mpv properties the player set, oldest first, as "name=value".
  List<String> mpvSets(String name) => [
    for (final c in Bed.videoCalls)
      if (c.startsWith('setProperty ') && c.contains('name: $name,')) '$name=${RegExp(r'value: ([^,}]*)').firstMatch(c)?[1]}',
  ];

  /// What the page asked of the phone's orientation, oldest first.
  final turns = <List<String>>[];
  void listenForTurns(WidgetTester t) {
    turns.clear();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        turns.add([for (final o in call.arguments as List) '$o'.replaceFirst('DeviceOrientation.', '')]);
      }
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  Future<void> turnScreen(WidgetTester t, Size to) async {
    t.view.physicalSize = to;
    await Bed.settle(t, rounds: 3);
  }

  test('each shape, in the words the engines take', () {
    const box = Size(800, 360);
    expect([for (final s in PictureShape.values) s.label], ['Fit', 'Fill', 'Stretch', '16:9', '4:3', '21:9']);
    expect([for (final s in PictureShape.values) s.aspectOverride(box)], ['no', 'no', '2.2222', '16:9', '4:3', '21:9']);
    expect([for (final s in PictureShape.values) s.panscan], ['0', '1.0', '0', '0', '0', '0']);
    expect([for (final s in PictureShape.values) s.boxFit], [0, 1, 2, 0, 0, 0]);
    expect(PictureShape.stretch.aspectOverride(null), 'no', reason: 'no box yet: the picture keeps its shape until there is one');
    expect([for (final s in PictureShape.values) s.next], [PictureShape.fill, PictureShape.stretch, PictureShape.fit, PictureShape.fit, PictureShape.fit, PictureShape.fit]);
    expect([for (final s in PictureShape.values) s.kept], [true, true, true, false, false, false]);
    expect(PictureShape.remembered('fill'), PictureShape.fill);
    expect(PictureShape.remembered('4:3'), PictureShape.fit, reason: 'a forced shape is never brought back');
    expect(PictureShape.remembered('?'), PictureShape.fit);
    expect(PictureShape.fit.forceMargins(zoomPercent: 100), isFalse);
    expect(PictureShape.fit.forceMargins(zoomPercent: 120), isTrue);
    expect(PictureShape.fill.forceMargins(zoomPercent: 100), isTrue);
  });

  testWidgets('a phone: an aspect ratio button and a rotate button among the tools; rotate turns the screen sideways and back, and lets go when the player closes', (t) async {
    listenForTurns(t);
    Bed.videoCalls.clear();
    final errors = await Bed.overflows(() async {
      await Bed.openPlayer(t);
      expect(find.byTooltip('Aspect ratio'), findsOneWidget);
      expect(find.byTooltip('Turn sideways'), findsOneWidget);
      await Bed.picture(t, 'picture/phone_1_tools');

      await t.tap(find.byTooltip('Turn sideways'));
      await Bed.settle(t, rounds: 2);
      expect(turns.last, ['landscapeLeft', 'landscapeRight'], reason: 'sideways either way round, whatever the rotation lock says');
      await turnScreen(t, sideways); // Android turns it
      expect(find.byTooltip('Turn upright'), findsOneWidget, reason: 'on its side the button turns it back');
      await Bed.picture(t, 'picture/phone_2_sideways');

      await t.tap(find.byTooltip('Turn upright'));
      await Bed.settle(t, rounds: 2);
      expect(turns.last, ['portraitUp']);
      await turnScreen(t, const Size(390, 844));
    });
    expect(errors, isEmpty, reason: 'the tools fit a phone held either way');

    await Bed.closePlayer(t);
    expect(turns.last, isEmpty, reason: 'out of the player the phone follows its own rotation setting again');
  }, variant: phone);

  testWidgets('a phone: the aspect ratio button goes Fit, Fill, Stretch and round, says which, and is remembered', (t) async {
    Bed.videoCalls.clear();
    await Bed.openPlayer(t);
    await t.tap(find.byTooltip('Aspect ratio'));
    await Bed.settle(t, rounds: 2);
    expect(find.text('Aspect ratio: Fill'), findsOneWidget, reason: 'it says what it changed to');
    expect(mpvSets('panscan').last, 'panscan=1.0', reason: 'Fill crops the picture to the screen');
    expect(mpvSets('sub-ass-force-margins').last, 'sub-ass-force-margins=yes', reason: 'and the subtitles stay on the screen');
    expect(AppSettings.pictureShape.value, 'fill');

    await t.tap(find.byTooltip('Aspect ratio'));
    await Bed.settle(t, rounds: 2);
    expect(find.text('Aspect ratio: Stretch'), findsOneWidget);
    expect(mpvSets('panscan').last, 'panscan=0');
    final screen = t.view.physicalSize / t.view.devicePixelRatio;
    expect(mpvSets('video-aspect-override').last, 'video-aspect-override=${(screen.width / screen.height).toStringAsFixed(4)}', reason: 'Stretch pulls the picture to the shape of its box');

    await turnScreen(t, sideways);
    expect(mpvSets('video-aspect-override').last, 'video-aspect-override=${(568 / 320).toStringAsFixed(4)}', reason: 'and follows it when the phone is turned');
    await turnScreen(t, const Size(390, 844));

    await t.tap(find.byTooltip('Aspect ratio'));
    await Bed.settle(t, rounds: 2);
    expect(find.text('Aspect ratio: Fit'), findsOneWidget);
    expect(mpvSets('video-aspect-override').last, 'video-aspect-override=no', reason: 'Fit: the picture\'s own shape');
    expect(AppSettings.pictureShape.value, 'fit');
    await Bed.closePlayer(t);

    // remembered: the next player starts with it, and tells mpv as the file opens
    AppSettings.pictureShape.set('fill');
    Bed.videoCalls.clear();
    await Bed.openPlayer(t);
    await Bed.videoEvent(t, 'file-loaded');
    expect(mpvSets('panscan'), contains('panscan=1.0'));
    await Bed.closePlayer(t);
  }, variant: phone);
  // The most tools there are (a series: Episodes and Next as well) on the narrowest phone.
  testWidgets('a series on a 320-wide phone: all seven tools fit, upright and sideways', (t) async {
    final errors = await Bed.overflows(() async {
      await Bed.openPlayer(t, series: true);
      expect(find.byTooltip('Episodes'), findsOneWidget);
      expect(find.byTooltip('Aspect ratio'), findsOneWidget);
      expect(find.byTooltip('Turn sideways'), findsOneWidget);
      await Bed.picture(t, 'picture/small_series');
      await turnScreen(t, sideways);
      expect(find.byTooltip('Turn upright'), findsOneWidget);
    });
    expect(errors, isEmpty);
    await Bed.closePlayer(t);
  }, variant: OnScreens([const Screen('small', Size(320, 568))]));
}
