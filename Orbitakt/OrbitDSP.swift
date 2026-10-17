import Foundation

/// Control surface between the main thread and the audio thread. Plain Float stores, no
/// locks, no allocation on the audio thread (the same scheme as Aether and Bellweathered).
///
/// Patterns are written into a *pending* slot per track; the audio thread adopts a track's
/// pending pattern only when that track wraps to step 1, so changes always land on its bar line.
final class OrbitParams {
    static let tracks = 4
    static let maxSteps = 32
    static let pingSlots = 4

    enum G: Int, CaseIterable {
        case master, run, bpm, swing, sendLevel
        case gongTrig, gongFreq, gongVel, gongPan
        case globalStep          // readback
        case pingCount, gongCount // readback
    }

    // Pending patterns (main writes)
    let pHit: UnsafeMutablePointer<Float>      // tracks × maxSteps, 0/1
    let pVel: UnsafeMutablePointer<Float>
    let pPan: UnsafeMutablePointer<Float>
    let pFreq: UnsafeMutablePointer<Float>
    let pLen: UnsafeMutablePointer<Float>      // per track
    let pGen: UnsafeMutablePointer<Float>      // per track; bump after writing a pattern
    let mute: UnsafeMutablePointer<Float>
    let level: UnsafeMutablePointer<Float>
    let bright: UnsafeMutablePointer<Float>    // per track tone (0…1)

    // Zenith pings (main writes freq/vel/pan, then bumps trig)
    let evTrig: UnsafeMutablePointer<Float>
    let evFreq: UnsafeMutablePointer<Float>
    let evVel: UnsafeMutablePointer<Float>
    let evPan: UnsafeMutablePointer<Float>

    // Readback (audio writes)
    let curStep: UnsafeMutablePointer<Float>   // per track: the step just played
    let hitCount: UnsafeMutablePointer<Float>  // per track: increments on every hit

    private let g: UnsafeMutablePointer<Float>

    init() {
        func make(_ v: Float, _ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: v, count: n)
            return p
        }
        let T = OrbitParams.tracks, S = OrbitParams.maxSteps, E = OrbitParams.pingSlots
        pHit = make(0, T * S); pVel = make(0.7, T * S); pPan = make(0, T * S); pFreq = make(110, T * S)
        pLen = make(16, T); pGen = make(0, T); mute = make(0, T); level = make(1, T); bright = make(0.5, T)
        evTrig = make(0, E); evFreq = make(880, E); evVel = make(0.7, E); evPan = make(0, E)
        curStep = make(0, T); hitCount = make(0, T)
        g = make(0, G.allCases.count)
        g[G.bpm.rawValue] = 84
        g[G.sendLevel.rawValue] = 1
        g[G.gongFreq.rawValue] = 98
    }

    subscript(_ k: G) -> Float {
        get { g[k.rawValue] }
        set { g[k.rawValue] = newValue }
    }

    deinit {
        [pHit, pVel, pPan, pFreq, pLen, pGen, mute, level, bright,
         evTrig, evFreq, evVel, evPan, curStep, hitCount, g].forEach { $0.deallocate() }
    }
}

/// The kit, synthesized: every sound is one "modal" voice — up to three decaying sine
/// partials with a pitch sweep, plus filtered noise — with different recipes:
///
///  • NAV kick: a sine swept down onto the root, with a felt click
///  • LEO rim: three short inharmonic partials and a band of noise (a brushed woodblock)
///  • SWARM shaker: high-passed noise grains, brighter for higher satellites
///  • BELT tom: a tuned membrane (modes 1, 1.59, 2.14) on the scale
///  • zenith ping: a glass bar (1, 2.76, 5.40), mostly into the echoes
///  • CREW gong: slow-struck inharmonic partials with long tails
///
/// The sequencer runs here, on the audio thread, so hits land on the exact sample.
/// Two outputs: dry, and a send bus that the engine feeds through delay and reverb.
final class OrbitDSP {
    private let sr: Float
    private let p: OrbitParams
    private var rng: UInt32 = 0x2545_F491

    private static let tableSize = 4096
    private let sine: UnsafeMutablePointer<Float>

