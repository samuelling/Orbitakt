'use strict';
/* Orbitakt's brain (port of RhythmModel.swift + SkyTracker.swift): keeps the catalog, reads the
 * sky twice a second, puts every satellite in each family's cone on the radar at its real
 * bearing, and drives the engine. No DOM in here; the page listens through `onChange`. */

const mtof = m => 440 * Math.pow(2, (m - 69) / 12);
const clamp01 = x => Math.min(1, Math.max(0, x));

const SCALES = [
  { name: 'Major pentatonic', steps: [0, 2, 4, 7, 9] },
  { name: 'Minor pentatonic', steps: [0, 3, 5, 7, 10] },
  { name: 'Major', steps: [0, 2, 4, 5, 7, 9, 11] },
  { name: 'Natural minor', steps: [0, 2, 3, 5, 7, 8, 10] },
  { name: 'Dorian', steps: [0, 2, 3, 5, 7, 9, 10] },
  { name: 'Lydian', steps: [0, 2, 4, 6, 7, 9, 11] },
  { name: 'Whole tone', steps: [0, 2, 4, 6, 8, 10] },
  { name: 'Hirajoshi', steps: [0, 2, 3, 7, 8] },
  { name: 'Suspended', steps: [0, 2, 5, 7, 10] },
];
const PITCH_NAMES = ['C', 'C♯', 'D', 'E♭', 'E', 'F', 'F♯', 'G', 'A♭', 'A', 'B♭', 'B'];

/** Four tracks: a family of satellites, a cone of sky around the zenith, and a drum.
 *  Sparse on purpose: about four kicks, two rimshots, five hats and two gated hats a sweep. */
const SPECS = [
  { fam: FAM.NAV, sound: 'kick', color: '#ff8c40', target: 4 },
  { fam: FAM.LEO, sound: 'rim', color: '#73d98c', target: 2 },
  { fam: FAM.SWARM, sound: 'hat', color: '#73bfff', target: 5 },
  { fam: FAM.BELT, sound: 'gate hat', color: '#d999ff', target: 2 },
];
const CREW_COLOR = '#ffd966';
const FAM_COLOR = [SPECS[0].color, SPECS[1].color, SPECS[2].color, SPECS[3].color, CREW_COLOR, '#808080'];
const MAX_EVENTS = 32, GRID_SLOTS = 16;

const PLACES = [
  { key: 'watertown', name: 'Watertown, MA', lat: 42.37, lon: -71.18 },
  { key: 'nyc', name: 'New York', lat: 40.71, lon: -74.01 },
  { key: 'london', name: 'London', lat: 51.51, lon: -0.13 },
  { key: 'reykjavik', name: 'Reykjavík', lat: 64.15, lon: -21.94 },
  { key: 'mumbai', name: 'Mumbai', lat: 19.08, lon: 72.88 },
  { key: 'singapore', name: 'Singapore', lat: 1.35, lon: 103.82 },
  { key: 'tokyo', name: 'Tokyo', lat: 35.68, lon: 139.69 },
  { key: 'capetown', name: 'Cape Town', lat: -33.92, lon: 18.42 },
  { key: 'saopaulo', name: 'São Paulo', lat: -23.55, lon: -46.63 },
  { key: 'sydney', name: 'Sydney', lat: -33.87, lon: 151.21 },
];

