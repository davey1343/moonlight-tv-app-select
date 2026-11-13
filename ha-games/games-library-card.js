// Games library card for the Main Dash "Games" page.
// Reads sensor.beast_games (sent by steam-games-to-ha.ps1 on BEAST) and starts a game via script.pc_play_game.
class GamesLibraryCard extends HTMLElement {
  setConfig(config) {
    this._config = Object.assign({
      title: 'Games',
      entity: 'sensor.beast_games',
      play_script: 'script.pc_play_game',
      stop_script: 'script.gaming_stop',
      refresh_entity: 'button.beast_refresh_game_list',
    }, config || {});
    this._q = '';
    this._sort = 'recent';
    this._busy = null;
    this._sig = '';
  }

  set hass(hass) {
    this._hass = hass;
    if (!this.shadowRoot) this._build();
    const c = this._config;
    const g = hass.states[c.entity];
    const s = hass.states['input_boolean.moonlight_streaming'];
    const lat = hass.states['input_number.moonlight_latency'];
    const fps = hass.states['input_number.moonlight_fps'];
    const app = hass.states['input_text.moonlight_app'];
    const run = hass.states[c.play_script];
    const sig = [g && g.attributes.updated, s && s.state, lat && lat.state, fps && fps.state, app && app.state, run && run.state].join('|');
    if (sig === this._sig) return;
    const listChanged = !this._sig || (g && g.attributes.updated) !== this._sig.split('|')[0];
    this._sig = sig;
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
      .bar{display:flex;align-items:center;gap:10px;margin-bottom:14px;flex-wrap:wrap}
      .tt{font-size:20px;font-weight:800;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      .cnt{font-size:12px;opacity:.6;font-weight:500;margin-left:6px}
      input{padding:9px 13px;border-radius:12px;border:1px solid rgba(255,255,255,.12);background:rgba(255,255,255,.06);color:var(--primary-text-color);font-size:14px;outline:none;width:220px;max-width:100%}
      .btn{padding:8px 12px;border-radius:12px;background:rgba(255,255,255,.08);cursor:pointer;font-size:13px;font-weight:600;user-select:none;white-space:nowrap}
      .btn:active{transform:scale(.97)}
      .btn.on{background:rgba(255,255,255,.16)}
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
      .ps img.wide{object-fit:cover;object-position:center}
      .ph{position:absolute;inset:0;display:grid;place-items:center;padding:12px;text-align:center;font-weight:800;font-size:15px;line-height:1.2;
          background:linear-gradient(160deg,rgba(90,110,255,.25),rgba(0,190,170,.12) 60%,rgba(255,160,0,.12));}
      .tag{z-index:2;position:absolute;left:6px;top:6px;font-size:10px;font-weight:700;padding:2px 6px;border-radius:6px;background:rgba(0,0,0,.55);opacity:.85}
      .nm{font-size:13px;font-weight:600;margin-top:7px;line-height:1.25;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
      .sub{font-size:11px;opacity:.55;margin-top:2px}
      .empty{opacity:.6;padding:40px 0;text-align:center;line-height:1.6}
    </style>
    <div class="wrap">
      <div class="bar">
        <div class="tt">Games<span class="cnt"></span></div>
        <input type="search" placeholder="Search games" />
        <div class="btn sort">Recent</div>
        <div class="btn refresh" title="Ask BEAST to resend its game list">Refresh</div>
      </div>
      <div class="status"><div class="msg"></div><div class="btn stop">Stop gaming</div></div>
      <div class="grid"></div>
    </div>`;
    const input = root.querySelector('input');
    input.addEventListener('input', () => { this._q = input.value; this._renderGrid(); });
    root.querySelector('.sort').addEventListener('click', () => {
      this._sort = this._sort === 'recent' ? 'az' : 'recent';
      root.querySelector('.sort').textContent = this._sort === 'recent' ? 'Recent' : 'A–Z';
      this._renderGrid();
    });
    root.querySelector('.refresh').addEventListener('click', () => this._refresh());
    root.querySelector('.stop').addEventListener('click', () => {
      if (confirm('Stop gaming? This closes Moonlight, turns the TV off and shuts BEAST down.')) {
        this._call(this._config.stop_script, {});
      }
    });
    root.querySelector('.grid').addEventListener('click', (e) => {
      const it = e.target.closest('.it');
      if (it) this._play(it.dataset.id, it.dataset.name);
    });
  }

  _games() {
    const g = this._hass && this._hass.states[this._config.entity];
    return (g && Array.isArray(g.attributes.games)) ? g.attributes.games : [];
  }

  _renderStatus() {
    const root = this.shadowRoot; if (!root) return;
    const st = (e) => this._hass.states[e] && this._hass.states[e].state;
    const box = root.querySelector('.status'), msg = root.querySelector('.msg');
    const streaming = st('input_boolean.moonlight_streaming') === 'on';
    const starting = st(this._config.play_script) === 'on' || st('script.pc_gaming_on_tv') === 'on';
    box.classList.toggle('show', streaming || starting);
    box.classList.toggle('starting', !streaming);
    if (streaming) {
      const lat = Math.round(Number(st('input_number.moonlight_latency') || 0));
      const fps = Math.round(Number(st('input_number.moonlight_fps') || 0));
      const app = this._busy ? this._busy.name : (st('input_text.moonlight_app') || 'Moonlight');
      msg.textContent = `Streaming ${app}` + (fps > 0 ? `  ·  ~${lat} ms  ·  ${fps} fps` : '');
    } else if (starting) {
      msg.textContent = `Starting ${this._busy ? this._busy.name : 'gaming'}… waking BEAST and the TV`;
    }
    const cnt = root.querySelector('.cnt');
    const g = this._hass.states[this._config.entity];
    cnt.textContent = g ? `${this._games().length}` : '';
  }

  _renderGrid() {
    const root = this.shadowRoot; if (!root || !this._hass) return;
    const grid = root.querySelector('.grid');
    const ent = this._hass.states[this._config.entity];
    if (!ent || !this._games().length) {
      grid.innerHTML = `<div class="empty" style="grid-column:1/-1">No game list yet.<br>It arrives from BEAST when the PC is on — press Refresh.</div>`;
      return;
    }
    const q = this._q.trim().toLowerCase();
    let list = this._games().filter(g => !q || String(g.name).toLowerCase().includes(q));
    if (this._sort === 'az') list = list.slice().sort((a, b) => String(a.name).localeCompare(String(b.name)));
    if (!list.length) {
      grid.innerHTML = `<div class="empty" style="grid-column:1/-1">No games match “${this._esc(this._q)}”.</div>`;
      return;
    }
    grid.innerHTML = list.map(g => {
      const played = Number(g.last_played) > 0 ? this._ago(Number(g.last_played)) : '';
      const tag = g.src === 'shortcut' ? '<div class="tag">Added</div>' : '';
      const cover = g.cover ? `<img loading="lazy" src="${this._esc(g.cover)}" data-fb="${this._esc(g.fallback || '')}" alt="">` : '';
      return `<div class="it${this._busy && this._busy.id === String(g.id) ? ' busy' : ''}" data-id="${this._esc(String(g.id))}" data-name="${this._esc(g.name)}">
        <div class="ps"><div class="ph">${this._esc(g.name)}</div>${cover}${tag}</div>
        <div class="nm">${this._esc(g.name)}</div>${played ? `<div class="sub">${played}</div>` : ''}
      </div>`;
    }).join('');
    // Missing art: try the wide header image, then fall back to the name tile underneath
    grid.querySelectorAll('img').forEach(img => {
      img.addEventListener('error', () => {
        const fb = img.dataset.fb;
        if (fb) { img.dataset.fb = ''; img.classList.add('wide'); img.src = fb; }
        else img.remove();
      });
    });
  }

  _play(id, name) {
    if (!id) return;
    if (this._busy && Date.now() - this._busy.at < 8000) return;
    this._busy = { id, name, at: Date.now() };
    this._call(this._config.play_script, { game_id: id, game_name: name });
    this._renderGrid();
    this._renderStatus();
  }

  _refresh() {
    const e = this._config.refresh_entity;
    if (this._hass.states[e]) this._hass.callService('button', 'press', { entity_id: e });
  }

  _call(entity, vars) {
    const [domain, object] = entity.split('.');
    if (domain === 'script') this._hass.callService('script', 'turn_on', { entity_id: entity, variables: vars });
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
window.customCards.push({ type: 'games-library-card', name: 'Games library', description: 'BEAST game library with launch via Moonlight' });
