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
        case master, run, bpm, swing
        case dub            // base echo feedback, 0…0.9
        case throwAmt       // 0…1: how far the echo send is thrown open right now
        case reverbSend     // 0…1
        case dust           // 0…1
        case gongTrig, gongFreq, gongVel, gongPan
        case globalStep          // readback
        case pingCount, gongCount // readback
    }

    // Pending patterns (main writes)
    let pHit: UnsafeMutablePointer<Float>      // tracks × maxSteps: probability 0…1 (0 = rest)
    let pVel: UnsafeMutablePointer<Float>
    let pPan: UnsafeMutablePointer<Float>
    let pFreq: UnsafeMutablePointer<Float>
    let pC1: UnsafeMutablePointer<Float>       // chord ratios for the stab track
    let pC2: UnsafeMutablePointer<Float>
    let pC3: UnsafeMutablePointer<Float>
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
    let hitCount: UnsafeMutablePointer<Float>  // per track: increments on every hit that fired

    private let g: UnsafeMutablePointer<Float>

    init() {
        func make(_ v: Float, _ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: v, count: n)
            return p
        }
        let T = OrbitParams.tracks, S = OrbitParams.maxSteps, E = OrbitParams.pingSlots
        pHit = make(0, T * S); pVel = make(0.7, T * S); pPan = make(0, T * S); pFreq = make(110, T * S)
        pC1 = make(1.189, T * S); pC2 = make(1.498, T * S); pC3 = make(1.782, T * S)
        pLen = make(16, T); pGen = make(0, T); mute = make(0, T); level = make(1, T); bright = make(0.5, T)
        evTrig = make(0, E); evFreq = make(880, E); evVel = make(0.7, E); evPan = make(0, E)
        curStep = make(0, T); hitCount = make(0, T)
        g = make(0, G.allCases.count)
        g[G.bpm.rawValue] = 84
        g[G.dub.rawValue] = 0.55
        g[G.reverbSend.rawValue] = 0.6
        g[G.gongFreq.rawValue] = 98
    }

    subscript(_ k: G) -> Float {
        get { g[k.rawValue] }
        set { g[k.rawValue] = newValue }
    }

    deinit {
        [pHit, pVel, pPan, pFreq, pC1, pC2, pC3, pLen, pGen, mute, level, bright,
         evTrig, evFreq, evVel, evPan, curStep, hitCount, g].forEach { $0.deallocate() }
    }
}

