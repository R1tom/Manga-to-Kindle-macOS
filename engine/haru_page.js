// Injected into HaruNeko's web app (via Chrome DevTools Protocol) by haru.py.
// Gives Manga to Kindle a small API on top of HaruNeko's own plugins + download manager.
(() => {
  const VERSION = 10;
  if (window.__mk && window.__mk.version === VERSION && window.__mk.H === window.HakuNeko) return 'ok';
  const H = window.HakuNeko;
  if (!H || !H.PluginController || !H.PluginController.WebsitePlugins.length) throw new Error('HaruNeko is still starting');
  const plugins = () => H.PluginController.WebsitePlugins;
  const byId = id => plugins().find(p => p.Identifier === id);
  const tagKeys = p => p.Tags.Value.map(t => t.titleKey);
  const LANGS = {
    Tags_Language_English: 'en', Tags_Language_Multilingual: 'multi', Tags_Language_Japanese: 'ja',
    Tags_Language_Spanish: 'es', Tags_Language_Portuguese: 'pt', Tags_Language_French: 'fr',
    Tags_Language_Indonesian: 'id', Tags_Language_Turkish: 'tr', Tags_Language_Russian: 'ru',
    Tags_Language_Arabic: 'ar', Tags_Language_Italian: 'it', Tags_Language_Chinese: 'zh',
    Tags_Language_Thai: 'th', Tags_Language_Vietnamese: 'vi', Tags_Language_German: 'de',
    Tags_Language_Korean: 'ko', Tags_Language_Polish: 'pl',
  };
  const info = p => {
    const k = tagKeys(p);
    return {
      id: p.Identifier, title: p.Title,
      langs: k.filter(x => LANGS[x]).map(x => LANGS[x]),
      official: k.includes('Tags_Source_Official'),
      scanlator: k.includes('Tags_Source_Scanlator'),
      aggregator: k.includes('Tags_Source_Aggregator'),
      adult: k.includes('Tags_Rating_Pornographic') || k.includes('Tags_Rating_Erotica'),
      regionLock: k.includes('Tags_Accessibility_RegionLock'),
      novel: k.includes('Tags_Media_Novel') && !k.includes('Tags_Media_Manga') && !k.includes('Tags_Media_Manhwa'),
      entries: p.Entries.Value.length,
    };
  };
  // sources whose lists are worth searching for a reader of `lang`
  const usable = (i, lang, adult) =>
    !i.novel && (adult || !i.adult) && (i.langs.length === 0 || i.langs.includes(lang.split('-')[0]) || i.langs.includes('multi'));

  const norm = s => (s || '').normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/[’'`]/g, '').replace(/[^\p{L}\p{N}]+/gu, ' ').trim();

  // chapter number from a chapter title ("Ch.0006.5 - …", "Chapter 12", "Bone 66", "Episode 3")
  const chNum = t => {
    const s = t.replace(/\[[^\]]*\]/g, ' ').replace(/\([a-z]{2,3}(-[a-z]{2,4})?\)/gi, ' ');
    let m = s.match(/(?:^|[^a-z])(?:ch(?:apter|ap|\.)?|episode|ep\.?|#)\s*[._-]?\s*(\d+(?:[.,]\d+)?)/i);
    if (!m) {
      const head = s.split(' - ')[0].replace(/(?:^|[^a-z])(?:vol(?:ume)?|v)\.?\s*\d+(?:\.\d+)?/ig, ' ');
      m = head.match(/(\d+(?:[.,]\d+)?)/) || s.match(/(\d+(?:[.,]\d+)?)/);
    }
    return m ? parseFloat(m[1].replace(',', '.')) : null;
  };
  // "(en)" at the end, or a bare language code in brackets ("第182話 [jp]", "Chapter 143 [en]") — not scan-group brackets
  const LANG_CODES = new Set(['en','ja','jp','ko','kr','zh','cn','es','pt','fr','id','vi','th','ru','de','it','tr','ar','pl','ms','fil','hi','uk']);
  const LANG_ALIAS = { jp: 'ja', kr: 'ko', cn: 'zh' };
  const chLang = t => {
    let m = t.match(/\(([a-z]{2,3}(?:-[a-z]{2,4})?)\)\s*(?:\[[^\]]*\])?\s*$/i);
    if (!m) { m = t.match(/\[([a-z]{2,3})(?:-[a-z]{2,4})?\]\s*$/i); if (m && !LANG_CODES.has(m[1].toLowerCase())) m = null; }
    if (!m) return null;
    const c = m[1].toLowerCase(); return LANG_ALIAS[c] || c;
  };

  const tid = t => `${t.Media.Parent?.Parent?.Identifier}|${t.Media.Parent?.Identifier}|${t.Media.Identifier}`;
  const withTimeout = (p, ms, what) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`timeout: ${what}`)), ms))]);

  // MangaHub-family scrapers (MangaReaderSite…) use one random API token; on "rate limit" they only wait 2.5 s and retry
  // with the same used-up token, so every later chapter fails. Get a fresh token instead.
  for (const p of plugins()) {
    const sc = p.scraper;
    if (!sc || typeof sc.RenewApiKey !== 'function' || typeof sc.FetchGQL !== 'function' || sc.__mkPatched) continue;
    const orig = sc.FetchGQL;
    sc.FetchGQL = async function (q, v, n) {
      for (let attempt = 0; ; attempt++) {
        try { return await orig.call(this, q, v, attempt ? 1 : n); }
        catch (e) {
          const msg = String(e?.message || e) + (e?.params ? e.params.join('') : '');
          if (attempt >= 3 || !/rate\s*limit/i.test(msg)) throw e;
          await this.RenewApiKey();
        }
      }
    };
    sc.__mkPatched = true;
  }

  const mk = {
    version: VERSION, H,
    index: { running: false, done: 0, total: 0, current: [], failed: [], ok: [] },

    status() {
      const all = plugins().map(info);
      return { ready: true, sources: all.length, indexed: all.filter(i => i.entries > 0).length,
               titles: all.reduce((a, i) => a + i.entries, 0), index: mk.index };
    },

    sources(lang = 'en', adult = false) {
      return plugins().map(info).filter(i => usable(i, lang, adult));
    },

    // load (and persist inside HaruNeko) the title lists of many sources, a few at a time
    startIndex(ids, concurrency = 4, timeoutMs = 120000, onlyMissing = true) {
      if (mk.index.running) return mk.index;
      const todo = ids.map(byId).filter(p => p && (!onlyMissing || p.Entries.Value.length === 0));
      mk.index = { running: true, done: 0, total: todo.length, current: [], failed: [], ok: [] };
      const queue = todo.slice();
      const worker = async () => {
        while (queue.length && mk.index.running) {
          const p = queue.shift();
          mk.index.current.push(p.Title);
          try {
            await withTimeout(p.Update(), timeoutMs, p.Title);
            (p.Entries.Value.length ? mk.index.ok : mk.index.failed).push(p.Identifier);
          } catch (e) { mk.index.failed.push(p.Identifier); }
          mk.index.current = mk.index.current.filter(t => t !== p.Title);
          mk.index.done++;
        }
      };
      Promise.all(Array.from({ length: concurrency }, worker)).then(() => { mk.index.running = false; });
      return mk.index;
    },
    stopIndex() { mk.index.running = false; return mk.index; },

    // search every loaded list; results grouped by normalised title
    search(q, lang = 'en', adult = false, limit = 40) {
      const nq = norm(q); if (!nq) return [];
      const toks = nq.split(' ');
      const groups = new Map();
      for (const p of plugins()) {
        const i = info(p);
        if (!i.entries || !usable(i, lang, adult)) continue;
        for (const m of p.Entries.Value) {
          const nt = norm(m.Title);
          if (!nt.includes(toks[0])) continue;
          let score;
          if (nt === nq) score = 100;
          else if (nt.startsWith(nq)) score = 85 - Math.min(20, (nt.length - nq.length) / 3);
          else if (nt.includes(nq)) score = 70 - Math.min(20, (nt.length - nq.length) / 3);
          else {
            const tt = nt.split(' ');
            if (!toks.every(t => tt.some(x => x.startsWith(t)))) continue;
            score = 55 - Math.min(25, (nt.length - nq.length) / 3);
          }
          let g = groups.get(nt);
          if (!g) { g = { key: nt, title: m.Title, score, sources: [] }; groups.set(nt, g); }
          g.score = Math.max(g.score, score);
          g.sources.push({ source: p.Identifier, sourceTitle: p.Title, mangaId: String(m.Identifier), title: m.Title,
                           official: i.official, multi: i.langs.includes('multi') });
        }
      }
      return [...groups.values()].sort((a, b) => b.score - a.score || b.sources.length - a.sources.length || a.title.localeCompare(b.title)).slice(0, limit);
    },

    _manga(src, id) {
      const p = byId(src); if (!p) throw new Error('unknown source ' + src);
      const m = p.Entries.Value.find(x => String(x.Identifier) === String(id));
      if (!m) throw new Error('manga not found in ' + p.Title);
      return m;
    },

    // chapter list of one manga on one source, with numbers + language + a quality score
    async chapters(src, id, lang = 'en', timeoutMs = 45000) {
      const m = mk._manga(src, id);
      await withTimeout(m.Update(), timeoutMs, m.Title);
      const list = m.Entries.Value.map(c => ({ id: String(c.Identifier), title: c.Title, num: chNum(c.Title), lang: chLang(c.Title) }));
      const tagged = list.some(c => c.lang);
      const mine = tagged ? list.filter(c => c.lang === lang || (c.lang || '').startsWith(lang + '-')) : list;
      const nums = new Set(mine.map(c => c.num).filter(n => n !== null));
      const max = nums.size ? Math.max(...nums) : 0;
      return { source: src, sourceTitle: m.Parent.Title, mangaId: id, title: m.Title, total: list.length,
               usable: mine.length, distinct: nums.size, latest: max, tagged, chapters: list };
    },

    // rank the sources of one search result: most distinct chapters in my language, then latest chapter
    async rank(items, lang = 'en', concurrency = 6) {
      const out = []; const queue = items.slice();
      const worker = async () => {
        while (queue.length) {
          const it = queue.shift();
          try {
            const r = await mk.chapters(it.source, it.mangaId, lang, 30000);
            delete r.chapters;
            out.push({ ...it, ...r, ok: true });
          } catch (e) { out.push({ ...it, ok: false, error: String(e).slice(0, 160) }); }
        }
      };
      await Promise.all(Array.from({ length: concurrency }, worker));
      out.sort((a, b) => (b.ok - a.ok) || (b.distinct - a.distinct) || (b.latest - a.latest) || (b.official - a.official));
      if (out[0] && out[0].ok && out[0].distinct > 0) out[0].best = true;
      return out;
    },

    // HaruNeko finds the source for a pasted manga URL
    async fromURL(url) {
      for (const p of plugins()) {
        try {
          const m = await p.TryGetEntry(url);
          if (m) {
            if (!p.Entries.Value.some(x => x.IsSameAs ? x.IsSameAs(m) : x.Identifier === m.Identifier)) p.Entries.Value.push(m);
            return { source: p.Identifier, sourceTitle: p.Title, mangaId: String(m.Identifier), title: m.Title };
          }
        } catch (e) { /* not this plugin */ }
      }
      return null;
    },

    // chapter numbers of chapter titles (same parser as everywhere else)
    chNums(titles) { return titles.map(chNum); },

    // which sources have the chapters that failed: for every source, the best chapter (my language,
    // scan group with the most chapters) for each wanted number
    async alternatives(items, nums, lang = 'en', concurrency = 6) {
      const want = nums.map(Number);
      const out = []; const queue = items.slice();
      const worker = async () => {
        while (queue.length) {
          const it = queue.shift();
          try {
            const r = await mk.chapters(it.source, it.mangaId, lang, 30000);
            const mine = r.tagged ? r.chapters.filter(c => c.lang === lang || (c.lang || '').startsWith(lang + '-')) : r.chapters;
            const grp = c => { const g = c.title.match(/\[([^\]]+)\]\s*$/); return g ? g[1] : ''; };
            const cov = {}; for (const c of mine) cov[grp(c)] = (cov[grp(c)] || 0) + 1;
            const has = {};
            for (const n of want) {
              const cands = mine.filter(c => c.num !== null && Math.abs(c.num - n) < 1e-6);
              cands.sort((a, b) => (cov[grp(b)] || 0) - (cov[grp(a)] || 0));
              if (cands.length) has[String(n)] = { id: cands[0].id, title: cands[0].title };
            }
            out.push({ source: it.source, sourceTitle: r.sourceTitle, mangaId: String(it.mangaId), title: r.title,
                       official: !!it.official, ok: true, distinct: r.distinct, has });
          } catch (e) { out.push({ source: it.source, sourceTitle: it.sourceTitle, mangaId: String(it.mangaId), title: it.title,
                                   official: !!it.official, ok: false, error: String(e).slice(0, 160), has: {} }); }
        }
      };
      await Promise.all(Array.from({ length: concurrency }, worker));
      out.sort((a, b) => (b.ok - a.ok) || (Object.keys(b.has).length - Object.keys(a.has).length) || (b.official - a.official) || (b.distinct - a.distinct));
      return out;
    },

    async download(src, id, chapterIds) {
      const m = mk._manga(src, id);
      if (!m.Entries.Value.length) await m.Update();
      const want = new Set(chapterIds.map(String));
      const chs = m.Entries.Value.filter(c => want.has(String(c.Identifier)));
      // a retry: drop the old finished/failed task of the same chapter, or HaruNeko ignores the new one
      const old = H.DownloadManager.Queue.Value.filter(t => t.Media.Parent?.Parent?.Identifier === src &&
        want.has(String(t.Media.Identifier)) && ['completed', 'failed'].includes(String(t.Status.Value)));
      for (const t of old) { try { await H.DownloadManager.Dequeue(t); } catch (e) { } }
      await H.DownloadManager.Enqueue(...chs);
      return { queued: chs.length, folder: [m.Parent.Title, m.Title] };
    },

    downloads() {
      return H.DownloadManager.Queue.Value.map(t => ({
        id: tid(t), chapter: t.Media.Title, manga: t.Media.Parent?.Title, source: t.Media.Parent?.Parent?.Title,
        sourceId: t.Media.Parent?.Parent?.Identifier, mangaId: String(t.Media.Parent?.Identifier), chapterId: String(t.Media.Identifier),
        status: String(t.Status.Value), progress: t.Progress.Value, errors: (t.Errors.Value || []).map(e => String(e.message || e)).slice(0, 3),
      }));
    },

    async clearFinished() {
      const done = H.DownloadManager.Queue.Value.filter(t => ['completed', 'failed'].includes(String(t.Status.Value)));
      for (const t of done) { try { await H.DownloadManager.Dequeue(t); } catch (e) { } }
      return done.length;
    },

    async cancel(ids) {
      const set = new Set(ids.map(String));
      const tasks = H.DownloadManager.Queue.Value.filter(t => set.has(tid(t)));
      for (const t of tasks) { try { t.Abort?.abort?.(); } catch (e) { } try { await H.DownloadManager.Dequeue(t); } catch (e) { } }
      return tasks.length;
    },

    settings() {
      const s = H.SettingsManager.OpenScope();
      const o = {};
      for (const x of Object.values(s.settings || {})) {
        const v = x.Value;
        o[x.ID] = v && typeof v === 'object' ? (v.name ?? null) : v;
      }
      return o;
    },
  };
  window.__mk = mk;
  return 'ok';
})()
