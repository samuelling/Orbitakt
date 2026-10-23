const { makePlateIR } = require('../src/plate.js');
const sr = 48000, [L, R] = makePlateIR(sr);
const n = L.length;
// Schroeder backward integration -> decay curve -> RT60 from the -5..-25 dB slope (T20 x 3)
const edc = new Float64Array(n); let acc = 0;
for (let i = n - 1; i >= 0; i--) { acc += L[i] * L[i]; edc[i] = acc; }
const dB = i => 10 * Math.log10(edc[i] / edc[0]);
const at = d => { for (let i = 0; i < n; i++) if (dB(i) <= d) return i / sr; return NaN; };
const t5 = at(-5), t25 = at(-25);
console.log('IR %d samples (%s s); energy gain L=%s R=%s; RT60 (T20x3) = %s s', n, (n / sr).toFixed(2),
  Array.from(L).reduce((s, v) => s + v * v, 0).toFixed(3), Array.from(R).reduce((s, v) => s + v * v, 0).toFixed(3), ((t25 - t5) * 3).toFixed(2));
// Band energy over time windows (crude DFT bands via biquad-free approach: split by simple differencing)
const win = (a, b) => { // spectral centroid of a window by FFT-less zero-crossing proxy -> use DFT of 4096 samples
  const N = 4096, i0 = Math.floor(a * sr), re = new Float64Array(N / 2), im = new Float64Array(N / 2);
  let num = 0, den = 0;
  for (let k = 1; k < N / 2; k += 2) { // every other bin keeps this quick
    let sr_ = 0, si = 0;
    for (let i = 0; i < N; i++) { const w = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / N), x = L[i0 + i] * w; sr_ += x * Math.cos(2 * Math.PI * k * i / N); si -= x * Math.sin(2 * Math.PI * k * i / N); }
    const p = sr_ * sr_ + si * si, f = k * sr / N; num += f * p; den += p;
  }
  return num / den;
};
console.log('spectral centroid (Hz) of the IR at 0.05 s / 0.5 s / 1.0 s / 2.0 s:', [0.05, 0.5, 1.0, 2.0].map(t => Math.round(win(t, t + 0.1))).join(' / '));
// Correlation between L and R (should be ~0: wide, decorrelated)
let c = 0, l2 = 0, r2 = 0; for (let i = 0; i < n; i++) { c += L[i] * R[i]; l2 += L[i] ** 2; r2 += R[i] ** 2; }
console.log('L/R correlation: %s', (c / Math.sqrt(l2 * r2)).toFixed(4));
