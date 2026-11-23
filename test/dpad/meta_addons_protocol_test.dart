// Stremio metadata addons, the data side: what VyseTV reads from a manifest (catalogs, details),
// the addresses it asks, the titles it makes of what comes back, and the ids the stream addons
// are asked for. The addons are made up (bed/fake_addons.dart); nothing is fetched here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/catalog/meta_addons.dart';
import 'package:vyse_tv/data/catalog/tmdb.dart';
import 'package:vyse_tv/data/sources/addons.dart';

import 'bed/fake_addons.dart';
import 'bed/fake_net.dart';
import 'bed/fake_tmdb.dart';

void main() {
  final lantern = Addon.fromManifest(lanternUrl, lanternManifest);
  final kite = Addon.fromManifest(kiteUrl, kiteManifest);
  final brook = Addon.fromManifest(brookUrl, brookManifest);
  final hollow = Addon.fromManifest(hollowUrl, hollowManifest);
  final shelfmark = Addon.fromManifest(shelfmarkUrl, shelfmarkManifest);
  final quill = Addon.fromManifest(quillUrl, quillManifest);
  late FakeHttp net;

  setUpAll(() => HttpOverrides.global = net = FakeHttp((method, uri) => fakeAddons(method, uri) ?? fakeTmdb(method, uri)));
  setUp(MetaAddons.debugReset);
  tearDown(() => Addons.list.value = const []);

  test('a manifest: catalogs (rows, genres, search, paging, what is never asked) and details', () {
    expect((lantern.metadata, lantern.meta, lantern.streams), (true, true, false));
    expect((brook.metadata, brook.streams), (false, true));
    expect(lantern.metaFor('series', 'tt0944947'), isTrue);
    expect(lantern.metaFor('series', 'kitsu:1'), isFalse, reason: 'its ids start with tt');
    final cats = lantern.catalogs;
    expect([for (final c in cats) if (c.board) c.id], ['top', 'top', 'list0', 'list1', 'list2', 'list3']);
    expect(cats.first.genres, contains('Western'));
    expect((cats.first.search, cats.first.skip), (true, true));
    expect(cats.firstWhere((c) => c.id == 'year').genreRequired, isTrue, reason: 'it lists one year at a time');
    expect(cats.firstWhere((c) => c.id == 'year').browsable, isTrue);
    expect(cats.firstWhere((c) => c.id == 'last-videos').otherRequired, isTrue, reason: 'it needs ids VyseTV has none of');
    expect(kite.catalogs.firstWhere((c) => c.id == 'kite-search').searchOnly, isTrue);

    // the older way of writing it
    final old = AddonCatalog.fromManifest({
      'type': 'movie',
      'id': 'old',
      'genres': ['A', 'B'],
      'extraSupported': ['genre', 'skip'],
      'extraRequired': ['genre'],
    })!;
    expect(old.genres, ['A', 'B']);
    expect((old.genreRequired, old.skip, old.name), (true, true, 'old'));

    // kept in the synced list as it was read
    final back = Addon.fromJson(jsonDecode(jsonEncode(lantern.toJson())) as Map<String, dynamic>)!;
    expect(back.catalogs.map((c) => c.toJson()), lantern.catalogs.map((c) => c.toJson()));
    expect(back.metaPrefixes, ['tt']);
    expect((back.meta, back.catalogsRead), (true, true));
    expect(Addon.fromJson({'url': 'https://x.test/manifest.json', 'id': 'x', 'name': 'X'})!.catalogsRead, isFalse, reason: 'saved before catalogs were read');
  });

  test('TMDB is a built-in metadata addon, on unless turned off; the list keeps your order', () {
    final l = Addons.withBuiltIns([lantern]);
    expect([for (final a in l) a.name], ['Lantern', 'TMDB', 'Knaben']);
    Addons.list.value = l;
    expect(Addons.tmdbOn, isTrue);
    expect(Addons.metaAddons.single.name, 'Lantern');
    Addons.list.value = [for (final a in l) a.manifestUrl == Addon.tmdb.manifestUrl ? a.copyWith(enabled: false) : a];
    expect((Addons.tmdbOn, Addons.addonsOnly), (false, true));
    Addons.list.value = const [];
    expect(Addons.tmdbOn, isTrue, reason: 'before the list is read');
  });

  test('catalog and details addresses, as Stremio asks them', () {
    final top = lantern.catalogs.first;
    expect(MetaAddons.catalogUrl(lantern, top), 'https://lantern.test/catalog/movie/top.json');
    expect(MetaAddons.catalogUrl(lantern, top, genre: 'Sci-Fi', skip: 100), 'https://lantern.test/catalog/movie/top/genre=Sci-Fi&skip=100.json');
    expect(MetaAddons.catalogUrl(lantern, top, search: 'blue hour'), 'https://lantern.test/catalog/movie/top/search=blue%20hour.json');
    expect(MetaAddons.segment('tt0944947:1:1'), 'tt0944947:1:1', reason: 'colons stay');
    expect(MetaAddons.catalogTitle(top), 'Popular · Movies');
    expect(MetaAddons.catalogTitle(kite.catalogs.first), 'Kite Trending · Anime');
  });

  test('a title from an addon: its key, TMDB id when the addon gives one, and every copy reads back as one', () {
    final film = MetaAddons.media(lanternFilm(5), type: 'movie', from: lantern)!;
    expect((film.key, film.isAddon, film.tmdbKnown, film.id < 0), ('meta/tt1000005', true, false, true));
    expect((film.title, film.year, film.rating, film.kind), ('Copperhead', '2015', 7.5, 'Movie'));
    expect(film.posterPath, 'https://img.test/lp5.jpg');
    expect(film.poster(), 'https://img.test/lp5.jpg', reason: 'a full address, used as it is');

    final matched = MetaAddons.media(lanternFilm(1), type: 'movie')!;
    expect((matched.id, matched.tmdbKnown, matched.key), (1001, true, 'meta/tt1000001'), reason: 'Cinemeta-style moviedb_id');
    expect(MetaAddons.media({'id': 'tmdb:550', 'type': 'movie', 'name': 'A film'})!.id, 550);
    expect(MetaAddons.media({'id': 'x'}), isNull, reason: 'no name');

    // Kite's catalog says anime, the item says series: the item's own word is what it is asked as
    final show = MetaAddons.media(kiteShow(2), type: 'anime')!;
    expect((show.addonType, show.isTv, show.kind), ('series', true, 'Series'));

    // the copies My List, progress and a party keep go through Media.fromJson
    final json = {'id': film.id, 'title': film.title, 'tv': false, 'release_date': film.date, ...film.addonFields};
    final read = Media.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>, tv: false);
    expect((read.key, read.addonType, read.isAddon), (film.key, 'movie', true));
    expect(film.withTmdb(1005).key, film.key, reason: 'matched to TMDB, still the same title');
    expect(film.withTmdb(1005).tmdbKnown, isTrue);
  });

  test('the ids a stream addon is asked for: the video\'s own, else IMDb\'s where its numbers are known', () {
    const t = AddonTarget(
      type: 'series',
      raw: 'kite:7',
      video: 'kite:7:2',
      imdb: 'tt777',
      season: 1,
      episode: 2,
      imdbSeason: 3,
      imdbEpisode: 14,
      videos: [AddonVideoRef(season: 1, episode: 3, id: 'kite:7:3', imdbSeason: 3, imdbEpisode: 15)],
    );
    expect(t.idFor(['kite', 'tt']), 'kite:7:2');
    expect(t.idFor(['tt']), 'tt777:3:14');
    expect(t.idFor(const []), 'tt777:3:14', reason: 'an addon that names no prefixes takes IMDb ids');
    expect(t.withEpisode(1, 3).idFor(['kite']), 'kite:7:3');
    expect(t.withEpisode(1, 3).idFor(['tt']), 'tt777:3:15');
    const unknown = AddonTarget(type: 'series', raw: 'kite:9', video: 'kite:9:1', imdb: 'tt9', season: 1, episode: 1);
    expect(unknown.idFor(['tt']), isNull, reason: "IMDb's numbers for it aren't known: no guess");
    const film = AddonTarget(type: 'movie', raw: 'tt42', imdb: 'tt42');
    expect(film.idFor(['tt']), 'tt42');
    const channel = AddonTarget(type: 'tv', raw: 'yt:abc');
    expect(channel.idFor(['yt']), 'yt:abc');
    expect(channel.typeOk(['tv']), isTrue);
    expect(MetaAddons.minutes('1h 42min'), 102);
    expect(MetaAddons.minutes('57 min'), 57);
    expect(MetaAddons.minutes(''), isNull);
  });

  test('a collection: its films are titles of their own (own ids, TMDB id where given, pictures), not episodes', () async {
    Addons.list.value = Addons.withBuiltIns([shelfmark]);
    final col = (await MetaAddons.page(shelfmark, shelfmark.catalogs.single)).single;
    expect((col.key, col.addonType, col.isTv), ('meta/col.1', 'movie', false));
    expect(col.poster(), 'https://image.tmdb.org/t/p/w342/col1.jpg', reason: 'a TMDB picture path, drawn from TMDB');
    final x = await MetaAddons.meta(col);
    expect(x.collection, isTrue);
    expect((x.media.isTv, x.details.episodeCount), (false, null));
    expect(x.details.seasons, isEmpty);
    expect([for (final p in x.parts) p.key], ['meta/tt1000002', 'meta/tt1000004']);
    expect([for (final p in x.details.parts) p.title], ['Paper Moons', 'Harbour Lights']);
    final first = x.parts.first, second = x.parts.last;
    expect((first.id, first.tmdbKnown, first.isTv, first.addonType, first.year), (1002, true, false, 'movie', '2014'));
    expect(first.poster(), 'https://image.tmdb.org/t/p/w342/p1002.jpg');
    expect(first.backdrop(), 'https://img.test/colt1.jpg');
    expect(second.tmdbKnown, isFalse, reason: 'Shelfmark gives no TMDB id for it');
    expect(await MetaAddons.partToPlay(col, (p) => p.key == first.key), same(second), reason: 'the first film not watched');
    expect(await MetaAddons.partToPlay(col, (_) => true), same(first), reason: 'all watched: from the start');
    expect(await MetaAddons.partToPlay(first, (_) => false), isNull, reason: 'a film is no collection');
  });

  test("TMDB matching: an addon's own TMDB id, else IMDb's, else the same name and year on TMDB", () async {
    Addons.list.value = Addons.withBuiltIns([shelfmark]);
    final x = await MetaAddons.meta((await MetaAddons.page(shelfmark, shelfmark.catalogs.single)).single);
    final byName = await MetaAddons.twin(x.parts.last);
    expect((byName?.id, byName?.isTv, byName?.key), (1001, false, 'meta/tt1000004'), reason: 'Harbour Lights (2013) is TMDB 1001');
    expect(net.seen.where((r) => r.contains('/3/search/movie') && r.contains('Harbour')), isNotEmpty);
    final nameless = MetaAddons.media({'id': 'zz:1', 'type': 'movie', 'name': 'No Such Film Anywhere', 'releaseInfo': '2001'})!;
    expect(await MetaAddons.twin(nameless), isNull, reason: 'a name TMDB has no film of');
    final known = MetaAddons.media(lanternFilm(3), type: 'movie')!;
    expect((await MetaAddons.twin(known))?.id, 1003, reason: 'by its IMDb id (/find)');
  });

  test("no addon has the details: TMDB's, while TMDB is on (the key stays the addon's); else what the catalog said", () async {
    Addons.list.value = Addons.withBuiltIns([hollow]);
    final moons = (await MetaAddons.page(hollow, hollow.catalogs.first)).first;
    expect((moons.title, MetaAddons.shapeOf(CatalogRef(hollow, hollow.catalogs.first))), ('Paper Moons', 'landscape'));
    final x = await MetaAddons.meta(moons);
    expect((x.from.manifestUrl, x.media.id, x.media.key), (Addon.tmdb.manifestUrl, 1002, moons.key));
    expect(x.details.genres, isNotEmpty, reason: "TMDB's details");
    MetaAddons.debugReset();
    Addons.list.value = [for (final a in Addons.withBuiltIns([hollow])) a.manifestUrl == Addon.tmdb.manifestUrl ? a.copyWith(enabled: false) : a];
    final plain = await MetaAddons.meta((await MetaAddons.page(hollow, hollow.catalogs.first)).first);
    expect((plain.media.title, plain.from.manifestUrl), ('Paper Moons', hollowUrl), reason: 'TMDB off: the catalog entry only');
    expect(plain.details.genres, isEmpty);
  });

  test("streams: a YouTube video and a page are links (listed last, never autoplayed); a stream's own subtitles", () async {
    Addons.list.value = Addons.withBuiltIns([brook]);
    const t = AddonTarget(type: 'movie', raw: 'tt1000001', imdb: 'tt1000001');
    final got = (await Addons.streams(brook, t))!.streams;
    expect(got.length, 3);
    final (file, yt, page) = (got[0], got[1], got[2]);
    expect((file.playable, file.subtitles.single.url, file.filename, file.sizeBytes), (true, 'https://subs.test/brook.en.srt', 'Brook.Film.1080p.WEB-DL.mkv', 1234567890));
    expect((yt.playable, yt.external), (false, 'https://www.youtube.com/watch?v=brookyt1'));
    expect((page.playable, page.external), (false, 'https://watch.test/film'));
    expect(AutoplayOrder.arrange(got), [file], reason: 'links are never played by themselves');
    expect(yt.rank < file.rank, isTrue);
  });

  test("streams a title's own details carry (a video's streams), and subtitle addons asked with the file's name and size", () async {
    Addons.list.value = Addons.withBuiltIns([lantern, quill]);
    final film = MetaAddons.media(lanternFilm(7), type: 'movie', from: lantern)!;
    final t = await MetaAddons.target(film);
    expect((t.video, t.inline.length, t.inlineFrom?.name), ('tt1000007', 1, 'Lantern'));
    expect(AddonStream.parse(lantern, t.inline.single)!.url, 'https://files.test/lantern-own.mkv');
    final plain = await Addons.subtitles(t);
    final matched = await Addons.subtitles(t, filename: 'Brook.Film.1080p.WEB-DL.mkv', size: 1234567890);
    expect((plain.single.url, matched.single.url), ('https://subs.test/quill.plain.srt', 'https://subs.test/quill.matched.srt'));
    expect(net.seen, contains('GET https://quill.test/subtitles/movie/tt1000007/videoSize=1234567890&filename=Brook.Film.1080p.WEB-DL.mkv.json'));
  });

  test("an addon's lists of addons (Stremio's addon catalogs): what each gives, which need setting up, no adult ones", () async {
    expect([for (final c in lantern.addonCatalogs) '${c.type}/${c.id}'], ['all/community', 'movie/community']);
    final listed = await MetaAddons.addonList(lantern, lantern.addonCatalogs.first);
    expect([for (final a in listed) a.name], ['Brook', 'Kite', 'Needs Setup']);
    expect([for (final a in listed) a.needsSetup], [false, false, true]);
    expect(listed.first.manifestUrl, brookUrl);
  });

  test("Stremio links: a title, a search, a catalog; Stremio Web's too; anything else is not one", () {
    final d = StremioLink.parse('stremio:///detail/movie/col.1') as StremioDetail;
    expect((d.type, d.id), ('movie', 'col.1'));
    final d2 = StremioLink.parse('stremio://detail/series/tt0944947') as StremioDetail;
    expect((d2.type, d2.id), ('series', 'tt0944947'));
    final web = StremioLink.parse('https://web.stremio.com/#/detail/movie/tt0111161') as StremioDetail;
    expect(web.id, 'tt0111161');
    expect((StremioLink.parse('stremio:///search?search=Iris%20Vale') as StremioSearch).query, 'Iris Vale');
    final disc = StremioLink.parse('stremio:///discover/https%3A%2F%2Flantern.test%2Fmanifest.json/movie/top?genre=Drama') as StremioDiscover;
    expect((disc.manifestUrl, disc.type, disc.catalogId, disc.genre), ('https://lantern.test/manifest.json', 'movie', 'top', 'Drama'));
    expect(StremioLink.parse('https://watch.test/film'), isNull);
    expect(StremioLink.parse('stremio:///board'), isNull);
  });

  test('manifests are read again (at most once a day): a changed addon is kept current, in its place, on or off as left', () async {
    final old = Addon.fromJson({...lantern.toJson(), 'cat': <Object>[], 'on': false})!;
    Addons.list.value = Addons.withBuiltIns([old, brook]);
    await Addons.refresh(force: true);
    final now = Addons.list.value;
    expect([for (final a in now) a.name], ['Lantern', 'Brook', 'TMDB', 'Knaben']);
    expect((now.first.catalogs.length, now.first.enabled), (lantern.catalogs.length, false));
  });
}
