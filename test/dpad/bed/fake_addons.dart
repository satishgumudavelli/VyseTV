// Made-up Stremio addons for the test bed, answered by the fake network: Lantern (films and
// shows by IMDb id, with genres, search and paging, and a list of addons, like Cinemeta), Kite
// (anime by its own ids, like Anime Kitsu), Brook (streams for both, some of them links),
// Hollow (catalogs that bring nothing back or fail), Shelfmark (collections of films, like TMDB
// Collections) and Quill (subtitles). Nothing here is a real addon.
import 'fake_net.dart';

const lanternUrl = 'https://lantern.test/manifest.json';
const kiteUrl = 'https://kite.test/manifest.json';
const brookUrl = 'https://brook.test/manifest.json';
const hollowUrl = 'https://hollow.test/manifest.json';
const shelfmarkUrl = 'https://shelfmark.test/manifest.json';
const quillUrl = 'https://quill.test/manifest.json';

const _films = [
  'Marigold', 'The Iron Bell', 'Saltmarsh', 'Quiet Engines', 'The Lodger', 'Copperhead', 'Brightwater', 'Falling Upward',
  'The Glass Wharf', 'Moth Season', 'Lowland', 'The Tinker',
];

final lanternManifest = <String, Object?>{
  'id': 'test.lantern',
  'name': 'Lantern',
  'version': '1.2.0',
  'description': 'Made up for the tests: films and shows by IMDb id.',
  'resources': ['catalog', 'meta', 'addon_catalog'],
  'types': ['movie', 'series'],
  'idPrefixes': ['tt'],
  'addonCatalogs': [
    {'type': 'all', 'id': 'community', 'name': 'Community'},
    {'type': 'movie', 'id': 'community', 'name': 'Community'},
  ],
  'catalogs': [
    {
      'type': 'movie',
      'id': 'top',
      'name': 'Popular',
      'extra': [
        {'name': 'genre', 'options': ['Drama', 'Comedy', 'Thriller', 'Horror', 'Mystery', 'Romance', 'Western', 'War', 'Family']},
        {'name': 'search'},
        {'name': 'skip'},
      ],
    },
    {
      'type': 'series',
      'id': 'top',
      'name': 'Popular',
      'extra': [
        {'name': 'genre', 'options': ['Drama', 'Comedy']},
        {'name': 'search'},
        {'name': 'skip'},
      ],
    },
    for (final (i, n) in ['Harbour Collection', 'Night Owls', 'Award Winners', 'Rainy Sundays'].indexed) {'type': 'movie', 'id': 'list$i', 'name': n},
    {
      'type': 'movie',
      'id': 'year',
      'name': 'New',
      'extra': [
        {'name': 'genre', 'isRequired': true, 'options': ['2026', '2025']},
      ],
    },
    {
      'type': 'series',
      'id': 'last-videos',
      'name': 'Last videos',
      'extra': [
        {'name': 'lastVideosIds', 'isRequired': true},
      ],
    },
  ],
};

final kiteManifest = <String, Object?>{
  'id': 'test.kite',
  'name': 'Kite',
  'version': '0.3.0',
  'description': 'Made up for the tests: anime by its own ids.',
  'resources': ['catalog', 'meta'],
  'types': ['anime', 'series', 'movie'],
  'idPrefixes': ['kite'],
  'catalogs': [
    {'type': 'anime', 'id': 'kite-trending', 'name': 'Kite Trending'},
    {
      'type': 'anime',
      'id': 'kite-search',
      'name': 'Kite',
      'extra': [
        {'name': 'search', 'isRequired': true},
      ],
    },
  ],
};

final brookManifest = <String, Object?>{
  'id': 'test.brook',
  'name': 'Brook',
  'version': '2.0.0',
  'description': 'Made up for the tests: streams.',
  'resources': ['stream'],
  'types': ['movie', 'series'],
  'idPrefixes': ['tt', 'kite'],
};

