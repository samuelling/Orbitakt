'use strict';
/* A synthetic plate-reverb impulse response, for the browser's ConvolverNode.
 *
 * The iPhone app uses Apple's built-in plate preset; browsers have no such thing, so this
 * generates one: a dense burst of decorrelated noise (a plate has no discrete early
 * reflections) that blooms in over a few milliseconds, decays exponentially (RT60 about 2.2 s)
 * and darkens as it goes (the top end dies first, as in a real plate). The page follows the
 * convolver with a 320 Hz high-pass and a 6 kHz low-pass, as the iPhone app's plate return does.
 *
 * The level is set by PLATE_ENERGY, the energy gain of the impulse response (1 = a transient
 * keeps its energy, spread out in time). */

const PLATE = { rt60: 2.2, seconds: 2.8, energy: 2.0, bloom: 0.004, brightHz: 16000, darkHz: 2800, seed: 0x51A7E };

function makePlateIR(sampleRate, opts) {
  const o = Object.assign({}, PLATE, opts || {});
  const n = Math.floor(o.seconds * sampleRate);
  const chans = [new Float32Array(n), new Float32Array(n)];
  chans.forEach((ch, c) => {
    let s = (o.seed + c * 0x9E3779B1) >>> 0;
    const rnd = () => {   // xorshift32 -> [-1, 1)
      s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0;
      return s / 2147483648 - 1;
    };
    let lp = 0;
    for (let i = 0; i < n; i++) {
      const t = i / sampleRate;
      const env = (1 - Math.exp(-t / o.bloom)) * Math.exp(-t * 6.907755 / o.rt60);
      // The low-pass cutoff glides from bright to dark over the decay (log-spaced)
      const fc = o.brightHz * Math.pow(o.darkHz / o.brightHz, Math.min(1, t / o.rt60));
      const a = 1 - Math.exp(-2 * Math.PI * fc / sampleRate);
      lp += (rnd() - lp) * a;
      ch[i] = lp * env;
    }
  });
  // Normalize the energy gain (sum of squares, averaged over the two channels)
  let e = 0;
  for (const ch of chans) for (let i = 0; i < n; i++) e += ch[i] * ch[i];
  e /= 2;
  const g = Math.sqrt(o.energy / e);
  for (const ch of chans) for (let i = 0; i < n; i++) ch[i] *= g;
  return chans;
}

if (typeof module !== 'undefined') module.exports = { makePlateIR, PLATE };
