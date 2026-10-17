import Foundation

/// One satellite above the horizon at the moment of a snapshot.
struct Blip {
    let id: Int32
    let family: Family
    let az: Float              // degrees clockwise from north
    let el: Float              // degrees above the horizon
    let period: Float          // minutes
    var zenith: Float { 90 - el }
}

struct SkySnapshot {
    var time: TimeInterval = 0
    var blips: [Blip] = []
    var catalogSize = 0
    var counts: [Family: Int] = [:]
}

/// Propagates the whole catalog twice a second on a background queue and hands the main
/// thread what's above the horizon. About 10,000 satellites × SGP4 is a few milliseconds.
final class SkyTracker {
    /// Called on the main queue with each snapshot.
    var onSnapshot: ((SkySnapshot) -> Void)?

    private let queue = DispatchQueue(label: "orbitakt.sky", qos: .userInitiated)
    private var sats: [Satellite] = []           // queue only
    private var observer = Observer(lat: 42.3708, lon: -71.1833)   // queue only
    private var timer: DispatchSourceTimer?

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.5, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.step() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func setCatalog(_ s: [Satellite]) {
        queue.async { [weak self] in
            self?.sats = s
            self?.step()
        }
    }

    func setLocation(lat: Double, lon: Double) {
        queue.async { [weak self] in
            self?.observer = Observer(lat: lat, lon: lon)
            self?.step()
        }
    }

    private func step() {
        let now = Date().timeIntervalSince1970
        let g = Sidereal.gmst(now)
        var snap = SkySnapshot()
        snap.time = now
        snap.catalogSize = sats.count
        snap.blips.reserveCapacity(2500)
        var counts = [Int](repeating: 0, count: Family.allCases.count)
        let obs = observer
        for s in sats {
            guard let r = s.orbit.position(at: now) else { continue }
            let look = obs.look(r, gmst: g)
            guard look.el > 0 else { continue }
            counts[s.family.rawValue] += 1
            snap.blips.append(Blip(id: s.id, family: s.family, az: Float(look.az), el: Float(look.el),
                                   period: Float(s.orbit.periodMinutes)))
        }
        for f in Family.allCases { snap.counts[f] = counts[f.rawValue] }
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snap) }
    }
}
