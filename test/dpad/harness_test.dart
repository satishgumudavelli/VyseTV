// The test bed checking itself: if these fail, no other D-pad test can be trusted.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/screens/home/home_page.dart';
import 'package:vyse_tv/widgets/media_rows.dart';

import 'harness.dart';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));

  test('a made-up picture is a real PNG', () async {
    final codec = await ui.instantiateImageCodec(fakePicture('poster', width: 10, height: 15));
    final frame = await codec.getNextFrame();
    expect((frame.image.width, frame.image.height), (10, 15));
    expect(fakePicture('a'), isNot(fakePicture('b')));
    expect(fakePicture('a'), fakePicture('a'));
  });

  testWidgets('TMDB requests are answered from the made-up catalogue', (t) async {
    final films = await Tmdb.list('/movie/popular', tv: false);
    expect(films, hasLength(20));
    expect(films.first.title, 'The Long Night');
    expect(films.first.poster(), 'https://image.tmdb.org/t/p/w342/p1000.jpg');
    final details = await Tmdb.details(films.first);
    expect(details.cast, hasLength(12));
    expect(details.recommendations, isNotEmpty);
    expect(Bed.http.missed, isEmpty);
  });

  testWidgets('Home builds inside the shell, with data, and can be photographed', (t) async {
    await Bed.pumpShell(t);
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(LandscapeCard), findsWidgets);
    expect(find.text('Hot right now'), findsOneWidget);
    // every picture asked for was made, none is still loading
    expect(Bed.images.seen, isNotEmpty);
    expect(imageCache.pendingImageCount, 0);
    expect(Bed.http.missed, isEmpty, reason: 'requests nothing answered');
    await Bed.picture(t, 'phase0/selftest_home');
  }, variant: OnScreens(Screens.windows));
}
