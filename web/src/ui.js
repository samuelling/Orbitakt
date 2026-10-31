'use strict';
/* The page: dome, track rows, readings, settings sheet. Everything here is presentation; the
 * model decides, the engine sounds. The look follows the iPhone app: night-sky gradient, glowing
 * dots, glass panels, monospaced readouts and an inset-grouped settings sheet. */

(function () {
  const $ = (sel, root) => (root || document).querySelector(sel);
  const SVGNS = 'http://www.w3.org/2000/svg';
  const el = (tag, props, ...kids) => {
    const n = document.createElement(tag);
    if (props) for (const k of Object.keys(props)) {
      if (k === 'class') n.className = props[k];
      else if (k === 'text') n.textContent = props[k];
      else if (k === 'html') n.innerHTML = props[k];
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), props[k]);
      else n.setAttribute(k, props[k]);
    }
    for (const c of kids) if (c != null) n.append(c);
    return n;
  };
  const icon = paths => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + paths + '</svg>';
  const ICON_SLIDERS = icon('<path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>');
  const ICON_WAVES = icon('<circle cx="7" cy="17" r="1.6" fill="currentColor" stroke="none"/><path d="M7 11.5a5.5 5.5 0 0 1 5.5 5.5M7 6a11 11 0 0 1 11 11"/>');
  const ICON_STOP = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="2.5" fill="currentColor"/></svg>';
  const ICON_CREW = icon('<circle cx="9" cy="8" r="3"/><path d="M3.5 19a5.5 5.5 0 0 1 11 0"/><circle cx="17" cy="9" r="2.3"/><path d="M15.5 14.2A4.5 4.5 0 0 1 21 18.5"/>');

  const hexA = (hex, a) => {
    const n = parseInt(hex.slice(1), 16);
    return 'rgba(' + (n >> 16) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + a.toFixed(3) + ')';
  };

  const engine = new OrbitEngine(document.getElementById('worklet-src').textContent);
  const model = new RhythmModel(engine);
  window.orbitakt = { model, engine };

  // ---------- Static structure ----------
  const app = $('#app');
  const domeCanvas = el('canvas', { id: 'dome', 'aria-label': 'Sky dome: satellites overhead, with the sweeping beam' });
  const playBtn = el('button', { id: 'play', class: 'play', type: 'button' });
  const statusEl = el('div', { class: 'status', role: 'status' });
  const crewEl = el('div', { class: 'badge', html: ICON_CREW + '<span></span>' });
  const gearBtn = el('button', { type: 'button', class: 'iconbtn', 'aria-label': 'Settings', 'aria-haspopup': 'dialog', html: ICON_SLIDERS });
  const rowsEl = el('div', { class: 'rows' });
  const readEl = el('div', { class: 'readings' });
  const dataNoteEl = el('div', { class: 'datanote' });

  app.append(
    el('header', { class: 'top' },
      el('div', { class: 'tile', 'aria-hidden': 'true', html: '<small>121</small>Ot' }),
      el('div', { class: 'titles' }, el('h1', { text: 'ORBITAKT' }), statusEl, crewEl),
      gearBtn),
    el('main', { class: 'stage' },
      el('div', { class: 'domewrap' }, domeCanvas),
      el('div', { class: 'side' },
        readEl,
        el('div', { class: 'panel' }, rowsEl),
        playBtn,
        dataNoteEl,
        aboutSection())));

  // Readings: five monospaced figures, like the app
  const readRefs = ['overhead', 'starlink', 'nav', 'geo', 'bpm'].map(label => {
    const b = el('b', { text: '–' });
    readEl.append(el('div', { class: 'reading' }, b, el('span', { text: label })));
    return b;
  });

  // Track rows: tap the label to mute, as on the phone
  const rowRefs = SPECS.map((spec, t) => {
    const canvas = el('canvas', { class: 'rowcanvas', 'aria-hidden': 'true' });
    const name = el('b', { style: 'color:' + spec.color, text: FAM_LABEL[spec.fam] });
    const info = el('span');
    const label = el('button', { type: 'button', class: 'rlabel', onclick: () => model.setMuted(!model.tracks[t].muted, t) }, name, info);
    rowsEl.append(el('div', { class: 'row' }, label, canvas));
    return { canvas, info, label };
  });

  function aboutSection() {
    return el('section', { class: 'about' },
      el('h2', { text: 'A drum machine played by the satellites above you.' }),
      el('div', { class: 'legend' },
        el('span', { style: 'color:var(--nav)', text: 'navigation · kick' }),
        el('span', { style: 'color:var(--leo)', text: 'low orbit · rim' }),
        el('span', { style: 'color:var(--swarm)', text: 'Starlink · hat' }),
        el('span', { style: 'color:var(--belt)', text: 'geostationary · gated hat' }),
        el('span', { style: 'color:var(--crew)', text: 'crewed station · gong' })),
      el('p', { text: 'Orbitakt reads where thousands of real satellites are right now, computed in your browser from their published orbits (SGP4, CelesTrak data), and turns the ones overhead into a rhythm.' }),
      el('p', { text: 'A beam sweeps around the sky like a radar. Each drum listens to one family of satellites inside a cone around straight-up, and a satellite sounds when the beam crosses its bearing; the higher it is, the louder. Anything passing nearly straight overhead rings a glass bar.' }),
      el('p', { text: 'The tempo is the overhead orbits’ own period raised thirteen octaves, so the music slowly drifts with the sky. Without orbital data the page falls back to a simulated sky of the same real shells. Your location, if you share it, is rounded to about a kilometre, stays on your device, and is used only for the sky maths.' }),
      el('p', { class: 'small', text: 'Sound by OrbitDSP, a small synthesizer written for this page. Orbital data: CelesTrak. Also an iPhone app.' }));
  }

  // ---------- Settings sheet (inset-grouped, like the app's Form) ----------
  const refreshers = [];
  const reg = (node, refresh) => { if (refresh) { refreshers.push(refresh); refresh(); } return node; };

  const group = (title, cells, foot, color) => el('section', { class: 'group' },
    el('h3', color ? { style: 'color:' + color, text: title } : { text: title }),
    el('div', { class: 'cells' }, ...cells),
    foot ? el('p', { class: 'foot', text: foot }) : null);

  const cellSwitch = (label, get, set) => {
    const cb = el('input', { type: 'checkbox', class: 'switch', role: 'switch', 'aria-label': label });
    cb.addEventListener('change', () => set(cb.checked));
    return reg(el('label', { class: 'cell' }, el('span', { class: 'lbl', text: label }), cb), () => { cb.checked = !!get(); });
  };
  const paint = inp => {
    const p = (parseFloat(inp.value) - parseFloat(inp.min)) / (parseFloat(inp.max) - parseFloat(inp.min));
    inp.style.setProperty('--p', (p * 100).toFixed(1) + '%');
  };
  const cellSlider = (text, min, max, step, get, set, opts) => {
    opts = opts || {};
    const head = el('span', { class: 'lbl' });
    const inp = el('input', { type: 'range', class: 'range', min, max, step, 'aria-label': opts.aria || '' });
    inp.addEventListener('input', () => { set(parseFloat(inp.value)); paint(inp); upd(); });
    const top = opts.ends ? el('div', { class: 'ends' }, el('span', { text: opts.ends[0] }), head, el('span', { text: opts.ends[1] })) : head;
    const node = el('div', { class: 'cell stack' }, top, inp);
    const upd = () => {
      head.textContent = text();
      if (!opts.aria) inp.setAttribute('aria-label', text());
      const dis = opts.disabled ? opts.disabled() : false;
      inp.disabled = dis; node.classList.toggle('muted', dis);
      if (opts.hidden) node.hidden = opts.hidden();
    };
    return reg(node, () => { if (document.activeElement !== inp) inp.value = get(); paint(inp); upd(); });
  };
  const cellPick = (label, options, get, set) => {
    const sel = el('select', { class: 'pick', 'aria-label': label });
    const fill = () => {
      const opts = typeof options === 'function' ? options() : options;
      if (sel.options.length !== opts.length) sel.replaceChildren(...opts.map(([v, txt]) => el('option', { value: String(v), text: txt })));
    };
    sel.addEventListener('change', () => set(sel.value));
    return reg(el('label', { class: 'cell' }, el('span', { class: 'lbl', text: label }), sel), () => { fill(); sel.value = String(get()); });
  };
  const cellSeg = (label, options, get, set) => {
    const seg = el('div', { class: 'seg', role: 'radiogroup', 'aria-label': label });
    const btns = options.map(([v, txt]) => {
      const b = el('button', { type: 'button', role: 'radio', text: txt, onclick: () => { set(v); refresh(); } });
      seg.append(b);
      return [v, b];
    });
    const refresh = () => btns.forEach(([v, b]) => b.setAttribute('aria-checked', String(get()) === String(v) ? 'true' : 'false'));
    return reg(el('div', { class: 'cell' }, seg), refresh);
  };
  const cellText = (text, hidden) => {
    const n = el('div', { class: 'cell muted' }, el('span', { class: 'lbl' }));
    return reg(n, () => { n.firstChild.textContent = text(); if (hidden) n.hidden = hidden(); });
  };

  const S = k => () => model.s[k];
  const set = (k, conv) => v => model.setSetting(k, conv ? conv(v) : v);
  const pct = v => Math.round(v * 100) + '%';

  const locBtn = el('button', { type: 'button', class: 'linkbtn', text: 'Use my location' });
  locBtn.addEventListener('click', async () => {
    locBtn.disabled = true; locBtn.textContent = 'Locating…';
    const ok = await model.useMyLocation();
    locBtn.disabled = false; locBtn.textContent = ok ? 'Using your location' : 'Location unavailable';
    refreshAll();
  });
  const placeOptions = () => (model.s.deviceLat != null ? [['device', 'My location']] : []).concat(PLACES.map(p => [p.key, p.name]));

  const TRACK_FOOT = [
    'GPS, Galileo, GLONASS and BeiDou, 20,000 km up. The cone holds about four on average; each kicks as the beam passes its bearing. They cross the sky in hours, so the kick pattern shifts slowly. A deep kick on the root.',
    'Low orbits other than Starlink: OneWeb, Iridium, weather and science satellites. About two in the cone; each crosses the sky in roughly ten minutes, so you hear its hit slide through the sweep. A tuned rimshot, mostly into the echo, and each new arrival throws the echo open.',
    'Starlink. Thousands of them, so the cone is narrow and hats drift, flam and merge as satellites cross. Metallic hats that brighten as more of the swarm is up; higher ones play louder.',
    'The geostationary belt: a fixed arc across your sky, to the south in the northern hemisphere. It never moves, so these hits stay put: your location’s fingerprint. A hi-hat into a gated reverb, its metal tuned by position, darker in the east, brighter toward the west.',
  ];
  const trackGroups = SPECS.map((spec, t) => group(FAM_LABEL[spec.fam] + ' · ' + spec.sound, [
    cellSwitch('Adaptive cone', () => model.tracks[t].auto,
      on => model.setCone(on ? null : Math.max(2, Math.round(model.tracks[t].cone)), t)),
    cellSlider(() => 'Cone: ' + Math.round(model.tracks[t].cone) + '° from the zenith · ' + model.tracks[t].inCone + ' inside',
      2, 90, 1, () => model.tracks[t].cone, v => model.setCone(v, t), { disabled: () => model.tracks[t].auto }),
    cellSwitch('Mute', () => model.tracks[t].muted, m => model.setMuted(m, t)),
  ], TRACK_FOOT[t], spec.color));

  const sheetBody = el('div', { class: 'sheetbody' },
    group('Sky', [
      cellSeg('Sky', [[true, 'Live'], [false, 'Simulated']], S('useLive'), v => model.setSetting('useLive', v)),
      cellPick('Place', placeOptions, S('place'), set('place')),
      el('div', { class: 'cell' }, locBtn),
    ], 'Orbital elements from CelesTrak (celestrak.org), positioned in your browser with SGP4. Simulated uses the real constellations’ shells and densities with invented positions.'),
    ...trackGroups,
    group('Events', [
      cellSlider(() => 'Zenith pings within ' + model.s.pingRadius.toFixed(model.s.pingRadius % 1 ? 1 : 0) + '° of straight up', 1, 10, 0.5, S('pingRadius'), set('pingRadius')),
      cellSwitch('Gong while a crewed station is up', S('gongOn'), set('gongOn')),
    ], 'Anything that passes almost directly overhead rings a glass bar, pitched by its catalog number. While the ISS or Tiangong is above the horizon, a gong sounds every four bars.'),
    group('Music', [
      cellPick('Scale', SCALES.map((s, i) => [i, s.name]), S('scaleIndex'), set('scaleIndex', Number)),
      cellPick('Root', PITCH_NAMES.map((n, i) => [i, n]), S('rootPC'), set('rootPC', Number)),
      cellSeg('Tempo', [['orbit', 'Orbit'], ['manual', 'Manual']], S('tempoSource'), v => { model.setSetting('tempoSource', v); refreshAll(); }),
      cellSlider(() => Math.round(model.s.manualBPM) + ' BPM', 60, 132, 1, S('manualBPM'), set('manualBPM'), { hidden: () => model.s.tempoSource !== 'manual' }),
      cellText(() => 'Orbit tempo: ' + model.orbitBPM.toFixed(1) + ' BPM', () => model.s.tempoSource === 'manual'),
      cellSeg('Sweep', [[2, 'Every 2 bars'], [4, 'Every bar']], S('division'), v => model.setSetting('division', Number(v))),
      cellSlider(() => 'Quantize ' + pct(model.s.quantize), 0, 1, 0.01, S('quantize'), set('quantize'), { ends: ['Literal', 'Grid'], aria: 'Quantize' }),
      cellSlider(() => 'Swing: ' + pct(model.s.swing), 0, 0.4, 0.01, S('swing'), set('swing')),
    ], 'Orbit tempo is the period of the low orbits overhead, thirteen octaves up: a 95-minute orbit × 2¹³ ≈ 86 BPM. The beam goes round your sky once per sweep, starting at north, and every satellite in a cone plays as the beam passes it. Literal plays each one exactly at its bearing; Grid snaps them to 16 slots per sweep. Swing applies to the grid.'),
    group('Dub', [
      cellSlider(() => 'Dub echo feedback: ' + pct(model.s.dub), 0, 0.85, 0.01, S('dub'), set('dub')),
      cellSlider(() => 'Plate: ' + pct(model.s.space), 0, 1, 0.01, S('space'), set('space')),
      cellSwitch('Dust', S('dustOn'), set('dustOn')),
    ], 'A ping-pong echo on a dotted eighth, darker and rounder with every repeat. Whenever a low-orbit satellite crosses into its cone, or something passes straight overhead, the echo send is thrown open for a few seconds. Dust is a breath of hiss and crackle that thickens with the crowd overhead.'),
    group('Screen', [
      cellSwitch('Keep the screen awake while playing', S('keepAwake'), set('keepAwake')),
    ]));

  const doneBtn = el('button', { type: 'button', class: 'done', text: 'Done' });
  const sheet = el('div', { class: 'sheet', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': 'sheet-title', inert: '' },
    el('div', { class: 'grabber', 'aria-hidden': 'true' }),
    el('div', { class: 'sheetbar' }, el('h2', { id: 'sheet-title', text: 'Settings' }), doneBtn),
    sheetBody);
  const scrim = el('div', { class: 'scrim', 'aria-hidden': 'true', style: 'pointer-events:none' });
  document.body.append(scrim, sheet);

  let sheetOpen = false;
  function openSheet(open) {
    sheetOpen = open;
    document.body.classList.toggle('sheet-open', open);
    document.body.classList.toggle('locked', open);
    scrim.style.pointerEvents = open ? 'auto' : 'none';
    if (open) { sheet.removeAttribute('inert'); app.setAttribute('inert', ''); refreshAll(); setTimeout(() => doneBtn.focus({ preventScroll: true }), 50); }
    else { sheet.setAttribute('inert', ''); app.removeAttribute('inert'); gearBtn.focus({ preventScroll: true }); }
  }
  gearBtn.addEventListener('click', () => openSheet(true));
  doneBtn.addEventListener('click', () => openSheet(false));
  scrim.addEventListener('click', () => openSheet(false));
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && sheetOpen) openSheet(false); });

  const refreshAll = () => refreshers.forEach(f => f());

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

  let shownPlaying = null;
  function renderText() {
    if (shownPlaying !== model.isPlaying) {
      shownPlaying = model.isPlaying;
      playBtn.innerHTML = (model.isPlaying ? ICON_STOP : ICON_WAVES) + '<span>' + (model.isPlaying ? 'Stop' : 'Play the sky') + '</span>';
      playBtn.setAttribute('aria-pressed', model.isPlaying ? 'true' : 'false');
    }
    statusEl.textContent = model.status;
    crewEl.lastChild.textContent = model.crewNote || '';
    crewEl.hidden = !model.crewNote;
    const sn = model.snapshot, c = sn.counts;
    const vals = [sn.blips.length, c[FAM.SWARM], c[FAM.NAV], c[FAM.BELT]].map(v => v.toLocaleString('en-US'));
    vals.push(model.effectiveBPM.toFixed(1));
    vals.forEach((v, i) => { if (readRefs[i].textContent !== v) readRefs[i].textContent = v; });
    dataNoteEl.textContent = model.dataNote;
    model.tracks.forEach((tr, t) => {
      rowRefs[t].info.textContent = tr.hits.length + ' ' + SPECS[t].sound;
      rowRefs[t].label.setAttribute('aria-pressed', tr.muted ? 'true' : 'false');
      rowRefs[t].label.setAttribute('aria-label', FAM_LABEL[SPECS[t].fam] + ' ' + SPECS[t].sound + ', ' + tr.hits.length + ' satellites' + (tr.muted ? ', muted' : '') + '. Tap to ' + (tr.muted ? 'unmute' : 'mute'));
    });
    if (sheetOpen) refreshAll();
    wantWake();
  }
  let textDirty = true;
  model.onChange = () => { textDirty = true; };

  // ---------- Drawing ----------
  function fit(c) {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const w = Math.max(1, c.clientWidth), h = Math.max(1, c.clientHeight);
    if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) { c.width = Math.round(w * dpr); c.height = Math.round(h * dpr); }
    const g = c.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    return { g, w, h };
  }
  const dot = (g, x, y, r) => { g.beginPath(); g.arc(x, y, r, 0, 6.2832); };
  const glow = (g, x, y, r, col, a) => {
    const gr = g.createRadialGradient(x, y, 0, x, y, r);
    gr.addColorStop(0, hexA(col, a)); gr.addColorStop(1, hexA(col, 0));
    g.fillStyle = gr; dot(g, x, y, r); g.fill();
  };

  // A still starfield behind everything, drawn once per resize
  const starCanvas = $('#stars');
  function drawStars() {
    const { g, w, h } = fit(starCanvas);
    g.clearRect(0, 0, w, h);
    let seed = 121;
    const rnd = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647; };
    const n = Math.round(w * h / 2600);
    for (let i = 0; i < n; i++) {
      const x = rnd() * w, y = rnd() * h, a = 0.08 + 0.5 * rnd() * rnd(), r = 0.35 + rnd() * 0.75;
      g.fillStyle = rnd() < 0.25 ? 'rgba(190,210,255,' + a + ')' : 'rgba(255,255,255,' + a + ')';
      dot(g, x, y, r); g.fill();
    }
  }
  drawStars();
  window.addEventListener('resize', drawStars);

  function drawDome() {
    const { g, w, h } = fit(domeCanvas);
    const k = Math.max(1, Math.min(w, h) / 360);          // phone-sized dome = 1
    const R = Math.min(w, h) / 2 - 16 * k, cx = w / 2, cy = h / 2;
    g.clearRect(0, 0, w, h);
    const sn = model.snapshot;
    const playing = model.isPlaying;
    const sweep = engine.beam().sweep;
    const pt = (az, zen) => {
      const r = R * Math.min(90, Math.max(0, zen)) / 90, a = az * Math.PI / 180;
      return [cx + r * Math.sin(a), cy - r * Math.cos(a)];
    };

    // The sky disc: deep blue at the zenith to near-black at the horizon
    const disc = g.createRadialGradient(cx, cy, 0, cx, cy, R);
    disc.addColorStop(0, 'rgb(13,18,41)'); disc.addColorStop(0.75, 'rgb(6,7,20)'); disc.addColorStop(1, 'rgb(3,3,10)');
    g.fillStyle = disc; dot(g, cx, cy, R); g.fill();
    // Glass rim: brighter at the top, like light catching the edge
    const rim = g.createLinearGradient(0, cy - R, 0, cy + R);
    rim.addColorStop(0, 'rgba(255,255,255,.30)'); rim.addColorStop(0.5, 'rgba(255,255,255,.12)'); rim.addColorStop(1, 'rgba(255,255,255,.20)');
    g.strokeStyle = rim; g.lineWidth = 1; dot(g, cx, cy, R); g.stroke();
    // A dub throw lights the horizon in the rimshot's colour while the echo spirals
    if (model.throwLevel > 0.02) {
      const th = model.throwLevel;
      g.strokeStyle = hexA(SPECS[1].color, 0.55 * th); g.lineWidth = 1 + 3 * th;
      dot(g, cx, cy, R); g.stroke();
    }
    g.strokeStyle = 'rgba(255,255,255,.06)'; g.lineWidth = 1;
    for (const z of [30, 60]) { dot(g, cx, cy, R * z / 90); g.stroke(); }
    g.fillStyle = 'rgba(255,255,255,.45)';
    g.font = '500 ' + Math.round(9 * Math.min(k, 1.35)) + 'px ui-monospace, "SF Mono", Menlo, monospace';
    g.textAlign = 'center'; g.textBaseline = 'middle';
    const lr = R + 8 * k;
    g.fillText('N', cx, cy - lr); g.fillText('S', cx, cy + lr); g.fillText('E', cx + lr, cy); g.fillText('W', cx - lr, cy);

    // Cones: one ring per track, solid when adaptive, dashed when set by hand
    SPECS.forEach((spec, t) => {
      const tr = model.tracks[t];
      g.setLineDash(tr.auto ? [] : [3, 3]);
      g.strokeStyle = hexA(spec.color, tr.muted ? 0.12 : 0.35); g.lineWidth = 1;
      dot(g, cx, cy, R * Math.min(90, tr.cone) / 90); g.stroke();
    });
    g.setLineDash([]);

    // The beam: the playhead itself, from north, clockwise, with a soft trailing wedge
    const a = sweep * 2 * Math.PI - Math.PI / 2;
    if (playing) {
      if (g.createConicGradient) {
        const wedge = g.createConicGradient(a - 0.9, cx, cy);
        wedge.addColorStop(0, 'rgba(170,200,255,0)'); wedge.addColorStop(0.143, 'rgba(170,200,255,.09)'); wedge.addColorStop(0.1433, 'rgba(170,200,255,0)'); wedge.addColorStop(1, 'rgba(170,200,255,0)');
        g.fillStyle = wedge; dot(g, cx, cy, R); g.fill();
      }
      const beam = g.createLinearGradient(cx, cy, cx + R * Math.cos(a), cy + R * Math.sin(a));
      beam.addColorStop(0, 'rgba(255,255,255,.05)'); beam.addColorStop(1, 'rgba(255,255,255,.45)');
      g.strokeStyle = beam; g.lineWidth = 1;
      g.beginPath(); g.moveTo(cx, cy); g.lineTo(cx + R * Math.cos(a), cy + R * Math.sin(a)); g.stroke();
    }

    // Which satellites are playing
    const inCone = new Map();
    model.tracks.forEach((tr, t) => tr.hits.forEach(hh => inCone.set(hh.id, t)));
    // Everything else above the horizon: small and dim in its family's colour
    for (const b of sn.blips) {
      const t = inCone.get(b.id);
      if (t != null && b.fam === SPECS[t].fam) continue;
      if (b.fam === FAM.CREW) continue;
      const [x, y] = pt(b.az, b.zenith);
      if (b.fam === FAM.OTHER) { g.fillStyle = 'rgba(255,255,255,.22)'; dot(g, x, y, 0.8 * k); g.fill(); continue; }
      g.fillStyle = hexA(FAM_COLOR[b.fam], 0.4);
      dot(g, x, y, (b.fam === FAM.SWARM ? 1.1 : 1.6) * k); g.fill();
    }
    // The lit ones glow, and flash as the beam passes
    g.globalCompositeOperation = 'lighter';
    for (const b of sn.blips) {
      const t = inCone.get(b.id);
      if (t == null || b.fam !== SPECS[t].fam) continue;
      const [x, y] = pt(b.az, b.zenith);
      const col = SPECS[t].color;
      let flash = 0;
      if (playing && !model.tracks[t].muted) {
        let d = sweep - model.firePhase(b.az / 360); d -= Math.floor(d);
        if (d < 0.05) flash = 1 - d / 0.05;
      }
      const r = (b.fam === FAM.SWARM ? 1.1 : 1.6) * k;
      glow(g, x, y, r * (3 + 4 * flash) + 2 * k, col, 0.5 + 0.4 * flash);
      g.fillStyle = col; dot(g, x, y, r + 0.6 * k + 1.6 * k * flash); g.fill();
    }
    // Crewed station: a golden glow
    for (const b of sn.blips) if (b.fam === FAM.CREW && b.el > 0) {
      const [x, y] = pt(b.az, b.zenith);
      glow(g, x, y, 9 * k, CREW_COLOR, 0.6);
      g.fillStyle = CREW_COLOR; dot(g, x, y, 3.2 * k); g.fill();
    }
    g.globalCompositeOperation = 'source-over';

    // Zenith pings: a ring spreading from where it passed overhead
    const now = performance.now() / 1000;
    for (const p of model.pings) {
      const age = now - p.t; if (age < 0 || age > 6) continue;
      const [x, y] = pt(p.az, 90 - p.el);
      g.strokeStyle = 'rgba(255,255,255,' + (0.6 * (1 - age / 6)).toFixed(3) + ')'; g.lineWidth = 1.2;
      dot(g, x, y, (4 + age * 18) * k); g.stroke();
    }
    g.strokeStyle = 'rgba(255,255,255,.25)'; g.lineWidth = 0.8;
    dot(g, cx, cy, Math.max(2, R * model.s.pingRadius / 90)); g.stroke();
    g.fillStyle = 'rgba(255,255,255,.7)'; dot(g, cx, cy, 1.6); g.fill();
  }

  // Each track's radar line: dots where its satellites play in the sweep, sized by height
  function drawRows() {
    const sweep = engine.beam().sweep, playing = model.isPlaying;
    SPECS.forEach((spec, t) => {
      const { g, w, h } = fit(rowRefs[t].canvas);
      const y = h / 2, pad = 7, W = w - 2 * pad;
      g.clearRect(0, 0, w, h);
      for (let s = 0; s <= GRID_SLOTS; s++) {
        const x = Math.round(pad + W * s / GRID_SLOTS) + 0.5, beat = s % 4 === 0, th = beat ? 7 : 3;
        g.strokeStyle = beat ? 'rgba(255,255,255,.18)' : 'rgba(255,255,255,.08)'; g.lineWidth = 1;
        g.beginPath(); g.moveTo(x, y - th); g.lineTo(x, y + th); g.stroke();
      }
      g.strokeStyle = 'rgba(255,255,255,.08)';
      g.beginPath(); g.moveTo(pad, y + 0.5); g.lineTo(pad + W, y + 0.5); g.stroke();
      const muted = model.tracks[t].muted;
      g.globalCompositeOperation = 'lighter';
      for (const hit of model.tracks[t].hits) {
        const f = model.firePhase(hit.phase), x = pad + W * f;
        let flash = 0;
        if (playing && !muted) { let d = sweep - f; d -= Math.floor(d); if (d < 0.04) flash = 1 - d / 0.04; }
        const r = 2.5 + 3 * hit.vel + 3 * flash;
        if (flash > 0) glow(g, x, y, r * 2.4, spec.color, 0.55 * flash);
        g.fillStyle = hexA(spec.color, muted ? 0.2 : 0.55 + 0.45 * flash);
        dot(g, x, y, r); g.fill();
      }
      g.globalCompositeOperation = 'source-over';
      if (playing) {
        const x = pad + W * sweep;
        g.fillStyle = 'rgba(255,255,255,.5)'; g.fillRect(x - 0.5, 1, 1, h - 2);
      }
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
  renderText();
  requestAnimationFrame(frame);
})();
