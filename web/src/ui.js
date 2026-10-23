'use strict';
/* The page: dome, track rows, readings, settings. Everything here is presentation; the
 * model decides, the engine sounds. */

(function () {
  const $ = (sel, root) => (root || document).querySelector(sel);
  const el = (tag, props, ...kids) => {
    const n = document.createElement(tag);
    if (props) for (const k of Object.keys(props)) {
      if (k === 'class') n.className = props[k];
      else if (k === 'text') n.textContent = props[k];
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), props[k]);
      else n.setAttribute(k, props[k]);
    }
    for (const c of kids) if (c != null) n.append(c);
    return n;
  };

  const engine = new OrbitEngine(document.getElementById('worklet-src').textContent);
  const model = new RhythmModel(engine);
  window.orbitakt = { model, engine };

  // ---------- Static structure ----------
  const app = $('#app');
  const domeCanvas = el('canvas', { id: 'dome', 'aria-label': 'Sky dome: satellites overhead, with the sweeping beam' });
  const playBtn = el('button', { id: 'play', class: 'play', type: 'button' });
  const statusEl = el('div', { class: 'status', role: 'status' });
  const crewEl = el('div', { class: 'crew' });
  const rowsEl = el('div', { class: 'rows' });
  const readEl = el('div', { class: 'readings' });
  const settingsEl = el('div', { class: 'settings' });
  const noteEl = el('div', { class: 'note' });

  app.append(
    el('header', null,
      el('h1', { text: 'Orbitakt' }),
      el('p', { class: 'tag', text: 'A drum machine played by the satellites above you.' })),
    statusEl,
    el('div', { class: 'domewrap' }, domeCanvas),
    el('div', { class: 'controls' }, playBtn, crewEl),
    rowsEl, readEl, settingsEl, noteEl);

  // Track rows
  const rowRefs = SPECS.map((spec, t) => {
    const canvas = el('canvas', { class: 'rowcanvas', 'aria-hidden': 'true' });
    const label = el('span', { class: 'rl', style: 'color:' + spec.color, text: ['NAV · kick', 'LEO · rim', 'SWARM · hat', 'BELT · gate hat'][t] });
    const info = el('span', { class: 'ri' });
    const mute = el('button', { type: 'button', class: 'mute', 'aria-label': 'Mute ' + spec.sound, onclick: () => model.setMuted(!model.tracks[t].muted, t), text: 'M' });
    rowsEl.append(el('div', { class: 'row' }, el('div', { class: 'rh' }, label, info, mute), canvas));
    return { canvas, info, mute };
  });

  // Settings
  const sect = (title, ...kids) => el('details', null, el('summary', { text: title }), el('div', { class: 'sec' }, ...kids));
  const slider = (label, key, min, max, step, fmt) => {
    const out = el('output');
    const inp = el('input', { type: 'range', min, max, step, 'aria-label': label });
    inp.addEventListener('input', () => { model.setSetting(key, parseFloat(inp.value)); out.textContent = fmt(model.s[key]); });
    const refresh = () => { inp.value = model.s[key]; out.textContent = fmt(model.s[key]); };
    refresh();
    return { node: el('label', { class: 'ctl' }, el('span', { text: label }), inp, out), refresh };
  };
  const select = (label, key, options, conv) => {
    const sel = el('select', { 'aria-label': label });
    options.forEach(([v, txt]) => sel.append(el('option', { value: v, text: txt })));
    sel.addEventListener('change', () => model.setSetting(key, conv ? conv(sel.value) : sel.value));
    const refresh = () => { sel.value = String(model.s[key]); };
    refresh();
    return { node: el('label', { class: 'ctl' }, el('span', { text: label }), sel), refresh };
  };
  const toggle = (label, key) => {
    const cb = el('input', { type: 'checkbox', 'aria-label': label });
    cb.addEventListener('change', () => model.setSetting(key, cb.checked));
    const refresh = () => { cb.checked = !!model.s[key]; };
    refresh();
    return { node: el('label', { class: 'ctl check' }, cb, el('span', { text: label })), refresh };
  };

  const pct = v => Math.round(v * 100) + '%';
  const placeOpts = PLACES.map(p => [p.key, p.name]);
  const placeSel = select('Place', 'place', placeOpts);
  const locBtn = el('button', { type: 'button', class: 'btn', text: 'Use my location', onclick: async () => {
    locBtn.disabled = true; locBtn.textContent = 'Locating…';
    const ok = await model.useMyLocation();
    locBtn.disabled = false; locBtn.textContent = ok ? 'Using your location' : 'Location unavailable';
    refreshAll();
  } });
  const live = toggle('Real satellites (CelesTrak)', 'useLive');
  const root = select('Key', 'rootPC', PITCH_NAMES.map((n, i) => [i, n]), Number);
  const scale = select('Scale', 'scaleIndex', SCALES.map((s, i) => [i, s.name]), Number);
  const tempoSrc = select('Tempo from', 'tempoSource', [['orbit', 'The orbits'], ['manual', 'Manual']]);
  const bpm = slider('Manual tempo', 'manualBPM', 60, 132, 1, v => Math.round(v) + ' BPM');
  const sweepLen = select('Sweep', 'division', [[2, 'Long (8 beats)'], [4, 'Short (4 beats)']], Number);
  const swing = slider('Swing', 'swing', 0, 0.4, 0.01, pct);
  const quant = slider('Quantize', 'quantize', 0, 1, 0.01, pct);
  const dub = slider('Dub echo', 'dub', 0, 0.85, 0.01, pct);
  const space = slider('Space (plate)', 'space', 0, 1, 0.01, pct);
  const dust = toggle('Dust (hiss and crackle)', 'dustOn');
  const ping = slider('Zenith ping radius', 'pingRadius', 1, 10, 0.5, v => v.toFixed(1) + '°');
  const gong = toggle('Gong for a crewed station', 'gongOn');
  const awake = toggle('Keep the screen awake while playing', 'keepAwake');

  const coneCtl = SPECS.map((spec, t) => {
    const out = el('output');
    const inp = el('input', { type: 'range', min: 2, max: 90, step: 1, 'aria-label': spec.sound + ' cone' });
    const auto = el('input', { type: 'checkbox', 'aria-label': spec.sound + ' cone auto' });
    const sync = () => { const tr = model.tracks[t]; auto.checked = tr.auto; inp.disabled = tr.auto; out.textContent = (tr.auto ? 'auto ' : '') + Math.round(tr.cone) + '°'; };
    auto.addEventListener('change', () => { model.setCone(auto.checked ? null : Math.max(2, Math.round(model.tracks[t].cone)), t); inp.value = model.tracks[t].cone; sync(); });
    inp.addEventListener('input', () => { model.setCone(parseFloat(inp.value), t); sync(); });
    return { node: el('label', { class: 'ctl' }, el('span', { style: 'color:' + spec.color, text: spec.sound + ' cone' }), auto, inp, out), sync, inp };
  });

  settingsEl.append(
    sect('Place and data', placeSel.node, locBtn, live.node),
    sect('Key and tempo', root.node, scale.node, tempoSrc.node, bpm.node, sweepLen.node),
    sect('Feel', swing.node, quant.node, dub.node, space.node, dust.node),
    sect('Events', ping.node, gong.node),
    sect('Cones (how much sky each drum listens to)', ...coneCtl.map(c => c.node)),
    sect('Screen', awake.node));
  const refreshAll = () => {
    [placeSel, live, root, scale, tempoSrc, bpm, sweepLen, swing, quant, dub, space, dust, ping, gong, awake].forEach(c => c.refresh());
  };

  noteEl.append(
    el('h2', { text: 'What is this?' }),
    el('p', { text: 'Orbitakt reads where thousands of real satellites are right now, computed in your browser from their published orbits (SGP4, CelesTrak data), and turns the ones overhead into a rhythm.' }),
    el('p', { text: 'A beam sweeps around the sky like a radar. Each drum listens to one family of satellites inside a cone around straight-up: navigation satellites play the kick, low-orbit ones the rimshot, the Starlink swarm the hats, and the geostationary belt a gated hat. A satellite sounds when the beam crosses its bearing; the higher it is, the louder. Anything passing nearly straight overhead rings a glass bar; a crewed station adds a gong.' }),
    el('p', { text: 'The tempo is the overhead orbits’ own period raised thirteen octaves, so the music slowly drifts with the sky. Without orbital data the page falls back to a simulated sky of the same real shells. Your location, if you share it, is rounded to about a kilometre, stays on your device, and is used only for the sky maths.' }),
    el('p', { class: 'small', text: 'Sound by OrbitDSP, a small synthesizer written for this page. Orbital data: CelesTrak.' }));

  // ---------- Buttons and state ----------
  let wake = null;
  async function wantWake() {
    try {
      if (model.isPlaying && model.s.keepAwake && 'wakeLock' in navigator && !wake) {
        wake = await navigator.wakeLock.request('screen');
        wake.addEventListener('release', () => { wake = null; });
      } else if ((!model.isPlaying || !model.s.keepAwake) && wake) { await wake.release(); wake = null; }
    } catch (e) { wake = null; }
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) wantWake(); });

  playBtn.addEventListener('click', () => {
    const starting = !model.isPlaying;
    model.togglePlay();                                   // first: audio must start inside the tap
    if (starting && !model.s.askedLocation && model.s.place !== 'device') model.useMyLocation().then(refreshAll);
  });
  engine.onstate = st => { if (st === 'interrupted' || st === 'suspended') { if (engine.wantsRunning && !document.hidden) engine.ctx.resume().catch(() => {}); } };

  function renderText() {
    playBtn.textContent = model.isPlaying ? 'Stop' : 'Play';
    playBtn.setAttribute('aria-pressed', model.isPlaying ? 'true' : 'false');
    statusEl.textContent = model.status;
    crewEl.textContent = model.crewNote || '';
    crewEl.style.display = model.crewNote ? '' : 'none';
    const sn = model.snapshot;
    readEl.replaceChildren(
      reading(Math.round(model.effectiveBPM), 'BPM'),
      reading(sn.blips.length.toLocaleString('en-US'), 'above the horizon'),
      reading(sn.catalogSize.toLocaleString('en-US'), model.live ? 'tracked' : 'simulated'),
      el('div', { class: 'datanote', text: model.dataNote }));
    model.tracks.forEach((tr, t) => {
      rowRefs[t].info.textContent = tr.inCone + ' in ' + Math.round(tr.cone) + '°' + (tr.auto ? '' : ' (set)');
      rowRefs[t].mute.classList.toggle('on', tr.muted);
      rowRefs[t].mute.setAttribute('aria-pressed', tr.muted ? 'true' : 'false');
    });
    coneCtl.forEach((c, t) => { if (document.activeElement !== c.inp) c.inp.value = model.tracks[t].cone; c.sync(); });
    wantWake();
  }
  const reading = (v, l) => el('div', { class: 'reading' }, el('b', { text: String(v) }), el('span', { text: l }));
  let textDirty = true;
  model.onChange = () => { textDirty = true; };

  // ---------- Drawing ----------
  const reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  function fit(c, h) {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const w = Math.max(1, c.clientWidth), hh = h || Math.max(1, c.clientHeight);
    if (c.width !== Math.round(w * dpr) || c.height !== Math.round(hh * dpr)) { c.width = Math.round(w * dpr); c.height = Math.round(hh * dpr); }
    const g = c.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    return { g, w, h: hh };
  }
  const css = getComputedStyle(document.documentElement);
  const INK = css.getPropertyValue('--ink').trim() || '#cfd6e6';

  function drawDome() {
    const { g, w, h } = fit(domeCanvas);
    const R = Math.min(w, h) / 2 - 22, cx = w / 2, cy = h / 2;
    g.clearRect(0, 0, w, h);
    const sn = model.snapshot;
    const bm = engine.beam();
    const sweep = bm.sweep;
    const pt = (az, zen) => [cx + R * (zen / 90) * Math.sin(az * Math.PI / 180), cy - R * (zen / 90) * Math.cos(az * Math.PI / 180)];

    // Sky disc and rings
    const grad = g.createRadialGradient(cx, cy, 0, cx, cy, R);
    grad.addColorStop(0, 'rgba(40,60,110,.35)'); grad.addColorStop(1, 'rgba(10,14,26,.15)');
    g.fillStyle = grad; g.beginPath(); g.arc(cx, cy, R, 0, 7); g.fill();
    g.strokeStyle = 'rgba(160,180,220,.22)'; g.lineWidth = 1;
    for (const e of [0, 30, 60]) { g.beginPath(); g.arc(cx, cy, R * (1 - e / 90), 0, 7); g.stroke(); }
    g.beginPath(); g.moveTo(cx - R, cy); g.lineTo(cx + R, cy); g.moveTo(cx, cy - R); g.lineTo(cx, cy + R); g.stroke();
    g.fillStyle = 'rgba(190,205,235,.7)'; g.font = '600 12px system-ui, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText('N', cx, cy - R - 11); g.fillText('S', cx, cy + R + 11); g.fillText('E', cx + R + 11, cy); g.fillText('W', cx - R - 11, cy);

    // Cones
    g.setLineDash([3, 4]);
    SPECS.forEach((spec, t) => {
      g.strokeStyle = spec.color + '88';
      g.beginPath(); g.arc(cx, cy, R * (model.tracks[t].cone / 90), 0, 7); g.stroke();
    });
    g.setLineDash([]);

    // The beam: a faint wedge trailing behind the line
    const a = sweep * 2 * Math.PI - Math.PI / 2;
    const wedge = g.createConicGradient ? g.createConicGradient(a - 0.9, cx, cy) : null;
    if (wedge) {
      wedge.addColorStop(0, 'rgba(160,200,255,0)'); wedge.addColorStop(0.14, 'rgba(160,200,255,.18)'); wedge.addColorStop(0.1432, 'rgba(160,200,255,0)'); wedge.addColorStop(1, 'rgba(160,200,255,0)');
      g.fillStyle = wedge; g.beginPath(); g.arc(cx, cy, R, 0, 7); g.fill();
    }
    g.strokeStyle = 'rgba(190,220,255,.85)'; g.lineWidth = 1.5;
    g.beginPath(); g.moveTo(cx, cy); g.lineTo(cx + R * Math.cos(a), cy + R * Math.sin(a)); g.stroke();

    // Every satellite above the horizon, small and dim
    const inCone = new Map();
    model.tracks.forEach((tr, t) => tr.hits.forEach(h => inCone.set(h.id, t)));
    for (const b of sn.blips) {
      if (inCone.has(b.id) && b.fam === SPECS[inCone.get(b.id)].fam) continue;
      const [x, y] = pt(b.az, b.zenith);
      g.fillStyle = FAM_COLOR[b.fam] + '55';
      g.fillRect(x - 1, y - 1, 2, 2);
    }
    // The ones playing, bright, flaring as the beam passes
    for (const b of sn.blips) {
      const t = inCone.get(b.id);
      if (t == null || b.fam !== SPECS[t].fam) continue;
      const [x, y] = pt(b.az, b.zenith);
      let d = sweep - b.az / 360; d -= Math.floor(d);                   // how far past the satellite the beam is
      const flare = model.isPlaying ? Math.exp(-d * 14) : 0;
      const col = SPECS[t].color;
      if (flare > 0.02) { g.fillStyle = col + Math.round(flare * 90).toString(16).padStart(2, '0'); g.beginPath(); g.arc(x, y, 4 + 12 * flare, 0, 7); g.fill(); }
      g.fillStyle = col; g.beginPath(); g.arc(x, y, 2.4 + 1.6 * flare, 0, 7); g.fill();
    }
    // Crewed station
    for (const b of sn.blips) if (b.fam === FAM.CREW && b.el > 0) {
      const [x, y] = pt(b.az, b.zenith);
      g.strokeStyle = CREW_COLOR; g.lineWidth = 1.5; g.beginPath(); g.arc(x, y, 5, 0, 7); g.stroke();
    }
    // Zenith pings
    const now = performance.now() / 1000;
    for (const p of model.pings) {
      const age = now - p.t; if (age > 2.5) continue;
      const [x, y] = pt(p.az, 90 - p.el);
      g.strokeStyle = 'rgba(255,255,255,' + (0.8 * (1 - age / 2.5)).toFixed(2) + ')'; g.lineWidth = 1.5;
      g.beginPath(); g.arc(x, y, 4 + age * 14, 0, 7); g.stroke();
    }
    // Zenith mark
    g.fillStyle = 'rgba(255,255,255,.5)'; g.fillRect(cx - 1, cy - 1, 2, 2);
  }

  function drawRows() {
    const sweep = engine.beam().sweep;
    SPECS.forEach((spec, t) => {
      const { g, w, h } = fit(rowRefs[t].canvas, 30);
      g.clearRect(0, 0, w, h);
      g.fillStyle = 'rgba(160,180,220,.07)'; g.fillRect(0, 0, w, h);
      g.fillStyle = 'rgba(160,180,220,.18)';
      for (let i = 0; i < 16; i++) g.fillRect(Math.round(i * w / 16), i % 4 === 0 ? 0 : h - 5, 1, i % 4 === 0 ? h : 5);
      const muted = model.tracks[t].muted;
      for (const hit of model.tracks[t].hits) {
        const ph = model.firePhase(hit.phase);
        let d = sweep - ph; d -= Math.floor(d);
        const flare = model.isPlaying && !muted ? Math.exp(-d * 10) : 0;
        const x = ph * w, bh = 5 + hit.vel * (h - 10);
        g.fillStyle = spec.color + (muted ? '33' : (flare > 0.05 ? 'ff' : '99'));
        g.fillRect(x - 1.5, h - bh - 1, 3, bh);
        if (flare > 0.05) { g.fillStyle = spec.color + Math.round(flare * 70).toString(16).padStart(2, '0'); g.fillRect(x - 6, 0, 12, h); }
      }
      g.fillStyle = 'rgba(200,225,255,.9)'; g.fillRect(sweep * w - 1, 0, 2, h);
    });
  }

  let lastText = 0;
  function frame(ts) {
    if (!document.hidden) {
      if (textDirty && ts - lastText > 200) { lastText = ts; textDirty = false; renderText(); }
      drawDome(); drawRows();
    }
    requestAnimationFrame(frame);
  }
  refreshAll();
  renderText();
  requestAnimationFrame(frame);
})();