/// Collections of films, the way TMDB Collections lists them: a collection is a "movie" whose
/// videos are its films, each under its own IMDb id (and TMDB's, for some); and for a film that
/// is in one, a stream that is a link to the collection's page.
final shelfmarkManifest = <String, Object?>{
  'id': 'test.shelfmark',
  'name': 'Shelfmark',
  'version': '2.2.1',
  'description': 'Made up for the tests: collections of films.',
  'types': ['movie', 'collections'],
  'resources': [
    'catalog',
    {'name': 'meta', 'types': ['movie'], 'idPrefixes': ['col.']},
    {'name': 'stream', 'types': ['movie'], 'idPrefixes': ['tt']},
  ],
  'idPrefixes': ['col.'],
  'catalogs': [
    {'type': 'collections', 'id': 'col.popular', 'name': 'Popular'},
  ],
};

/// The collection Shelfmark lists: two films, one TMDB knows by the id Shelfmark gives (1002),
/// one only by its name (Harbour Lights, 2013: the bed's TMDB has it as 1001).
Map<String, Object?> shelfmarkCollection({bool videos = false}) => {
  'id': 'col.1',
  'type': 'movie',
  'name': 'Harbour Saga Collection',
  'poster': '/col1.jpg',
  'background': 'https://img.test/colb1.jpg',
  'releaseInfo': '2012-2013',
  'description': 'Two made-up films about a harbour.',
  if (videos)
    'videos': [
      {
        'id': 'tt1000002',
        'tmdbId': 1002,
        'title': 'Paper Moons',
        'released': '2014-03-15T00:00:00.000Z',
        'season': 1,
        'episode': 1,
        'overview': 'The first made-up film.',
        'poster': '/p1002.jpg',
        'thumbnail': 'https://img.test/colt1.jpg',
      },
      {
        'id': 'tt1000004',
        'title': 'Harbour Lights',
        'released': '2013-02-15T00:00:00.000Z',
        'season': 1,
        'episode': 2,
        'overview': 'The second made-up film.',
        'poster': '/p1004.jpg',
        'thumbnail': 'https://img.test/colt2.jpg',
      },
    ],
};

/// Subtitles, matched by the file's name and size when the player says them.
final quillManifest = <String, Object?>{
  'id': 'test.quill',
  'name': 'Quill',
  'version': '1.0.0',
  'description': 'Made up for the tests: subtitles.',
  'resources': ['subtitles'],
  'types': ['movie', 'series'],
  'idPrefixes': ['tt'],
};

/// Three catalogs: one with titles, one that comes back empty, one that fails.
final hollowManifest = <String, Object?>{
  'id': 'test.hollow',
  'name': 'Hollow',
  'version': '0.1.0',
  'description': 'Made up for the tests: one catalog with titles, one empty, one that fails.',
  'resources': ['catalog'],
  'types': ['movie'],
  'idPrefixes': ['tt'],
  'catalogs': [
    {'type': 'movie', 'id': 'fine', 'name': 'Fine'},
    {'type': 'movie', 'id': 'empty', 'name': 'Empty'},
    {'type': 'movie', 'id': 'broken', 'name': 'Broken'},
  ],
};

/// Lantern's film [i]: `tt100xxxx`. Film 1 says its TMDB id (1001); the others don't.
Map<String, Object?> lanternFilm(int i, {String? name, String? year}) => {
  'id': 'tt${1000000 + i}',
  'type': 'movie',
  'name': name ?? '${_films[i % _films.length]}${i < _films.length ? '' : ' ${i ~/ _films.length + 1}'}',
  'poster': 'https://img.test/lp$i.jpg',
  'background': 'https://img.test/lb$i.jpg',
  'logo': 'https://img.test/ll$i.png',
  'releaseInfo': year ?? '${2010 + i % 15}',
  'imdbRating': '${6 + i % 4}.${i % 10}',
  'description': 'A made-up film from Lantern, number $i, long enough to wrap onto a second line on most screens.',
  if (i == 1) 'moviedb_id': 1001,
};