class RhythmModel {
  constructor(engine) {
    this.engine = engine;
    this.onChange = null;

    // What the sky is doing
    this.snapshot = { time: 0, blips: [], catalogSize: 0, counts: [0, 0, 0, 0, 0, 0] };
    this.tracks = SPECS.map(() => ({ hits: [], cone: 30, inCone: 0, auto: true, muted: false }));
    this.isPlaying = false;
    this.status = 'Reading the sky…';
    this.dataNote = '';
    this.live = false;
    this.crewNote = null;
    this.orbitBPM = 84;
    this.effectiveBPM = 84;
    this.throwLevel = 0;
    this.pings = [];          // recent zenith pings, for the dome

    // Settings (persisted)
    this.s = {
      useLive: true, scaleIndex: 0, rootPC: 2, tempoSource: 'orbit', manualBPM: 84,
      swing: 0.1, space: 0.6, dub: 0.55, dustOn: true, division: 2, quantize: 0.5,
      pingRadius: 4, gongOn: true, place: 'watertown', keepAwake: true, askedLocation: false,
      deviceLat: null, deviceLon: null,
    };
    this.runs = SPECS.map(() => ({ cone: -1, ids: new Set(), manualCone: null }));
    this._load();

    // Sky
    this.observer = null;
    this.sats = [];
    this.fetching = false;
    this.loadedLive = false;
    this.lastSnapTime = 0;
    this.pingIDs = new Set();
    this.pingSlot = 0;
    this.lastPing = 0;
    this.crewIDs = new Set();
    this.lastGongBar = -1;
    this.scratch = { r: [0, 0, 0], lk: [0, 0] };
    this._applyPlace();
    this._pushAll();

    this.tracker = setInterval(() => this._step(), 500);
    this.ticker = setInterval(() => this._fastTick(), 250);
    this.catalogTimer = setInterval(() => this._refreshCatalogIfDue(), 30 * 60 * 1000);
    this._reloadCatalog();
  }

  get steps() { return SCALES[Math.max(0, Math.min(SCALES.length - 1, this.s.scaleIndex))].steps; }
  get placeName() {
    if (this.s.place === 'device') {
      const la = this.s.deviceLat, lo = this.s.deviceLon;
      return `Your location (${Math.abs(la).toFixed(2)}°${la >= 0 ? 'N' : 'S'} ${Math.abs(lo).toFixed(2)}°${lo >= 0 ? 'E' : 'W'})`;
    }
    return (PLACES.find(p => p.key === this.s.place) || PLACES[0]).name;
  }
  get lat() { return this.s.place === 'device' ? this.s.deviceLat : (PLACES.find(p => p.key === this.s.place) || PLACES[0]).lat; }
  get lon() { return this.s.place === 'device' ? this.s.deviceLon : (PLACES.find(p => p.key === this.s.place) || PLACES[0]).lon; }

  _emit() { if (this.onChange) this.onChange(); }

  // ---------- Settings ----------

  /** Change a setting and push whatever it affects to the engine. */
  setSetting(k, v) {
    this.s[k] = v;
    switch (k) {
      case 'swing': this.engine.set('swing', v); break;
      case 'dub': this.engine.set('dub', v); break;
      case 'division': this.engine.set('division', v); break;
      case 'quantize': this.engine.set('quantize', v); break;
      case 'space': this.engine.setSpace(v); break;
      case 'useLive': this._reloadCatalog(); break;
      case 'place': this._applyPlace(); break;
    }
    this._save();
    this._emit();
  }

  _pushAll() {
    const e = this.engine, s = this.s;
    e.set('swing', s.swing); e.set('dub', s.dub); e.set('division', s.division); e.set('quantize', s.quantize);
    e.setSpace(s.space);
    this.tracks.forEach((t, i) => e.setMute(i, t.muted));
  }

  setMuted(m, t) {
    this.tracks[t].muted = m;
    this.engine.setMute(t, m);
    this._save();
    this._emit();
  }

  /** null = the cone adapts by itself; otherwise a fixed half-angle in degrees. */
  setCone(deg, t) {
    this.runs[t].manualCone = deg;
    this.tracks[t].auto = deg == null;
    if (deg != null) { this.runs[t].cone = deg; this.tracks[t].cone = deg; }
    this._save();
    if (this.snapshot.time > 0) this._build(t, this.snapshot, 0);
    this._emit();
  }

