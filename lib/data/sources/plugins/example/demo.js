// VyseTV plugin example: returns one test stream for any title. Replace the body with a real site's steps.
async function getStreams(q) {
  // q.tmdbId, q.imdbId, q.title, q.year, q.season, q.episode ... (see ../README.md)
  var r = await http('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8', { method: 'GET', timeout: 8000 });
  if (r.status !== 200) return [];                       // a failed request is status 0, never an exception
  return [{ url: r.url, type: 'hls', quality: 'Auto', server: 'Example', label: q.title }];
}
