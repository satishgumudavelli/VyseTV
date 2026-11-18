// Canned TMDB answers for the test bed: a small made-up catalogue, the same every run.
import 'fake_net.dart';

const _names = [
  'The Long Night', 'Harbour Lights', 'Paper Moons', 'Northbound', 'A Quiet Year', 'Glasshouse', 'Second Wind',
  'The Cartographer', 'Low Tide', 'Ember Road', 'Small Hours', 'Winterline', 'Open Water', 'The Understudy',
  'Halfway Home', 'Salt and Iron', 'Night Ferry', 'The Orchard', 'Signal Fire', 'Copper Sky', 'Far Country',
  'The Lamplighter', 'Stillwater', 'Kite Season', 'Borrowed Time', 'The Fold', 'Greywater', 'Last Light',
  'The Weather Station', 'Ninety East', 'Blue Hour', 'The Understory', 'Marrow', 'Old Harbour', 'Tidewrack',
  'The Long Field', 'Hollow Pine', 'Sundial', 'The Night Shift', 'Riverkeeper',
];

const _people = [
  'Mara Ellison', 'Tomas Reyes', 'Ines Okafor', 'Daniel Brandt', 'Yuki Tanabe', 'Leila Haddad', 'Oskar Lind',
  'Priya Raman', 'Noah Castell', 'Hana Sorensen', 'Emeka Obi', 'Clara Voss',
];

/// The streaming services Home asks for by id (the first few of the app's own list).
const _providers = {8: 'Netflix', 337: 'Disney Plus', 9: 'Prime Video', 1899: 'Max', 15: 'Hulu', 350: 'Apple TV', 2303: 'Paramount Plus', 283: 'Crunchyroll', 386: 'Peacock', 43: 'Starz'};

/// One title, in the shape TMDB lists them. [n] picks the name; ids are stable.
Map<String, dynamic> fakeTitle(int n, {required bool tv, bool mediaType = false}) {
  final id = (tv ? 2000 : 1000) + n;
  final name = _names[n % _names.length];
  final date = '${2012 + n % 13}-${(1 + n % 12).toString().padLeft(2, '0')}-15';
  return {
    'id': id,
    tv ? 'name' : 'title': tv ? '$name: The Series' : name,
    'overview': 'A made-up description of $name, long enough to wrap onto a second line on most screens so layouts are exercised.',
    'poster_path': '/p$id.jpg',
    'backdrop_path': '/b$id.jpg',
    'vote_average': 6.1 + (n % 30) / 10,
    'vote_count': 400 + n * 37,
    'popularity': 300.0 - n,
    'genre_ids': [const [28, 35, 18, 878, 27, 16][n % 6], const [53, 14, 99][n % 3]],
    tv ? 'first_air_date' : 'release_date': date,
    if (mediaType) 'media_type': tv ? 'tv' : 'movie',
  };
}

Map<String, dynamic> _page(Uri uri, {required bool? tv}) {
  final page = int.tryParse(uri.queryParameters['page'] ?? '1') ?? 1;
  final start = (page - 1) * 20;
  return {
    'page': page,
    'total_pages': 3,
    'total_results': 60,
    'results': [
      for (var i = 0; i < 20; i++) fakeTitle(start + i, tv: tv ?? (start + i).isOdd, mediaType: tv == null),
    ],
  };
}

Map<String, dynamic> _person(int n) => {
  'id': 500 + n,
  'name': _people[n % _people.length],
  'profile_path': '/f${500 + n}.jpg',
  'known_for_department': n % 4 == 3 ? 'Directing' : 'Acting',
  'popularity': 50.0 - n,
  'known_for': [fakeTitle(n, tv: false), fakeTitle(n + 1, tv: true)],
};