  /** When a hit fires within the sweep, matching the engine: its bearing pulled toward the
   *  nearest of 16 grid slots by Quantize, odd slots a little late with swing. */
  firePhase(bearingPhase) {
    const g = GRID_SLOTS;
    const slot = Math.round(bearingPhase * g);
    const grid = (slot + (slot % 2 === 1 ? Math.min(0.4, this.s.swing) : 0)) / g;
    const f = bearingPhase + this.s.quantize * (grid - bearingPhase);
    return f >= 1 ? f - 1 : f;
  }

  // ---------- Transport ----------

  async togglePlay() {
    if (this.isPlaying) {
      this.engine.stop();
      this.isPlaying = false;
      this._emit();
      return;
    }
    this.isPlaying = true;          // optimistic: the button answers the tap at once
    this._emit();
    try {
      await this.engine.start();
    } catch (err) {
      this.isPlaying = false;
      this.status = 'Audio failed to start: ' + (err && err.message ? err.message : err);
      this._emit();
    }
  }

  // ---------- Location ----------

  /** Ask the browser for the player's position (rounded to 0.01 degrees, about a kilometre). */
  useMyLocation() {
    return new Promise(resolve => {
      this.s.askedLocation = true;
      this._save();
      if (!navigator.geolocation) { resolve(false); return; }
      navigator.geolocation.getCurrentPosition(pos => {
        const la = Math.round(pos.coords.latitude * 100) / 100, lo = Math.round(pos.coords.longitude * 100) / 100;
        this.s.deviceLat = la; this.s.deviceLon = lo;
        this.setSetting('place', 'device');
        resolve(true);
      }, () => resolve(false), { enableHighAccuracy: false, timeout: 15000, maximumAge: 3600000 });
    });
  }

  _applyPlace() {
    if (this.s.place === 'device' && (this.s.deviceLat == null || this.s.deviceLon == null)) this.s.place = 'watertown';
    this.observer = new Observer(this.lat, this.lon);
    if (this.snapshot.time > 0) this._step();
    this._updateStatus();
  }

  // ---------- Catalog ----------

  async _reloadCatalog() {
    this.live = false;
    this.loadedLive = false;
    const text = this.s.useLive ? CatalogStore.cached() : null;
    if (text) {
      const sats = await this._parseChunked(text);
      this._adopt(sats, true);
    } else {
      this._adopt(simulatedCatalog(), false);
    }
    this._refreshCatalogIfDue();
  }

  /** Parse the big TLE text in slices, so the page stays responsive while it does. */
  async _parseChunked(text) {
    const lines = text.split(/\r?\n/);
    const out = [];
    const slice = 3 * 1500;
    for (let i = 0; i < lines.length; i += slice) {
      let end = Math.min(lines.length, i + slice + 3);
      out.push(...parseTLE(lines.slice(i, end).join('\n')));
      await new Promise(r => setTimeout(r, 0));
    }
    // Slices overlap by a few lines so no entry is cut; drop the duplicates that makes
    const seen = new Set(), uniq = [];
    for (const s of out) { const k = s.id + '|' + s.name; if (!seen.has(k)) { seen.add(k); uniq.push(s); } }
    return uniq;
  }

  _adopt(sats, isLive) {
    if (isLive && !this.s.useLive) return;
    if (isLive && sats.length < 100) {
      if (!this.live && this.snapshot.catalogSize === 0) this._setCatalog(simulatedCatalog());
      return;
    }
    this._setCatalog(sats);
    this.live = isLive;
    this.loadedLive = isLive;
    this.runs = this.runs.map(r => ({ cone: -1, ids: new Set(), manualCone: r.manualCone }));
    this._updateStatus();
  }

  _setCatalog(sats) { this.sats = sats; this._step(); }

  async _refreshCatalogIfDue() {
    if (!this.s.useLive || this.fetching || !CatalogStore.shouldFetch()) return;
    this.fetching = true;
    this._updateStatus();
    const text = await CatalogStore.download();
    this.fetching = false;
    if (text) this._adopt(await this._parseChunked(text), true);
    else this._updateStatus();
  }

