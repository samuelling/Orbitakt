/* Runs inside the AudioWorklet, after dsp.js (OrbitDSP) in the same module. */
class OrbitProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.dsp = new OrbitDSP(sampleRate);
    this.k = 0;
    this.port.onmessage = (e) => {
      const m = e.data, d = this.dsp;
      switch (m.type) {
        case 'set': d.setParam(m.k, m.v); break;
        case 'list': d.setList(m.t, m); break;
        case 'mute': d.setMute(m.t, m.v); break;
        case 'bright': d.setBright(m.t, m.v); break;
        case 'ping': d.ping(m.f, m.v, m.p); break;
        case 'gong': d.gong(m.f, m.v, m.p); break;
      }
    };
  }

  process(inputs, outputs) {
    const dry = outputs[0], send = outputs[1];
    if (!dry || dry.length < 2 || !send || send.length < 2) return true;
    const n = dry[0].length;
    this.dsp.render(n, dry[0], dry[1], send[0], send[1]);
    // Tell the page where the beam is, about every 20 ms
    if ((this.k++ & 7) === 0) {
      this.port.postMessage({ s: this.dsp.sweep, b: this.dsp.beats, r: this.dsp.running, t: currentTime });
    }
    return true;
  }
}
registerProcessor('orbitakt', OrbitProcessor);