Map<String, dynamic> _details(int id, {required bool tv}) {
  final n = id % 1000;
  return {
    ...fakeTitle(n, tv: tv),
    'tagline': 'Some things are worth the wait.',
    'status': tv ? 'Returning Series' : 'Released',
    'runtime': 112,
    'episode_run_time': [48],
    'genres': [
      {'id': 18, 'name': 'Drama'},
      {'id': 53, 'name': 'Thriller'},
    ],
    'spoken_languages': [
      {'english_name': 'English', 'name': 'English'},
    ],
    'production_countries': [
      {'name': 'United States of America'},
    ],
    'production_companies': [
      {'id': 70, 'name': 'Northlight Pictures', 'logo_path': '/c70.png', 'origin_country': 'US'},
      {'id': 71, 'name': 'Halden Films', 'logo_path': null, 'origin_country': 'GB'},
    ],
    'networks': [
      if (tv) {'id': 49, 'name': 'HBO', 'logo_path': '/n49.png', 'origin_country': 'US'},
    ],
    'created_by': [
      if (tv) {'id': 503, 'name': _people[3]},
    ],
    'budget': 40000000,
    'revenue': 185000000,
    if (tv) 'number_of_seasons': _seasons(id),
    if (tv) 'number_of_episodes': _seasons(id) * _episodes(id),
    'seasons': [
      if (tv)
        for (var s = 1; s <= _seasons(id); s++)
          {'season_number': s, 'name': 'Season $s', 'episode_count': _episodes(id), 'air_date': '${2019 + s}-03-01', 'poster_path': '/s$id$s.jpg'},
    ],
    'credits': {
      'cast': [
        for (var i = 0; i < 12; i++) {'id': 500 + i, 'name': _people[i % _people.length], 'character': 'Character ${i + 1}', 'profile_path': '/f${500 + i}.jpg'},
      ],
      'crew': [
        {'id': 503, 'name': _people[3], 'job': 'Director', 'department': 'Directing'},
        {'id': 507, 'name': _people[7], 'job': 'Screenplay', 'department': 'Writing'},
      ],
    },
    'videos': {
      'results': [
        for (var i = 0; i < 4; i++) {'key': 'vid$id$i', 'name': i == 0 ? 'Official Trailer' : 'Clip ${i + 1}', 'type': i == 0 ? 'Trailer' : 'Clip', 'official': true, 'site': 'YouTube'},
      ],
    },
    'recommendations': {
      'results': [for (var i = 1; i <= 12; i++) fakeTitle(n + i, tv: tv)],
    },
    'similar': {'results': <Object>[]},
    'content_ratings': {
      'results': [
        {'iso_3166_1': 'US', 'rating': 'TV-MA'},
      ],
    },
    'release_dates': {
      'results': [
        {
          'iso_3166_1': 'US',
          'release_dates': [
            {'certification': 'PG-13'},
          ],
        },
      ],
    },
    'external_ids': {'imdb_id': 'tt${7000000 + id}'},
    'imdb_id': 'tt${7000000 + id}',
  };
}

/// The series with six seasons of ten episodes, as a tester's had (the others have three of
/// eight): `Bed.catalogue[87]`.
const sixSeasons = 2007;
int _seasons(int show) => show == sixSeasons ? 6 : 3;
int _episodes(int show) => show == sixSeasons ? 10 : 8;

Map<String, dynamic> _season(int show, int season) => {
  'id': show * 10 + season,
  'season_number': season,
  'name': 'Season $season',
  'episodes': [
    for (var e = 1; e <= _episodes(show); e++)
      {
        'id': show * 1000 + season * 100 + e,
        'episode_number': e,
        'season_number': season,
        'name': 'Chapter $e: ${_names[(show + e) % _names.length]}',
        'overview': 'What happens in episode $e, told in a sentence or two so the row has something to show.',
        'still_path': '/e$show$season$e.jpg',
        'air_date': '${2019 + season}-03-${(e * 3).toString().padLeft(2, '0')}',
        'runtime': 44 + e,
        'vote_average': 7.2 + e / 10,
      },
  ],
};