/// The kit, synthesized in the spirit of a Machinedrum played through a dub desk.
///
/// Drums are one "modal" voice — up to three decaying sine partials with a pitch sweep,
/// plus filtered noise — with different recipes:
///  • NAV kick: a round sine dropping onto the root, a soft click, almost nothing to the echo
///  • LEO rimshot: a short tuned knock and a band of noise, mostly *into* the echo
///  • SWARM hat: three metallic partials over high-passed noise, tiny and bright
///  • zenith ping: a glass bar, almost all echo
///  • CREW gong: slow-struck inharmonic partials with long tails
/// and one chord voice:
///  • BELT stab: four detuned saws (a scale chord) through a resonant lowpass that snaps shut
///
/// The dub delay lives here too: a stereo ping-pong on a dotted eighth, high- and low-passed
/// and gently saturated in the loop, with a little tape wow. `dub` sets its feedback; `throwAmt`
/// opens the send and pushes the feedback toward a spiral, the way a dub engineer rides it.
///
/// The sequencer runs on the audio thread, so hits land on the exact sample. Each step holds a
/// probability (a Machinedrum-style trig condition) rather than a plain on/off.
///
/// Two outputs: dry (with the echoes in it), and a reverb send that the engine feeds through a
/// plate.
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
    private let c1: UnsafeMutablePointer<Float>
    private let c2: UnsafeMutablePointer<Float>
    private let c3: UnsafeMutablePointer<Float>
    private let len: UnsafeMutablePointer<Int>
    private let gen: UnsafeMutablePointer<Float>
    private let step: UnsafeMutablePointer<Int>
    private let lastEv: UnsafeMutablePointer<Float>
    private var lastGong: Float = 0
    private var running = false
    private var toTick: Double = 0
    private var globalStep = 0
    private var bpm: Float = 84

    // Drum voices: per-voice scalars in strided blocks
    private static let voices = 24
    private enum VS: Int, CaseIterable {
        case on, age, atk, amp, gl, gr, send
        case ph1, ph2, ph3, inc1, inc2, inc3, g1, g2, g3, m1, m2, m3
        case penv, pmul, pdepth
        case na, nmul, hp, fa1, fa2, fa3, fk, ic1, ic2
    }
    private let vs: UnsafeMutablePointer<Float>
    private var voiceRR = 0

    // Stab voices: four saws each
    private static let stabs = 4
    private static let stabOsc = 4
    private enum SS: Int, CaseIterable {
        case on, age, atk, amp, env, emul, cut, floor, cmul, gl, gr, send, ic1, ic2
    }
    private let ss: UnsafeMutablePointer<Float>
    private let sPh: UnsafeMutablePointer<Float>
    private let sInc: UnsafeMutablePointer<Float>
    private var stabRR = 0

    // Buses
    static let maxFrames = 8192
    private let sendL: UnsafeMutablePointer<Float>     // into the echo
    private let sendR: UnsafeMutablePointer<Float>
    private let verbL: UnsafeMutablePointer<Float>     // into the plate (handed to the engine)
    private let verbR: UnsafeMutablePointer<Float>
    private var verbFrames = 0
    private var master: Float = 0

    // Dub delay
    private let dlL: UnsafeMutablePointer<Float>
    private let dlR: UnsafeMutablePointer<Float>
    private let dlCap: Int
    private var dlW = 0
    private var dlTime: Float = 0            // samples, smoothed (tape-like glide on tempo changes)
    private var wowPh: Float = 0
    private var fb: Float = 0.55, inGain: Float = 0.55
    private var hpL: Float = 0, hpR: Float = 0, lpL: Float = 0, lpR: Float = 0
    private var reverbSend: Float = 0.6

    // Dust
    private var dust: Float = 0
    private var hissL: Float = 0, hissR: Float = 0
    private var crackle: Float = 0

    init(sampleRate: Float, params: OrbitParams) {
        sr = sampleRate
        p = params
        func make(_ v: Float, _ n: Int) -> UnsafeMutablePointer<Float> {
            let q = UnsafeMutablePointer<Float>.allocate(capacity: n)
            q.initialize(repeating: v, count: n)
            return q
        }
        func makeInt(_ v: Int, _ n: Int) -> UnsafeMutablePointer<Int> {
            let q = UnsafeMutablePointer<Int>.allocate(capacity: n)
            q.initialize(repeating: v, count: n)
            return q
        }
        let n = OrbitDSP.tableSize
        sine = make(0, n + 1)
        for i in 0...n { sine[i] = sinf(2 * Float.pi * Float(i) / Float(n)) }
        let T = OrbitParams.tracks
        let TS = T * OrbitParams.maxSteps
        hit = make(0, TS); vel = make(0, TS); pan = make(0, TS); freq = make(110, TS)
        c1 = make(1, TS); c2 = make(1, TS); c3 = make(1, TS)
        len = makeInt(16, T); gen = make(-1, T); step = makeInt(0, T)
        lastEv = make(0, OrbitParams.pingSlots)
        vs = make(0, VS.allCases.count * OrbitDSP.voices)
        ss = make(0, SS.allCases.count * OrbitDSP.stabs)
        sPh = make(0, OrbitDSP.stabs * OrbitDSP.stabOsc)
        sInc = make(0, OrbitDSP.stabs * OrbitDSP.stabOsc)
        sendL = make(0, OrbitDSP.maxFrames); sendR = make(0, OrbitDSP.maxFrames)
        verbL = make(0, OrbitDSP.maxFrames); verbR = make(0, OrbitDSP.maxFrames)
        dlCap = Int(2.6 * sampleRate) + 8
        dlL = make(0, dlCap); dlR = make(0, dlCap)
        dlTime = 0.5 * sampleRate
    }

    deinit {
        [sine, hit, vel, pan, freq, c1, c2, c3, gen, lastEv, vs, ss, sPh, sInc,
         sendL, sendR, verbL, verbR, dlL, dlR].forEach { $0.deallocate() }
        len.deallocate()
        step.deallocate()
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

    @inline(__always) private func rand01() -> Float { 0.5 * (white() + 1) }

    @inline(__always) private func at(_ k: VS, _ v: Int) -> Int { k.rawValue * OrbitDSP.voices + v }
    @inline(__always) private func st(_ k: SS, _ v: Int) -> Int { k.rawValue * OrbitDSP.stabs + v }

    @inline(__always) private func polyBlep(_ t: Float, _ dt: Float) -> Float {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    // MARK: Drum note-on

    private enum Kind { case kick, rim, hat, ping, gong }

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
            // Round and short-attacked, like a Machinedrum EFM kick with the decay up
            r.r2 = 2; r.a2 = 0.05; r.t1 = 0.13 + 0.09 * vel; r.t2 = 0.04
            r.pdepth = 3.0; r.ptau = 0.018
            r.na = 0.10; r.ntau = 0.003; r.nfc = 3200; r.nq = 0.8
            r.atk = 0.002; r.gain = 0.75; r.send = 0.03
        case .rim:
            // A tuned rimshot: short knock, a bandpassed tick, mostly thrown into the echo
            r.r2 = 1.48; r.a1 = 0.65; r.a2 = 0.3
            r.t1 = 0.028; r.t2 = 0.016
            r.pdepth = 0.04; r.ptau = 0.008
            r.na = 0.45; r.ntau = 0.012; r.nfc = f * 1.15; r.nq = 2.2
            r.atk = 0.0008; r.gain = 0.6; r.send = 0.9
        case .hat:
            // Metallic partials over high-passed noise; brighter for a busier Starlink sky
            r.r2 = 1.342; r.r3 = 1.791
            r.a1 = 0.22; r.a2 = 0.18; r.a3 = 0.14
            r.t1 = 0.022 + 0.02 * vel; r.t2 = 0.018; r.t3 = 0.014
            r.na = 0.75; r.ntau = 0.014 + 0.03 * vel; r.nfc = 6500 + 2500 * bright; r.nq = 0.7
            r.highpass = true
            r.atk = 0.0012; r.gain = 0.3; r.send = 0.35
        case .ping:
            r.r2 = 2.76; r.r3 = 5.40; r.a2 = 0.3; r.a3 = 0.1
            r.t1 = 1.2; r.t2 = 0.4; r.t3 = 0.1
            r.atk = 0.0015; r.gain = 0.16; r.send = 1.0
        case .gong:
            r.r2 = 1.47; r.r3 = 2.09; r.a2 = 0.55; r.a3 = 0.35
            r.t1 = 4.0; r.t2 = 2.6; r.t3 = 1.6
            r.pdepth = 0.015; r.ptau = 1.2
            r.na = 0.04; r.ntau = 0.2; r.nfc = f * 4; r.nq = 1.5
            r.atk = 0.06; r.gain = 0.22; r.send = 0.85
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

    // MARK: Stab note-on

    private func triggerStab(f: Float, r1: Float, r2: Float, r3: Float, vel: Float, pan pn: Float, bright: Float) {
        let V = OrbitDSP.stabs
        var v = -1
        for i in 0..<V where ss[st(.on, (stabRR + i) % V)] < 0.5 { v = (stabRR + i) % V; break }
        if v < 0 {
            var oldest: Float = -1
            for i in 0..<V where ss[st(.age, i)] > oldest { oldest = ss[st(.age, i)]; v = i }
        }
        stabRR = (v + 1) % V
        func set(_ k: SS, _ x: Float) { ss[st(k, v)] = x }
        func dec(_ tau: Float) -> Float { expf(-1 / (max(0.001, tau) * sr)) }
        let vv = max(0, min(1.2, vel))
        let ang = (max(-1, min(1, pn)) + 1) * Float.pi / 4
        set(.on, 1); set(.age, 0); set(.atk, 0.004 * sr)
        set(.amp, 0.5 * vv); set(.env, 0); set(.emul, dec(0.17 + 0.12 * vv))
        // The filter opens on the hit and snaps shut, like a dub-techno chord
        set(.cut, 450 + (1400 + 1600 * bright) * vv); set(.floor, 230); set(.cmul, dec(0.085))
        set(.gl, cosf(ang)); set(.gr, sinf(ang)); set(.send, 0.95)
        set(.ic1, 0); set(.ic2, 0)
        // Root, then the three chord tones, each slightly detuned
        let O = OrbitDSP.stabOsc, f0 = max(20, f)
        sInc[v * O] = min(0.45, f0 * (1 - 0.0045) / sr)
        sInc[v * O + 1] = min(0.45, f0 * r1 * (1 + 0.0032) / sr)
        sInc[v * O + 2] = min(0.45, f0 * r2 * (1 - 0.0021) / sr)
        sInc[v * O + 3] = min(0.45, f0 * r3 * (1 + 0.0051) / sr)
        for o in 0..<O { sPh[v * O + o] = rand01() }
    }

    // MARK: Sequencer

    private func adopt(_ t: Int) {
        let S = OrbitParams.maxSteps
        for s in 0..<S {
            let i = t * S + s
            hit[i] = p.pHit[i]; vel[i] = p.pVel[i]; pan[i] = p.pPan[i]; freq[i] = p.pFreq[i]
            c1[i] = p.pC1[i]; c2[i] = p.pC2[i]; c3[i] = p.pC3[i]
        }
        len[t] = max(1, min(S, Int(p.pLen[t])))
        gen[t] = p.pGen[t]
    }

    private func tick() {
        let S = OrbitParams.maxSteps
        for t in 0..<OrbitParams.tracks {
            if step[t] == 0 && p.pGen[t] != gen[t] { adopt(t) }
            let s = step[t]
            let i = t * S + s
            let prob = hit[i]
            if prob > 0 && p.mute[t] < 0.5 && rand01() < prob {
                let v = vel[i] * p.level[t]
                switch t {
                case 0: trigger(.kick, f: freq[i], vel: v, pan: pan[i], bright: p.bright[t])
                case 1: trigger(.rim, f: freq[i], vel: v, pan: pan[i], bright: p.bright[t])
                case 2: trigger(.hat, f: freq[i], vel: v, pan: pan[i], bright: p.bright[t])
                default: triggerStab(f: freq[i], r1: c1[i], r2: c2[i], r3: c3[i], vel: v, pan: pan[i],
                                     bright: p.bright[t])
                }
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

    // MARK: Render: voices

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

        // Stabs: four saws → resonant lowpass (coefficients updated every 16 samples)
        let O = OrbitDSP.stabOsc
        for v in 0..<OrbitDSP.stabs where ss[st(.on, v)] > 0.5 {
            var age = ss[st(.age, v)], env = ss[st(.env, v)]
            let atk = max(1, ss[st(.atk, v)]), emul = ss[st(.emul, v)]
            var cut = ss[st(.cut, v)]
            let floorHz = ss[st(.floor, v)], cmul = ss[st(.cmul, v)]
            let amp = ss[st(.amp, v)]
            let gl = ss[st(.gl, v)] * amp, gr = ss[st(.gr, v)] * amp, snd = ss[st(.send, v)]
            var ic1 = ss[st(.ic1, v)], ic2 = ss[st(.ic2, v)]
            let k: Float = 0.62
            var ph0 = sPh[v * O], ph1 = sPh[v * O + 1], ph2 = sPh[v * O + 2], ph3 = sPh[v * O + 3]
            let i0 = sInc[v * O], i1 = sInc[v * O + 1], i2 = sInc[v * O + 2], i3 = sInc[v * O + 3]
            var a1: Float = 0, a2: Float = 0, a3: Float = 0
            let cmul16 = powf(cmul, 16)
            var j = 0
            for i in o..<(o + m) {
                if j & 15 == 0 {
                    let gg = tanf(Float.pi * min(max(cut, 40), sr * 0.45) / sr)
                    a1 = 1 / (1 + gg * (gg + k)); a2 = gg * a1; a3 = gg * a2
                    cut = floorHz + (cut - floorHz) * cmul16
                }
                j += 1
                var x = 2 * ph0 - 1 - polyBlep(ph0, i0)
                x += 2 * ph1 - 1 - polyBlep(ph1, i1)
                x += 2 * ph2 - 1 - polyBlep(ph2, i2)
                x += 2 * ph3 - 1 - polyBlep(ph3, i3)
                ph0 += i0; if ph0 >= 1 { ph0 -= 1 }
                ph1 += i1; if ph1 >= 1 { ph1 -= 1 }
                ph2 += i2; if ph2 >= 1 { ph2 -= 1 }
                ph3 += i3; if ph3 >= 1 { ph3 -= 1 }
                let v3 = x * 0.25 - ic2
                let v1 = a1 * ic1 + a2 * v3
                let v2 = ic2 + a2 * ic1 + a3 * v3
                ic1 = 2 * v1 - ic1
                ic2 = 2 * v2 - ic2
                if age < atk { env = age / atk } else { env *= emul }
                age += 1
                let y = v2 * env
                L[i] += y * gl
                R[i] += y * gr
                sendL[i] += y * gl * snd
                sendR[i] += y * gr * snd
            }
            sPh[v * O] = ph0; sPh[v * O + 1] = ph1; sPh[v * O + 2] = ph2; sPh[v * O + 3] = ph3
            ss[st(.age, v)] = age; ss[st(.env, v)] = env; ss[st(.cut, v)] = cut
            ss[st(.ic1, v)] = abs(ic1) < 1e-15 ? 0 : ic1
            ss[st(.ic2, v)] = abs(ic2) < 1e-15 ? 0 : ic2
            if age > atk && env < 1e-4 { ss[st(.on, v)] = 0 }
        }
    }

    // MARK: Render: the dub delay and dust

    @inline(__always) private func readDelay(_ buf: UnsafeMutablePointer<Float>, _ d: Float) -> Float {
        var r = Float(dlW) - d
        while r < 0 { r += Float(dlCap) }
        let i = Int(r)
        let f = r - Float(i)
        let a = buf[i % dlCap], b = buf[(i + 1) % dlCap]
        return a + (b - a) * f
    }

    private func renderDub(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, count n: Int) {
        let bt = Float(n) / sr
        // Dotted eighth; the time glides (pitching the echoes a little, like tape) when tempo moves
        let target = min(Float(dlCap - 4), 60 / max(30, bpm) * 0.75 * sr)
        dlTime += (target - dlTime) * (1 - expf(-bt / 1.2))
        let thr = max(0, min(1, p[.throwAmt]))
        let fbT = min(0.93, max(0, p[.dub]) + 0.28 * thr)
        let inT = 0.5 + 0.9 * thr
        let fb0 = fb, in0 = inGain
        fb += (fbT - fb) * (1 - expf(-bt / 0.25))
        inGain += (inT - inGain) * (1 - expf(-bt / 0.05))
        let fbInc = (fb - fb0) / Float(n), inInc = (inGain - in0) / Float(n)
        reverbSend += (p[.reverbSend] - reverbSend) * (1 - expf(-bt / 0.5))
        let hpA = 1 - expf(-2 * Float.pi * 220 / sr)
        let lpA = 1 - expf(-2 * Float.pi * 2600 / sr)
        let wowInc = 0.33 / sr
        var f = fb0, g = in0
        let dWet: Float = 0.8
        for i in 0..<n {
            f += fbInc; g += inInc
            wowPh += wowInc; if wowPh >= 1 { wowPh -= 1 }
            let d = dlTime * (1 + 0.0018 * sn(wowPh))
            let yL = readDelay(dlL, d), yR = readDelay(dlR, d)
            // Ping-pong: the input enters left, each side feeds the other
            let inp = (sendL[i] + sendR[i]) * 0.5 * g
            var xL = inp + f * yR
            var xR = f * yL
            // Band-limit and saturate the loop so repeats get darker and rounder
            hpL += (xL - hpL) * hpA; xL -= hpL
            hpR += (xR - hpR) * hpA; xR -= hpR
            lpL += (xL - lpL) * lpA
            lpR += (xR - lpR) * lpA
            dlL[dlW] = tanhf(lpL * 1.3) / 1.3
            dlR[dlW] = tanhf(lpR * 1.3) / 1.3
            dlW += 1; if dlW >= dlCap { dlW = 0 }
            L[i] += yL * dWet
            R[i] += yR * dWet
            verbL[i] = (sendL[i] * 0.35 + yL * 0.55) * reverbSend
            verbR[i] = (sendR[i] * 0.35 + yR * 0.55) * reverbSend
        }
        if abs(hpL) < 1e-15 { hpL = 0 }; if abs(hpR) < 1e-15 { hpR = 0 }
        if abs(lpL) < 1e-15 { lpL = 0 }; if abs(lpR) < 1e-15 { lpR = 0 }

        // Dust: a breath of hiss and the odd crackle, more of it the busier the sky
        dust += (p[.dust] - dust) * (1 - expf(-bt / 2))
        if dust > 1e-4 {
            let hissG = 0.0035 * dust
            let rate = (2 + 10 * dust) / sr
            let hA = 1 - expf(-2 * Float.pi * 4500 / sr)
            for i in 0..<n {
                hissL += (white() - hissL) * hA
                hissR += (white() - hissR) * hA
                if rand01() < rate { crackle = (white() > 0 ? 1 : -1) * (0.01 + 0.03 * rand01()) * dust }
                let c = crackle
                crackle *= 0.55
                L[i] += hissL * hissG + c
                R[i] += hissR * hissG + c * 0.7
            }
        }
    }

    // MARK: Render

    /// Render the dry bus (with echoes) into L/R, and the plate send for `copySend`.
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

        renderDub(L, R, count: n)

        // Master: soft clip the dry bus; the plate send takes the same gain
        let m0 = master
        master += (p[.master] - master) * (1 - expf(-bt / 0.6))
        let mInc = (master - m0) / Float(n)
        var mg = m0
        for i in 0..<n {
            mg += mInc
            L[i] = tanhf(L[i] * mg)
            R[i] = tanhf(R[i] * mg)
            verbL[i] *= mg
            verbR[i] *= mg
        }
        verbFrames = n
    }

    /// The plate send from the most recent `render`. Called from the second source node in the
    /// same render cycle (or, if that node is pulled first, it gets the previous cycle: one
    /// buffer of pre-delay on the reverb, which nobody can hear).
    func copySend(frames n: Int, left L: UnsafeMutablePointer<Float>, right R: UnsafeMutablePointer<Float>) {
        let k = min(n, verbFrames)
        if k > 0 {
            L.update(from: verbL, count: k)
            R.update(from: verbR, count: k)
        }
        if n > k {
            (L + k).update(repeating: 0, count: n - k)
            (R + k).update(repeating: 0, count: n - k)
        }
    }
}
