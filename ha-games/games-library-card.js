// Games library card for the Main Dash "Games" page.
// Reads sensor.beast_games (sent by steam-games-to-ha.ps1 on BEAST).
// Installed games: tap to play (script.pc_play_game). Not installed: greyed out, tap to install (script.pc_install_game).
class GamesLibraryCard extends HTMLElement {
  setConfig(config) {
    this._config = Object.assign({
      title: 'Games',
      entity: 'sensor.beast_games',
      play_script: 'script.pc_play_game',
      install_script: 'script.pc_install_game',
      stop_script: 'script.gaming_stop',
      refresh_entity: 'button.beast_refresh_game_list',
    }, config || {});
    this._q = '';
    this._sort = this._load('sort', 'recent');
    this._show = this._load('show', 'all');          // all | installed | not
    this._stores = this._load('stores', ['steam', 'epic', 'xbox']);
    this._busy = null;
    this._sig = '';
  }

  _load(k, d) { try { const v = localStorage.getItem('glc_' + k); return v ? JSON.parse(v) : d; } catch (e) { return d; } }
  _save(k, v) { try { localStorage.setItem('glc_' + k, JSON.stringify(v)); } catch (e) { /* ignore */ } }

  set hass(hass) {
    this._hass = hass;
    if (!this.shadowRoot) this._build();
    const c = this._config;
    const st = (e) => hass.states[e] && hass.states[e].state;
    const g = hass.states[c.entity];
    const updated = g && g.attributes.updated;
    const sig = [updated, st('input_boolean.moonlight_streaming'), st('input_number.moonlight_latency'),
      st('input_number.moonlight_fps'), st('input_text.moonlight_app'), st(c.play_script), st(c.install_script),
      st('script.pc_gaming_on_tv')].join('|');
    if (sig === this._sig) return;
    const listChanged = !this._sig || updated !== this._lastUpdated;
    this._sig = sig;
    this._lastUpdated = updated;
    this._renderStatus();
    if (listChanged) this._renderGrid();
  }

  getCardSize() { return 12; }

