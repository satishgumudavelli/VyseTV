// Cinejoy (cinejoy.pk), ported from the Vyla SDK's cinejoy.js as a film source of its own, listed
// right under Movy (2026-11-23). Here a made-up Cinejoy answers: which of its servers are asked
// and with what, the links that come back, and where it sits in Settings > Sources, reached with
// the remote. Played and seeked against the real site with VyseTV's relay and libmpv, outside the
// tests (Light, Nebula, Sirius and Polaris: found, played, seeked 75% in). How the relay takes
// Polaris's video out of its PNG pictures is in cinejoy_relay_test.dart.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/sources/film_sources/common.dart';
import 'package:vyse_tv/data/sources/film_sources/film_sources.dart';
import 'package:vyse_tv/data/sources/film_sources/scrapers.dart';
import 'package:vyse_tv/data/sources/film_sources/source_settings.dart';

import 'bed/phase8_pages.dart';
import 'harness.dart';

const _light = '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="ENGLISH",LANGUAGE="en",DEFAULT=YES,URI="audio-en/playlist.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=8128000,RESOLUTION=1920x1080,AUDIO="audio"
1080p/playlist.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=23328000,RESOLUTION=3840x2160,AUDIO="audio"
2160p/playlist.m3u8
''';

const _nebula = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=4692000,RESOLUTION=1920x1080
1080p/playlist.jpg
#EXT-X-STREAM-INF:BANDWIDTH=2628000,RESOLUTION=1280x720
720p/playlist.jpg
''';

