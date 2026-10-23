'use strict';
/* The satellite catalog: families, the real catalog (CelesTrak TLEs) and a simulated stand-in.
 * Port of Orbitakt's Catalog.swift. */

// Which part of the sky a satellite belongs to. Each family drives one part of the kit.
const FAM = { NAV: 0, LEO: 1, SWARM: 2, BELT: 3, CREW: 4, OTHER: 5 };
const FAM_LABEL = ['NAV', 'LEO', 'SWARM', 'BELT', 'CREW', 'OTHER'];

/** Sort a catalog entry into a family by name and orbit. */
function classify(name, periodMinutes, eccentricity) {
  const n = name.toUpperCase();
  if (n.includes('ISS (ZARYA)') || n.includes('TIANHE')) return FAM.CREW;
  if (n.startsWith('STARLINK')) return FAM.SWARM;
  if (periodMinutes < 225) return FAM.LEO;
  if (!(eccentricity < 0.1)) return FAM.OTHER;
  if (periodMinutes < 1300) return FAM.NAV;
  if (periodMinutes <= 1600) return FAM.BELT;
  return FAM.OTHER;
}

/** A circular orbit with J2 nodal drift, for the simulated sky. */
class CircularOrbit {
  constructor(altitudeKm, inclinationDeg, raan, u, epoch) {
    const MU = 398600.4418, RE = 6378.137;
    this.a = RE + altitudeKm;
    this.inc = inclinationDeg * Math.PI / 180;
    this.raan0 = raan;
    this.u0 = u;
    this.n = Math.sqrt(MU / (this.a * this.a * this.a));
    const ratio = RE / this.a;
    this.raanDot = -1.5 * this.n * 1.08262668e-3 * ratio * ratio * Math.cos(this.inc);
    this.epoch = epoch;
    this.cosInc = Math.cos(this.inc);
    this.sinInc = Math.sin(this.inc);
    this.periodMinutes = 2 * Math.PI / this.n / 60;
  }
  position(unix, out) {
    const dt = unix - this.epoch;
    const u = this.u0 + this.n * dt, o = this.raan0 + this.raanDot * dt;
    const cu = Math.cos(u), su = Math.sin(u), co = Math.cos(o), so = Math.sin(o);
    const ci = this.cosInc, si = this.sinInc;
    out[0] = this.a * (cu * co - su * ci * so);
    out[1] = this.a * (cu * so + su * ci * co);
    out[2] = this.a * su * si;
    return true;
  }
}

/** NORAD catalog number, including the Alpha-5 form used past 99999 ("A0001" = 100001). */
function catalogNumber(field) {
  const f = field.trim();
  if (/^\d+$/.test(f)) return parseInt(f, 10);
  const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const i = letters.indexOf(f[0]);
  const rest = parseInt(f.slice(1), 10);
  if (i < 0 || !Number.isFinite(rest)) return -1;
  return (10 + i) * 10000 + rest;
}

/** Parse 3-line TLE text (name, line 1, line 2) into satellites {id, name, fam, orbit}. */
function parseTLE(text) {
  const out = [];
  const lines = text.split(/\r?\n/);
  let i = 0;
  while (i + 1 < lines.length) {
    const l1 = lines[i], l2 = lines[i + 1];
    if (!l1.startsWith('1 ') || !l2.startsWith('2 ')) { i += 1; continue; }
    let name = '';
    if (i > 0) {
      const prev = lines[i - 1];
      if (!prev.startsWith('1 ') && !prev.startsWith('2 ')) {
        name = prev.trim();
        if (name.startsWith('0 ')) name = name.slice(2);
      }
    }
    i += 2;
    const s = SGP4.fromLines(l1, l2);
    if (!s || !s.isUsable) continue;
    const id = catalogNumber(l1.slice(2, 7));
    out.push({ id, name, fam: classify(name, s.periodMinutes, s.eccentricity), orbit: s });
  }
  return out;
}

