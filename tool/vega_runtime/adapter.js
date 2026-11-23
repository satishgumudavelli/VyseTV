// Runs a Vega provider (its catalog/posts/meta/episodes/stream modules)
// as a VyseTV plugin. VyseTV asks a plugin `getStreams(query)`; a Vega provider answers it by being browsed:
//   search the site for the title -> read the page (meta) -> pick the movie link or the season/episode -> stream.
// Needs, defined before this file: __axiosLib (real axios), __cheerioLib (real cheerio), the polyfills, and the
// plugin globals `http`, `searchQueries`, `rankMatches` (assets/plugins/helpers.js).
// The provider's own modules are registered by the plugin script: __vega.source(base, value) and
// __vega.module('posts', function (exports, module, require, __awaiter, providerGlobal) { ... }).
var __vega = (function () {
  var BUDGET_MS = 17000;
  var started = Date.now();
  var rawHttp = http;
  var V = { base: '', value: '', mods: {}, loaded: {}, urls: null, kv: {}, glob: {} };

  // ── the network, with a time budget and one retry for a connection that was reset (like tools/run-guard.js) ──
  function left() { return BUDGET_MS - (Date.now() - started); }
  async function net(url, opts) {
    opts = Object.assign({}, opts || {});
    var l = left();
    if (l < 400) return { status: 0, error: 'out of time', text: '', headers: {}, url: url };
    opts.timeout = Math.min(opts.timeout || 12000, l);
    var r = await rawHttp(url, opts);
    var method = String(opts.method || 'GET').toUpperCase();
    if (r.status === 0 && method === 'GET' && /reset|refused|closed/i.test(String(r.error || '')) && left() > 3000) {
      r = await rawHttp(url, Object.assign({}, opts, { timeout: Math.min(opts.timeout, left()) }));
    }
    return r;
  }

  // ── axios: the real one, its transport replaced by net() ──
  var AxiosError = __axiosLib.AxiosError, AxiosHeaders = __axiosLib.AxiosHeaders;
  function withParams(url, params) {
    if (!params) return url;
    var q = typeof params.toString === 'function' && params.constructor !== Object
      ? params.toString()
      : Object.keys(params).filter(function (k) { return params[k] != null; }).map(function (k) {
        var v = params[k];
        return (Array.isArray(v) ? v : [v]).map(function (x) { return encodeURIComponent(k) + '=' + encodeURIComponent(x); }).join('&');
      }).join('&');
    return q ? url + (url.indexOf('?') >= 0 ? '&' : '?') + q : url;
  }
  async function adapter(config) {
    var url = config.url || '';
    if (config.baseURL && !/^https?:/i.test(url)) url = config.baseURL.replace(/\/+$/, '') + '/' + url.replace(/^\/+/, '');
    url = withParams(url, config.params);
    var headers = config.headers && config.headers.toJSON ? config.headers.toJSON() : Object.assign({}, config.headers || {});
    Object.keys(headers).forEach(function (k) { if (headers[k] == null || headers[k] === false) delete headers[k]; else headers[k] = String(headers[k]); });
    var body = config.data;
    if (body != null && typeof body !== 'string') body = typeof body.toString === 'function' && body.constructor !== Object && !Array.isArray(body) ? body.toString() : JSON.stringify(body);
    var r = await net(url, { method: (config.method || 'get').toUpperCase(), headers: headers, body: body == null ? undefined : body, timeout: config.timeout || 0 });
    var request = { url: url, responseURL: r.url || url, res: { responseUrl: r.url || url } };
    if (!r.status) throw new AxiosError(r.error && /time/i.test(r.error) ? 'timeout of ' + (config.timeout || 0) + 'ms exceeded' : 'Network Error: ' + (r.error || ''), r.error && /time/i.test(r.error) ? 'ECONNABORTED' : 'ERR_NETWORK', config, request);
    var data = r.text;
    if (config.responseType !== 'text') { try { data = r.text ? JSON.parse(r.text) : ''; } catch (e) { data = r.text; } }
    var res = { data: data, status: r.status, statusText: '', headers: new AxiosHeaders(r.headers || {}), config: config, request: request };
    var ok = config.validateStatus ? config.validateStatus(r.status) : r.status >= 200 && r.status < 300;
    if (!ok) throw new AxiosError('Request failed with status code ' + r.status, r.status >= 500 ? 'ERR_BAD_RESPONSE' : 'ERR_BAD_REQUEST', config, request, res);
    return res;
  }
  __axiosLib.defaults.adapter = adapter;

  // ── fetch (a provider may call it directly) ──
  async function vfetch(input, init) {
    init = init || {};
    var url = typeof input === 'string' ? input : String((input && input.url) || input);
    var h = {};
    var addH = function (src) {
      if (!src) return;
      if (typeof src.forEach === 'function' && !Array.isArray(src)) src.forEach(function (v, k) { h[k] = v; });
      else if (Array.isArray(src)) src.forEach(function (e) { h[e[0]] = e[1]; });
      else Object.keys(src).forEach(function (k) { h[k] = src[k]; });
    };
    addH(input && input.headers); addH(init.headers);
    var body = init.body;
    if (body != null && typeof body !== 'string') body = typeof body.toString === 'function' && body.constructor !== Object ? body.toString() : JSON.stringify(body);
    var r = await net(url, { method: init.method || (input && input.method) || 'GET', headers: h, body: body == null ? undefined : body });
    if (!r.status) throw new TypeError('Network request failed: ' + (r.error || ''));
    var lower = r.headers || {};
    return {
      ok: r.status >= 200 && r.status < 300, status: r.status, statusText: '', url: r.url || url,
      headers: { get: function (k) { var v = lower[String(k).toLowerCase()]; return v == null ? null : v; }, has: function (k) { return String(k).toLowerCase() in lower; }, forEach: function (f) { Object.keys(lower).forEach(function (k) { f(lower[k], k); }); } },
      text: function () { return Promise.resolve(r.text); },
      json: function () { return Promise.resolve().then(function () { return JSON.parse(r.text); }); },
      clone: function () { return vfetch.call(null, input, init); }
    };
  }
  if (typeof globalThis.fetch === 'undefined') globalThis.fetch = vfetch;

  // ── the provider's context ──
  var commonHeaders = {
    'sec-ch-ua': '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"', 'sec-ch-ua-mobile': '?1', 'sec-ch-ua-platform': '"Android"',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Accept-Language': 'en-US,en;q=0.9'
  };
  // The repository's urls.json says where each site lives now ({"Key": {"name", "url"}}): read once, 4 s at most.
  async function getBaseUrl(key) {
    if (V.urls == null) {
      V.urls = {};
      if (V.base) {
        var r = await net(V.base + '/urls.json', { timeout: 4000 });
        try { V.urls = JSON.parse(r.text) || {}; } catch (e) {}
      }
    }
    var e = V.urls[key] || V.urls[String(key).toLowerCase()];
    if (!e) { var k = Object.keys(V.urls).filter(function (x) { return x.toLowerCase() === String(key).toLowerCase(); })[0]; e = k && V.urls[k]; }
    return e && e.url ? String(e.url).replace(/\/+$/, '') : '';
  }
  var kvStore = {
    get: async function (k) { return V.kv[k]; }, set: async function (k, v) { V.kv[k] = v; },
    delete: async function (k) { var h = k in V.kv; delete V.kv[k]; return h; },
    keys: async function () { return Object.keys(V.kv); }, clear: async function () { V.kv = {}; }
  };
  var ctx = {
    axios: __axiosLib, cheerio: __cheerioLib, Crypto: {}, commonHeaders: commonHeaders, getBaseUrl: getBaseUrl, kvStore: kvStore,
    openWebView: async function () { throw new Error('this provider needs a browser challenge, which VyseTV cannot run'); },
    getCookies: async function () { return {}; }
  };
  function awaiter(thisArg, _arguments, P, generator) {
    P = P || Promise;
    return new P(function (resolve, reject) {
      var it = generator.apply(thisArg, _arguments || []);
      function step(r) { r.done ? resolve(r.value) : Promise.resolve(r.value).then(ok, bad); }
      function ok(v) { try { step(it.next(v)); } catch (e) { reject(e); } }
      function bad(v) { try { step(it['throw'](v)); } catch (e) { reject(e); } }
      ok();
    });
  }
  function load(name) {
    if (V.loaded[name]) return V.loaded[name].exports;
    var fn = V.mods[name];
    if (!fn) return null;
    var m = { exports: {} };
    V.loaded[name] = m;
    fn(m.exports, m, function () { return {}; }, awaiter, V.glob);
    return m.exports;
  }

  return {
    source: function (base, value) { V.base = String(base || '').replace(/\/+$/, ''); V.value = value; },
    module: function (name, fn) { V.mods[name] = fn; },
    load: load, ctx: ctx, V: V, left: left, vfetch: vfetch
  };
})();