    // Sequencer state
    private let hit: UnsafeMutablePointer<Float>
    private let vel: UnsafeMutablePointer<Float>
    private let pan: UnsafeMutablePointer<Float>
    private let freq: UnsafeMutablePointer<Float>
    private var len = [Int](repeating: 16, count: OrbitParams.tracks)
    private var gen = [Float](repeating: -1, count: OrbitParams.tracks)
    private var step = [Int](repeating: 0, count: OrbitParams.tracks)
    private var lastEv = [Float](repeating: 0, count: OrbitParams.pingSlots)
    private var lastGong: Float = 0
    private var running = false
    private var toTick: Double = 0
    private var globalStep = 0
    private var bpm: Float = 84

    // Voices: per-voice scalars in strided blocks
    private static let voices = 24
    private enum VS: Int, CaseIterable {
        case on, age, atk, amp, gl, gr, send
        case ph1, ph2, ph3, inc1, inc2, inc3, g1, g2, g3, m1, m2, m3
        case penv, pmul, pdepth
        case na, nmul, hp, fa1, fa2, fa3, fk, ic1, ic2
    }
    private let vs: UnsafeMutablePointer<Float>
    private var voiceRR = 0

    // Send bus, rendered with the dry bus and handed to the second source node
    static let maxFrames = 8192
    private let sendL: UnsafeMutablePointer<Float>
    private let sendR: UnsafeMutablePointer<Float>
    private var sendFrames = 0
    private var master: Float = 0
    private var sendLevel: Float = 1

    init(sampleRate: Float, params: OrbitParams) {
        sr = sampleRate
        p = params
        func make(_ v: Float, _ n: Int) -> UnsafeMutablePointer<Float> {
            let q = UnsafeMutablePointer<Float>.allocate(capacity: n)
            q.initialize(repeating: v, count: n)
            return q
        }
        let n = OrbitDSP.tableSize
        sine = make(0, n + 1)
        for i in 0...n { sine[i] = sinf(2 * Float.pi * Float(i) / Float(n)) }
        let TS = OrbitParams.tracks * OrbitParams.maxSteps
        hit = make(0, TS); vel = make(0, TS); pan = make(0, TS); freq = make(110, TS)
        vs = make(0, VS.allCases.count * OrbitDSP.voices)
        sendL = make(0, OrbitDSP.maxFrames)
        sendR = make(0, OrbitDSP.maxFrames)
    }

    deinit {
        [sine, hit, vel, pan, freq, vs, sendL, sendR].forEach { $0.deallocate() }
    }

    // MARK: Helpers

    @inline(__always) private func sn(_ ph: Float) -> Float {
        let x = ph * Float(OrbitDSP.tableSize)
        let i = min(max(Int(x), 0), OrbitDSP.tableSize - 1)
        let f = x - Float(i)
        return sine[i] + (sine[i + 1] - sine[i]) * f
    }