Map<String, dynamic> _personDetails(int id) {
  final n = id % 100;
  return {
    ..._person(n),
    'id': id,
    'biography': '${_people[n % _people.length]} is a made-up person with a made-up career, written out at some length here so the biography wraps and can be opened.\n\nA second paragraph follows.',
    'birthday': '1984-06-02',
    'place_of_birth': 'Leeds, England',
    'also_known_as': ['M. Ellison'],
    'images': {
      'profiles': [for (var i = 0; i < 6; i++) {'file_path': '/f$id$i.jpg'}],
    },
    'external_ids': {'imdb_id': 'nm$id', 'instagram_id': 'someone', 'twitter_id': '', 'tiktok_id': null},
    'combined_credits': {
      'cast': [
        for (var i = 0; i < 18; i++) {...fakeTitle(i, tv: i.isOdd, mediaType: true), 'character': 'Role ${i + 1}', if (i.isOdd) 'episode_count': 6 + i},
      ],
      'crew': [
        for (var i = 0; i < 4; i++) {...fakeTitle(20 + i, tv: false, mediaType: true), 'job': 'Director', 'department': 'Directing'},
      ],
    },
  };
}

/// Answers for api.themoviedb.org. Anything it doesn't know gets an empty list, which every
/// page treats as "nothing here".
FakeReply? fakeTmdb(String method, Uri uri) {
  if (uri.host != 'api.themoviedb.org') return null;
  final p = uri.path.replaceFirst('/3', '');
  final s = p.split('/').where((x) => x.isNotEmpty).toList();
  Object data;
  if (p.startsWith('/watch/providers/')) {
    data = {
      'results': [
        for (final e in _providers.entries) {'provider_id': e.key, 'provider_name': e.value, 'logo_path': '/l${e.key}.jpg'},
      ],
    };
  } else if (p.endsWith('/images')) {
    data = {'logos': <Object>[], 'posters': <Object>[], 'backdrops': <Object>[]};
  } else if (p == '/search/person') {
    data = {'results': [for (var i = 0; i < 8; i++) _person(i)]};
  } else if (p == '/search/company') {
    data = {
      'results': [
        for (var i = 0; i < 5; i++) {'id': 70 + i, 'name': '${_names[i]} Pictures', 'logo_path': i.isEven ? '/c${70 + i}.png' : null, 'origin_country': 'US'},
      ],
    };
  } else if (s.length == 2 && s[0] == 'network') {
    data = {'id': int.parse(s[1]), 'name': 'HBO', 'logo_path': '/n${s[1]}.png', 'origin_country': 'US'};
  } else if (s.length == 2 && s[0] == 'person') {
    data = _personDetails(int.parse(s[1]));
  } else if (s.length == 4 && s[0] == 'tv' && s[2] == 'season') {
    data = _season(int.parse(s[1]), int.parse(s[3]));
  } else if (s.length == 2 && (s[0] == 'movie' || s[0] == 'tv') && int.tryParse(s[1]) != null) {
    data = _details(int.parse(s[1]), tv: s[0] == 'tv');
  } else if (s.length == 3 && s[0] == 'genre') {
    data = {
      'genres': [
        for (final g in const {28: 'Action', 35: 'Comedy', 18: 'Drama', 878: 'Science Fiction', 27: 'Horror', 16: 'Animation'}.entries) {'id': g.key, 'name': g.value},
      ],
    };
  } else if (p.contains('/tv') || p.endsWith('/tv/day') || p.endsWith('/tv/week')) {
    data = _page(uri, tv: true);
  } else if (p.contains('/movie')) {
    data = _page(uri, tv: false);
  } else if (p.startsWith('/trending/all') || p == '/search/multi') {
    data = _page(uri, tv: null);
  } else {
    data = {'results': <Object>[], 'page': 1, 'total_pages': 1, 'total_results': 0};
  }
  return FakeReply.json(data);
}
