'use strict';
/* SGP4 satellite propagation: a line-for-line port of Orbitakt's SGP4.swift (Vallado's SGP4,
 * WGS-72 constants, "improved" mode, near-Earth). High orbits (period >= 225 min) run
 * through the same equations without SDP4's lunar-solar terms, which stays within about
 * 0.04 degrees of the full model as seen from Earth for near-circular orbits. */

const SGP4_MU = 398600.8;
const SGP4_RE = 6378.135;
const SGP4_XKE = 60.0 / Math.sqrt((SGP4_RE * SGP4_RE * SGP4_RE) / SGP4_MU);
const SGP4_J2 = 0.001082616;
const SGP4_J3 = -0.00000253881;
const SGP4_J4 = -0.00000165597;
const SGP4_J3OJ2 = SGP4_J3 / SGP4_J2;
const TWO_PI = 2 * Math.PI;
const X2O3 = 2.0 / 3.0;

class SGP4 {
  /** Angles in radians, meanMotion in radians per minute (Kozai, as in the TLE). */
  constructor(epoch, bstar, ecc, incl, node, argp, meanAnomaly, noKozai) {
    const re = SGP4_RE, xke = SGP4_XKE, j2 = SGP4_J2, j4 = SGP4_J4, j3oj2 = SGP4_J3OJ2;
    this.epoch = epoch;
    this.bstar = bstar;
    this.ecco = ecc;
    this.inclo = incl;
    this.nodeo = node;
    this.argpo = argp;
    this.mo = meanAnomaly;
    this.eccentricity = ecc;
    this.inclination = incl;

    // initl: recover the original mean motion and semi-major axis
    const eccsq = ecc * ecc;
    const omeosq = 1 - eccsq;
    const rteosq = Math.sqrt(omeosq);
    const cosio = Math.cos(incl);
    const cosio2 = cosio * cosio;
    const ak = Math.pow(xke / noKozai, X2O3);
    const d1 = 0.75 * j2 * (3 * cosio2 - 1) / (rteosq * omeosq);
    let del = d1 / (ak * ak);
    const adel = ak * (1 - del * del - del * (1.0 / 3.0 + 134 * del * del / 81));
    del = d1 / (adel * adel);
    const no = noKozai / (1 + del);
    const ao = Math.pow(xke / no, X2O3);
    const sinio = Math.sin(incl);
    const po = ao * omeosq;
    const con42 = 1 - 5 * cosio2;
    const con41 = -con42 - cosio2 - cosio2;
    const posq = po * po;
    const rp = ao * (1 - ecc);
    this.no = no;
    this.cosio = cosio;
    this.sinio = sinio;
    this.con41 = con41;
    this.periodMinutes = TWO_PI / no;

    // sgp4init (near-Earth)
    const ss = 78.0 / re + 1;
    const qzms2t = Math.pow((120.0 - 78.0) / re, 4);
    // Low perigee, or a deep-space orbit (as the reference does): skip the higher drag terms
    const simple = rp < (220.0 / re + 1) || TWO_PI / no >= 225;
    this.isimp = simple;
    let sfour = ss;
    let qzms24 = qzms2t;
    const perige = (rp - 1) * re;
    if (perige < 156) {
      sfour = perige - 78;
      if (perige < 98) sfour = 20;
      qzms24 = Math.pow((120 - sfour) / re, 4);
      sfour = sfour / re + 1;
    }
    const pinvsq = 1 / posq;
    const tsi = 1 / (ao - sfour);
    const eta = ao * ecc * tsi;
    const etasq = eta * eta;
    const eeta = ecc * eta;
    const psisq = Math.abs(1 - etasq);
    const coef = qzms24 * Math.pow(tsi, 4);
    const coef1 = coef / Math.pow(psisq, 3.5);
    const cc2 = coef1 * no * (ao * (1 + 1.5 * etasq + eeta * (4 + etasq))
      + 0.375 * j2 * tsi / psisq * con41 * (8 + 3 * etasq * (8 + etasq)));
    const cc1 = bstar * cc2;
    let cc3 = 0;
    if (ecc > 1e-4) cc3 = -2 * coef * tsi * j3oj2 * no * sinio / ecc;
    const x1mth2 = 1 - cosio2;
    const cc4a = eta * (2 + 0.5 * etasq) + ecc * (0.5 + 2 * etasq);
    const cc4b = -3 * con41 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta));
    const cc4c = 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * Math.cos(2 * argp);
    const cc4 = 2 * no * coef1 * ao * omeosq * (cc4a - j2 * tsi / (ao * psisq) * (cc4b + cc4c));
    const cc5 = 2 * coef1 * ao * omeosq * (1 + 2.75 * (etasq + eeta) + eeta * etasq);
    const cosio4 = cosio2 * cosio2;
    const temp1 = 1.5 * j2 * pinvsq * no;
    const temp2 = 0.5 * temp1 * j2 * pinvsq;
    const temp3 = -0.46875 * j4 * pinvsq * pinvsq * no;
    this.mdot = no + 0.5 * temp1 * rteosq * con41
      + 0.0625 * temp2 * rteosq * (13 - 78 * cosio2 + 137 * cosio4);
    this.argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7 - 114 * cosio2 + 395 * cosio4)
      + temp3 * (3 - 36 * cosio2 + 49 * cosio4);
    const xhdot1 = -temp1 * cosio;
    this.nodedot = xhdot1 + (0.5 * temp2 * (4 - 19 * cosio2) + 2 * temp3 * (3 - 7 * cosio2)) * cosio;
    this.omgcof = bstar * cc3 * Math.cos(argp);
    this.xmcof = ecc > 1e-4 ? -X2O3 * coef * bstar / eeta : 0;
    this.nodecf = 3.5 * omeosq * xhdot1 * cc1;
    this.t2cof = 1.5 * cc1;
    if (Math.abs(cosio + 1) > 1.5e-12) {
      this.xlcof = -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / (1 + cosio);
    } else {
      this.xlcof = -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / 1.5e-12;
    }
    this.aycof = -0.5 * j3oj2 * sinio;
    const dm = 1 + eta * Math.cos(meanAnomaly);
    this.delmo = dm * dm * dm;
    this.sinmao = Math.sin(meanAnomaly);
    this.x7thm1 = 7 * cosio2 - 1;
    this.x1mth2 = x1mth2;
    this.cc1 = cc1;
    this.cc4 = cc4;
    this.cc5 = cc5;
    this.eta = eta;
    if (!simple) {
      const cc1sq = cc1 * cc1;
      const d2 = 4 * ao * tsi * cc1sq;
      const temp = d2 * tsi * cc1 / 3;
      const d3 = (17 * ao + sfour) * temp;
      const d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * sfour) * cc1;
      this.d2 = d2; this.d3 = d3; this.d4 = d4;
      this.t3cof = d2 + 2 * cc1sq;
      this.t4cof = 0.25 * (3 * d3 + cc1 * (12 * d2 + 10 * cc1sq));
      this.t5cof = 0.2 * (3 * d4 + 12 * cc1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq));
    } else {
      this.d2 = 0; this.d3 = 0; this.d4 = 0; this.t3cof = 0; this.t4cof = 0; this.t5cof = 0;
    }
  }

  /** Usable for sky positions: near-Earth, or a high orbit that is close to circular. */
  get isUsable() { return this.periodMinutes < 225 || this.eccentricity < 0.1; }

  /** Position in the TEME frame (km) at `t` minutes after epoch, written into out[0..2].
   *  Returns false if the model fails (decayed, or elements too old to mean anything). */
  positionMinutes(t, out) {
    const xmdf = this.mo + this.mdot * t;
    const argpdf = this.argpo + this.argpdot * t;
    const nodedf = this.nodeo + this.nodedot * t;
    let argpm = argpdf;
    let mm = xmdf;
    const t2 = t * t;
    let nodem = nodedf + this.nodecf * t2;
    let tempa = 1 - this.cc1 * t;
    let tempe = this.bstar * this.cc4 * t;
    let templ = this.t2cof * t2;
    if (!this.isimp) {
      const delomg = this.omgcof * t;
      const dm = 1 + this.eta * Math.cos(xmdf);
      const delm = this.xmcof * (dm * dm * dm - this.delmo);
      const temp = delomg + delm;
      mm = xmdf + temp;
      argpm = argpdf - temp;
      const t3 = t2 * t;
      const t4 = t3 * t;
      tempa = tempa - this.d2 * t2 - this.d3 * t3 - this.d4 * t4;
      tempe = tempe + this.bstar * this.cc5 * (Math.sin(mm) - this.sinmao);
      templ = templ + this.t3cof * t3 + t4 * (this.t4cof + t * this.t5cof);
    }
    if (!(this.no > 0)) return false;
    const am = Math.pow(SGP4_XKE / this.no, X2O3) * tempa * tempa;
    let em = this.ecco - tempe;
    if (!(em < 1 && em >= -0.001 && am >= 0.95)) return false;
    if (em < 1e-6) em = 1e-6;
    mm = mm + this.no * templ;
    let xlm = mm + argpm + nodem;
    nodem = nodem % TWO_PI;
    argpm = argpm % TWO_PI;
    xlm = xlm % TWO_PI;
    mm = (xlm - argpm - nodem) % TWO_PI;

    // Long-period periodics
    const axnl = em * Math.cos(argpm);
    let temp = 1 / (am * (1 - em * em));
    const aynl = em * Math.sin(argpm) + temp * this.aycof;
    const xl = mm + argpm + nodem + temp * this.xlcof * axnl;

    // Kepler's equation
    const u = (xl - nodem) % TWO_PI;
    let eo1 = u;
    let tem5 = 9999.9;
    let ktr = 1;
    let sineo1 = 0, coseo1 = 0;
    while (Math.abs(tem5) >= 1e-12 && ktr <= 10) {
      sineo1 = Math.sin(eo1);
      coseo1 = Math.cos(eo1);
      tem5 = 1 - coseo1 * axnl - sineo1 * aynl;
      tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5;
      if (Math.abs(tem5) >= 0.95) tem5 = tem5 > 0 ? 0.95 : -0.95;
      eo1 += tem5;
      ktr += 1;
    }

    // Short-period periodics
    const ecose = axnl * coseo1 + aynl * sineo1;
    const esine = axnl * sineo1 - aynl * coseo1;
    const el2 = axnl * axnl + aynl * aynl;
    const pl = am * (1 - el2);
    if (!(pl >= 0)) return false;
    const rl = am * (1 - ecose);
    const betal = Math.sqrt(1 - el2);
    temp = esine / (1 + betal);
    const sinu = am / rl * (sineo1 - aynl - axnl * temp);
    const cosu = am / rl * (coseo1 - axnl + aynl * temp);
    let su = Math.atan2(sinu, cosu);
    const sin2u = (cosu + cosu) * sinu;
    const cos2u = 1 - 2 * sinu * sinu;
    temp = 1 / pl;
    const temp1 = 0.5 * SGP4_J2 * temp;
    const temp2 = temp1 * temp;
    const mrt = rl * (1 - 1.5 * temp2 * betal * this.con41) + 0.5 * temp1 * this.x1mth2 * cos2u;
    su = su - 0.25 * temp2 * this.x7thm1 * sin2u;
    const xnode = nodem + 1.5 * temp2 * this.cosio * sin2u;
    const xinc = this.inclo + 1.5 * temp2 * this.cosio * this.sinio * cos2u;
    if (!(mrt >= 1)) return false;

    const sinsu = Math.sin(su), cossu = Math.cos(su);
    const snod = Math.sin(xnode), cnod = Math.cos(xnode);
    const sini = Math.sin(xinc), cosi = Math.cos(xinc);
    const xmx = -snod * cosi;
    const xmy = cnod * cosi;
    const r = mrt * SGP4_RE;
    out[0] = r * (xmx * sinsu + cnod * cossu);
    out[1] = r * (xmy * sinsu + snod * cossu);
    out[2] = r * (sini * sinsu);
    return true;
  }

  /** Same, at a Unix time in seconds. */
  position(unix, out) { return this.positionMinutes((unix - this.epoch) / 60, out); }

  /** Parse the two element lines of a TLE (the name line is handled by the caller). */
  static fromLines(l1, l2) {
    if (l1.length < 63 || l2.length < 63 || l1[0] !== '1' || l2[0] !== '2') return null;
    const field = (s, lo, hi) => s.slice(lo, Math.min(hi, s.length)).trim();
    const num = (s, lo, hi) => {
      const f = field(s, lo, hi);
      if (f === '') return NaN;
      const v = Number(f);
      return Number.isFinite(v) ? v : NaN;
    };
    // TLE "assumed decimal" exponent field, e.g. " 12345-3" = 0.12345e-3.
    const expo = (s, lo, hi) => {
      let f = field(s, lo, hi);
      if (f === '') return 0;
      let sign = 1;
      if (f[0] === '-') { sign = -1; f = f.slice(1); } else if (f[0] === '+') { f = f.slice(1); }
      if (f.length < 3) return 0;
      const mant = f.slice(0, -2);
      const ex = f.slice(-2);
      const m = Number('0.' + mant), e = Number(ex);
      if (!Number.isFinite(m) || !Number.isFinite(e)) return NaN;
      return sign * m * Math.pow(10, e);
    };
    const yy = parseInt(field(l1, 18, 20), 10);
    const doy = num(l1, 20, 32);
    const bstar = expo(l1, 53, 61);
    const incl = num(l2, 8, 16), node = num(l2, 17, 25);
    const ecc = Number('0.' + field(l2, 26, 33));
    const argp = num(l2, 34, 42), ma = num(l2, 43, 51), n = num(l2, 52, 63);
    if ([yy, doy, bstar, incl, node, ecc, argp, ma, n].some(v => !Number.isFinite(v)) || !(n > 0)) return null;
    const year = yy < 57 ? 2000 + yy : 1900 + yy;
    const deg = Math.PI / 180;
    const epoch = Date.UTC(year, 0, 1) / 1000 + (doy - 1) * 86400;
    return new SGP4(epoch, bstar, ecc, incl * deg, node * deg, argp * deg, ma * deg, n * 2 * Math.PI / 1440);
  }
}