    @inline(__always) private func white() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng >> 8) / 8_388_608 - 1
    }

    @inline(__always) private func at(_ k: VS, _ v: Int) -> Int { k.rawValue * OrbitDSP.voices + v }

    // MARK: Note-on

    private enum Kind { case kick, rim, shaker, tom, ping, gong }

    private struct Recipe {
        var r1: Float = 1, r2: Float = 0, r3: Float = 0
        var a1: Float = 1, a2: Float = 0, a3: Float = 0
        var t1: Float = 0.3, t2: Float = 0.1, t3: Float = 0.1
        var pdepth: Float = 0, ptau: Float = 0.05
        var na: Float = 0, ntau: Float = 0.05, nfc: Float = 2000, nq: Float = 1, highpass = false
        var atk: Float = 0.001, gain: Float = 0.5, send: Float = 0.3
    }

    private func recipe(_ kind: Kind, f: Float, vel: Float, bright: Float) -> Recipe {
        var r = Recipe()
        switch kind {
        case .kick:
            r.r2 = 2; r.a2 = 0.08; r.t1 = 0.16 + 0.14 * vel; r.t2 = 0.06
            r.pdepth = 2.2; r.ptau = 0.028
            r.na = 0.22; r.ntau = 0.004; r.nfc = 2500; r.nq = 0.8
            r.atk = 0.0015; r.gain = 0.95; r.send = 0.05
        case .rim:
            r.r2 = 1.48; r.r3 = 2.21; r.a1 = 0.6; r.a2 = 0.35; r.a3 = 0.2
            r.t1 = 0.045; r.t2 = 0.03; r.t3 = 0.018
            r.pdepth = 0.05; r.ptau = 0.01
            r.na = 0.55; r.ntau = 0.05; r.nfc = 1800 + 1400 * bright; r.nq = 1.4
            r.atk = 0.001; r.gain = 0.55; r.send = 0.3
        case .shaker:
            r.a1 = 0
            r.na = 1; r.ntau = 0.016 + 0.045 * vel; r.nfc = 5500 + 4000 * bright; r.nq = 0.7
            r.highpass = true
            r.atk = 0.004; r.gain = 0.3; r.send = 0.28
        case .tom:
            r.r2 = 1.59; r.r3 = 2.14; r.a2 = 0.35; r.a3 = 0.15
            r.t1 = 0.35 + 0.3 * vel; r.t2 = 0.2; r.t3 = 0.09
            r.pdepth = 0.16; r.ptau = 0.06
            r.na = 0.08; r.ntau = 0.015; r.nfc = f * 3; r.nq = 1
            r.atk = 0.002; r.gain = 0.5; r.send = 0.5
        case .ping:
            r.r2 = 2.76; r.r3 = 5.40; r.a2 = 0.3; r.a3 = 0.1
            r.t1 = 1.4; r.t2 = 0.45; r.t3 = 0.12
            r.atk = 0.0015; r.gain = 0.22; r.send = 0.9
        case .gong:
            r.r2 = 1.47; r.r3 = 2.09; r.a2 = 0.55; r.a3 = 0.35
            r.t1 = 4.0; r.t2 = 2.6; r.t3 = 1.6
            r.pdepth = 0.015; r.ptau = 1.2
            r.na = 0.05; r.ntau = 0.2; r.nfc = f * 4; r.nq = 1.5
            r.atk = 0.05; r.gain = 0.32; r.send = 0.85
        }
        return r
    }

    private func trigger(_ kind: Kind, f: Float, vel: Float, pan pn: Float, bright: Float) {
        // A free voice, else the oldest
        let V = OrbitDSP.voices
        var v = -1
        for i in 0..<V where vs[at(.on, (voiceRR + i) % V)] < 0.5 { v = (voiceRR + i) % V; break }
        if v < 0 {
            var oldest: Float = -1
            for i in 0..<V where vs[at(.age, i)] > oldest { oldest = vs[at(.age, i)]; v = i }
        }
        voiceRR = (v + 1) % V
        let r = recipe(kind, f: max(20, f), vel: vel, bright: bright)
        func set(_ k: VS, _ x: Float) { vs[at(k, v)] = x }
        func dec(_ tau: Float) -> Float { expf(-1 / (max(0.001, tau) * sr)) }
        let ang = (max(-1, min(1, pn)) + 1) * Float.pi / 4
        set(.on, 1); set(.age, 0); set(.atk, max(1, r.atk * sr))
        set(.amp, r.gain * max(0, min(1.2, vel)))
        set(.gl, cosf(ang)); set(.gr, sinf(ang)); set(.send, r.send)
        let i1 = f * r.r1 / sr, i2 = f * r.r2 / sr, i3 = f * r.r3 / sr
        set(.inc1, i1); set(.inc2, i2); set(.inc3, i3)
        // Partials above ~0.45·sr (allowing for the pitch sweep) are left out
        let top = 0.45 / (1 + r.pdepth)
        set(.g1, i1 < top ? r.a1 : 0); set(.g2, i2 < top ? r.a2 : 0); set(.g3, i3 < top ? r.a3 : 0)
        set(.m1, dec(r.t1)); set(.m2, dec(r.t2)); set(.m3, dec(r.t3))
        set(.ph1, 0); set(.ph2, 0.25); set(.ph3, 0.5)
        set(.penv, 1); set(.pmul, dec(r.ptau)); set(.pdepth, r.pdepth)
        set(.na, r.na); set(.nmul, dec(r.ntau)); set(.hp, r.highpass ? 1 : 0)
        let k = 1 / max(0.5, r.nq)
        let gg = tanf(Float.pi * min(max(r.nfc, 40), sr * 0.45) / sr)
        let a1 = 1 / (1 + gg * (gg + k))
        set(.fa1, a1); set(.fa2, gg * a1); set(.fa3, gg * gg * a1); set(.fk, k)
        set(.ic1, 0); set(.ic2, 0)
    }

    // MARK: Sequencer

    private func adopt(_ t: Int) {
        let S = OrbitParams.maxSteps
        for s in 0..<S {
            hit[t * S + s] = p.pHit[t * S + s]
            vel[t * S + s] = p.pVel[t * S + s]
            pan[t * S + s] = p.pPan[t * S + s]
            freq[t * S + s] = p.pFreq[t * S + s]
        }
        len[t] = max(1, min(S, Int(p.pLen[t])))
        gen[t] = p.pGen[t]
    }

    @inline(__always) private static func kind(track t: Int) -> Kind {
        switch t {
        case 0: return .kick
        case 1: return .rim
        case 2: return .shaker
        default: return .tom
        }
    }

    private func tick() {
        let S = OrbitParams.maxSteps
        for t in 0..<OrbitParams.tracks {
            if step[t] == 0 && p.pGen[t] != gen[t] { adopt(t) }
            let s = step[t]
            let i = t * S + s
            if hit[i] > 0.5 && p.mute[t] < 0.5 {
                trigger(OrbitDSP.kind(track: t), f: freq[i], vel: vel[i] * p.level[t], pan: pan[i], bright: p.bright[t])
                p.hitCount[t] += 1
            }
            p.curStep[t] = Float(s)
            step[t] = (s + 1) % len[t]
        }
        for e in 0..<OrbitParams.pingSlots where p.evTrig[e] != lastEv[e] {
            lastEv[e] = p.evTrig[e]
            trigger(.ping, f: p.evFreq[e], vel: p.evVel[e], pan: p.evPan[e], bright: 0.5)
            p[.pingCount] += 1
        }
        if p[.gongTrig] != lastGong {
            lastGong = p[.gongTrig]
            trigger(.gong, f: p[.gongFreq], vel: p[.gongVel], pan: p[.gongPan], bright: 0.5)
            p[.gongCount] += 1
        }
        globalStep += 1
        p[.globalStep] = Float(globalStep)
    }

    /// Samples from one sixteenth to the next, with swing on the off-beats.
    private func interval() -> Double {
        let spb = Double(sr) * 60 / Double(max(30, bpm)) / 4
        let sw = Double(max(0, min(0.4, p[.swing])))
        return globalStep % 2 == 1 ? spb * (1 + sw) : spb * (1 - sw)
    }

    // MARK: Render

    private func renderVoices(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>,
                              from o: Int, count m: Int) {
        let V = OrbitDSP.voices
        for v in 0..<V where vs[at(.on, v)] > 0.5 {
            var age = vs[at(.age, v)]
            let atk = vs[at(.atk, v)], amp = vs[at(.amp, v)]
            let gl = vs[at(.gl, v)] * amp, gr = vs[at(.gr, v)] * amp
            let snd = vs[at(.send, v)]
            var ph1 = vs[at(.ph1, v)], ph2 = vs[at(.ph2, v)], ph3 = vs[at(.ph3, v)]
            let inc1 = vs[at(.inc1, v)], inc2 = vs[at(.inc2, v)], inc3 = vs[at(.inc3, v)]
            var g1 = vs[at(.g1, v)], g2 = vs[at(.g2, v)], g3 = vs[at(.g3, v)]
            let m1 = vs[at(.m1, v)], m2 = vs[at(.m2, v)], m3 = vs[at(.m3, v)]
            var penv = vs[at(.penv, v)]
            let pmul = vs[at(.pmul, v)], pdepth = vs[at(.pdepth, v)]
            var na = vs[at(.na, v)]
            let nmul = vs[at(.nmul, v)], hp = vs[at(.hp, v)] > 0.5
            let fa1 = vs[at(.fa1, v)], fa2 = vs[at(.fa2, v)], fa3 = vs[at(.fa3, v)], fk = vs[at(.fk, v)]
            var ic1 = vs[at(.ic1, v)], ic2 = vs[at(.ic2, v)]
            let noisy = na > 1e-5
            for i in o..<(o + m) {
                let pm = 1 + pdepth * penv
                penv *= pmul
                var x = g1 * sn(ph1) + g2 * sn(ph2) + g3 * sn(ph3)
                ph1 += inc1 * pm; if ph1 >= 1 { ph1 -= floorf(ph1) }
                ph2 += inc2 * pm; if ph2 >= 1 { ph2 -= floorf(ph2) }
                ph3 += inc3 * pm; if ph3 >= 1 { ph3 -= floorf(ph3) }
                g1 *= m1; g2 *= m2; g3 *= m3
                if noisy {
                    let w = white()
                    let v3 = w - ic2
                    let v1 = fa1 * ic1 + fa2 * v3
                    let v2 = ic2 + fa2 * ic1 + fa3 * v3
                    ic1 = 2 * v1 - ic1
                    ic2 = 2 * v2 - ic2
                    x += (hp ? (w - fk * v1 - v2) : v1) * na
                    na *= nmul
                }
                let env: Float = age < atk ? age / atk : 1
                age += 1
                let y = x * env
                L[i] += y * gl
                R[i] += y * gr
                sendL[i] += y * gl * snd
                sendR[i] += y * gr * snd
            }
            vs[at(.age, v)] = age
            vs[at(.ph1, v)] = ph1; vs[at(.ph2, v)] = ph2; vs[at(.ph3, v)] = ph3
            vs[at(.g1, v)] = g1; vs[at(.g2, v)] = g2; vs[at(.g3, v)] = g3
            vs[at(.penv, v)] = penv; vs[at(.na, v)] = na
            vs[at(.ic1, v)] = abs(ic1) < 1e-15 ? 0 : ic1
            vs[at(.ic2, v)] = abs(ic2) < 1e-15 ? 0 : ic2
            if age > atk && g1 + g2 + g3 + na < 1e-4 { vs[at(.on, v)] = 0 }
        }
    }

    /// Render the dry bus into L/R, and the send bus into the internal buffer for `copySend`.
    func render(frames n0: Int, left L: UnsafeMutablePointer<Float>, right R: UnsafeMutablePointer<Float>) {
        guard n0 > 0 else { return }
        L.update(repeating: 0, count: n0)
        R.update(repeating: 0, count: n0)
        let n = min(n0, OrbitDSP.maxFrames)
        sendL.update(repeating: 0, count: n)
        sendR.update(repeating: 0, count: n)
        let bt = Float(n) / sr
        bpm += (p[.bpm] - bpm) * (1 - expf(-bt / 0.4))

        // Transport
        let wantRun = p[.run] > 0.5
        if wantRun && !running {
            running = true
            for t in 0..<OrbitParams.tracks { step[t] = 0; adopt(t) }
            globalStep = 0
            toTick = 0
        } else if !wantRun && running {
            running = false
        }

        var o = 0
        while o < n {
            if running && toTick <= 0 {
                tick()
                toTick += interval()
            }
            let m = running ? min(n - o, max(1, Int(toTick.rounded(.up)))) : n - o
            renderVoices(L, R, from: o, count: m)
            if running { toTick -= Double(m) }
            o += m
        }

        // Master: soft clip the dry bus; the send bus is returned as is
        let m0 = master
        master += (p[.master] - master) * (1 - expf(-bt / 0.6))
        let mInc = (master - m0) / Float(n)
        sendLevel += (p[.sendLevel] - sendLevel) * (1 - expf(-bt / 0.6))
        var mg = m0
        for i in 0..<n {
            mg += mInc
            L[i] = tanhf(L[i] * mg)
            R[i] = tanhf(R[i] * mg)
            sendL[i] *= mg * sendLevel
            sendR[i] *= mg * sendLevel
        }
        sendFrames = n
    }

    /// The send bus from the most recent `render`. Called from the second source node in the
    /// same render cycle (or, if that node is pulled first, it gets the previous cycle: one
    /// buffer of pre-delay on the echoes, which nobody can hear).
    func copySend(frames n: Int, left L: UnsafeMutablePointer<Float>, right R: UnsafeMutablePointer<Float>) {
        let k = min(n, sendFrames)
        if k > 0 {
            L.update(from: sendL, count: k)
            R.update(from: sendR, count: k)
        }
        if n > k {
            (L + k).update(repeating: 0, count: n - k)
            (R + k).update(repeating: 0, count: n - k)
        }
    }
}
