// Runs one Vega provider through the adapter in Node (QuickJS-like: a bare vm context, no URL/fetch of Node's).
//   node try.mjs <manifest-base-url> <provider> movie|tv "<title>" <year> <tmdbId> <imdbId> [season episode]
// e.g. node try.mjs <the repository's raw base link> <provider> movie "Oppenheimer" 2023 872585 tt15398776
import fs from 'node:fs';
import vm from 'node:vm';

const [base, value, type, title, year, tmdbId, imdbId, season, episode] = process.argv.slice(2);
if (!episode && type === 'tv') { console.error('tv needs season and episode'); process.exit(2); }
const dir = new URL('.', import.meta.url).pathname;
const asset = (f) => fs.readFileSync(dir + '../../assets/plugins/' + f, 'utf8');
const get = async (u) => { const r = await fetch(u); if (!r.ok) throw new Error(r.status + ' ' + u); return r.text(); };

let code = `// @vega-provider ${value}\n__vega.source(${JSON.stringify(base)}, ${JSON.stringify(value)});\n`;
for (const m of ['catalog', 'posts', 'meta', 'episodes', 'stream']) {
  try { code += `__vega.module(${JSON.stringify(m)}, function (exports, module, require, __awaiter, providerGlobal) {\n${await get(`${base}/dist/${value}/${m}.js`)}\n});\n`; } catch (e) { if (m !== 'episodes' && m !== 'catalog') throw e; }
}

const logs = [];
const http = async (url, o = {}) => {
  try {
    const r = await fetch(url, { method: o.method || 'GET', headers: { 'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0', ...(o.headers || {}) }, body: o.body, redirect: 'follow', signal: AbortSignal.timeout(o.timeout || 12000) });
    const headers = {}; r.headers.forEach((v, k) => (headers[k] = v));
    return { status: r.status, url: r.url, headers, text: await r.text() };
  } catch (e) { return { status: 0, error: String(e.cause?.code || e.message), text: '', headers: {}, url }; }
};
// only what QuickJS has: no URL, URLSearchParams, fetch, TextEncoder, AbortController of Node's
const ctx = vm.createContext({ http, setTimeout, clearTimeout, Promise, console: { log: (...a) => logs.push(a.join(' ')) }, btoa, atob });
vm.runInContext(asset('helpers.js'), ctx);
vm.runInContext(asset('vega_runtime.js'), ctx);
vm.runInContext(code, ctx);
const q = { tmdbId: +tmdbId, imdbId, type, isTv: type === 'tv', title, originalTitle: title, titles: [title], isAnime: false, year: +year, season: season ? +season : null, episode: episode ? +episode : null };
ctx.q = q;
const t0 = Date.now();
const out = await vm.runInContext('getStreams(q)', ctx);
console.log(logs.join('\n'));
console.log(`${out.length} stream(s) in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
for (const s of out) console.log(' ', s.type.padEnd(4), String(s.quality).padEnd(6), s.server, s.url.slice(0, 110));