  _build() {
    const root = this.attachShadow({ mode: 'open' });
    root.innerHTML = `
    <style>
      :host{display:block}
      .wrap{max-width:1300px;margin:0 auto;padding:16px}
      .bar{display:flex;align-items:center;gap:10px;margin-bottom:10px;flex-wrap:wrap}
      .tt{font-size:20px;font-weight:800;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      .cnt{font-size:12px;opacity:.6;font-weight:500;margin-left:6px}
      input{padding:9px 13px;border-radius:12px;border:1px solid rgba(255,255,255,.12);background:rgba(255,255,255,.06);color:var(--primary-text-color);font-size:14px;outline:none;width:220px;max-width:100%}
      .btn{padding:8px 12px;border-radius:12px;background:rgba(255,255,255,.08);cursor:pointer;font-size:13px;font-weight:600;user-select:none;white-space:nowrap}
      .btn:active{transform:scale(.97)}
      .filters{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px;align-items:center}
      .chip{padding:6px 11px;border-radius:999px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.08);cursor:pointer;font-size:12px;font-weight:600;user-select:none;opacity:.65}
      .chip.on{background:rgba(255,255,255,.16);border-color:rgba(255,255,255,.22);opacity:1}
      .sep{width:1px;height:20px;background:rgba(255,255,255,.12);margin:0 4px}
      .status{display:none;align-items:center;gap:12px;padding:10px 14px;margin-bottom:14px;border-radius:14px;background:rgba(76,175,80,.12);border:1px solid rgba(76,175,80,.25);font-size:14px}
      .status.show{display:flex}
      .status.starting{background:rgba(255,255,255,.06);border-color:rgba(255,255,255,.1)}
      .status .msg{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:16px}
      .it{cursor:pointer;min-width:0}
      .it:active .ps{transform:scale(.97)}
      .it.busy .ps{outline:2px solid rgba(76,175,80,.7)}
      .ps{aspect-ratio:2/3;border-radius:12px;overflow:hidden;background:rgba(255,255,255,.06);box-shadow:0 6px 18px rgba(0,0,0,.35);transition:transform .15s;position:relative}
      .ps img{position:absolute;inset:0;z-index:1;width:100%;height:100%;object-fit:cover;display:block}
      .it.ni .ps img{filter:grayscale(1) brightness(.55)}
      .it.ni .ph{filter:grayscale(1);opacity:.5}
      .it.ni .nm{opacity:.55}
      .ph{position:absolute;inset:0;display:grid;place-items:center;padding:12px;text-align:center;font-weight:800;font-size:15px;line-height:1.2;
          background:linear-gradient(160deg,rgba(90,110,255,.25),rgba(0,190,170,.12) 60%,rgba(255,160,0,.12));}
      .tag{z-index:2;position:absolute;left:6px;top:6px;font-size:10px;font-weight:700;padding:2px 6px;border-radius:6px;background:rgba(0,0,0,.6);opacity:.9;letter-spacing:.02em}
      .rt{z-index:2;position:absolute;right:6px;top:6px;font-size:10px;font-weight:800;padding:2px 6px;border-radius:6px;background:rgba(0,0,0,.6)}
      .rt.hi{color:#8fd19e}.rt.mid{color:#e3c27a}.rt.lo{color:#e08a8a}
      .dl{z-index:2;position:absolute;inset:auto 0 0 0;padding:6px;text-align:center;font-size:11px;font-weight:700;background:linear-gradient(transparent,rgba(0,0,0,.75))}
      .nm{font-size:13px;font-weight:600;margin-top:7px;line-height:1.25;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
      .sub{font-size:11px;opacity:.55;margin-top:2px}
      .empty{opacity:.6;padding:40px 0;text-align:center;line-height:1.6}
    </style>
    <div class="wrap">
      <div class="bar">
        <div class="tt">Games<span class="cnt"></span></div>
        <input type="search" placeholder="Search games" />
        <div class="btn sort"></div>
        <div class="btn refresh" title="Ask BEAST to resend its game list">Refresh</div>
      </div>
      <div class="filters">
        <div class="chip show" data-v="all">All</div>
        <div class="chip show" data-v="installed">Installed</div>
        <div class="chip show" data-v="not">Not installed</div>
        <div class="sep"></div>
        <div class="chip store" data-v="steam">Steam</div>
        <div class="chip store" data-v="epic">Epic</div>
        <div class="chip store" data-v="xbox">Xbox</div>
      </div>
      <div class="status"><div class="msg"></div><div class="btn stop">Stop gaming</div></div>
      <div class="grid"></div>
    </div>`;
    const input = root.querySelector('input');
    input.addEventListener('input', () => { this._q = input.value; this._renderGrid(); });
    const sortBtn = root.querySelector('.sort');
    const sortLabel = () => { sortBtn.textContent = { recent: 'Recent', az: 'A–Z', rating: 'Top rated' }[this._sort] || 'Recent'; };
    sortLabel();
    sortBtn.addEventListener('click', () => {
      this._sort = { recent: 'az', az: 'rating', rating: 'recent' }[this._sort] || 'recent'; this._save('sort', this._sort); sortLabel(); this._renderGrid();
    });
    root.querySelectorAll('.chip.show').forEach(ch => ch.addEventListener('click', () => {
      this._show = ch.dataset.v; this._save('show', this._show); this._renderChips(); this._renderGrid();
    }));
    root.querySelectorAll('.chip.store').forEach(ch => ch.addEventListener('click', () => {
      const v = ch.dataset.v;
      const set = new Set(this._stores);
      if (set.has(v) && set.size > 1) set.delete(v); else set.add(v);
      this._stores = [...set]; this._save('stores', this._stores); this._renderChips(); this._renderGrid();
    }));
    this._renderChips();
    root.querySelector('.refresh').addEventListener('click', () => this._refresh());
    root.querySelector('.stop').addEventListener('click', () => {
      if (confirm('Stop gaming? This closes Moonlight, turns the TV off and shuts BEAST down.')) this._script(this._config.stop_script, {});
    });
    root.querySelector('.grid').addEventListener('click', (e) => {
      const it = e.target.closest('.it');
      if (!it) return;
      const g = this._games()[Number(it.dataset.i)];
      if (g) this._tap(g);
    });
  }