/** An observer on the WGS-84 ellipsoid, with the rotation to local east/north/up. */
class Observer {
  constructor(latDeg, lonDeg, heightKm = 0) {
    const a = 6378.137, f = 1 / 298.257223563;
    const e2 = f * (2 - f);
    const phi = latDeg * Math.PI / 180, lam = lonDeg * Math.PI / 180;
    this.sphi = Math.sin(phi); this.cphi = Math.cos(phi);
    this.slam = Math.sin(lam); this.clam = Math.cos(lam);
    const n = a / Math.sqrt(1 - e2 * this.sphi * this.sphi);
    this.x = (n + heightKm) * this.cphi * this.clam;
    this.y = (n + heightKm) * this.cphi * this.slam;
    this.z = (n * (1 - e2) + heightKm) * this.sphi;
  }

  /** Azimuth (degrees clockwise from north, 0..<360) and elevation (degrees) of a TEME
   *  position r = [x,y,z], given Greenwich mean sidereal time (radians). Written into out. */
  look(r, gmst, out) {
    const cg = Math.cos(gmst), sg = Math.sin(gmst);
    const ex = cg * r[0] + sg * r[1];
    const ey = -sg * r[0] + cg * r[1];
    const dx = ex - this.x, dy = ey - this.y, dz = r[2] - this.z;
    const e = -this.slam * dx + this.clam * dy;
    const n = -this.sphi * this.clam * dx - this.sphi * this.slam * dy + this.cphi * dz;
    const u = this.cphi * this.clam * dx + this.cphi * this.slam * dy + this.sphi * dz;
    out[1] = Math.atan2(u, Math.sqrt(e * e + n * n)) * 180 / Math.PI;
    let az = Math.atan2(e, n) * 180 / Math.PI;
    if (az < 0) az += 360;
    out[0] = az;
  }
}

/** Greenwich mean sidereal time (IAU-82, radians) for a Unix time, taking UT1 ~ UTC. */
function gmstFromUnix(unix) {
  const jd = unix / 86400 + 2440587.5;
  const t = (jd - 2451545) / 36525;
  let s = -6.2e-6 * t * t * t + 0.093104 * t * t
    + (876600 * 3600 + 8640184.812866) * t + 67310.54841;
  s = (s * Math.PI / 180 / 240) % TWO_PI;
  return s < 0 ? s + TWO_PI : s;
}

if (typeof module !== 'undefined') module.exports = { SGP4, Observer, gmstFromUnix };