// A listing's title as the matcher should read it: sites prefix "Download"/"Watch" and add the formats after the year.
function __vegaTitle(p) {
  var t = String((p && p.title) || '').replace(/^\s*(?:download|watch|stream)\s+/i, '').replace(/\s+(?:full\s+)?(?:movie|series|web\s*series)\b.*$/i, function (m) { return /\(\d{4}\)|\b(19|20)\d{2}\b/.test(m) ? m : ''; });
  return t;
}

// ── choosing what to open on the site's page ──
function __vegaQ(s) { var m = /(\d{3,4})\s*p\b/i.exec(String(s || '')) || /\b(2160|1080|720|480|360)\b/.exec(String(s || '')); return m ? +m[1] : (/\b4k\b/i.test(s || '') ? 2160 : 0); }
function __vegaRank(n) { return n === 1080 ? 0 : n === 720 ? 1 : n === 2160 ? 2 : n === 480 ? 3 : n ? 4 : 5; }
function __vegaNum(re, s) { var m = re.exec(String(s || '')); return m ? +m[1] : null; }

// The links that play the film: every direct link of the page, the 1080p/720p ones first.
function __vegaMovieLinks(info) {
  var out = [];
  (info.linkList || []).forEach(function (e) {
    (e.directLinks || []).forEach(function (d) {
      if (d && d.link) out.push({ link: d.link, quality: __vegaQ(e.quality) || __vegaQ(e.title) || __vegaQ(d.title), title: d.title || e.title });
    });
  });
  out.sort(function (a, b) { return __vegaRank(a.quality) - __vegaRank(b.quality); });
  return out.slice(0, 4);
}

