// Browser globals that QuickJS lacks and Vega providers use (new URL, URLSearchParams, TextEncoder,
// AbortController). Each is defined only when missing.
(function (g) {
  function enc(s) { return encodeURIComponent(s).replace(/%20/g, '+').replace(/[!'()~]/g, function (c) { return '%' + c.charCodeAt(0).toString(16).toUpperCase(); }); }
  function dec(s) { try { return decodeURIComponent(String(s).replace(/\+/g, ' ')); } catch (e) { return String(s); } }

  if (typeof g.URLSearchParams === 'undefined') {
    var USP = function URLSearchParams(init) {
      this._l = [];
      this._u = null; // the URL this belongs to: it is told when the list changes
      if (init == null) return;
      if (typeof init === 'string') {
        init = init.replace(/^\?/, '');
        if (init) init.split('&').forEach(function (p) {
          if (!p) return;
          var i = p.indexOf('=');
          this._l.push([dec(i < 0 ? p : p.slice(0, i)), dec(i < 0 ? '' : p.slice(i + 1))]);
        }, this);
      } else if (init instanceof USP) {
        this._l = init._l.map(function (e) { return e.slice(); });
      } else if (typeof init[Symbol.iterator] === 'function' && typeof init !== 'object') {
        // (strings handled above)
      } else if (Array.isArray(init)) {
        init.forEach(function (e) { this._l.push([String(e[0]), String(e[1])]); }, this);
      } else if (typeof init === 'object') {
        Object.keys(init).forEach(function (k) { this._l.push([k, String(init[k])]); }, this);
      }
    };
    USP.prototype._c = function () { if (this._u) this._u._q(this.toString()); };
    USP.prototype.append = function (k, v) { this._l.push([String(k), String(v)]); this._c(); };
    USP.prototype.delete = function (k) { this._l = this._l.filter(function (e) { return e[0] !== k; }); this._c(); };
    USP.prototype.get = function (k) { for (var i = 0; i < this._l.length; i++) if (this._l[i][0] === k) return this._l[i][1]; return null; };
    USP.prototype.getAll = function (k) { return this._l.filter(function (e) { return e[0] === k; }).map(function (e) { return e[1]; }); };
    USP.prototype.has = function (k) { return this.get(k) !== null; };
    USP.prototype.set = function (k, v) {
      var done = false;
      this._l = this._l.filter(function (e) { if (e[0] !== k) return true; if (done) return false; e[1] = String(v); done = true; return true; });
      if (!done) this._l.push([String(k), String(v)]);
      this._c();
    };
    USP.prototype.sort = function () { this._l.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; }); this._c(); };
    USP.prototype.forEach = function (f, t) { this._l.slice().forEach(function (e) { f.call(t, e[1], e[0], this); }, this); };
    USP.prototype.keys = function () { return this._l.map(function (e) { return e[0]; })[Symbol.iterator](); };
    USP.prototype.values = function () { return this._l.map(function (e) { return e[1]; })[Symbol.iterator](); };
    USP.prototype.entries = function () { return this._l.map(function (e) { return [e[0], e[1]]; })[Symbol.iterator](); };
    USP.prototype[Symbol.iterator] = USP.prototype.entries;
    USP.prototype.toString = function () { return this._l.map(function (e) { return enc(e[0]) + '=' + enc(e[1]); }).join('&'); };
    Object.defineProperty(USP.prototype, 'size', { get: function () { return this._l.length; } });
    Object.defineProperty(USP.prototype, Symbol.toStringTag, { value: 'URLSearchParams' });
    g.URLSearchParams = USP;
  }

  if (typeof g.URL === 'undefined') {
    var DEFAULT_PORT = { 'http:': '80', 'https:': '443', 'ftp:': '21', 'ws:': '80', 'wss:': '443' };
    var RE = /^([a-zA-Z][a-zA-Z0-9+.\-]*:)?(?:\/\/([^\/?#]*))?([^?#]*)(\?[^#]*)?(#.*)?$/;
    var fixPath = function (p) { return p.replace(/[^\x21-\x7e]|["<>`{}\\^|]/g, function (c) { return encodeURIComponent(c); }); };
    var fixQuery = function (q) { return q.replace(/[^\x21-\x7e]|["<>']/g, function (c) { return encodeURIComponent(c); }); };
    var squash = function (path) {
      var out = [];
      path.split('/').forEach(function (seg, i, all) {
        if (seg === '..') { if (out.length > 1) out.pop(); if (i === all.length - 1) out.push(''); }
        else if (seg === '.') { if (i === all.length - 1) out.push(''); }
        else out.push(seg);
      });
      var r = out.join('/');
      return r.charAt(0) === '/' ? r : '/' + r;
    };
    var parse = function (s) {
      var m = RE.exec(s);
      var o = { protocol: m[1] || '', auth: '', host: '', path: m[3] || '', query: m[4] || '', hash: m[5] || '', authority: m[2] };
      if (m[2] != null) {
        var a = m[2], at = a.lastIndexOf('@');
        if (at >= 0) { o.auth = a.slice(0, at); a = a.slice(at + 1); }
        o.host = a;
      }
      return o;
    };
    var URLPoly = function URL(input, base) {
      input = String(input).trim();
      var u = parse(input);
      if (!u.protocol) {
        if (base == null) throw new TypeError('Invalid URL: ' + input);
        var b = base instanceof URLPoly ? base : new URLPoly(base);
        u.protocol = b.protocol;
        if (u.authority == null) {
          u.auth = b._auth; u.host = b._host;
          if (u.path === '') { u.path = b._path; if (!u.query) u.query = b._query; }
          else if (u.path.charAt(0) !== '/') u.path = b._path.replace(/[^\/]*$/, '') + u.path;
        }
      }
      if (!/^(https?|ftp|wss?|file|blob|data|javascript|mailto|tel):$/i.test(u.protocol)) throw new TypeError('Invalid URL: ' + input);
      var special = !!DEFAULT_PORT[u.protocol.toLowerCase()];
      if (special && !u.host) throw new TypeError('Invalid URL: ' + input);
      this._proto = u.protocol.toLowerCase();
      this._auth = u.auth;
      var host = u.host.toLowerCase(), port = '';
      var pm = /^(.*?)(?::(\d*))?$/.exec(host);
      if (pm && !/\]$/.test(host)) { host = pm[1]; port = pm[2] || ''; }
      if (port === DEFAULT_PORT[this._proto]) port = '';
      this._host = port ? host + ':' + port : host;
      this._hostname = host; this._port = port;
      this._path = special || u.host ? fixPath(squash(u.path || '/')) : u.path;
      this._query = u.query === '?' ? '' : fixQuery(u.query);
      this._hash = u.hash === '#' ? '' : fixQuery(u.hash);
      this.searchParams = new g.URLSearchParams(this._query);
      this.searchParams._u = this;
    };
    URLPoly.prototype._q = function (q) { this._query = q ? '?' + q : ''; };
    var def = function (name, get, set) { Object.defineProperty(URLPoly.prototype, name, { get: get, set: set, enumerable: true, configurable: true }); };
    def('protocol', function () { return this._proto; }, function (v) { this._proto = String(v).replace(/:?$/, ':'); });
    def('host', function () { return this._host; }, function (v) { this._host = String(v); });
    def('hostname', function () { return this._hostname; }, function (v) { this._hostname = String(v); this._host = this._port ? this._hostname + ':' + this._port : this._hostname; });
    def('port', function () { return this._port; }, function (v) { this._port = String(v); this._host = this._port ? this._hostname + ':' + this._port : this._hostname; });
    def('pathname', function () { return this._path; }, function (v) { v = String(v); this._path = fixPath(v.charAt(0) === '/' ? v : '/' + v); });
    def('search', function () { return this._query; }, function (v) {
      v = String(v); this._query = v && v !== '?' ? (v.charAt(0) === '?' ? v : '?' + v) : '';
      this.searchParams._l = new g.URLSearchParams(this._query)._l;
    });
    def('hash', function () { return this._hash; }, function (v) { v = String(v); this._hash = v && v !== '#' ? (v.charAt(0) === '#' ? v : '#' + v) : ''; });
    def('username', function () { return this._auth.split(':')[0]; }, function () {});
    def('password', function () { var i = this._auth.indexOf(':'); return i < 0 ? '' : this._auth.slice(i + 1); }, function () {});
    def('origin', function () { return DEFAULT_PORT[this._proto] ? this._proto + '//' + this._host : 'null'; }, function () {});
    def('href', function () {
      return this._proto + (this._host || this._auth ? '//' + (this._auth ? this._auth + '@' : '') + this._host : '') + this._path + this._query + this._hash;
    }, function (v) { var n = new URLPoly(v); for (var k in n) if (Object.prototype.hasOwnProperty.call(n, k)) this[k] = n[k]; this.searchParams._u = this; });
    URLPoly.prototype.toString = function () { return this.href; };
    URLPoly.prototype.toJSON = function () { return this.href; };
    URLPoly.canParse = function (s, b) { try { new URLPoly(s, b); return true; } catch (e) { return false; } };
    g.URL = URLPoly;
  }

  if (typeof g.TextEncoder === 'undefined') {
    g.TextEncoder = function TextEncoder() { this.encoding = 'utf-8'; };
    g.TextEncoder.prototype.encode = function (s) {
      var str = unescape(encodeURIComponent(String(s == null ? '' : s))), a = new Uint8Array(str.length);
      for (var i = 0; i < str.length; i++) a[i] = str.charCodeAt(i);
      return a;
    };
  }
  if (typeof g.TextDecoder === 'undefined') {
    g.TextDecoder = function TextDecoder(label) { this.encoding = (label || 'utf-8').toLowerCase(); };
    g.TextDecoder.prototype.decode = function (b) {
      if (!b) return '';
      var a = b instanceof ArrayBuffer ? new Uint8Array(b) : new Uint8Array(b.buffer || b, b.byteOffset || 0, b.byteLength);
      var s = '';
      for (var i = 0; i < a.length; i++) s += String.fromCharCode(a[i]);
      if (this.encoding === 'latin1' || this.encoding === 'iso-8859-1' || this.encoding === 'ascii') return s;
      try { return decodeURIComponent(escape(s)); } catch (e) { return s; }
    };
  }

  if (typeof g.AbortController === 'undefined') {
    var Sig = function AbortSignal() { this.aborted = false; this.reason = undefined; this._h = []; };
    Sig.prototype.addEventListener = function (t, f) { if (t === 'abort') this._h.push(f); };
    Sig.prototype.removeEventListener = function (t, f) { this._h = this._h.filter(function (x) { return x !== f; }); };
    Sig.prototype.throwIfAborted = function () { if (this.aborted) throw this.reason; };
    g.AbortSignal = Sig;
    g.AbortController = function AbortController() { this.signal = new Sig(); };
    g.AbortController.prototype.abort = function (r) {
      var s = this.signal;
      if (s.aborted) return;
      s.aborted = true; s.reason = r === undefined ? new Error('aborted') : r;
      s._h.forEach(function (f) { try { f({ type: 'abort', target: s }); } catch (e) {} });
    };
  }

  if (typeof g.queueMicrotask === 'undefined') g.queueMicrotask = function (f) { Promise.resolve().then(f); };
})(globalThis);
