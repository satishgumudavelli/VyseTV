// Runs demo.js in Node with a stand-in http(): node lib/data/sources/plugins/example/run.mjs
import fs from 'node:fs';
import vm from 'node:vm';
const dir = new URL('.', import.meta.url).pathname;
const code = fs.readFileSync(dir + '../../../../../assets/plugins/helpers.js', 'utf8') + '\n' + fs.readFileSync(dir + 'demo.js', 'utf8');
const ctx = { console, Promise, setTimeout, JSON, Math, Date, RegExp,
  http: async (url) => { const r = await fetch(url); return { status: r.status, url: r.url, text: await r.text(), headers: {} }; } };
vm.createContext(ctx); vm.runInContext(code, ctx);
console.log(await ctx.getStreams({ title: 'Oppenheimer', year: 2023, type: 'movie', isTv: false, tmdbId: 872585, imdbId: 'tt15398776' }));
