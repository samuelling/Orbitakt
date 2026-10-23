// Emit JS az/el for reference TEME positions (using the reference's gst) as JSON for pymap3d to check.
const fs = require('fs');
const { Observer } = require('../src/sgp4.js');
const rows = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const sites = [[42.37, -71.18], [-33.87, 151.21], [64.15, -21.94], [1.35, 103.82]];
const out = [];
for (const [lat, lon] of sites) {
  const obs = new Observer(lat, lon), lk = [0, 0];
  for (const row of rows.filter((_, i) => i % 7 === 0)) for (const p of row.pts) {
    obs.look(p.r, p.gst, lk);
    out.push({ lat, lon, r: p.r, gst: p.gst, az: lk[0], el: lk[1] });
  }
}
fs.writeFileSync(process.argv[3], JSON.stringify(out));
console.log(out.length, 'look samples');