  _renderChips() {
    const root = this.shadowRoot;
    root.querySelectorAll('.chip.show').forEach(ch => ch.classList.toggle('on', ch.dataset.v === this._show));
    root.querySelectorAll('.chip.store').forEach(ch => ch.classList.toggle('on', this._stores.includes(ch.dataset.v)));
  }

  _games() {
    const g = this._hass && this._hass.states[this._config.entity];
    return (g && Array.isArray(g.attributes.games)) ? g.attributes.games : [];
  }

  _isInstalled(g) { return g.installed !== false; }
  _store(g) { return g.store || (g.src === 'shortcut' ? 'steam' : (g.src || 'steam')); }

  _renderStatus() {
    const root = this.shadowRoot; if (!root) return;
    const st = (e) => this._hass.states[e] && this._hass.states[e].state;
    const box = root.querySelector('.status'), msg = root.querySelector('.msg');
    const streaming = st('input_boolean.moonlight_streaming') === 'on';
    const starting = st(this._config.play_script) === 'on' || st('script.pc_gaming_on_tv') === 'on';
    const installing = st(this._config.install_script) === 'on';
    box.classList.toggle('show', streaming || starting || installing);
    box.classList.toggle('starting', !streaming);
    root.querySelector('.stop').style.display = installing && !streaming ? 'none' : '';
    if (streaming) {
      const lat = Math.round(Number(st('input_number.moonlight_latency') || 0));
      const fps = Math.round(Number(st('input_number.moonlight_fps') || 0));
      const app = this._busy ? this._busy.name : (st('input_text.moonlight_app') || 'Moonlight');
      msg.textContent = `Streaming ${app}` + (fps > 0 ? `  ·  ~${lat} ms  ·  ${fps} fps` : '');
    } else if (installing) {
      msg.textContent = `Opening the install for ${this._busy ? this._busy.name : 'the game'} on BEAST…`;
    } else if (starting) {
      msg.textContent = `Starting ${this._busy ? this._busy.name : 'gaming'}… waking BEAST and the TV`;
    }
    const all = this._games();
    const inst = all.filter(g => this._isInstalled(g)).length;
    root.querySelector('.cnt').textContent = all.length ? `${inst} installed · ${all.length} total` : '';
  }

