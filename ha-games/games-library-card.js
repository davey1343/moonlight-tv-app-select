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
      end_stream_script: 'script.gaming_end_stream',
      refresh_entity: 'button.beast_refresh_game_list',
    }, config || {});
    this._q = '';
    this._sort = this._load('sort', 'recent'); if (this._sort !== 'az') this._sort = 'recent';
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
      .dl{z-index:2;position:absolute;inset:auto 0 0 0;padding:6px;text-align:center;font-size:11px;font-weight:700;background:linear-gradient(transparent,rgba(0,0,0,.75))}
      .nm{font-size:13px;font-weight:600;margin-top:7px;line-height:1.25;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
      .sub{font-size:11px;opacity:.55;margin-top:2px}
      .empty{opacity:.6;padding:40px 0;text-align:center;line-height:1.6}
      .it{-webkit-touch-callout:none;user-select:none;-webkit-user-select:none}
      .it img{-webkit-user-drag:none;pointer-events:none}
      .hold{z-index:3;position:absolute;inset:auto 0 0 0;height:0;background:rgba(76,175,80,.35);pointer-events:none}
      .it.holding .hold{height:100%;transition:height var(--hold,700ms) linear}
      .it.ni.holding .hold{background:rgba(120,160,255,.35)}
      .toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:30;background:#1d2024;color:#c9ccd1;padding:9px 16px;border-radius:12px;font-size:13px;font-weight:600;opacity:0;transition:opacity .2s;pointer-events:none}
      .toast.show{opacity:1}
      .sd{display:none;position:fixed;inset:0;z-index:25;background:rgba(0,0,0,.6);align-items:center;justify-content:center;padding:16px}
      .sd.open{display:flex}
      .sd .box{background:#16181c;border:1px solid #23262c;border-radius:18px;padding:18px;width:100%;max-width:380px;display:flex;flex-direction:column;gap:12px}
      .sd .t{font-size:17px;font-weight:800}
      .sd .hb{position:relative;overflow:hidden;border-radius:14px;padding:14px 16px;background:#1f2227;cursor:pointer;user-select:none;-webkit-user-select:none;touch-action:none;-webkit-touch-callout:none}
      .sd .hb b{display:block;font-size:15px;position:relative;z-index:1}
      .sd .hb span{display:block;font-size:12px;opacity:.6;margin-top:3px;position:relative;z-index:1}
      .sd .hb::before{content:'';position:absolute;inset:0 auto 0 0;width:0;background:rgba(255,255,255,.12)}
      .sd .hb.off::before{background:rgba(229,115,115,.35)}
      .sd .hb.holding::before{width:100%;transition:width var(--hold,1200ms) linear}
      .sd .cancel{text-align:center;padding:8px;opacity:.6;cursor:pointer;font-size:13px}
      .tp{display:none;position:fixed;inset:0;z-index:20;background:#0b0c0e;flex-direction:column;padding:10px;gap:10px;box-sizing:border-box;
          padding-top:max(10px,env(safe-area-inset-top));padding-bottom:max(10px,env(safe-area-inset-bottom))}
      .tp.open{display:flex}
      .tp .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
      .tp .btn{background:#1a1c20;color:#c9ccd1}
      .tp .dot{width:9px;height:9px;border-radius:50%;background:#7a5b2a;flex:none}
      .tp .dot.ok{background:#3f7d4a}
      .tp .st{flex:1;min-width:0;font-size:12px;color:#8a8d93;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      .tp .area{flex:1;border-radius:16px;background:#121418;border:1px solid #1f2227;touch-action:none;position:relative;user-select:none;-webkit-user-select:none}
      .tp .hint{position:absolute;inset:auto 0 14px 0;text-align:center;font-size:12px;color:#4b4f56;pointer-events:none;line-height:1.5}
      .tp .mb{display:grid;grid-template-columns:1fr 1fr;gap:8px;height:64px}
      .tp .mb div{border-radius:14px;background:#16181c;border:1px solid #1f2227;display:grid;place-items:center;color:#8a8d93;font-size:13px;font-weight:600;touch-action:none;user-select:none;-webkit-user-select:none}
      .tp .mb div.down{background:#23262c}
      .tp .kb{position:absolute;opacity:0;width:1px;height:1px;left:-100px;pointer-events:none}
    </style>
    <div class="wrap">
      <div class="bar">
        <div class="tt">Games<span class="cnt"></span></div>
        <input type="search" placeholder="Search games" />
        <div class="btn sort"></div>
        <div class="btn refresh" title="Ask BEAST to resend its game list">Refresh</div>
        <div class="btn padbtn" title="Use this screen as a touchpad for BEAST">Touchpad</div>
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
    </div>
    <div class="sd">
      <div class="box">
        <div class="t">Stop gaming</div>
        <div class="hb end"><b>End stream</b><span>Hold — closes Moonlight. The PC and TV stay on.</span></div>
        <div class="hb off"><b>Shut down PC</b><span>Hold — ends the stream, turns the TV off and shuts BEAST down.</span></div>
        <div class="cancel">Cancel</div>
      </div>
    </div>
    <div class="toast"></div>
    <div class="tp">
      <div class="row">
        <div class="btn close">✕ Close</div>
        <div class="dot"></div><div class="st">Connecting…</div>
        <div class="btn key" data-k="esc">Esc</div>
        <div class="btn key" data-k="enter">Enter</div>
        <div class="btn key" data-k="back">⌫</div>
        <div class="btn key" data-k="alt+tab">Alt+Tab</div>
        <div class="btn key" data-k="win">Win</div>
        <div class="btn kbd">⌨ Keyboard</div>
      </div>
      <div class="area"><div class="hint">Drag to move · tap to click · two-finger tap to right-click · two fingers to scroll</div></div>
      <div class="mb"><div data-b="l">Left</div><div data-b="r">Right</div></div>
      <input class="kb" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" />
    </div>`;
    const input = root.querySelector('input');
    input.addEventListener('input', () => { this._q = input.value; this._renderGrid(); });
    const sortBtn = root.querySelector('.sort');
    const sortLabel = () => { sortBtn.textContent = { recent: 'Recent', az: 'A–Z' }[this._sort] || 'Recent'; };
    sortLabel();
    sortBtn.addEventListener('click', () => {
      this._sort = { recent: 'az', az: 'recent' }[this._sort] || 'recent'; this._save('sort', this._sort); sortLabel(); this._renderGrid();
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
    const sd = root.querySelector('.sd');
    root.querySelector('.stop').addEventListener('click', () => sd.classList.add('open'));
    sd.querySelector('.cancel').addEventListener('click', () => sd.classList.remove('open'));
    sd.addEventListener('click', (e) => { if (e.target === sd) sd.classList.remove('open'); });
    this._holdify(sd.querySelector('.hb.end'), 1200, () => { sd.classList.remove('open'); this._script(this._config.end_stream_script, {}); this._toast('Ending the stream'); });
    this._holdify(sd.querySelector('.hb.off'), 1200, () => { sd.classList.remove('open'); this._script(this._config.stop_script, {}); this._toast('Shutting down BEAST'); });
    this._setupPad(root);
    // Games: press and hold a cover to play (or install); a quick tap just shows a hint
    const grid = root.querySelector('.grid');
    let hold = null;
    const cancelHold = () => { if (hold) { clearTimeout(hold.timer); hold.it.classList.remove('holding'); hold = null; } };
    grid.addEventListener('contextmenu', (e) => { if (e.target.closest('.it')) e.preventDefault(); });
    grid.addEventListener('pointerdown', (e) => {
      const it = e.target.closest('.it');
      if (!it || (e.pointerType === 'mouse' && e.button !== 0)) return;
      cancelHold();
      const g = this._games()[Number(it.dataset.i)];
      if (!g) return;
      it.style.setProperty('--hold', '700ms');
      it.classList.add('holding');
      hold = { it, x: e.clientX, y: e.clientY, at: e.timeStamp, done: false,
               timer: setTimeout(() => { hold.done = true; it.classList.remove('holding'); if (navigator.vibrate) navigator.vibrate(30); this._tap(g); }, 700) };
    });
    grid.addEventListener('pointermove', (e) => { if (hold && Math.hypot(e.clientX - hold.x, e.clientY - hold.y) > 10) cancelHold(); });
    grid.addEventListener('pointerup', () => {
      if (hold && !hold.done) {
        const it = hold.it, g = this._games()[Number(it.dataset.i)];
        this._toast(g && !this._isInstalled(g) ? 'Hold to install' : 'Hold to play');
      }
      cancelHold();
    });
    grid.addEventListener('pointercancel', cancelHold);
    grid.addEventListener('pointerleave', cancelHold);
  }

  // ---------- Touchpad for BEAST (talks straight to beast-touchpad.ps1 on the PC) ----------
  _setupPad(root) {
    const tp = root.querySelector('.tp'), area = tp.querySelector('.area'), kb = tp.querySelector('.kb');
    const padBtn = root.querySelector('.padbtn');
    if (!this._config.touchpad_key) { padBtn.style.display = 'none'; return; }
    padBtn.addEventListener('click', () => this._padOpen(true));
    tp.querySelector('.close').addEventListener('click', () => this._padOpen(false));
    tp.querySelectorAll('.key').forEach(b => b.addEventListener('click', () => this._padSend('k ' + b.dataset.k)));
    tp.querySelector('.kbd').addEventListener('click', () => { kb.value = ''; kb.focus(); });
    kb.addEventListener('keydown', (e) => {
      const map = { Enter: 'enter', Backspace: 'back', Escape: 'esc', Tab: 'tab', ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' };
      if (map[e.key]) { e.preventDefault(); this._padSend('k ' + map[e.key]); }
    });
    kb.addEventListener('input', (e) => {
      if (e.inputType === 'deleteContentBackward') this._padSend('k back');
      else if (e.data) this._padSend('t ' + e.data);
      else if (kb.value) this._padSend('t ' + kb.value);
      kb.value = '';
    });

    // Mouse buttons: press and hold Left with one finger while moving with another to drag
    tp.querySelectorAll('.mb div').forEach(b => {
      b.addEventListener('pointerdown', (e) => { e.preventDefault(); b.classList.add('down'); this._padSend('bd ' + b.dataset.b); });
      const up = () => { if (b.classList.contains('down')) { b.classList.remove('down'); this._padSend('bu ' + b.dataset.b); } };
      b.addEventListener('pointerup', up); b.addEventListener('pointercancel', up); b.addEventListener('pointerleave', up);
    });

    // Pad gestures
    const pts = new Map();
    let acc = { x: 0, y: 0, w: 0 }, raf = 0, gesture = null;
    const sens = Number(this._config.touchpad_speed || 1.6);
    const flush = () => {
      raf = 0;
      const dx = Math.trunc(acc.x), dy = Math.trunc(acc.y), w = Math.trunc(acc.w);
      let msg = [];
      if (dx || dy) { msg.push(`m ${dx} ${dy}`); acc.x -= dx; acc.y -= dy; }
      if (w) { msg.push(`w ${w}`); acc.w -= w; }
      if (msg.length) this._padSend(msg.join('\n'));
    };
    const queue = () => { if (!raf) raf = requestAnimationFrame(flush); };
    area.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      area.setPointerCapture(e.pointerId);
      pts.set(e.pointerId, { x: e.clientX, y: e.clientY, t: e.timeStamp });
      if (pts.size === 1) gesture = { start: e.timeStamp, moved: 0, max: 1 };
      else if (gesture) gesture.max = Math.max(gesture.max, pts.size);
    });
    area.addEventListener('pointermove', (e) => {
      const p = pts.get(e.pointerId);
      if (!p) return;
      const dx = e.clientX - p.x, dy = e.clientY - p.y, dt = Math.max(1, e.timeStamp - p.t);
      p.x = e.clientX; p.y = e.clientY; p.t = e.timeStamp;
      if (gesture) gesture.moved += Math.abs(dx) + Math.abs(dy);
      if (pts.size === 1) {
        const speed = Math.hypot(dx, dy) / dt;                 // px per ms
        const f = sens * (1 + Math.min(speed, 2.5) * 0.9);      // light acceleration
        acc.x += dx * f; acc.y += dy * f;
      } else if (pts.size === 2) {
        acc.w += -dy * 2.5;                                      // two fingers: scroll (half per finger)
      }
      queue();
    });
    const end = (e) => {
      if (!pts.has(e.pointerId)) return;
      pts.delete(e.pointerId);
      if (pts.size === 0 && gesture) {
        const quick = e.timeStamp - gesture.start < 250 && gesture.moved < 12;
        if (quick) this._padSend(gesture.max >= 2 ? 'c r' : 'c l');
        gesture = null;
      }
    };
    area.addEventListener('pointerup', end);
    area.addEventListener('pointercancel', end);
  }

  _padOpen(open) {
    const tp = this.shadowRoot.querySelector('.tp');
    tp.classList.toggle('open', open);
    if (open) this._padConnect();
    else { this._padWanted = false; clearTimeout(this._padRetry); if (this._ws) { try { this._ws.close(); } catch (e) {} this._ws = null; } }
  }

  _padStatus(text, ok) {
    const tp = this.shadowRoot.querySelector('.tp');
    tp.querySelector('.st').textContent = text;
    tp.querySelector('.dot').classList.toggle('ok', !!ok);
  }

  _padConnect() {
    this._padWanted = true;
    if (location.protocol === 'https:') {
      this._padStatus('The touchpad only works on home Wi-Fi: open Home Assistant at http://192.168.1.133:8123');
      return;
    }
    if (this._ws && this._ws.readyState <= 1) return;
    const url = (this._config.touchpad_url || 'ws://192.168.1.103:9876/') + '?k=' + encodeURIComponent(this._config.touchpad_key);
    this._padStatus('Connecting to BEAST…');
    let ws;
    try { ws = new WebSocket(url); } catch (e) { this._padStatus('Couldn\'t connect: ' + e.message); return; }
    this._ws = ws;
    ws.onopen = () => {
      this._padFails = 0;
      this._padStatus('Connected to BEAST', true);
      clearInterval(this._padPing);
      this._padPing = setInterval(() => { if (ws.readyState === 1) ws.send('p'); }, 20000);
    };
    ws.onclose = () => {
      clearInterval(this._padPing);
      if (this._ws === ws) this._ws = null;
      if (!this._padWanted) return;
      this._padFails = (this._padFails || 0) + 1;
      const pcOn = !['unavailable', 'unknown', undefined].includes(this._hass && this._hass.states['sensor.beast_cpuload'] && this._hass.states['sensor.beast_cpuload'].state);
      if (!pcOn) this._padStatus('BEAST is off');
      else if (this._padFails === 2) {
        // Listener not running yet: the game-list refresh on BEAST starts it
        this._padStatus('Starting the touchpad on BEAST…');
        this._refresh();
      } else this._padStatus(this._padFails > 6 ? 'Can\'t reach BEAST (check its firewall allowed PowerShell on private networks)' : 'Reconnecting…');
      this._padRetry = setTimeout(() => this._padConnect(), this._padFails > 2 ? 5000 : 1500);
    };
  }

  _padSend(msg) {
    if (this._ws && this._ws.readyState === 1) this._ws.send(msg);
  }

  // Press-and-hold button: fill animates while held, action runs when it completes
  _holdify(el, ms, done) {
    let t = null;
    el.style.setProperty('--hold', ms + 'ms');
    const stop = () => { clearTimeout(t); t = null; el.classList.remove('holding'); };
    el.addEventListener('contextmenu', (e) => e.preventDefault());
    el.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      stop(); el.classList.add('holding');
      t = setTimeout(() => { stop(); if (navigator.vibrate) navigator.vibrate(40); done(); }, ms);
    });
    el.addEventListener('pointerup', () => { if (t) this._toast('Keep holding to confirm'); stop(); });
    el.addEventListener('pointerleave', stop);
    el.addEventListener('pointercancel', stop);
  }

  _toast(msg) {
    const el = this.shadowRoot.querySelector('.toast');
    el.textContent = msg; el.classList.add('show');
    clearTimeout(this._toastT); this._toastT = setTimeout(() => el.classList.remove('show'), 1800);
  }

  _renderChips() {
    const root = this.shadowRoot;
    root.querySelectorAll('.chip.show').forEach(ch => ch.classList.toggle('on', ch.dataset.v === this._show));
    root.querySelectorAll('.chip.store').forEach(ch => ch.classList.toggle('on', this._stores.includes(ch.dataset.v)));
  }

  _games() {
    const g = this._hass && this._hass.states[this._config.entity];
    if (!g) return [];
    const a = g.attributes;
    return [a.games, a.games2, a.games3, a.games4].filter(Array.isArray).flat();
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
        <div class="ps"><div class="ph">${this._esc(g.name)}</div>${cover}<div class="hold"></div><div class="tag">${g.gamepass && !inst ? 'Game Pass' : (label[this._store(g)] || 'Steam')}</div>${inst ? '' : '<div class="dl">⬇ Install</div>'}</div>
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

  _tap(g) {
    if (this._busy && Date.now() - this._busy.at < 8000) return;
    const inst = this._isInstalled(g);
    if (!inst) {
      if (!g.install) { alert(`${g.name} can't be installed from here — open the store app on BEAST to install it.`); return; }
      this._toast(`Opening the installer for ${g.name} on BEAST — confirm it there`);
      this._busy = { key: this._key(g), name: g.name, at: Date.now() };
      this._script(this._config.install_script, { url: g.install, game_name: g.name });
    } else {
      this._busy = { key: this._key(g), name: g.name, at: Date.now() };
      const vars = { game_name: g.name };
      if (g.launch) vars.url = g.launch; else vars.game_id = String(g.id);
      if (g.vp) vars.app = g.name;   // has its own Vibepollo app: Moonlight opens it directly
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
