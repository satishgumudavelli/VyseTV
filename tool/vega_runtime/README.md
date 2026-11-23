# Vega providers in VyseTV

A plugin repository link in Settings → Addons can be a Vega provider `manifest.json`: a JSON list of
providers, each built into `dist/<value>/{posts,meta,stream,episodes}.js` next to it. Every enabled provider becomes a source named
`vega-<value>`. (`disabled` ones, and the torrent/live/YouTube ones, are left out.)

Vega providers browse a site, so the app adapts them to the plugin contract `getStreams(query)`:

1. search the site with the title (`getSearchPosts`) and keep the listings that match (title, year; "Download …" prefixes are ignored),
2. read the page (`getMeta`; a listing naming another IMDb id is skipped) and pick the film's links, or the season and episode
   (`getEpisodes` when a season is loaded separately),
3. resolve each link to video files (`getStream`); DRM streams are dropped.

They run in the same sandbox, with the same time budget (17 s) and one retry for reset connections, as other plugins, on
`assets/plugins/vega_runtime.js`: the real axios (its transport replaced by the plugin `http()`), the real cheerio, polyfills for
`URL`, `URLSearchParams`, `TextEncoder`/`TextDecoder` and `AbortController`, a `fetch`, and the adapter. The domain a provider asks
`getBaseUrl` for is read from the repository's `urls.json`.

Not supported: `openWebView` (a browser challenge: those providers find nothing), cookies kept between calls, multipart bodies.

## Scraper lists

`assets/plugins/scraper_runtime.js` runs a scraper from a scraper list (a `manifest.json` with a `scrapers` list):
the real crypto-js, then `scrapers.js`, which gives the scraper `module`, `exports` and `require` (cheerio, axios,
crypto-js), runs it in a function of its own and answers VyseTV's `getStreams(query)` with its
`getStreams(tmdbId, mediaType, season, episode)`. It loads after `vega_runtime.js`, whose `fetch`, axios and cheerio it uses.

## Files

* `polyfills.js`, `adapter.js`, `scrapers.js`: the sources. `package.json` pins axios, cheerio, crypto-js and esbuild.
* `node build.mjs` (after `npm install`): writes `assets/plugins/vega_runtime.js` and `scraper_runtime.js`. Rebuild after editing a source file.
* `node try.mjs <base-url> <provider> movie|tv "<title>" <year> <tmdbId> <imdbId> [season episode]`: runs one provider in Node and
  lists the streams, e.g.
  `node try.mjs <the repository's raw base link> <provider> movie "Oppenheimer" 2023 872585 tt15398776`.
* `test/dpad/t4_journeys_plugins_engine_test.dart` runs a provider with no network in the real QuickJS engine (it needs the engine library from a build of the app).