// The links of one episode: the season's entries (one per quality, at most 3), then the episode in each.
async function __vegaEpisodeLinks(info, q, mod, ctx) {
  var list = info.linkList || [];
  var seasonOf = function (e) { return __vegaNum(/\b(?:season|s)\s*0*(\d{1,2})\b/i, e.title); };
  var entries = list.filter(function (e) { return seasonOf(e) === q.season; });
  if (!entries.length && list.length === 1 && seasonOf(list[0]) == null) entries = list;
  if (!entries.length && q.season === 1 && list.every(function (e) { return seasonOf(e) == null; })) entries = list;
  entries.sort(function (a, b) { return __vegaRank(__vegaQ(a.quality) || __vegaQ(a.title)) - __vegaRank(__vegaQ(b.quality) || __vegaQ(b.title)); });
  var out = [];
  for (var i = 0; i < Math.min(entries.length, 3); i++) {
    var e = entries[i], eps = e.directLinks || [];
    if (!eps.length && e.episodesLink && mod.getEpisodes) {
      try { eps = await mod.getEpisodes({ url: e.episodesLink, providerContext: ctx, signal: new AbortController().signal }) || []; }
      catch (err) { console.log('episodes: ' + (err && err.message)); eps = []; }
    }
    var n = q.episode;
    var hit = eps.filter(function (x) {
      var t = String(x.title || '');
      var num = __vegaNum(/\b(?:episode|ep|e)\s*0*(\d{1,4})\b/i, t);
      if (num == null) num = __vegaNum(/^\s*0*(\d{1,4})\s*$/, t);
      if (num == null) num = __vegaNum(/^\s*0*(\d{1,4})\b/, t);
      return num === n;
    })[0] || (eps.length >= n && !eps.some(function (x) { return /\d/.test(x.title || ''); }) ? eps[n - 1] : null);
    if (hit && hit.link) out.push({ link: hit.link, quality: __vegaQ(e.quality) || __vegaQ(e.title) || __vegaQ(hit.title), title: hit.title });
  }
  return out;
}

