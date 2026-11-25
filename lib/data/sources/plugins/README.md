# Scraper plugins

A plugin is **one JavaScript file** that finds playable streams for a film or an episode. VyseTV
downloads it from a *repository* (a `repo.json` on any web host, for example a GitHub raw link), runs it in a
sandbox and asks it for streams with your other addons. The app ships no plugins.

* Engine and bridge: [`js_plugins.dart`](js_plugins.dart) (QuickJS through `flutter_js`, JavaScriptCore on Apple
  devices, each run in an isolate of its own).
* The repository as an addon: `Addons.install`, `Addons.streams` in [`../addons.dart`](../addons.dart).
* Title helpers every plugin can call: [`assets/plugins/helpers.js`](../../../../assets/plugins/helpers.js).
* A working example: [`example/`](example).
* Tests: `test/dpad/t4_journeys_plugins_test.dart` (a stand-in engine), `t4_journeys_plugin_catalogs_test.dart`
  (plugins that list titles), `t4_journeys_party_plugins_test.dart` (watch parties) and
  `test/dpad/t4_journeys_plugins_engine_test.dart` (the real engine, where its library is built).

## For users

Settings → Addons → paste the repository's link (its `repo.json`, a scraper list's `manifest.json` or a Vega
`manifest.json`) where Stremio addon links go. The repository
becomes one addon, marked *Plugins*: it can be moved, switched off and removed like the others, and its plugins'
streams show on the sources screen with the other addons'. Your addon list syncs with your account; the scripts
don't: each device downloads them the first time it needs them. They are checked once a day with the other addons,
and only the plugins whose `version` changed are downloaded again. What the plugins report is in the addon's
*Plugin log*.

*Find plugins*, in the same Settings tab, lists every public repository that works today: VyseTV's server checks them
once a day (`lib/data/sources/plugins/plugin_index.dart`), and Install adds one as if its link had been pasted.

Plugins run code from the repository you add: only add repositories you trust. See *Sandbox* below.

## repo.json

```json
{
  "name": "My plugins",
  "plugins": [
    { "id": "mysite", "name": "MySite", "version": "1", "note": "Films and shows",
      "types": ["movie", "tv"], "url": "plugins/mysite.js" }
  ]
}
```

`id` is unique and stable, `version` is any string (a change means an update), `url` is relative to the
`repo.json` or absolute. `types` is `movie`, `tv` or both.

## The plugin contract

Define a global `getStreams(query)` (it may be `async`).

```js
// query
{
  tmdbId: 872585, imdbId: 'tt15398776',   // either can be null
  type: 'movie' | 'tv', isTv: false,
  title: 'Oppenheimer', originalTitle: 'Oppenheimer', year: 2023,
  titles: ['Oppenheimer', /* every name TMDB knows it by */],
  isAnime: false,
  season: null, episode: null             // numbers for 'tv'
}

// return an array, empty when the title is not on the site
[{
  url: 'https://…',             // required, http(s) only
  type: 'hls' | 'dash' | 'mp4', // 'mp4' also for mkv/webm; guessed from the URL when left out
  quality: '1080p',             // shown in the list
  server: 'MySite Fast',        // shown in the list
  label: undefined,             // optional extra text
  audio: 'Hindi',               // optional: the language this link is dubbed in
  headers: { Referer: '…' }     // optional: sent with every request for this stream
}]
```

Return `[]` when the title is not found; do not throw for that. Put the best links first.

### What the script can use

| Global | |
|---|---|
| `http(url, {method, headers, body, timeout})` | `Promise<{status, url, headers, text}>`. **Never throws**: on a network error `status` is `0` and `error` says why. Response header names are lower-case. `body` is a string or an object (sent as JSON). Up to 5 redirects are followed. `timeout` in ms, capped at 20000. |
| `JSON`, `RegExp`, `Promise`, `Math`, `Date`, `setTimeout`, `btoa`, `atob` | the language |
| `parseHtml(html)`, `unescapeHtml(s)` | a small HTML tree with CSS selectors (`select`, `selectFirst`, `attr`, `text`, `data`, `html`) |
| title helpers | `searchQueries`, `searchBest`, `searchByImdb`, `bestMatch`, `rankMatches`, `parseTitle`, `titleScore`, `imdbMatches`, `normTitle` |
| `console.log` | goes to the plugin log |

