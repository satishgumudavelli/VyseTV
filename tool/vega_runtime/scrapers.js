// Runs a scraper from a scraper list (a manifest.json with a "scrapers" list) as a VyseTV plugin.
// Such a scraper is a CommonJS script: it sets module.exports.getStreams (or a global getStreams) to
// getStreams(tmdbId, mediaType, season, episode) and answers [{ name, title, url, quality, size,
// headers }]. It may require('cheerio-without-node-native') (or cheerio, react-native-cheerio),
// 'axios' or 'crypto-js', and use fetch, URL, atob and setTimeout.
// Some also list titles to browse (their manifest entry names `catalogs`): getCatalog(args) answers a
// page of one, and getMeta(args) a title's details, Stremio's way ({ metas } and { meta }) or the
// paged way ({ items, nextPageToken }). Their getStreams then also takes their own ids.
// Needs, defined before this file: vega_runtime.js (fetch, __axiosLib, __cheerioLib, the polyfills)
// and __cryptoLib (the real crypto-js, bundled ahead of this file in scraper_runtime.js).
// The plugin script calls __scrapers.load(id, function (module, exports, require) { <the scraper> }),
// then hands VyseTV its own getStreams(query): __scrapers.getStreams.
var __scrapers = (function () {
  var modules = {
    'cheerio': __cheerioLib,
    'cheerio-without-node-native': __cheerioLib,
    'react-native-cheerio': __cheerioLib,
    'axios': __axiosLib,
    'crypto-js': __cryptoLib
  };
  function require(name) {
    if (Object.prototype.hasOwnProperty.call(modules, name)) return modules[name];
    throw new Error("Cannot find module '" + name + "'");
  }
  if (typeof globalThis.global === 'undefined') globalThis.global = globalThis;
  if (typeof globalThis.window === 'undefined') globalThis.window = globalThis;
  if (typeof globalThis.self === 'undefined') globalThis.self = globalThis;
  if (typeof globalThis.CryptoJS === 'undefined') globalThis.CryptoJS = __cryptoLib;
  if (typeof console.debug !== 'function') console.debug = console.log;

  var found = null, catalogFn = null, metaFn = null;
  function text(x) { return x == null ? '' : String(x).trim(); }
  // the script's own function [name]: exported, or left global by the script
  function own(ex, name, before) {
    if (ex && typeof ex[name] === 'function') return ex[name];
    return globalThis[name] !== before && typeof globalThis[name] === 'function' ? globalThis[name] : null;
  }

  return {
    // The scraper's code runs in a function of its own, so its getStreams stays its own.
    load: function (id, run) {
      globalThis.SCRAPER_ID = id;
      globalThis.SCRAPER_SETTINGS = {};
      var module = { exports: {} };
      var before = { getStreams: globalThis.getStreams, getCatalog: globalThis.getCatalog, getMeta: globalThis.getMeta };
      run.call(globalThis, module, module.exports, require);
      var ex = module.exports;
      found = (ex && typeof ex.getStreams === 'function' && ex.getStreams) || (typeof ex === 'function' ? ex : null) || own(null, 'getStreams', before.getStreams);
      catalogFn = own(ex, 'getCatalog', before.getCatalog);
      metaFn = own(ex, 'getMeta', before.getMeta);
    },
    // VyseTV's question in the scraper's words, and its answer in VyseTV's. `ownId`: one of the
    // scraper's own titles (from its catalogs), asked for by its own id.
    getStreams: async function (q) {
      if (!found) throw new Error('the scraper has no getStreams');
      var id = q.ownId != null ? String(q.ownId) : (q.tmdbId == null ? null : String(q.tmdbId));
      if (id == null) return [];
      var tv = !!q.isTv;
      var r = await found(id, tv ? 'tv' : 'movie', tv ? q.season : undefined, tv ? q.episode : undefined);
      return (Array.isArray(r) ? r : []).filter(function (s) { return s && typeof s.url === 'string'; }).map(function (s) {
        var hints = s.behaviorHints || {};
        var proxy = hints.proxyHeaders && hints.proxyHeaders.request;
        var label = [text(s.title), text(s.size)].filter(Boolean).join(' · ');
        return {
          url: s.url,
          type: typeof s.type === 'string' ? s.type : undefined,
          quality: text(s.quality) || undefined,
          server: text(s.name) || text(s.provider) || undefined,
          label: label || undefined,
          headers: s.headers || proxy || undefined
        };
      });
    },
    // One page of one of its catalogs (or a search in it). Asked both ways scripts are written:
    // Stremio's ({ type, id, extra: { search, skip, genre } }) and the paged one ({ catalogId, type,
    // pageToken }). The answer: { metas, next } (next: the paged one's token for the page after).
    catalog: async function (q) {
      if (!catalogFn) throw new Error('the scraper has no getCatalog');
      var extra = {};
      if (q.search) extra.search = q.search;
      if (q.skip) extra.skip = q.skip;
      if (q.genre) extra.genre = q.genre;
      var r = await catalogFn({
        catalogId: q.catalogId, id: q.catalogId, type: q.type, pageToken: q.pageToken || undefined, page: q.page || 1,
        skip: q.skip || 0, search: q.search || undefined, query: q.search || undefined, genre: q.genre || undefined, extra: extra
      });
      var list = Array.isArray(r) ? r : (r && (r.metas || r.items || r.results)) || [];
      return {
        metas: (Array.isArray(list) ? list : []).filter(function (m) { return m && m.id != null && (m.name || m.title); }),
        next: r && !Array.isArray(r) && r.nextPageToken != null ? String(r.nextPageToken) : undefined
      };
    },
    // A title's details, Stremio's way ({ meta }); null when the script has none to give.
    meta: async function (q) {
      if (!metaFn) return { meta: null };
      var r = await metaFn({ id: q.id, type: q.type });
      var m = r && (r.meta || (r.id != null ? r : null));
      return { meta: m || null };
    }
  };
})();
globalThis.__scraperCatalog = function (q) { return __scrapers.catalog(q); };
globalThis.__scraperMeta = function (q) { return __scrapers.meta(q); };