function __vegaType(t, link) {
  t = String(t || '').toLowerCase();
  if (/m3u8|hls/.test(t) || /\.m3u8(\?|$)/i.test(link)) return 'hls';
  if (/mpd|dash/.test(t) || /\.mpd(\?|$)/i.test(link)) return 'dash';
  return 'mp4';
}

function __vegaErr(e) { return String((e && e.message) || e).slice(0, 160); }

// Each link of the page turned into video files, in parallel: DRM ones dropped, 12 at most.
async function __vegaResolve(links, tv) {
  var V = __vega.V, ctx = __vega.ctx, streamMod = __vega.load('stream'), signal = new AbortController().signal;
  var got = await Promise.all(links.map(function (l) {
    return (async function () {
      try { return { l: l, s: (await streamMod.getStream({ link: l.link, type: tv ? 'series' : 'movie', signal: signal, providerContext: ctx, isDownload: false })) || [] }; }
      catch (e) { console.log('stream ' + l.link + ': ' + __vegaErr(e)); return { l: l, s: [] }; }
    })();
  }));
  var out = [], have = {};
  got.forEach(function (g) {
    g.s.forEach(function (s) {
      if (!s || !s.link || s.drm || !/^https?:/i.test(s.link) || have[s.link]) return;
      // a comic's pages are pictures, not a video
      if (String(s.type || '').toLowerCase() === 'image' || /\.(?:jpe?g|png|webp|gif|avif)(?:[?#]|$)/i.test(s.link)) return;
      have[s.link] = true;
      var ql = s.quality ? (/^\d+$/.test(String(s.quality)) ? s.quality + 'p' : String(s.quality)) : (g.l.quality ? g.l.quality + 'p' : '');
      out.push({ url: s.link, type: __vegaType(s.type, s.link), quality: ql, server: s.server || V.value, label: s.tag || undefined, headers: s.headers || undefined });
    });
  });
  return out.slice(0, 12);
}

// ── browsing the provider, the way VyseTV browses a Stremio addon ──
// Its catalogs and genres are read when it is installed (from its catalog module, by the app); these
// answer for one page of a catalog or a search, a title's details, and its own titles' streams. A
// title goes by its page's link; an episode by `<link>|<season>|<episode>`.

// "Download Oppenheimer (2023) Dual Audio {Hindi-English} 480p [450MB]" -> "Oppenheimer";
// "Tulsa King (Season 2 – 4) English (DD5.1)" -> "Tulsa King"
function __vegaName(t) {
  t = String(t || '').replace(/^\s*(?:download|watch|stream)\s+/i, '');
  var y = /^(.*?)[\s([{-]*\b(19\d\d|20\d\d)\b/.exec(t);
  if (y && y[1].trim().length > 1) t = y[1];
  t = t.split(/\s*(?:[[{|]|\((?=\s*(?:season|s\d|\d))|\b(?:season\s*\d|s\d{1,2}\b|480p|720p|1080p|2160p|4k|hdrip|web-?dl|webrip|bluray|dual audio)\b)/i)[0];
  return t.replace(/[\s:,(\-$|+–—]+$/, '').trim();
}
function __vegaYear(t) { var m = /\b(19\d\d|20\d\d)\b/.exec(String(t || '')); return m ? m[1] : undefined; }
// A listing is a show when its title or its link says so (seasons, episodes, "web series"); else
// what its catalog lists.
function __vegaKind(t, link, fallback) {
  var re = /(?:^|[\s\-_/(])(?:seasons?[\s\-_]*\d|s\d{1,2}(?:\s*e\d{1,3})?|episodes?[\s\-_]*\d|ep\s?\d+|web[\s-]?series|tv[\s-]?series|series)(?=$|[\s\-_/)\d])/i;
  return re.test(String(t || '')) || re.test(String(link || '')) ? 'series' : (fallback || 'movie');
}

async function __vegaCatalog(q) {
  var V = __vega.V, ctx = __vega.ctx, posts = __vega.load('posts'), signal = new AbortController().signal;
  if (!posts) return { metas: [] };
  var page = q.page || 1, items = [], filter = String(q.filter || '');
  if (q.genre) {
    var cat = __vega.load('catalog') || {};
    var g = (cat.genres || []).filter(function (x) { return x && x.title === q.genre; })[0];
    if (g) filter = String(g.filter || '');
  }
  if (q.search) {
    if (!posts.getSearchPosts) return { metas: [] };
    items = await posts.getSearchPosts({ searchQuery: String(q.search), page: page, providerValue: V.value, signal: signal, providerContext: ctx });
  } else {
    if (!posts.getPosts) return { metas: [] };
    items = await posts.getPosts({ filter: filter, page: page, providerValue: V.value, signal: signal, providerContext: ctx });
  }
  var seen = {};
  return {
    metas: (Array.isArray(items) ? items : []).filter(function (p) {
      if (!p || !p.link || !p.title || seen[p.link]) return false;
      return (seen[p.link] = true);
    }).map(function (p) {
      // (a comic's title is its own: no film formats to cut)
      var name = q.comic ? String(p.title).trim() : (__vegaName(p.title) || String(p.title).trim());
      return { id: String(p.link), type: q.comic ? 'comic' : __vegaKind(p.title, p.link, q.type), name: name, poster: p.image || undefined, releaseInfo: q.comic ? undefined : __vegaYear(p.title) };
    })
  };
}

// ── a comic provider (its manifest entry's type "comic"): a series' chapters and a chapter's pages ──

// A series: its details, and its chapters from its page (each entry's direct links, or its
// chapters list through getEpisodes), each once.
async function __vegaComic(q) {
  var V = __vega.V, ctx = __vega.ctx, metaMod = __vega.load('meta'), epMod = __vega.load('episodes') || {}, signal = new AbortController().signal;
  if (!metaMod || !metaMod.getMeta) return { meta: null, chapters: [] };
  var info = await metaMod.getMeta({ link: q.link, provider: V.value, providerContext: ctx, signal: signal });
  if (!info) return { meta: null, chapters: [] };
  var chapters = [], seen = {};
  function add(c) {
    if (!c || !c.link || seen[c.link]) return;
    seen[c.link] = true;
    var n = typeof c.chapterNumber === 'number' ? c.chapterNumber : (c.chapterNumber != null && !isNaN(parseFloat(c.chapterNumber)) ? parseFloat(c.chapterNumber) : null);
    chapters.push({ link: String(c.link), title: String(c.title || '').trim(), number: n, volume: c.volume != null ? c.volume : undefined, language: c.language || undefined });
  }
  var list = info.linkList || [];
  for (var i = 0; i < list.length && __vega.left() > 1500; i++) {
    var e = list[i];
    (e.directLinks || []).forEach(add);
    if (e.episodesLink && epMod.getEpisodes) {
      try { ((await epMod.getEpisodes({ url: e.episodesLink, providerContext: ctx, signal: signal })) || []).forEach(add); }
      catch (err) { console.log('chapters: ' + __vegaErr(err)); }
    }
  }
  return {
    meta: {
      title: String(info.title || '').trim(), image: info.image || info.cover || info.poster || undefined,
      synopsis: info.synopsis || undefined, tags: Array.isArray(info.tags) ? info.tags : undefined,
      author: Array.isArray(info.cast) && info.cast.length ? String(info.cast[0]) : (info.author || undefined),
      status: info.status || undefined
    },
    chapters: chapters
  };
}

// A chapter's pages, in order: each picture's link, with the headers its site wants.
async function __vegaPages(q) {
  var V = __vega.V, ctx = __vega.ctx, streamMod = __vega.load('stream') || {}, signal = new AbortController().signal;
  var get = streamMod.getPages || streamMod.getStream;
  if (!get) return { pages: [] };
  var list = (await get({ link: q.link, type: 'comic', signal: signal, providerContext: ctx, isDownload: false })) || [];
  var pages = list.map(function (p, i) {
    var url = typeof p === 'string' ? p : (p && (p.imageUrl || p.link || p.url));
    return url && /^https?:/i.test(url) ? { index: p && typeof p.index === 'number' ? p.index : i, url: url, headers: (p && p.headers) || undefined } : null;
  }).filter(Boolean);
  pages.sort(function (a, b) { return a.index - b.index; });
  return { pages: pages.map(function (p) { return { url: p.url, headers: p.headers }; }) };
}

function __vegaSeasonOf(e) { return __vegaNum(/\b(?:season|s)\s*0*(\d{1,2})\b/i, e && e.title); }
function __vegaEpisodeOf(t) {
  var n = __vegaNum(/\b(?:episode|ep|e)\s*0*(\d{1,4})\b/i, t);
  if (n == null) n = __vegaNum(/^\s*0*(\d{1,4})\s*$/, t);
  if (n == null) n = __vegaNum(/^\s*0*(\d{1,4})\b/, t);
  return n;
}

async function __vegaMeta(q) {
  var V = __vega.V, ctx = __vega.ctx, metaMod = __vega.load('meta'), epMod = __vega.load('episodes') || {}, signal = new AbortController().signal;
  if (!metaMod || !metaMod.getMeta) return { meta: null };
  var info = await metaMod.getMeta({ link: q.link, provider: V.value, providerContext: ctx, signal: signal });
  if (!info) return { meta: null };
  var list = info.linkList || [];
  var numbered = list.some(function (e) { return __vegaSeasonOf(e) != null; });
  var series = String(info.type || '').toLowerCase() === 'series' || numbered || list.some(function (e) { return e && e.episodesLink; });
  var videos = [];
  if (series) {
    // each season once (its best quality): its episodes, numbered as the site names them
    var bySeason = {};
    list.forEach(function (e) {
      var s = __vegaSeasonOf(e);
      if (s == null) { if (numbered) return; s = 1; }
      (bySeason[s] = bySeason[s] || []).push(e);
    });
    var seasons = Object.keys(bySeason).map(Number).sort(function (a, b) { return a - b; }).slice(0, 40);
    var lists = await Promise.all(seasons.map(function (s) {
      return (async function () {
        var entries = bySeason[s].slice().sort(function (a, b) { return __vegaRank(__vegaQ(a.quality) || __vegaQ(a.title)) - __vegaRank(__vegaQ(b.quality) || __vegaQ(b.title)); });
        for (var i = 0; i < Math.min(entries.length, 2) && __vega.left() > 1500; i++) {
          var e = entries[i], eps = e.directLinks || [];
          if (!eps.length && e.episodesLink && epMod.getEpisodes) {
            try { eps = (await epMod.getEpisodes({ url: e.episodesLink, providerContext: ctx, signal: signal })) || []; }
            catch (err) { console.log('episodes: ' + __vegaErr(err)); eps = []; }
          }
          if (eps.length) return { s: s, eps: eps };
        }
        return { s: s, eps: [] };
      })();
    }));
    lists.forEach(function (x) {
      var used = {};
      x.eps.forEach(function (ep, i) {
        var n = __vegaEpisodeOf(ep && ep.title);
        if (n == null || used[n]) n = i + 1;
        if (used[n]) return;
        used[n] = true;
        videos.push({ id: q.link + '|' + x.s + '|' + n, season: x.s, episode: n, title: String((ep && ep.title) || ('Episode ' + n)).trim() });
      });
    });
  }
  return {
    meta: {
      id: q.link, type: series ? 'series' : 'movie', name: __vegaName(info.title) || String(info.title || '').trim(),
      description: info.synopsis || undefined, poster: info.image || undefined, background: info.image || undefined,
      imdb_id: /^tt\d+$/.test(String(info.imdbId || '')) ? info.imdbId : undefined,
      genres: Array.isArray(info.tags) ? info.tags : undefined, cast: Array.isArray(info.cast) ? info.cast : undefined,
      imdbRating: info.rating || undefined, releaseInfo: __vegaYear(info.title), videos: videos
    }
  };
}

// One of the provider's own titles (`ownId`: its page's link, and for an episode `|season|episode`).
async function __vegaOwnStreams(q) {
  var V = __vega.V, ctx = __vega.ctx, metaMod = __vega.load('meta'), epMod = __vega.load('episodes') || {};
  var m = /^(.*)\|(\d+)\|(\d+)$/.exec(String(q.ownId));
  var link = m ? m[1] : String(q.ownId), tv = !!m;
  var info;
  try { info = await metaMod.getMeta({ link: link, provider: V.value, providerContext: ctx, signal: new AbortController().signal }); }
  catch (e) { console.log('page ' + link + ': ' + __vegaErr(e)); return []; }
  if (!info) return [];
  var links = tv ? await __vegaEpisodeLinks(info, { season: +m[2], episode: +m[3] }, epMod, ctx) : __vegaMovieLinks(info);
  if (!links.length) { console.log('no ' + (tv ? 'episode S' + m[2] + 'E' + m[3] : 'movie link') + ' on ' + link); return []; }
  return __vegaResolve(links, tv);
}

async function getStreams(q) {
  var V = __vega.V, ctx = __vega.ctx;
  var posts = __vega.load('posts'), metaMod = __vega.load('meta'), streamMod = __vega.load('stream'), epMod = __vega.load('episodes') || {};
  if (!metaMod || !metaMod.getMeta || !streamMod || !streamMod.getStream) { console.log('this provider lacks meta/stream'); return []; }
  if (q.ownId) return __vegaOwnStreams(q);
  if (!posts || !posts.getSearchPosts) { console.log('this provider has no search'); return []; }
  var signal = new AbortController().signal;
  var ign = __vegaErr;

  // 1. find the title on the site
  var cands = [], qs = searchQueries(q), seen = {};
  for (var i = 0; i < qs.length && !cands.length && __vega.left() > 2500; i++) {
    var items = [];
    try { items = await posts.getSearchPosts({ searchQuery: qs[i], page: 1, providerValue: V.value, signal: signal, providerContext: ctx }); }
    catch (e) { console.log('search "' + qs[i] + '": ' + ign(e)); }
    cands = rankMatches(Array.isArray(items) ? items : [], q, __vegaTitle).filter(function (p) { if (!p.link || seen[p.link]) return false; return (seen[p.link] = true); });
  }
  if (!cands.length) { console.log('not found on the site'); return []; }

  // 2. open the best listings until one gives streams
  for (var c = 0; c < Math.min(cands.length, 3) && __vega.left() > 2500; c++) {
    var info;
    try { info = await metaMod.getMeta({ link: cands[c].link, providerContext: ctx, signal: signal }); }
    catch (e) { console.log('page ' + cands[c].link + ': ' + ign(e)); continue; }
    if (!info) continue;
    if (q.imdbId && info.imdbId && /^tt\d+$/.test(info.imdbId) && info.imdbId !== q.imdbId) { console.log('skipped: another IMDb id (' + info.imdbId + ')'); continue; }
    var links = q.isTv ? await __vegaEpisodeLinks(info, q, epMod, ctx) : __vegaMovieLinks(info);
    if (!links.length) { console.log('no ' + (q.isTv ? 'episode S' + q.season + 'E' + q.episode : 'movie link') + ' on ' + cands[c].link); continue; }

    // 3. turn each link into video files (in parallel)
    var out = await __vegaResolve(links, q.isTv);
    if (out.length) return out;
  }
  return [];
}
