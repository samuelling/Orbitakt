import Foundation
import CoreLocation
import SwiftUI

@inline(__always) func mtof(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
@inline(__always) func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

/// A Euclidean rhythm E(k, n): k hits spread as evenly as possible over n steps, the first on
/// step 0. (The same patterns as Bjorklund's algorithm, up to rotation.)
func euclid(_ k: Int, _ n: Int) -> [Bool] {
    guard n > 0 else { return [] }
    let k = max(0, min(n, k))
    return (0..<n).map { k > 0 && ($0 * k) % n < k }
}

/// One of the four Euclidean tracks: a family of satellites, a cone of sky around the zenith,
/// and a drum.
struct TrackSpec {
    let family: Family
    let sound: String
    let color: Color
    let defaultSteps: Int
    /// The cone opens until it holds about this fraction of the steps.
    let fill: Double
}

struct TrackState: Equatable {
    var steps = 16
    var k = 0
    var rotation = 0
    var hits: [Bool] = []
    var cone = 30.0              // half-angle from the zenith, degrees
    var inCone = 0               // satellites inside (can exceed steps)
    var auto = true
    var muted = false
}

enum TempoSource: String, CaseIterable, Identifiable {
    case orbit = "Orbit"
    case manual = "Manual"
    var id: String { rawValue }
}

/// Orbitakt's brain: keeps the catalog, reads the snapshots, turns each family's cone of sky
/// into a Euclidean pattern, and drives the engine and the link with the other apps.
@MainActor
final class RhythmModel: NSObject, ObservableObject {
    static let specs: [TrackSpec] = [
        TrackSpec(family: .nav, sound: "kick", color: Color(red: 1.0, green: 0.55, blue: 0.25),
                  defaultSteps: 16, fill: 5.0 / 16),
        TrackSpec(family: .leo, sound: "rim", color: Color(red: 0.45, green: 0.85, blue: 0.55),
                  defaultSteps: 12, fill: 4.0 / 12),
        TrackSpec(family: .swarm, sound: "shaker", color: Color(red: 0.45, green: 0.75, blue: 1.0),
                  defaultSteps: 16, fill: 0.5),
        TrackSpec(family: .belt, sound: "tom", color: Color(red: 0.85, green: 0.6, blue: 1.0),
                  defaultSteps: 13, fill: 5.0 / 13),
    ]
    static let crewColor = Color(red: 1.0, green: 0.85, blue: 0.4)

    // What the sky is doing
    @Published private(set) var snapshot = SkySnapshot()
    @Published private(set) var tracks: [TrackState] = RhythmModel.specs.map { TrackState(steps: $0.defaultSteps) }
    @Published private(set) var isPlaying = false
    @Published private(set) var status = "Reading the sky…"
    @Published private(set) var dataNote = ""
    @Published private(set) var live = false
    @Published private(set) var place = "Watertown, MA"
    @Published private(set) var crewNote: String?
    @Published private(set) var orbitBPM = 84.0
    @Published private(set) var effectiveBPM = 84.0

    // Settings (persisted)
    @Published var useLive = true { didSet { save(); if !loading { reloadCatalog() } } }
    @Published var scaleIndex = 0 { didSet { save() } }
    @Published var rootPC = 2 { didSet { save() } }                 // D
    @Published var tempoSource = TempoSource.orbit { didSet { save() } }
    @Published var manualBPM = 84.0 { didSet { save() } }
    @Published var swing = 0.08 { didSet { save(); engine.params[.swing] = Float(swing) } }
    @Published var space = 0.55 { didSet { save(); engine.setSpace(space) } }
    @Published var pingRadius = 4.0 { didSet { save() } }           // degrees from the zenith
    @Published var gongOn = true { didSet { save() } }

    // Link
    let duo = DuoLink(role: "orbitakt")
    @Published private(set) var partnerSummary: String?
    /// "Bellweathered + Aether" while we're listening to them, else nil.
    @Published private(set) var linkName: String?
    @Published var followTempo = true { didSet { save() } }
    @Published var followKey = true { didSet { save() } }
    private var partnerBPM: Double?
    /// The latest state from each lead and when it arrived. Orbitakt is a listener: it never
    /// sends, so each lead is forgotten 10 s after it goes quiet.
    private var leads: [String: (state: DuoState, at: TimeInterval)] = [:]

    /// Recent zenith pings, for the dome to draw (not published; the dome redraws anyway).
    private(set) var pings: [(az: Double, el: Double, t: TimeInterval)] = []

    let engine = OrbitEngine()
    private let tracker = SkyTracker()
    private let locator = CLLocationManager()
    private var lat = 42.3708, lon = -71.1833
    private var askedLocation = false
    private var loadedLive = false
    private var fetching = false
    private var catalogTimer: Timer?

    // Per-track memory between snapshots
    private struct Run {
        var cone = -1.0
        var ids: Set<Int32> = []
        var newestAz = -1.0
        var manualCone: Double?
    }
    private var runs: [Run] = RhythmModel.specs.map { _ in Run() }
    private var lastSnapTime: TimeInterval = 0
    private var pingIDs: Set<Int32> = []
    private var pingSlot = 0
    private var lastPing: TimeInterval = 0
    private var crewIDs: Set<Int32> = []
    private var lastGongBar = -1
    private var crewUp = false
    private var crewEl = 0.0
    private var ticker: Timer?

    var steps: [Int] { DuoScales.all[max(0, min(DuoScales.all.count - 1, scaleIndex))].steps }

    override init() {
        super.init()
        load()
        let p = engine.params
        p[.swing] = Float(swing)
        for (i, t) in tracks.enumerated() {
            p.pLen[i] = Float(t.steps)
            p.mute[i] = t.muted ? 1 : 0
        }
        engine.setSpace(space)

        tracker.onSnapshot = { [weak self] s in MainActor.assumeIsolated { self?.process(s) } }
        tracker.start()
        reloadCatalog()
        let ct = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCatalogIfDue() }
        }
        RunLoop.main.add(ct, forMode: .common)
        catalogTimer = ct

        locator.delegate = self
        locator.desiredAccuracy = kCLLocationAccuracyKilometer
        if [.authorizedWhenInUse, .authorizedAlways].contains(locator.authorizationStatus) {
            locator.requestLocation()
        }

        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fastTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        duo.onState = { [weak self] s in MainActor.assumeIsolated { self?.receiveDuo(s) } }
        duo.onLost = { [weak self] in MainActor.assumeIsolated { self?.forgetLeads() } }
        duo.start()
    }

    // MARK: Transport

    func togglePlay() {
        let p = engine.params
        if isPlaying {
            p[.run] = 0
            engine.stop()
            isPlaying = false
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            if !askedLocation {
                askedLocation = true
                if locator.authorizationStatus == .notDetermined { locator.requestWhenInUseAuthorization() }
            }
            do {
                try engine.start()
                p[.run] = 1
                isPlaying = true
                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                status = "Audio failed to start: \(error.localizedDescription)"
            }
        }
    }

    func setSteps(_ n: Int, track t: Int) {
        guard tracks.indices.contains(t) else { return }
        tracks[t].steps = max(3, min(OrbitParams.maxSteps, n))
        save()
        if snapshot.time > 0 { build(track: t, snapshot: snapshot, dt: 0) }
    }

    func setMuted(_ m: Bool, track t: Int) {
        guard tracks.indices.contains(t) else { return }
        tracks[t].muted = m
        engine.params.mute[t] = m ? 1 : 0
        save()
    }

    /// nil = the cone adapts by itself; otherwise a fixed half-angle in degrees.
    func setCone(_ deg: Double?, track t: Int) {
        guard tracks.indices.contains(t) else { return }
        runs[t].manualCone = deg
        tracks[t].auto = deg == nil
        if let d = deg { runs[t].cone = d; tracks[t].cone = d }
        save()
        if snapshot.time > 0 { build(track: t, snapshot: snapshot, dt: 0) }
    }

    /// The step each track just played (read by the views every frame, straight from the engine).
    func playhead(_ t: Int) -> Int { Int(engine.params.curStep[t]) }
    func hitCount(_ t: Int) -> Int { Int(engine.params.hitCount[t]) }

    // MARK: Catalog

    private func reloadCatalog() {
        live = false
        loadedLive = false
        if useLive, let text = CatalogStore.cached() {
            Task.detached(priority: .userInitiated) { [weak self] in
                let sats = CatalogStore.parse(text)
                await MainActor.run { self?.adopt(sats, live: true) }
            }
        } else {
            adopt(SimulatedCatalog.make(), live: false)
        }
        refreshCatalogIfDue()
    }

    private func adopt(_ sats: [Satellite], live isLive: Bool) {
        guard !isLive || useLive else { return }
        if isLive && sats.count < 100 {
            if !live && snapshot.catalogSize == 0 { tracker.setCatalog(SimulatedCatalog.make()) }
            return
        }
        tracker.setCatalog(sats)
        live = isLive
        loadedLive = isLive
        runs = runs.map { var r = Run(); r.manualCone = $0.manualCone; return r }
        updateStatus()
    }

    private func refreshCatalogIfDue() {
        guard useLive, !fetching, CatalogStore.shouldFetch else { return }
        fetching = true
        updateStatus()
        Task.detached(priority: .utility) { [weak self] in
            let text = await CatalogStore.download()
            let sats = text.map { CatalogStore.parse($0) }
            await MainActor.run {
                guard let self else { return }
                self.fetching = false
                if let sats { self.adopt(sats, live: true) } else { self.updateStatus() }
            }
        }
    }

    private func updateStatus() {
        if live {
            status = "Live · \(place)"
            if let f = CatalogStore.fetchedAt {
                let h = Date().timeIntervalSince(f) / 3600
                let age = h < 1 ? "under an hour" : (h < 48 ? "\(Int(h)) h" : "\(Int(h / 24)) days")
                dataNote = "\(snapshot.catalogSize.formatted()) satellites · elements \(age) old (CelesTrak)"
            }
        } else if useLive {
            status = fetching ? "Simulated sky · fetching orbits…" : "Simulated sky (no orbital data yet)"
            dataNote = "Stand-in constellations until CelesTrak's catalog arrives"
        } else {
            status = "Simulated sky"
            dataNote = "Real shells and densities, invented positions"
        }
    }

    // MARK: Sky → rhythm (twice a second)

    private func process(_ s: SkySnapshot) {
        let dt = lastSnapTime > 0 ? min(5, s.time - lastSnapTime) : 0
        lastSnapTime = s.time
        snapshot = s
        for t in RhythmModel.specs.indices { build(track: t, snapshot: s, dt: dt) }
        zenithPings(s)
        crew(s)
        tempo(s, dt: dt)
        if live { updateStatus() }
    }

    private func build(track t: Int, snapshot s: SkySnapshot, dt: Double) {
        let spec = RhythmModel.specs[t]
        let n = tracks[t].steps
        let fam = s.blips.filter { $0.family == spec.family }
        var run = runs[t]

        // The cone: adaptive, like contrast gain control. It settles where it holds about
        // `fill · n` satellites on average (the slow mean is divided out) while the
        // moment-to-moment comings and goings pass straight through.
        if let m = run.manualCone {
            run.cone = m
        } else {
            let want = max(1, Int((spec.fill * Double(n)).rounded()))
            let zs = fam.map { Double($0.zenith) }.sorted()
            let target = zs.count >= want ? min(90, zs[want - 1] + 0.1) : 90
            if run.cone < 0 {
                run.cone = target
            } else if dt > 0 {
                run.cone += (target - run.cone) * (1 - exp(-dt / 60))
            }
        }
        let cone = max(1, run.cone)
        let members = fam.filter { Double($0.zenith) <= cone }
        let ids = Set(members.map(\.id))
        // Newest arrival sets where the bar starts: the pattern turns to face it.
        if let arrival = members.filter({ !run.ids.contains($0.id) }).max(by: { $0.el < $1.el }),
           !run.ids.isEmpty || run.newestAz < 0 {
            run.newestAz = Double(arrival.az)
        }
        if run.newestAz < 0, let top = members.max(by: { $0.el < $1.el }) { run.newestAz = Double(top.az) }
        run.ids = ids
        runs[t] = run

        // If the cone holds more than n, the n highest play.
        var chosen = members
        if chosen.count > n { chosen = Array(chosen.sorted { $0.el > $1.el }.prefix(n)) }
        let k = chosen.count
        let origin = max(0, run.newestAz)
        chosen.sort { fmod(Double($0.az) - origin + 360, 360) < fmod(Double($1.az) - origin + 360, 360) }
        let rot = Int((origin / 360 * Double(n)).rounded()) % n
        let base = euclid(k, n)
        var hits = [Bool](repeating: false, count: n)
        for st in 0..<n { hits[st] = base[(st - rot + n) % n] }

        // Write the pattern: the playhead sweeps the sky clockwise from north once per bar,
        // so the j-th hit after the rotation point plays the j-th satellite clockwise from
        // the newest arrival. Its height sets velocity; east–west sets pan.
        let p = engine.params
        let S = OrbitParams.maxSteps
        let root = rootPC
        let sc = steps
        var j = 0
        for off in 0..<n {
            let st = (rot + off) % n
            let i = t * S + st
            p.pHit[i] = hits[st] ? 1 : 0
            guard hits[st], j < chosen.count else { continue }
            let b = chosen[j]
            j += 1
            let el = Double(b.el), az = Double(b.az) * .pi / 180
            p.pVel[i] = Float(0.4 + 0.6 * clamp01((el - (90 - cone)) / max(1, cone)))
            p.pPan[i] = Float(max(-0.9, min(0.9, sin(az) * cos(el * .pi / 180) * 1.1)))
            p.pFreq[i] = Float(pitch(track: t, blip: b, root: root, scale: sc))
        }
        p.pLen[t] = Float(n)
        p.bright[t] = Float(t == 2 ? clamp01(Double(members.map(\.el).max() ?? 45) / 90) : 0.5)
        p.pGen[t] += 1

        var v = tracks[t]
        v.k = k
        v.rotation = rot
        v.hits = hits
        v.cone = cone
        v.inCone = members.count
        v.auto = run.manualCone == nil
        if v != tracks[t] { tracks[t] = v }
    }

    private func semis(_ d: Int, _ sc: [Int]) -> Int {
        let n = sc.count
        let q = Int(floor(Double(d) / Double(n)))
        return sc[d - q * n] + 12 * q
    }

    private func pitch(track t: Int, blip b: Blip, root: Int, scale sc: [Int]) -> Double {
        switch t {
        case 0:   // kick on the root, low (G1…F♯2, 49–92 Hz)
            return mtof(Double(31 + (root + 5) % 12))
        case 1:   // rim on the fifth-ish degree, in the woodblock register
            return mtof(Double(72 + root + semis(2, sc)))
        case 3:   // the belt is a xylophone strung across your sky: east low, west high
            let x = clamp01((1 - sin(Double(b.az) * .pi / 180)) / 2)   // east 0 … west 1
            let d = Int((x * Double(2 * sc.count - 1)).rounded())
            return mtof(Double(48 + root + semis(d, sc)))
        default:
            return 1000
        }
    }

    // MARK: Events

    /// Anything passing within `pingRadius` of straight up rings a glass bar.
    private func zenithPings(_ s: SkySnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        let close = s.blips.filter { $0.family != .other && Double($0.zenith) <= pingRadius }
        let ids = Set(close.map(\.id))
        let fresh = close.filter { !pingIDs.contains($0.id) }
        pingIDs = ids
        pings.removeAll { now - $0.t > 6 }
        guard isPlaying, let b = fresh.max(by: { $0.el < $1.el }), now - lastPing > 1.2 else { return }
        lastPing = now
        let p = engine.params
        let sc = steps
        let d = Int(UInt32(bitPattern: b.id) % UInt32(2 * sc.count))
        let slot = pingSlot
        pingSlot = (pingSlot + 1) % OrbitParams.pingSlots
        p.evFreq[slot] = Float(mtof(Double(72 + rootPC + semis(d, sc))))
        p.evVel[slot] = Float(Double.random(in: 0.6...1))
        let az = Double(b.az) * .pi / 180
        p.evPan[slot] = Float(sin(az) * 0.6)
        p.evTrig[slot] += 1
        pings.append((Double(b.az), Double(b.el), now))
    }

    /// While a crewed station is up, a gong every two bars; and one as it rises.
    private func crew(_ s: SkySnapshot) {
        let up = s.blips.filter { $0.family == .crew && $0.el > 5 }
        let ids = Set(up.map(\.id))
        let rising = !ids.subtracting(crewIDs).isEmpty
        crewIDs = ids
        crewUp = !up.isEmpty
        if let top = up.max(by: { $0.el < $1.el }) {
            crewEl = Double(top.el)
            let name = top.id == 25544 ? "ISS" : (top.id == 48274 ? "Tiangong" : "A crewed station")
            crewNote = "\(name) overhead · \(Int(crewEl.rounded()))° up"
        } else {
            crewNote = nil
        }
        guard isPlaying, gongOn, crewUp else { return }
        let bar = Int(engine.params[.globalStep]) / 32
        if rising || bar != lastGongBar {
            lastGongBar = bar
            let p = engine.params
            p[.gongFreq] = Float(mtof(Double(36 + rootPC)))
            p[.gongVel] = Float(0.35 + 0.65 * sin(crewEl * .pi / 180))
            p[.gongPan] = 0
            p[.gongTrig] += 1
        }
    }

    // MARK: Tempo

    /// The overhead orbits' own period, thirteen octaves up: a 95-minute Starlink orbit is
    /// 1/5736 Hz; × 2¹³ that's 85.7 BPM. Higher shells are slower, the ISS a touch faster.
    private func tempo(_ s: SkySnapshot, dt: Double) {
        let low = s.blips.filter { ($0.family == .swarm || $0.family == .leo) && $0.el > 30 }
            .map { Double($0.period) }.sorted()
        if !low.isEmpty {
            let target = 8192 / low[low.count / 2]
            orbitBPM = dt > 0 ? orbitBPM + (target - orbitBPM) * (1 - exp(-dt / 20)) : target
        }
        var bpm: Double
        if followTempo, let pb = partnerBPM, pb.isFinite, pb > 1 {
            bpm = pb
            while bpm < 60 { bpm *= 2 }
            while bpm >= 132 { bpm /= 2 }
        } else {
            bpm = tempoSource == .orbit ? orbitBPM : manualBPM
        }
        effectiveBPM = bpm
        engine.params[.bpm] = Float(bpm)
        engine.setTempo(bpm)
    }

    private func fastTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let stale = leads.filter { now - $0.value.at > 10 }.map { $0.key }
        if !stale.isEmpty {
            for r in stale { leads[r] = nil }
            leadsChanged()
        }
    }

    // MARK: Link (Orbitakt listens in on Aether and Bellweathered, like Leitmotif)

    private func receiveDuo(_ s: DuoState) {
        guard s.role == "aether" || s.role == "bellweather" else { return }
        let isNew = leads[s.role] == nil
        leads[s.role] = (s, ProcessInfo.processInfo.systemUptime)
        // Key: Bellweathered's sky leads; Aether carries it on when the sky isn't here
        // (Aether follows the sky's key itself, so they agree when both are present).
        let keySource = leads["bellweather"]?.state ?? leads["aether"]?.state
        if followKey, let k = keySource, k.role == s.role {
            if let pc = k.rootPC, (0..<12).contains(pc), pc != rootPC { rootPC = pc }
            if let st = k.scaleSteps, let i = DuoScales.all.firstIndex(where: { $0.steps == st }),
               i != scaleIndex { scaleIndex = i }
        }
        if isNew { leadsChanged() } else { summarize() }
    }

    private func forgetLeads() {
        leads.removeAll()
        leadsChanged()
    }

    private func leadsChanged() {
        let names = ["bellweather", "aether"].filter { leads[$0] != nil }.map(DuoLink.appName(of:))
        linkName = names.isEmpty ? nil : names.joined(separator: " + ")
        summarize()
    }

    /// Tempo from Aether (time leads there), and a one-line summary for Settings.
    private func summarize() {
        partnerBPM = leads["aether"]?.state.bpm.flatMap { $0.isFinite && $0 > 1 && $0 < 1000 ? $0 : nil }
        var bits: [String] = []
        if let a = leads["aether"]?.state {
            if let d = a.devices { bits.append("\(d) devices") }
            if let b = a.bpm { bits.append("\(Int(b.rounded())) BPM") }
        }
        if let b = leads["bellweather"]?.state {
            if let t = b.tempF { bits.append("\(Int(t.rounded()))°F") }
            if let c = b.cloud { bits.append("\(Int(c.rounded()))% cloud") }
            if let pl = b.place, !pl.isEmpty { bits.append(pl) }
        }
        let text = bits.isEmpty ? nil : bits.joined(separator: " · ")
        if text != partnerSummary { partnerSummary = text }
    }

    // MARK: Persistence

    private var loading = false

    private func save() {
        guard !loading else { return }
        let d = UserDefaults.standard
        d.set(useLive, forKey: "o.live")
        d.set(scaleIndex, forKey: "o.scale")
        d.set(rootPC, forKey: "o.root")
        d.set(tempoSource.rawValue, forKey: "o.tempo")
        d.set(manualBPM, forKey: "o.bpm")
        d.set(swing, forKey: "o.swing")
        d.set(space, forKey: "o.space")
        d.set(pingRadius, forKey: "o.ping")
        d.set(gongOn, forKey: "o.gong")
        d.set(followTempo, forKey: "o.followTempo")
        d.set(followKey, forKey: "o.followKey")
        d.set(tracks.map(\.steps), forKey: "o.steps")
        d.set(tracks.map(\.muted), forKey: "o.mutes")
        d.set(runs.map { $0.manualCone ?? -1 }, forKey: "o.cones")
    }

    private func load() {
        loading = true
        defer { loading = false }
        let d = UserDefaults.standard
        if d.object(forKey: "o.live") != nil { useLive = d.bool(forKey: "o.live") }
        if d.object(forKey: "o.scale") != nil { scaleIndex = d.integer(forKey: "o.scale") }
        if d.object(forKey: "o.root") != nil { rootPC = d.integer(forKey: "o.root") }
        if let t = d.string(forKey: "o.tempo"), let ts = TempoSource(rawValue: t) { tempoSource = ts }
        if d.object(forKey: "o.bpm") != nil { manualBPM = d.double(forKey: "o.bpm") }
        if d.object(forKey: "o.swing") != nil { swing = d.double(forKey: "o.swing") }
        if d.object(forKey: "o.space") != nil { space = d.double(forKey: "o.space") }
        if d.object(forKey: "o.ping") != nil { pingRadius = d.double(forKey: "o.ping") }
        if d.object(forKey: "o.gong") != nil { gongOn = d.bool(forKey: "o.gong") }
        if d.object(forKey: "o.followTempo") != nil { followTempo = d.bool(forKey: "o.followTempo") }
        if d.object(forKey: "o.followKey") != nil { followKey = d.bool(forKey: "o.followKey") }
        if let s = d.array(forKey: "o.steps") as? [Int], s.count == tracks.count {
            for i in s.indices { tracks[i].steps = max(3, min(OrbitParams.maxSteps, s[i])) }
        }
        if let m = d.array(forKey: "o.mutes") as? [Bool], m.count == tracks.count {
            for i in m.indices { tracks[i].muted = m[i] }
        }
        if let c = d.array(forKey: "o.cones") as? [Double], c.count == runs.count {
            for i in c.indices where c[i] > 0 {
                runs[i].manualCone = c[i]
                tracks[i].auto = false
                tracks[i].cone = c[i]
            }
        }
    }
}

// MARK: - Location

extension RhythmModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        MainActor.assumeIsolated {
            if st == .authorizedWhenInUse || st == .authorizedAlways { self.locator.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let la = (loc.coordinate.latitude * 100).rounded() / 100
        let lo = (loc.coordinate.longitude * 100).rounded() / 100
        MainActor.assumeIsolated {
            self.lat = la
            self.lon = lo
            self.tracker.setLocation(lat: la, lon: lo)
            Task { [weak self] in
                guard let marks = try? await CLGeocoder().reverseGeocodeLocation(loc),
                      let m = marks.first else { return }
                let name = [m.locality, m.administrativeArea].compactMap { $0 }.joined(separator: ", ")
                if !name.isEmpty { self?.place = name; self?.updateStatus() }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
