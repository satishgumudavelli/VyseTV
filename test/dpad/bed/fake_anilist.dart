// A made-up AniList for the test bed. The app asks AniList one question per request (a GraphQL
// query in the request's body). The bed's fake network does not read bodies, so every request
// gets the same answer holding everything any of the app's queries reads: a page of anime, one
// anime in full, and the genre, tag and streaming-site lists.
const _titles = [
  'Paper Lanterns', 'The Ninth Tide', 'Clockwork Garden', 'Ashfall Academy', 'Moonlit Courier', 'Iron Sparrow',
  'Quiet Thunder', 'Glass Orchard', 'Saltwater Saints', 'Lantern Street', 'Winter Atlas', 'The Hollow Crown',
  'Signal Fires', 'Tin Soldier Blues', 'Northbound', 'Harbor of Stars', 'The Long Rain', 'Ember and Oak',
  'Fox in the Machine', 'Paper Cranes', 'Violet Hours', 'Second Summer', 'The Cartographer', 'Stray Comet',
  'Low Tide Detective', 'Kingdom of Dust', 'Rooftop Radio', 'A Field of Kites', 'Midnight Ferry', 'Borrowed Wings',
];

const _genres = ['Action', 'Adventure', 'Comedy', 'Drama', 'Fantasy', 'Mystery', 'Romance', 'Sci-Fi', 'Slice of Life', 'Sports'];

Map<String, Object?> _card(int n) => {
  'id': 9000 + n,
  'idMal': 4000 + n,
  'title': {'romaji': _titles[n % _titles.length], 'english': _titles[n % _titles.length], 'native': ''},
  'synonyms': const <String>[],
  'coverImage': {'extraLarge': 'https://img.anilist.example/cover$n.jpg', 'large': 'https://img.anilist.example/cover$n.jpg', 'color': '#5b8def'},
  'bannerImage': 'https://img.anilist.example/banner$n.jpg',
  'type': 'ANIME',
  'format': n % 5 == 0 ? 'MOVIE' : 'TV',
  'status': n % 4 == 0 ? 'RELEASING' : 'FINISHED',
  'episodes': n % 5 == 0 ? 1 : 12 + n % 3 * 12,
  'duration': 24,
  'season': const ['WINTER', 'SPRING', 'SUMMER', 'FALL'][n % 4],
  'seasonYear': 2015 + n % 10,
  'startDate': {'year': 2015 + n % 10, 'month': 1 + n % 12, 'day': 1 + n % 27},
  'endDate': {'year': 2015 + n % 10, 'month': 1 + (n + 3) % 12, 'day': 1 + n % 27},
  'averageScore': 62 + n % 30,
  'popularity': 100000 - n * 900,
  'favourites': 9000 - n * 70,
  'genres': [_genres[n % _genres.length], _genres[(n + 3) % _genres.length]],
  'description': 'A made-up description of ${_titles[n % _titles.length]}, long enough to wrap onto a second line on most screens.',
  'studios': {
    'nodes': [
      {'name': 'Studio Marrow'},
    ],
  },
  'source': 'MANGA',
  'countryOfOrigin': 'JP',
  'isAdult': false,
  'siteUrl': 'https://anilist.co/anime/${9000 + n}',
};

/// The one answer every AniList request gets.
Map<String, Object?> fakeAniList() => {
  'data': {
    'Page': {
      'pageInfo': {'total': 30, 'hasNextPage': false},
      'media': [for (var n = 0; n < 30; n++) _card(n)],
    },
    'Media': {
      ..._card(0),
      'tags': [
        for (final t in const ['Found Family', 'Coming of Age', 'Travel']) {'name': t, 'rank': 80, 'isMediaSpoiler': false, 'isGeneralSpoiler': false},
      ],
      'relations': {
        'edges': [
          for (var n = 1; n <= 3; n++) {'relationType': n == 1 ? 'SEQUEL' : 'SIDE_STORY', 'node': _card(n)},
        ],
      },
      'recommendations': {
        'nodes': [
          for (var n = 4; n <= 12; n++) {'mediaRecommendation': _card(n)},
        ],
      },
      'characters': {
        'edges': [
          for (var n = 0; n < 8; n++)
            {
              'role': n < 2 ? 'MAIN' : 'SUPPORTING',
              'node': {
                'id': 700 + n,
                'name': {'full': 'Character ${n + 1}'},
                'image': {'large': 'https://img.anilist.example/char$n.jpg'},
              },
              'voiceActors': [
                {
                  'id': 800 + n,
                  'name': {'full': 'Voice Actor ${n + 1}'},
                  'image': {'large': 'https://img.anilist.example/va$n.jpg'},
                },
              ],
            },
        ],
      },
      'streamingEpisodes': [
        for (var e = 1; e <= 12; e++) {'title': 'Episode $e - Chapter $e', 'thumbnail': 'https://img.anilist.example/ep$e.jpg'},
      ],
    },
    'GenreCollection': _genres,
    'MediaTagCollection': [
      for (final t in const ['Found Family', 'Coming of Age', 'Travel', 'School', 'Magic', 'Space'])
        {'name': t, 'category': 'Theme', 'description': 'A made-up tag.', 'isAdult': false},
    ],
    'ExternalLinkSourceCollection': [
      for (var i = 0; i < 4; i++) {'id': 50 + i, 'site': const ['Crunchyroll', 'HIDIVE', 'Netflix', 'Hulu'][i], 'color': '#f47521', 'icon': null},
    ],
  },
};