  _updateStatus() {
    if (this.live) {
      this.status = 'Live · ' + this.placeName;
      const f = CatalogStore.fetchedAt();
      if (f) {
        const h = (Date.now() / 1000 - f) / 3600;
        const age = h < 1 ? 'under an hour' : (h < 48 ? Math.floor(h) + ' h' : Math.floor(h / 24) + ' days');
        this.dataNote = this.snapshot.catalogSize.toLocaleString('en-US') + ' satellites · elements ' + age + ' old (CelesTrak)';
      }
    } else if (this.s.useLive) {
      this.status = (this.fetching ? 'Simulated sky · fetching orbits…' : 'Simulated sky (no orbital data yet)') + ' · ' + this.placeName;
      this.dataNote = 'Stand-in constellations until CelesTrak’s catalog arrives';
    } else {
      this.status = 'Simulated sky · ' + this.placeName;
      this.dataNote = 'Real shells and densities, invented positions';
    }
    this._emit();
  }

  // ---------- Sky: propagate the catalog (twice a second) ----------

  _step() {
    if (!this.observer || !this.sats.length) return;
    const now = Date.now() / 1000;
    const g = gmstFromUnix(now);
    const blips = [];
    const counts = [0, 0, 0, 0, 0, 0];
    const { r, lk } = this.scratch;
    const obs = this.observer;
    for (const s of this.sats) {
      if (!s.orbit.position(now, r)) continue;
      obs.look(r, g, lk);
      if (lk[1] <= 0) continue;
      counts[s.fam]++;
      blips.push({ id: s.id, fam: s.fam, az: lk[0], el: lk[1], zenith: 90 - lk[1], period: s.orbit.periodMinutes });
    }
    this._process({ time: now, blips, catalogSize: this.sats.length, counts });
  }

  /** Sky -> rhythm. */
  _process(s) {
    const dt = this.lastSnapTime > 0 ? Math.min(5, s.time - this.lastSnapTime) : 0;
    this.lastSnapTime = s.time;
    this.snapshot = s;
    for (let t = 0; t < SPECS.length; t++) this._build(t, s, dt);
    this._zenithPings(s);
    this._crew(s);
    this._tempo(s, dt);
    if (this.live) this._updateStatus(); else this._emit();
  }

  _build(t, snap, dt) {
    const spec = SPECS[t];
    const fam = snap.blips.filter(b => b.fam === spec.fam);
    const run = this.runs[t];

    // The cone: it adapts slowly (ten minutes) to hold about `target` satellites on average, so
    // the difference between, say, Starlink's hundreds and GPS's dozen is divided out, while a
    // busy or empty spell still comes through as more or fewer hits.
    if (run.manualCone != null) {
      run.cone = run.manualCone;
    } else {
      const zs = fam.map(b => b.zenith).sort((a, b) => a - b);
      const target = zs.length >= spec.target ? Math.min(90, zs[spec.target - 1] + 0.1) : 90;
      if (run.cone < 0) run.cone = target;
      else if (dt > 0) run.cone += (target - run.cone) * (1 - Math.exp(-dt / 600));
    }
    const cone = Math.max(1, run.cone);
    let members = fam.filter(b => b.zenith <= cone);
    const ids = new Set(members.map(b => b.id));
    // A low-orbit satellite crossing into its cone throws the echo send open
    if (t === 1 && dt > 0 && run.ids.size > 0) {
      for (const id of ids) if (!run.ids.has(id)) { this._throwEcho(0.55 + 0.45 * Math.random()); break; }
    }
    run.ids = ids;

    // Every satellite in the cone hits once a sweep, as the beam passes its bearing.
    // (If a hand-set cone holds more than 32, the highest 32 play.)
    if (members.length > MAX_EVENTS) members = members.sort((a, b) => b.el - a.el).slice(0, MAX_EVENTS);
    members.sort((a, b) => a.az - b.az);
    const root = this.s.rootPC, sc = this.steps;
    const list = { count: members.length, phase: [], vel: [], pan: [], freq: [] };
    const hits = [];
    for (const b of members) {
      const height = clamp01((b.el - (90 - cone)) / Math.max(1, cone));   // 0 at the cone's rim, 1 at the zenith
      const v = t === 0 ? 0.55 + 0.35 * height : 0.35 + 0.65 * height;
      const ph = b.az / 360;
      list.phase.push(ph); list.vel.push(v);
      list.pan.push(Math.max(-0.9, Math.min(0.9, Math.sin(b.az * Math.PI / 180) * Math.cos(b.el * Math.PI / 180) * 1.1)));
      list.freq.push(this._pitch(t, b, root, sc));
      hits.push({ id: b.id, phase: ph, vel: v });
    }
    this.engine.setList(t, list);
    this.engine.setBright(t, t === 2 ? clamp01(fam.length / 450) : 0.5);   // hats brighten with a busier Starlink sky

    const v = this.tracks[t];
    v.hits = hits; v.cone = cone; v.inCone = members.length; v.auto = run.manualCone == null;
  }