void main() {
  setUpAll(() => Bed.boot(as: TargetPlatform.windows));
  late FakeRoute route;
  final asked = <Map<String, String>>[]; // the questions Cinejoy's servers were sent
  setUp(() {
    asked.clear();
    route = Bed.http.route;
    Bed.http.route = (method, uri) {
      final page = switch ((method, uri.host, uri.path)) {
        ('GET', 'api.themoviedb.org', '/3/movie/27205') => FakeReply.json({'title': 'Inception', 'release_date': '2010-07-16', 'imdb_id': 'tt1375666'}),
        ('GET', 'api.themoviedb.org', '/3/tv/1396') => FakeReply.json({'name': 'Breaking Bad', 'first_air_date': '2008-01-20', 'external_ids': {'imdb_id': 'tt0903747'}}),
        ('GET', 'api.wing.st', '/servers') => FakeReply.json({
          'servers': [
            {'name': 'Light', 'status': 'ok', '4k': true},
            {'name': 'Nebula', 'status': 'ok', '4k': false},
            {'name': 'Sirius', 'status': 'ok', '4k': true},
            {'name': 'Polaris', 'status': 'ok', '4k': false},
          ],
        }),
        ('GET', 'enc-dec.app', '/api/enc-cinejoy') => () {
          asked.add(Uri.parse(uri.queryParameters['url']!).queryParameters);
          return FakeReply.json({
            'status': 200,
            'result': {'data': base64Url.encode(utf8.encode('sealed question')).replaceAll('=', ''), 'state': {'responseKey': 'k'}},
          });
        }(),
        ('POST', 'api.wing.st', '/g') => const FakeReply(200, [7, 7, 7], type: 'application/octet-stream'),
        ('POST', 'enc-dec.app', '/api/dec-cinejoy') => FakeReply.json({
          'status': 200,
          'result': {
            'data': {
              'stream': [
                {'type': 'hls', 'id': 'primary', 'playlist': 'https://light.test/hls/1/master.m3u8'},
                {'type': 'hls', 'id': 'gone', 'playlist': 'https://gone.test/master.m3u8'},
                {'type': 'hls', 'id': 'primary', 'playlist': 'https://nebula.test/hls/master.m3u8'},
                {'type': 'hls', 'id': 'primary', 'playlist': 'https://polaris.test/playlists/movie/27205/720p.m3u8?token=t'},
              ],
            },
          },
        }),
        ('GET', 'light.test', '/hls/1/master.m3u8') => FakeReply(200, utf8.encode(_light), type: 'application/vnd.apple.mpegurl'),
        // Nebula serves its playlists as pictures
        ('GET', 'nebula.test', '/hls/master.m3u8') => FakeReply(200, utf8.encode(_nebula), type: 'image/jpeg'),
        // Polaris: one quality, no master; its pieces are video inside PNG pictures
        ('GET', 'polaris.test', '/playlists/movie/27205/720p.m3u8') =>
          FakeReply(200, utf8.encode('#EXTM3U\n#EXT-X-TARGETDURATION:9\n#EXTINF:8.008,\nhttps://cdn.test/obj/1\n#EXT-X-ENDLIST\n'), type: 'application/vnd.apple.mpegurl'),
        _ => null,
      };
      return page ?? (uri.host.endsWith('.test') ? null : route(method, uri));
    };
  });
  tearDown(() {
    Bed.http.route = route;
    AppSettings.sourceOrder.set('');
  });
  final laptop = OnScreens([Screens.laptop]);

  test('a film: every Cinejoy server is asked as its site asks it, and each playlist comes back whole, with its Referer', () async {
    final found = await cinejoy(const FilmQuery(tmdbId: 27205, isTv: false));
    expect([for (final q in asked) q['server']], unorderedEquals(['Light', 'Nebula', 'Sirius', 'Polaris']));
    for (final q in asked) {
      expect(q, containsPair('title', 'Inception'));
      expect((q['type'], q['year'], q['imdb'], q['tmdb']), ('movie', '2010', 'tt1375666', '27205'));
      expect(q.containsKey('season'), isFalse);
    }
    expect([for (final f in found) f.url], [
      'https://light.test/hls/1/master.m3u8',
      'https://nebula.test/hls/master.m3u8',
      'https://polaris.test/playlists/movie/27205/720p.m3u8?token=t',
    ], reason: 'a playlist that does not answer is left out; the same link from several servers is kept once');
    expect([for (final f in found) f.quality], ['4K', '1080p', '720p'], reason: 'the best quality in each master; Polaris\'s from its name');
    for (final f in found) {
      expect(f.type, 'hls', reason: 'the master itself: the player picks the quality, and Light keeps its separate sound');
      expect(f.headers, containsPair('Referer', 'https://cinejoy.pk/'));
      expect(f.headers, containsPair('Origin', 'https://cinejoy.pk'));
    }
  });

  test('an episode is asked for as a series, with its season and episode', () async {
    final found = await cinejoy(const FilmQuery(tmdbId: 1396, isTv: true, season: 3, episode: 7));
    expect(found, isNotEmpty);
    for (final q in asked) {
      expect((q['title'], q['type'], q['year'], q['imdb'], q['tmdb']), ('Breaking Bad', 'series', '2008', 'tt0903747', '1396'));
      expect((q['season'], q['episode']), ('3', '7'));
    }
  });

  test('in the list of sources Cinejoy comes right under Movy, also in an order saved before it was there', () {
    expect([for (final s in filmSources.take(6)) s.name], ['Movy', 'Cinejoy', 'CNO', 'VidUp', '111477', 'VidLink']);
    final cinejoySource = filmSources[1];
    expect((cinejoySource.id, cinejoySource.scraper, cinejoySource.filmsOnly, cinejoySource.showsOnly), ('cinejoy', cinejoy, false, false));

    // saved by someone who put CNO first and Movy second, before Cinejoy existed
    final saved = [for (final s in filmSources) if (s.id != 'cinejoy') s.id]..remove('cno');
    AppSettings.sourceOrder.set(['cno', ...saved].join(','));
    expect([for (final s in orderedFilmSources().take(4)) s.id], ['cno', 'movy', 'cinejoy', 'vidup'], reason: 'right under Movy, wherever Movy is');
    expect(orderedFilmSources().length, filmSources.length, reason: 'every source once');

    // an order that already has Cinejoy is yours: it stays where you put it (the last here)
    AppSettings.sourceOrder.set([...saved, 'cno', 'cinejoy'].join(','));
    expect(orderedFilmSources().last.id, 'cinejoy');
    expect(orderedFilmSources().first.id, 'movy');
  });

  testWidgets('Settings > Sources with the remote: Cinejoy is the row under Movy, and Down from Movy reaches it', (t) async {
    await openSettings(t, 'Sources');
    await Bed.right(t);
    Rect at(String name) => t.getRect(find.text(name));
    expect(at('Movy').top < at('Cinejoy').top && at('Cinejoy').top < at('CNO').top, isTrue, reason: 'Movy, then Cinejoy, then CNO');
    // the row the remote is on: the name whose line the focused control sits on (the list
    // scrolls as focus moves, so every position is read again)
    String? row() {
      final y = FocusManager.instance.primaryFocus?.rect.center.dy;
      if (y == null) return null;
      for (final name in ['Movy', 'Cinejoy', 'CNO']) {
        final r = at(name);
        if (y > r.top - 10 && y < r.bottom + 40) return name;
      }
      return null;
    }

    for (var i = 0; i < 10 && row() != 'Movy'; i++) {
      await Bed.down(t);
    }
    expect(row(), 'Movy', reason: 'focus is on ${Bed.focused()}');
    await Bed.down(t);
    expect(row(), 'Cinejoy', reason: 'Down from Movy is Cinejoy\'s row; focus is on ${Bed.focused()}');
  }, variant: laptop);
}
