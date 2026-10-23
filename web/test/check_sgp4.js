// Compare the JS SGP4 port with reference positions from the Python sgp4 package.
const fs = require('fs');
const { SGP4, Observer, gmstFromUnix } = require('../src/sgp4.js');
const rows = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const out = [0, 0, 0];
const stats = { near: { n: 0, maxKm: 0, maxMin: 0, byT: {} }, high: { n: 0, maxKm: 0, maxDeg: 0, byT: {} } };
let parseFail = 0, usableFalse = 0, modelFail = 0;
for (const row of rows) {
  const s = SGP4.fromLines(row.l1, row.l2);
  if (!s) { parseFail++; continue; }
  if (!s.isUsable) { usableFalse++; continue; }
  const cat = s.periodMinutes < 225 ? 'near' : 'high';
  for (const p of row.pts) {
    if (!s.positionMinutes(p.min, out)) { modelFail++; continue; }
    const dx = out[0] - p.r[0], dy = out[1] - p.r[1], dz = out[2] - p.r[2];
    const km = Math.hypot(dx, dy, dz);
    const rr = Math.hypot(...p.r);
    const st = stats[cat];
    st.n++;
    if (km > st.maxKm) { st.maxKm = km; st.maxMin = p.min; }
    st.byT[p.min] = Math.max(st.byT[p.min] || 0, km);
    if (cat === 'high') st.maxDeg = Math.max(st.maxDeg, Math.atan2(km, rr) * 180 / Math.PI);
  }
}
console.log('rows', rows.length, 'parseFail', parseFail, 'notUsable(skipped)', usableFalse, 'modelFail', modelFail);
console.log('near-Earth: n=%d  max error %s km (at +%s min)', stats.near.n, stats.near.maxKm.toExponential(2), stats.near.maxMin);
console.log('  max error by minutes-after-epoch:', Object.entries(stats.near.byT).map(([t, v]) => t + ':' + v.toExponential(1)).join('  '));
console.log('high orbit: n=%d  max error %s km, = %s deg from geocenter', stats.high.n, stats.high.maxKm.toFixed(2), stats.high.maxDeg.toFixed(4));
console.log('  max error by minutes-after-epoch:', Object.entries(stats.high.byT).map(([t, v]) => t + ':' + v.toFixed(2)).join('  '));

// Sidereal time against the reference's gstime (they use different formulas of equal vintage)
let gmax = 0;
for (const row of rows.slice(0, 200)) for (const p of row.pts) {
  const unix = (row.epoch_jd + p.min / 1440 - 2440587.5) * 86400;
  let d = Math.abs(gmstFromUnix(unix) - p.gst);
  d = Math.min(d, 2 * Math.PI - d);
  gmax = Math.max(gmax, d);
}
console.log('GMST max difference vs reference gstime: %s rad (= %s deg)', gmax.toExponential(2), (gmax * 180 / Math.PI).toExponential(2));