  _semis(d, sc) {
    const n = sc.length;
    const q = Math.floor(d / n);
    return sc[d - q * n] + 12 * q;
  }

  _pitch(t, b, root, sc) {
    switch (t) {
      case 0: return mtof(29 + (root + 7) % 12);                  // a deep kick on the root (F1..E2, 44-82 Hz)
      case 1: return mtof(81 + root + this._semis(2, sc));        // rimshot tuned to a scale degree, up where it cuts through the echo
      case 2: return 5400;                                        // hat partials sit in a fixed metallic band
      case 3: {                                                   // the gated hat's metal, tuned by where the satellite sits along the belt:
        const x = clamp01((1 - Math.sin(b.az * Math.PI / 180)) / 2);   // darker in the east (~3.8 kHz) to brighter in the west (~6.2 kHz)
        return 3800 * Math.pow(2, 0.7 * x);
      }
      default: return 1000;
    }
  }

  /** Throw the echo send open (a dub move); it falls back over a few seconds. */
  _throwEcho(amount) {
    this.throwLevel = Math.max(this.throwLevel, Math.min(1, amount));
    this.engine.set('throwAmt', this.throwLevel);
  }

  // ---------- Events ----------

  /** Anything passing within `pingRadius` of straight up rings a glass bar. */
  _zenithPings(s) {
    const now = performance.now() / 1000;
    const close = s.blips.filter(b => b.fam !== FAM.OTHER && b.zenith <= this.s.pingRadius);
    const ids = new Set(close.map(b => b.id));
    const fresh = close.filter(b => !this.pingIDs.has(b.id));
    this.pingIDs = ids;
    this.pings = this.pings.filter(p => now - p.t <= 6);
    if (!this.isPlaying || !fresh.length || now - this.lastPing <= 1.2) return;
    const b = fresh.reduce((m, c) => (c.el > m.el ? c : m));
    this.lastPing = now;
    const sc = this.steps;
    const d = (b.id >>> 0) % (2 * sc.length);
    this.engine.ping(mtof(72 + this.s.rootPC + this._semis(d, sc)), 0.55 + Math.random() * 0.35, Math.sin(b.az * Math.PI / 180) * 0.6);
    this._throwEcho(0.85);
    this.pings.push({ az: b.az, el: b.el, t: now });
  }

  /** While a crewed station is up, a gong every four bars; and one as it rises. */
  _crew(s) {
    const up = s.blips.filter(b => b.fam === FAM.CREW && b.el > 5);
    const ids = new Set(up.map(b => b.id));
    let rising = false;
    for (const id of ids) if (!this.crewIDs.has(id)) rising = true;
    this.crewIDs = ids;
    const crewUp = up.length > 0;
    let crewEl = 0;
    if (crewUp) {
      const top = up.reduce((m, c) => (c.el > m.el ? c : m));
      crewEl = top.el;
      const name = top.id === 25544 ? 'ISS' : (top.id === 48274 ? 'Tiangong' : 'A crewed station');
      this.crewNote = name + ' overhead · ' + Math.round(crewEl) + '° up';
    } else {
      this.crewNote = null;
    }
    if (!this.isPlaying || !this.s.gongOn || !crewUp) return;
    const bar = Math.floor(this.engine.beam().beats / 16);
    if (rising || bar !== this.lastGongBar) {
      this.lastGongBar = bar;
      this.engine.gong(mtof(36 + this.s.rootPC), 0.35 + 0.65 * Math.sin(crewEl * Math.PI / 180), 0);
    }
  }