Not available: a browser DOM, `fetch`, `XMLHttpRequest`, `require`/`import`, Node APIs, `crypto`, WebAssembly, cookies
between calls (send them in `headers`).

### Sandbox

* The script has no access to the app, its files or its settings; only `http()` and the globals above.
* `http()` refuses `localhost`, loopback, private ranges (`10.x`, `172.16–31.x`, `192.168.x`, `100.64–127.x`),
  link-local and `*.local`, also after a redirect, so a plugin can't reach the user's own network.
* Every call starts a fresh engine: nothing is kept between calls.

### Limits

* A plugin gets 25 s. The engine stops a script after 20 s of computation. A memory cap (96 MB) is set only
  where the engine's library can set one: flutter_js's libraries for Windows and Android can't, so keep memory use
  modest. Aim for under 10 s and run independent requests with `Promise.all`.
* A repository's plugins are asked several at once (as many as the device has cores, 3 to 8), and what each
  finds shows on the sources screen as soon as it answers. Ones that keep failing are asked last.
* QuickJS is an interpreter: CPU-heavy code (pure-JS crypto with many rounds) is 20–50× slower than in Node, more on a TV.

### What the app does with the links

Links play the way an addon's do: return direct stream URLs (not pages with a player), set `type` (an HLS link
need not end in `.m3u8` then), and drop expired signed URLs. The Linux build's player has no DASH: a `dash` link
isn't offered there.

In a watch party the host's link is never shared: a plugin's links are often only good for whoever asked. The
room gets which plugin found it and which of its links it was (its place in the list, `server`, `quality`,
`label`, `audio`, `type`). Each guest runs that plugin on their own device, even when the repository isn't one
of their addons (its list and that one script are fetched and kept in memory, never installed), and plays the
link most like the host's: the same language first, then label, server and quality. When the plugin finds
nothing there, the repository's other plugins are asked until one does. So keep the order and names of your
links steady from one run to the next.

## Matching titles

Do not write your own matching. `searchBest(query, search, get)` runs the site's search with each string from
`searchQueries(query)` until a listing matches; matching ignores case and punctuation, checks a film's year, and for a
show prefers the right season. `imdbMatches(pageText, query)` confirms a page is the right film by its IMDb id.

```js
var hit = await searchBest(q, async function (text) {
  var r = await http(BASE + '/search?q=' + encodeURIComponent(text));
  return parseListings(r.text);               // [{ name: 'Dune Part Two (2024) 1080p', url: '…' }, …]
}, function (l) { return l.name; });
if (!hit) return [];
```

## Scraper lists

A repository link can also be a scraper list: a `manifest.json` with a `scrapers` list, the format several other
players use for their community scrapers.

```json
{
  "name": "Their scrapers",
  "scrapers": [
    { "id": "site", "name": "Site", "version": "1.0.0", "filename": "providers/site.js",
      "supportedTypes": ["movie", "tv"], "enabled": true, "contentLanguage": ["en"] }
  ]
}
```

Each scraper whose `enabled` isn't `false` becomes a plugin (its `filename` is relative to the manifest). A scraper is a
CommonJS script: it sets `module.exports.getStreams` (or a global `getStreams`) to
`getStreams(tmdbId, mediaType, season, episode)` (`mediaType` is `movie` or `tv`; season and episode are left out for a
film) and answers `[{ name, title, url, quality, size, headers }]`. VyseTV runs it on the scraper-list adapter
(`assets/plugins/scraper_runtime.js`, after the Vega runtime): `fetch`, `require` for `cheerio`,
`cheerio-without-node-native`, `react-native-cheerio`, `axios` and `crypto-js` (the real libraries), `URL`, `atob`,
`setTimeout`/`clearTimeout`, `SCRAPER_ID` and `SCRAPER_SETTINGS` (empty). Its `name` shows as the server, its `title`
and `size` under it. A title with no TMDB id (one from a metadata addon that has none) isn't asked.

