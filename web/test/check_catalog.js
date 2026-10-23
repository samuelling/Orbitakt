const fs = require('fs'), path = require('path');
global.SGP4 = require('../src/sgp4.js').SGP4;
const { Observer, gmstFromUnix } = require('../src/sgp4.js');
const C = require('../src/catalog.js');
const dir = process.argv[2];
let all = [];
for (const f of fs.readdirSync(dir).filter(f => f.endsWith('.tle'))) {
  const sats = C.parseTLE(fs.readFileSync(path.join(dir, f), 'utf8'));
  const c = [0, 0, 0, 0, 0, 0]; sats.forEach(s => c[s.fam]++);
  console.log(f.padEnd(16), String(sats.length).padStart(5), 'parsed   NAV', c[0], 'LEO', c[1], 'SWARM', c[2], 'BELT', c[3], 'CREW', c[4], 'OTHER', c[5]);
  all = all.concat(sats);
}
console.log('crew:', all.filter(s => s.fam === C.FAM.CREW).map(s => s.id + ' ' + s.name).join(' | '));
console.log('catalogNumber A0001 =', C.catalogNumber('A0001'), ' 25544 =', C.catalogNumber('25544'), ' "T0000" =', C.catalogNumber('T0000'));
console.log('classify checks:', C.classify('STARLINK-1234', 95, 0.001) === C.FAM.SWARM, C.classify('X', 718, 0.001) === C.FAM.NAV, C.classify('X', 1436, 0.0003) === C.FAM.BELT, C.classify('MOLNIYA', 718, 0.7) === C.FAM.OTHER, C.classify('X', 100, 0.0) === C.FAM.LEO);

const t0 = Date.now();
const sim = C.simulatedCatalog();
const c = [0, 0, 0, 0, 0, 0]; sim.forEach(s => c[s.fam]++);
console.log('simulated:', sim.length, 'satellites  NAV', c[0], 'LEO', c[1], 'SWARM', c[2], 'BELT', c[3], 'CREW', c[4], ' built in', Date.now() - t0, 'ms');

// Propagate the simulated sky for one observer, timed
const obs = new Observer(42.37, -71.18), r = [0, 0, 0], lk = [0, 0];
const now = Date.now() / 1000, g = gmstFromUnix(now);
let up = [0, 0, 0, 0, 0, 0];
const t1 = process.hrtime.bigint();
for (let rep = 0; rep < 20; rep++) {
  up = [0, 0, 0, 0, 0, 0];
  for (const s of sim) { if (!s.orbit.position(now, r)) continue; obs.look(r, g, lk); if (lk[1] > 0) up[s.fam]++; }
}
console.log('simulated sky above horizon: NAV', up[0], 'LEO', up[1], 'SWARM', up[2], 'BELT', up[3], 'CREW', up[4], '| propagate+look for', sim.length, 'sats:', (Number(process.hrtime.bigint() - t1) / 20 / 1e6).toFixed(2), 'ms');
// Real catalog subset timing + above-horizon at a location
const t2 = process.hrtime.bigint();
let n = 0;
for (let rep = 0; rep < 20; rep++) { n = 0; for (const s of all) { if (!s.orbit.position(now, r)) continue; obs.look(r, g, lk); if (lk[1] > 0) n++; } }
console.log('real subset (%d sats): %d above horizon, %s ms per pass', all.length, n, (Number(process.hrtime.bigint() - t2) / 20 / 1e6).toFixed(2));