/// Lantern's show [i]: `tt200xxxx`.
Map<String, Object?> lanternShow(int i) => {
  'id': 'tt${2000000 + i}',
  'type': 'series',
  'name': '${_films[(i + 5) % _films.length]}: The Series',
  'poster': 'https://img.test/sp$i.jpg',
  'background': 'https://img.test/sb$i.jpg',
  'releaseInfo': '${2015 + i % 8}–',
  'imdbRating': '8.${i % 10}',
  'description': 'A made-up show from Lantern, number $i.',
};

/// Kite's show [i]: `kite:i`, type series in a catalog of type anime.
Map<String, Object?> kiteShow(int i) => {
  'id': 'kite:$i',
  'type': 'series',
  'name': const ['Paper Cranes', 'Sky Lanterns', 'The Clockwork Fox', 'Starfall Academy'][i % 4] + (i < 4 ? '' : ' ${i ~/ 4 + 1}'),
  'poster': 'https://img.test/kp$i.jpg',
  'background': 'https://img.test/kb$i.jpg',
  'releaseInfo': '${2018 + i % 6}',
  'description': 'A made-up anime from Kite, number $i.',
};

/// Answers for the three made-up addons; null for anything else.
FakeReply? fakeAddons(String method, Uri uri) {
  final p = uri.path;
  final films = [for (var i = 0; i < 45; i++) lanternFilm(i)];
  if (uri.host == 'lantern.test') {
    if (p == '/manifest.json') return FakeReply.json(lanternManifest);
    if (p == '/catalog/movie/top.json') return FakeReply.json({'metas': films.take(30).toList()});
    if (p == '/catalog/movie/top/skip=30.json') return FakeReply.json({'metas': films.skip(30).toList()});
    if (p.startsWith('/catalog/movie/top/skip=')) return FakeReply.json({'metas': <Object>[]});
    final genre = RegExp(r'^/catalog/movie/top/genre=(\w+)(&skip=\d+)?\.json$').firstMatch(p);
    if (genre != null) {
      if (genre[2] != null) return FakeReply.json({'metas': <Object>[]});
      return FakeReply.json({
        'metas': [for (var i = 0; i < 10; i++) lanternFilm(100 + i, name: '${genre[1]} Story ${i + 1}')],
      });
    }
    if (p.startsWith('/catalog/movie/top/search=')) {
      return FakeReply.json({
        'metas': [
          // TMDB's made-up catalogue has a film of this name and year: search shows it once
          lanternFilm(9999, name: 'The Long Night', year: '2012'),
          lanternFilm(9998, name: 'Lantern Only Film', year: '2020'),
        ],
      });
    }
    if (p.startsWith('/catalog/series/top/search=')) return FakeReply.json({'metas': <Object>[]});
    if (p == '/catalog/series/top.json') return FakeReply.json({'metas': [for (var i = 0; i < 20; i++) lanternShow(i)]});
    final list = RegExp(r'^/catalog/movie/list(\d)\.json$').firstMatch(p);
    if (list != null) {
      final n = int.parse(list[1]!);
      return FakeReply.json({'metas': [for (var i = 0; i < 10; i++) lanternFilm(50 + n * 10 + i)]});
    }
    if (p.startsWith('/catalog/movie/year/genre=')) return FakeReply.json({'metas': [for (var i = 0; i < 10; i++) lanternFilm(200 + i)]});
    if (p == '/addon_catalog/all/community.json') {
      return FakeReply.json({
        'addons': [
          {'transportUrl': brookUrl, 'transportName': 'http', 'manifest': brookManifest},
          {'transportUrl': kiteUrl, 'transportName': 'http', 'manifest': kiteManifest},
          {
            'transportUrl': 'https://setup.test/manifest.json',
            'transportName': 'http',
            'manifest': {
              'id': 'test.setup',
              'name': 'Needs Setup',
              'version': '1.0.0',
              'description': 'Made up: has to be set up first.',
              'resources': ['stream'],
              'types': ['movie'],
              'behaviorHints': {'configurable': true, 'configurationRequired': true},
            },
          },
          {
            'transportUrl': 'https://adult.test/manifest.json',
            'transportName': 'http',
            'manifest': {
              'id': 'test.adult',
              'name': 'Grown Ups Only',
              'version': '1.0.0',
              'resources': ['catalog'],
              'types': ['movie'],
              'catalogs': <Object>[],
              'behaviorHints': {'adult': true},
            },
          },
        ],
      });
    }
    final film = RegExp(r'^/meta/movie/tt(\d+)\.json$').firstMatch(p);
    if (film != null) {
      final i = int.parse(film[1]!) - 1000000;
      return FakeReply.json({
        'meta': {
          ...lanternFilm(i),
          'runtime': '112 min',
          'genres': ['Drama', 'Thriller'],
          'director': ['Ada Morrow'],
          'writer': ['Ben Halloway'],
          'cast': ['Iris Vale', 'Tom Arden', 'June Okoro'],
          'country': 'United Kingdom',
          'released': '${2010 + i % 15}-04-02T00:00:00.000Z',
          'trailerStreams': [
            {'title': 'Official trailer', 'ytId': 'lt$i'},
          ],
          'behaviorHints': {'defaultVideoId': 'tt${1000000 + i}'},
          // film 7's details carry a stream of their own
          if (i == 7)
            'videos': [
              {
                'id': 'tt1000007',
                'title': 'Lowland',
                'released': '2017-04-02T00:00:00.000Z',
                'streams': [
                  {'url': 'https://files.test/lantern-own.mkv', 'name': 'Lantern', 'description': 'Lantern own 720p, from its details'},
                ],
              },
            ],
        },
      });
    }
    final show = RegExp(r'^/meta/series/tt(\d+)\.json$').firstMatch(p);
    if (show != null) {
      final i = int.parse(show[1]!) - 2000000;
      final id = 'tt${2000000 + i}';
      return FakeReply.json({
        'meta': {
          ...lanternShow(i),
          'runtime': '48 min',
          'genres': ['Drama'],
          'status': 'Continuing',
          'videos': [
            {'id': '$id:0:1', 'title': 'Behind the scenes', 'season': 0, 'episode': 1, 'released': '2015-01-01T00:00:00.000Z'},
            for (var s = 1; s <= 2; s++)
              for (var e = 1; e <= (s == 1 ? 3 : 2); e++)
                {
                  'id': '$id:$s:$e',
                  'title': 'Lantern chapter $s.$e',
                  'season': s,
                  'episode': e,
                  'released': '${2015 + s}-0$e-10T00:00:00.000Z',
                  'thumbnail': 'https://img.test/st$i$s$e.jpg',
                  'overview': 'A made-up episode.',
                },
          ],
        },
      });
    }
    return FakeReply.notFound;
  }
  if (uri.host == 'kite.test') {
    if (p == '/manifest.json') return FakeReply.json(kiteManifest);
    if (p == '/catalog/anime/kite-trending.json') return FakeReply.json({'metas': [for (var i = 0; i < 12; i++) kiteShow(i)]});
    if (p.startsWith('/catalog/anime/kite-search/search=')) return FakeReply.json({'metas': [kiteShow(1), kiteShow(5)]});
    final m = RegExp(r'^/meta/(series|anime)/kite:(\d+)\.json$').firstMatch(p);
    if (m != null) {
      final i = int.parse(m[2]!);
      return FakeReply.json({
        'meta': {
          ...kiteShow(i),
          'genres': ['Adventure', 'Fantasy'],
          'runtime': '24 min',
          'videos': [
            for (var e = 1; e <= 4; e++)
              {
                'id': 'kite:$i:$e',
                'title': 'Kite episode $e',
                'season': 1,
                'episode': e,
                'released': '2020-0$e-01T00:00:00.000Z',
                'thumbnail': 'https://img.test/kt$i$e.jpg',
              },
          ],
        },
      });
    }
    return FakeReply.notFound;
  }
  if (uri.host == 'shelfmark.test') {
    if (p == '/manifest.json') return FakeReply.json(shelfmarkManifest);
    if (p == '/catalog/collections/col.popular.json') return FakeReply.json({'metas': [shelfmarkCollection()]});
    if (p == '/meta/movie/col.1.json') return FakeReply.json({'meta': shelfmarkCollection(videos: true)});
    if (p.startsWith('/meta/')) return FakeReply.json({'meta': <Object>[]}); // (what it answers for an id it doesn't know)
    if (p == '/stream/movie/tt1000002.json' || p == '/stream/movie/tt1000004.json') {
      return FakeReply.json({
        'streams': [
          {'name': 'Shelfmark', 'description': '📚 "Harbour Saga Collection"\nThe film is part of it', 'externalUrl': 'stremio:///detail/movie/col.1'},
        ],
      });
    }
    if (p.startsWith('/stream/')) return FakeReply.json({'streams': <Object>[]});
    return FakeReply.notFound;
  }
  if (uri.host == 'quill.test') {
    if (p == '/manifest.json') return FakeReply.json(quillManifest);
    if (p.startsWith('/subtitles/')) {
      return FakeReply.json({
        'subtitles': [
          {'id': 'q1', 'url': 'https://subs.test/quill.${p.contains('videoSize=') ? 'matched' : 'plain'}.srt', 'lang': 'eng'},
        ],
      });
    }
    return FakeReply.notFound;
  }
  if (uri.host == 'hollow.test') {
    if (p == '/manifest.json') return FakeReply.json(hollowManifest);
    if (p == '/catalog/movie/fine.json') {
      return FakeReply.json({
        'metas': [
          for (var i = 0; i < 8; i++) {...lanternFilm(300 + i, name: i == 0 ? 'Paper Moons' : null, year: i == 0 ? '2014' : null), 'posterShape': 'landscape'},
        ],
      });
    }
    if (p == '/catalog/movie/empty.json') return FakeReply.json({'metas': <Object>[]});
    if (p == '/catalog/movie/broken.json') return const FakeReply(500, <int>[]);
    return FakeReply.notFound;
  }
  if (uri.host == 'brook.test') {
    if (p == '/manifest.json') return FakeReply.json(brookManifest);
    if (p.startsWith('/stream/')) {
      return FakeReply.json({
        'streams': [
          {
            'url': 'https://files.test/brook.mkv',
            'name': 'Brook\n1080p',
            'description': 'Made-up stream 1080p WEB-DL',
            'subtitles': [
              {'id': 'b1', 'url': 'https://subs.test/brook.en.srt', 'lang': 'eng'},
            ],
            'behaviorHints': {'filename': 'Brook.Film.1080p.WEB-DL.mkv', 'videoSize': 1234567890},
          },
          {'ytId': 'brookyt1', 'name': 'Brook', 'description': 'The trailer on YouTube'},
          {'externalUrl': 'https://watch.test/film', 'name': 'Brook', 'description': 'Watch it on the site'},
        ],
      });
    }
    return FakeReply.notFound;
  }
  // TMDB's match for Lantern's film 3 (it doesn't say its TMDB id)
  if (uri.host == 'api.themoviedb.org' && p == '/3/find/tt1000003') {
    return FakeReply.json({
      'movie_results': [
        {'id': 1003, 'title': 'Quiet Engines'},
      ],
      'tv_results': <Object>[],
    });
  }
  return null;
}