## Vega providers

A repository link can also be a Vega provider `manifest.json` (a JSON list of providers built into
`dist/<value>/{posts,meta,stream,episodes}.js` next to it). Each enabled provider becomes a plugin named after it.
Vega providers browse a site, so the app adapts them to `getStreams`: it searches the site with the title, opens the
matching page, picks the film's links or the season and episode, and resolves them to video files (DRM streams are
dropped). They run on `assets/plugins/vega_runtime.js` (the real axios and cheerio, `URL` polyfills and the adapter),
in the same sandbox and with the same limits as other plugins. Providers that need a browser challenge
(`openWebView`) find nothing. Details, and how to rebuild the runtime: [tool/vega_runtime/README.md](../../../../tool/vega_runtime/README.md).

## Plugins that list titles

Some plugins also list titles to browse, the way a Stremio metadata addon does. VyseTV shows them like one
([`plugin_catalogs.dart`](plugin_catalogs.dart)): their catalogs are rows on Home, catalogs on Discover and a search,
their titles open on their own pages (details, seasons, episodes), and they play from the same plugin, asked for
their own ids. Which plugins' catalogs show is picked per repository in Settings → Addons → *Catalogs to browse*: a
scraper list's are on when it is added, a Vega provider's off (a repository of them can list hundreds). A title goes
by `pl:<repository key>:<plugin id>:<its own id>`.

* **Vega providers**: each provider's `dist/<value>/catalog.js` (`catalog`: `[{ title, filter }]`, `genres`) is read
  when it is installed, on its own without the runtime. A catalog's page is `getPosts({ filter, page })`, a genre's the
  genre's filter, a search `getSearchPosts`; a title's page is `getMeta` (a show's seasons from its `linkList`, each
  season's episodes from `getEpisodes` or its `directLinks`). A title's own id is its page's link, an episode's
  `<link>|<season>|<episode>`.
* **Scraper lists**: an entry that names `catalogs` (`[{ id, name, type, extra }]`, `type` `movie`, or `tv` for shows;
  `extra` may name `search` and `genre` with its `options`) lists titles with its script's `getCatalog(args)`. VyseTV
  asks it both ways scripts are written: Stremio's (`{ type, id, extra: { search, skip, genre } }`, answered
  `{ metas: [...] }`) and the paged one (`{ catalogId, type, pageToken }`, answered `{ items: [...], nextPageToken }`).
  An entry whose `resources` name `meta` gives a title's details with `getMeta({ id, type })` (answered `{ meta }`, with
  its `videos`); without it, a title's page comes from TMDB when TMDB knows it, else from its catalog. Its
  `getStreams(id, mediaType, season, episode)` is then also asked with the title's own id (or its episode's) in place of
  a TMDB id.
* **Comics**: a Vega provider whose manifest entry's `type` is `comic` (or a scraper whose types say `manga` or
  `comic`) lists comics, not videos ([`data/manga/plugin_comics.dart`](../../manga/plugin_comics.dart)). It is never
  asked for a video's streams and its catalogs never reach Home: the Manga section has a shelf of each one's first list
  (See all opens all its lists), and its search joins the Manga search. A series' details and chapters come from
  `getMeta` (its `linkList`: `directLinks`, or `getEpisodes` for an `episodesLink`), a chapter's pages from `getPages`
  (else `getStream`): `[{ link | imageUrl, index, headers }]`, read in the Manga reader with their headers. Comic
  plugins are on until turned off in *Catalogs to browse* (marked *In Manga*).

## Try a plugin without the app

The helpers file is plain JavaScript, so a plugin can be run in Node with a small stand-in for `http()` (see
`example/demo.js`, which only prints what it would return):

```
node lib/data/sources/plugins/example/run.mjs
```