/** Small deterministic generator (so the simulated sky is the same every visit). */
function makeRng(seed) {
  let a = seed >>> 0;
  return () => {   // mulberry32
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** A stand-in sky, used before the real catalog arrives or with no connection: the same
 *  constellations, shell by shell, as Walker patterns (Starlink's shells, OneWeb, Iridium,
 *  Kuiper, the navigation constellations, the geostationary belt, two crewed stations, and a
 *  scatter of other low orbits). Positions are invented; densities are realistic. */
function simulatedCatalog() {
  const rng = makeRng(0x0B17A472);
  const epoch = 1792195200;     // 2026-10-17 00:00 UTC
  const out = [];
  let nextID = 90000;
  const add = (name, fam, alt, inc, raan, u) => {
    out.push({ id: nextID++, name, fam, orbit: new CircularOrbit(alt, inc, raan, u, epoch) });
  };
  const walker = (name, fam, alt, inc, planes, perPlane, phasing) => {
    const off = rng() * 2 * Math.PI;
    for (let j = 0; j < planes; j++) {
      for (let k = 0; k < perPlane; k++) {
        const raan = off + 2 * Math.PI * j / planes;
        const u = 2 * Math.PI * k / perPlane + 2 * Math.PI * (phasing * j) / (planes * perPlane);
        add(name, fam, alt, inc, raan, u);
      }
    }
  };
  walker('STARLINK', FAM.SWARM, 550, 53, 72, 22, 17);
  walker('STARLINK', FAM.SWARM, 540, 53.2, 72, 22, 13);
  walker('STARLINK', FAM.SWARM, 570, 70, 36, 20, 11);
  walker('STARLINK', FAM.SWARM, 560, 97.6, 10, 52, 5);
  walker('STARLINK', FAM.SWARM, 525, 43, 28, 120, 7);
  walker('ONEWEB', FAM.LEO, 1200, 87.9, 12, 49, 3);
  walker('IRIDIUM', FAM.LEO, 780, 86.4, 6, 11, 2);
  walker('KUIPER', FAM.LEO, 630, 51.9, 10, 20, 3);
  for (let k = 0; k < 1800; k++) {
    const r = rng();
    let inc, alt;
    if (r < 0.45) { inc = 97.4 + rng() * 1.2; alt = 480 + rng() * 320; }
    else if (r < 0.6) { inc = 51.6; alt = 400 + rng() * 150; }
    else { inc = 30 + rng() * 70; alt = 400 + rng() * 800; }
    add('LEO', FAM.LEO, alt, inc, rng() * 2 * Math.PI, rng() * 2 * Math.PI);
  }
  walker('NAVSTAR', FAM.NAV, 20180, 55, 6, 5, 1);
  walker('GALILEO', FAM.NAV, 23222, 56, 3, 8, 1);
  walker('GLONASS', FAM.NAV, 19130, 64.8, 3, 8, 1);
  walker('BEIDOU', FAM.NAV, 21528, 55, 3, 8, 1);
  for (let k = 0; k < 560; k++) {
    add('GEO', FAM.BELT, 35786, rng() * 3, rng() * 2 * Math.PI, rng() * 2 * Math.PI);
  }
  add('ISS (ZARYA)', FAM.CREW, 420, 51.64, rng() * 2 * Math.PI, rng() * 2 * Math.PI);
  add('CSS (TIANHE)', FAM.CREW, 385, 41.47, rng() * 2 * Math.PI, rng() * 2 * Math.PI);
  return out;
}

/** The real catalog from CelesTrak ("active satellites", TLE form), cached in the browser.
 *
 *  CelesTrak refreshes about every two hours and allows one download per update, so this asks
 *  at most once every 12 hours, and after any failure waits 12 hours before asking again
 *  (CelesTrak blocks clients that retry on errors). CelesTrak sends
 *  `access-control-allow-origin: *`, so a page can fetch it directly. */
const CatalogStore = {
  url: 'https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle',
  refreshAge: 12 * 3600,
  retryAfterFailure: 12 * 3600,
  maxAge: 30 * 86400,   // older than this, the elements are too stale to place satellites usefully
  keys: { text: 'orbitakt.tle', at: 'orbitakt.tleAt', next: 'orbitakt.tleNext' },

  _get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  _set(k, v) { try { localStorage.setItem(k, v); return true; } catch (e) { return false; } },

  fetchedAt() { const t = parseFloat(this._get(this.keys.at)); return t > 0 ? t : null; },

  /** Time to ask: the copy we have is over 12 h old (or missing), and we're not backing off. */
  shouldFetch(now = Date.now() / 1000) {
    const f = this.fetchedAt();
    if (f !== null && now - f < this.refreshAge) return false;
    return now >= (parseFloat(this._get(this.keys.next)) || 0);
  },

  /** The cached text, if it exists and isn't hopelessly old. */
  cached(now = Date.now() / 1000) {
    const f = this.fetchedAt();
    if (f === null || now - f > this.maxAge) return null;
    return this._get(this.keys.text);
  },

  /** One polite download: the text on success, otherwise null. Never retries by itself. */
  async download(now = Date.now() / 1000) {
    this._set(this.keys.next, String(now + 600));      // offline: try again in 10 minutes
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 60000);
    let resp;
    try {
      resp = await fetch(this.url, { signal: ctl.signal, cache: 'no-store' });
    } catch (e) {
      return null;
    } finally {
      clearTimeout(timer);
    }
    // A reply that isn't the data (e.g. 403, "not updated since your last download"): wait 12 h
    this._set(this.keys.next, String(now + this.retryAfterFailure));
    if (!resp.ok) return null;
    let text;
    try { text = await resp.text(); } catch (e) { return null; }
    if (!text.includes('\n1 ')) return null;
    this._set(this.keys.text, text);
    this._set(this.keys.at, String(Date.now() / 1000));
    return text;
  },
};

if (typeof module !== 'undefined') {
  module.exports = { FAM, FAM_LABEL, classify, CircularOrbit, catalogNumber, parseTLE, simulatedCatalog, CatalogStore };
}
