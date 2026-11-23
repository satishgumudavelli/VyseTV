// A phone's player, by touch: a double tap on either side of the picture skips back or forward
// (each tap on that side after it skips again), and holding the picture plays at 2x until it is
// let go.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';
import 'package:vyse_tv/screens/player/player_page.dart';

import 'harness.dart';

void main() {
  setUpAll(() async {
    await Bed.boot(as: TargetPlatform.android);
  });
  final phone = OnScreens([Screens.phone]);
  late FakeRoute route;
  setUp(() {
    PlayerPage.debugTouch = true;
    debugFilmSources = [
      FilmSource(id: 'first', name: 'First', note: '', scraper: (_) async => const [FoundStream(url: 'http://files.test/film.mkv', type: 'mkv')]),
    ];
    route = Bed.http.route;
    Bed.http.route = (method, uri) => uri.host == 'files.test' ? const FakeReply(206, [0, 0, 0, 0], type: 'video/x-matroska') : route(method, uri);
  });
  tearDown(() {
    PlayerPage.debugTouch = null;
    debugFilmSources = null;
    Bed.http.route = route;
  });

  var mark = 0; // what the player asked of mpv before the test's own taps

  /// Opens a film playing at 100 s, the controls gone again.
  Future<void> playing(WidgetTester t) async {
    Bed.videoCalls.clear();
    await Bed.openPlayer(t);
    await Bed.videoProperty(t, 'duration', 6000.0);
    await Bed.videoProperty(t, 'pause', false);
    await Bed.videoProperty(t, 'paused-for-cache', false);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 260)));
    await Bed.videoProperty(t, 'time-pos', 100.0);
    await t.pump(const Duration(seconds: 5)); // (the controls hide)
    mark = Bed.videoCalls.length;
  }

  /// Where mpv was asked to seek to, in order.
  List<double> seeks() => [
    for (final c in Bed.videoCalls.skip(mark))
      if (c.startsWith('command') && c.contains('[seek, ')) double.parse(RegExp(r'\[seek, ([\d.]+)').firstMatch(c)![1]!),
  ];

  /// The speeds mpv was given, in order.
  List<String> speeds() => [for (final c in Bed.videoCalls.skip(mark)) if (c.contains('name: speed,')) RegExp(r'value: ([\d.]+)').firstMatch(c)![1]!];

  Future<void> tap(WidgetTester t, double x) async {
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    await t.tapAt(Offset(size.width * x, size.height * .45));
    await t.pump(const Duration(milliseconds: 80));
  }

  Future<void> leave(WidgetTester t) async {
    await Bed.closePlayer(t);
    t.takeException(); // (Continue watching hears the progress saved as the player closes)
    await t.pump(const Duration(seconds: 31)); // (the film sources' timers)
  }

  testWidgets('a double tap on the right skips forward, each tap after it skips again, and the controls stay hidden', (t) async {
    await playing(t);
    await tap(t, .8);
    expect(seeks(), isEmpty, reason: 'one tap only shows the controls');
    await tap(t, .8);
    expect(seeks(), [110.0]);
    expect(find.text('+10s'), findsOneWidget);
    await tap(t, .75);
    expect(seeks(), [110.0, 120.0]);
    expect(find.text('+20s'), findsOneWidget);
    expect(find.byTooltip('Lock').hitTestable(), findsNothing, reason: 'the controls stay as they were: hidden');
    await t.pump(const Duration(seconds: 1));
    expect(find.text('+20s'), findsNothing, reason: 'the note goes once the taps stop');
    await leave(t);
  }, variant: phone);

  testWidgets('a double tap on the left skips back', (t) async {
    await playing(t);
    await tap(t, .2);
    await tap(t, .2);
    expect(seeks(), [90.0]);
    expect(find.text('−10s'), findsOneWidget);
    await t.pump(const Duration(seconds: 1));
    await leave(t);
  }, variant: phone);

  testWidgets('a tap on each side is two taps, not a skip', (t) async {
    await playing(t);
    await tap(t, .2);
    await tap(t, .8);
    expect(seeks(), isEmpty);
    await t.pump(const Duration(seconds: 1));
    await leave(t);
  }, variant: phone);

  testWidgets('held down: 2x, and the speed it had once let go', (t) async {
    await playing(t);
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    final finger = await t.startGesture(Offset(size.width * .5, size.height * .3));
    await t.pump(const Duration(milliseconds: 700));
    expect(speeds().last, '2.0', reason: '${Bed.videoCalls}');
    expect(find.text('2x'), findsOneWidget);
    await finger.up();
    await t.pump();
    expect(speeds().last, '1.0');
    expect(find.text('2x'), findsNothing);
    await leave(t);
  }, variant: phone);

  testWidgets('held down while paused: nothing', (t) async {
    await playing(t);
    await Bed.videoProperty(t, 'pause', true);
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    final finger = await t.startGesture(Offset(size.width * .5, size.height * .3));
    await t.pump(const Duration(milliseconds: 700));
    await finger.up();
    await t.pump();
    expect(speeds(), isEmpty);
    expect(find.text('2x'), findsNothing);
    await leave(t);
  }, variant: phone);
}
