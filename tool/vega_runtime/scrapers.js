// Runs a scraper from a scraper list (a manifest.json with a "scrapers" list) as a VyseTV plugin.
// Such a scraper is a CommonJS script: it sets module.exports.getStreams (or a global getStreams) to
// getStreams(tmdbId, mediaType, season, episode) and answers [{ name, title, url, quality, size,
// headers }]. It may require('cheerio-without-node-native') (or cheerio, react-native-cheerio),
// 'axios' or 'crypto-js', and use fetch, URL, atob and setTimeout.
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

  var found = null;
  function text(x) { return x == null ? '' : String(x).trim(); }

  return {
    // The scraper's code runs in a function of its own, so its getStreams stays its own.
    load: function (id, run) {
      globalThis.SCRAPER_ID = id;
      globalThis.SCRAPER_SETTINGS = {};
      var module = { exports: {} };
      var before = globalThis.getStreams;
      run.call(globalThis, module, module.exports, require);
      var ex = module.exports;
      found = (ex && typeof ex.getStreams === 'function' && ex.getStreams) ||
        (typeof ex === 'function' ? ex : null) ||
        (globalThis.getStreams !== before && typeof globalThis.getStreams === 'function' ? globalThis.getStreams : null);
    },
    // VyseTV's question in the scraper's words, and its answer in VyseTV's.
    getStreams: async function (q) {
      if (!found) throw new Error('the scraper has no getStreams');
      if (q.tmdbId == null) return [];
      var tv = !!q.isTv;
      var r = await found(String(q.tmdbId), tv ? 'tv' : 'movie', tv ? q.season : undefined, tv ? q.episode : undefined);
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
    }
  };
})();