  // ---------- Tempo ----------

  /** The overhead orbits' own period, thirteen octaves up: a 95-minute Starlink orbit is
   *  1/5736 Hz; x 2^13 that's 85.7 BPM. Higher shells are slower, the ISS a touch faster. */
  _tempo(s, dt) {
    const low = s.blips.filter(b => (b.fam === FAM.SWARM || b.fam === FAM.LEO) && b.el > 30)
      .map(b => b.period).sort((a, b) => a - b);
    if (low.length) {
      const target = 8192 / low[Math.floor(low.length / 2)];
      this.orbitBPM = dt > 0 ? this.orbitBPM + (target - this.orbitBPM) * (1 - Math.exp(-dt / 20)) : target;
    }
    this.effectiveBPM = this.s.tempoSource === 'orbit' ? this.orbitBPM : this.s.manualBPM;
    this.engine.set('bpm', this.effectiveBPM);
    // Dust: a breath of hiss and crackle that thickens with the crowd overhead
    this.engine.set('dust', this.s.dustOn ? 0.25 + 0.75 * clamp01(s.blips.length / 1500) : 0);
  }

  _fastTick() {
    if (this.throwLevel > 0.001) {
      this.throwLevel *= Math.exp(-0.25 / 2.5);
      if (this.throwLevel < 0.01) this.throwLevel = 0;
      this.engine.set('throwAmt', this.throwLevel);
    }
  }

  // ---------- Persistence ----------

  _save() {
    try {
      localStorage.setItem('orbitakt.settings', JSON.stringify({
        s: this.s, mutes: this.tracks.map(t => t.muted), cones: this.runs.map(r => r.manualCone),
      }));
    } catch (e) {}
  }

  _load() {
    try {
      const raw = localStorage.getItem('orbitakt.settings');
      if (!raw) return;
      const d = JSON.parse(raw);
      for (const k of Object.keys(this.s)) if (d.s && k in d.s && typeof d.s[k] === typeof this.s[k]) this.s[k] = d.s[k];
      if (d.s) { if (d.s.deviceLat != null) this.s.deviceLat = d.s.deviceLat; if (d.s.deviceLon != null) this.s.deviceLon = d.s.deviceLon; }
      this.s.division = this.s.division === 4 ? 4 : 2;
      this.s.dub = Math.min(0.85, Math.max(0, this.s.dub));
      this.s.quantize = clamp01(this.s.quantize);
      this.s.scaleIndex = Math.max(0, Math.min(SCALES.length - 1, Math.floor(this.s.scaleIndex)));
      this.s.rootPC = Math.max(0, Math.min(11, Math.floor(this.s.rootPC)));
      if (Array.isArray(d.mutes) && d.mutes.length === this.tracks.length) d.mutes.forEach((m, i) => { this.tracks[i].muted = !!m; });
      if (Array.isArray(d.cones) && d.cones.length === this.runs.length) {
        d.cones.forEach((c, i) => { if (typeof c === 'number' && c > 0) { this.runs[i].manualCone = c; this.runs[i].cone = c; this.tracks[i].auto = false; this.tracks[i].cone = c; } });
      }
    } catch (e) {}
  }
}

if (typeof module !== 'undefined') module.exports = { RhythmModel, SPECS, SCALES, PITCH_NAMES, PLACES, FAM_COLOR, CREW_COLOR, mtof, clamp01 };