  _renderGrid() {
    const root = this.shadowRoot; if (!root || !this._hass) return;
    const grid = root.querySelector('.grid');
    const all = this._games();
    if (!this._hass.states[this._config.entity] || !all.length) {
      grid.innerHTML = `<div class="empty" style="grid-column:1/-1">No game list yet.<br>It arrives from BEAST when the PC is on — press Refresh.</div>`;
      return;
    }
    const q = this._q.trim().toLowerCase();
    let list = all.map((g, i) => ({ g, i })).filter(({ g }) => {
      if (q && !String(g.name).toLowerCase().includes(q)) return false;
      const inst = this._isInstalled(g);
      if (this._show === 'installed' && !inst) return false;
      if (this._show === 'not' && inst) return false;
      return this._stores.includes(this._store(g));
    });
    list.sort((a, b) => {
      if (this._sort === 'az') return String(a.g.name).localeCompare(String(b.g.name));
      if (this._sort === 'rating') {
        const ra = a.g.rating == null ? -1 : Number(a.g.rating), rb = b.g.rating == null ? -1 : Number(b.g.rating);
        return rb - ra || (Number(b.g.rating_count) || 0) - (Number(a.g.rating_count) || 0) || String(a.g.name).localeCompare(String(b.g.name));
      }
      const ia = this._isInstalled(a.g), ib = this._isInstalled(b.g);
      if (ia !== ib) return ia ? -1 : 1;                          // installed first
      return (Number(b.g.last_played) || 0) - (Number(a.g.last_played) || 0) || String(a.g.name).localeCompare(String(b.g.name));
    });
    if (!list.length) {
      grid.innerHTML = `<div class="empty" style="grid-column:1/-1">No games match these filters.</div>`;
      return;
    }
    const label = { steam: 'Steam', epic: 'Epic', xbox: 'Xbox' };
    grid.innerHTML = list.map(({ g, i }) => {
      const inst = this._isInstalled(g);
      const played = inst && Number(g.last_played) > 0 ? this._ago(Number(g.last_played)) : '';
      const sub = inst ? played : (g.gamepass ? 'Game Pass · not installed' : (g.install ? 'Not installed' : 'Not installed · install in the store app'));
      const cover = g.cover ? `<img loading="lazy" src="${this._esc(g.cover)}" data-fb="${this._esc(g.fallback || '')}" alt="">` : '';
      const busy = this._busy && this._busy.key === this._key(g) ? ' busy' : '';
      return `<div class="it${inst ? '' : ' ni'}${busy}" data-i="${i}">
        <div class="ps"><div class="ph">${this._esc(g.name)}</div>${cover}<div class="tag">${g.gamepass && !inst ? 'Game Pass' : (label[this._store(g)] || 'Steam')}</div>${this._ratingBadge(g)}${inst ? '' : '<div class="dl">⬇ Install</div>'}</div>
        <div class="nm">${this._esc(g.name)}</div>${sub ? `<div class="sub">${sub}</div>` : ''}
      </div>`;
    }).join('');
    grid.querySelectorAll('img').forEach(img => {
      img.addEventListener('error', () => {
        const fb = img.dataset.fb;
        if (fb) { img.dataset.fb = ''; img.src = fb; } else img.remove();
      });
    });
  }

  _key(g) { return String(g.id); }

  _ratingBadge(g) {
    if (g.rating == null || g.rating === '') return '';
    const r = Number(g.rating);
    const cls = r >= 80 ? 'hi' : r >= 60 ? 'mid' : 'lo';
    const src = g.rating_src === 'msstore' ? 'Microsoft Store' : 'Steam';
    return `<div class="rt ${cls}" title="${r}% positive · ${Number(g.rating_count || 0).toLocaleString('en-GB')} ${src} reviews">${r}%</div>`;
  }

  _tap(g) {
    if (this._busy && Date.now() - this._busy.at < 8000) return;
    const inst = this._isInstalled(g);
    if (!inst) {
      if (!g.install) { alert(`${g.name} can't be installed from here — open the store app on BEAST to install it.`); return; }
      if (!confirm(`Install ${g.name} on BEAST?\n\nThis opens the store's install dialog on the PC — you'll need to confirm it there (or with the controller while streaming).`)) return;
      this._busy = { key: this._key(g), name: g.name, at: Date.now() };
      this._script(this._config.install_script, { url: g.install, game_name: g.name });
    } else {
      this._busy = { key: this._key(g), name: g.name, at: Date.now() };
      const vars = { game_name: g.name };
      if (g.launch) vars.url = g.launch; else vars.game_id = String(g.id);
      this._script(this._config.play_script, vars);
    }
    this._renderGrid();
    this._renderStatus();
  }

  _refresh() {
    const e = this._config.refresh_entity;
    if (this._hass.states[e]) this._hass.callService('button', 'press', { entity_id: e });
  }

  _script(entity, vars) {
    this._hass.callService('script', 'turn_on', { entity_id: entity, variables: vars });
  }

  _ago(ts) {
    const d = (Date.now() / 1000 - ts) / 86400;
    if (d < 1) return 'Played today';
    if (d < 2) return 'Played yesterday';
    if (d < 30) return `Played ${Math.floor(d)} days ago`;
    if (d < 365) return `Played ${Math.floor(d / 30)} mo ago`;
    return '';
  }

  _esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
}
customElements.define('games-library-card', GamesLibraryCard);
window.customCards = window.customCards || [];
window.customCards.push({ type: 'games-library-card', name: 'Games library', description: 'BEAST game library with launch and install' });
