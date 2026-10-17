import Foundation

/// Which part of the sky a satellite belongs to. Each family drives one part of the kit.
enum Family: Int, CaseIterable {
    case nav      // mid orbits: GPS, Galileo, GLONASS, BeiDou, O3b (kick)
    case leo      // low orbits other than Starlink (rim)
    case swarm    // Starlink (shaker)
    case belt     // the geostationary belt (tuned tom)
    case crew     // crewed stations: ISS, Tiangong (gong)
    case other    // everything else (drawn, but plays nothing)

    var label: String {
        switch self {
        case .nav: return "NAV"
        case .leo: return "LEO"
        case .swarm: return "SWARM"
        case .belt: return "BELT"
        case .crew: return "CREW"
        case .other: return "OTHER"
        }
    }

    /// Sort a catalog entry into a family by name and orbit.
    static func classify(name: String, periodMinutes p: Double, eccentricity e: Double) -> Family {
        let n = name.uppercased()
        if n.contains("ISS (ZARYA)") || n.contains("TIANHE") { return .crew }
        if n.hasPrefix("STARLINK") { return .swarm }
        if p < 225 { return .leo }
        guard e < 0.1 else { return .other }
        if p < 1300 { return .nav }
        if p <= 1600 { return .belt }
        return .other
    }
}

/// How a satellite moves: the real thing (SGP4 from a TLE) or a simulated circular orbit.
enum Orbit {
    case tle(SGP4)
    case circular(CircularOrbit)

    @inline(__always) func position(at t: TimeInterval) -> (x: Double, y: Double, z: Double)? {
        switch self {
        case .tle(let s): return s.position(at: t)
        case .circular(let c): return c.position(at: t)
        }
    }

    var periodMinutes: Double {
        switch self {
        case .tle(let s): return s.periodMinutes
        case .circular(let c): return c.periodMinutes
        }
    }
}

struct Satellite {
    let id: Int32            // NORAD catalog number (simulated: a made-up one)
    let name: String
    let family: Family
    let orbit: Orbit
}

/// A circular orbit with J2 nodal drift, for the simulated sky.
struct CircularOrbit {
    static let mu = 398_600.4418
    static let re = 6378.137
    let a, inc, raan0, u0, n, raanDot: Double
    let epoch: TimeInterval

    init(altitudeKm alt: Double, inclinationDeg: Double, raan: Double, u: Double, epoch: TimeInterval) {
        a = CircularOrbit.re + alt
        inc = inclinationDeg * .pi / 180
        raan0 = raan
        u0 = u
        n = (CircularOrbit.mu / (a * a * a)).squareRoot()
        let ratio = CircularOrbit.re / a
        raanDot = -1.5 * n * 1.08262668e-3 * ratio * ratio * cos(inc)
        self.epoch = epoch
    }

    var periodMinutes: Double { 2 * .pi / n / 60 }

    @inline(__always) func position(at t: TimeInterval) -> (x: Double, y: Double, z: Double)? {
        let dt = t - epoch
        let u = u0 + n * dt, o = raan0 + raanDot * dt
        let cu = cos(u), su = sin(u), co = cos(o), so = sin(o), ci = cos(inc), si = sin(inc)
        return (a * (cu * co - su * ci * so), a * (cu * so + su * ci * co), a * su * si)
    }
}

// MARK: - The real catalog (CelesTrak)

/// Fetches CelesTrak's "active satellites" list and keeps it on disk.
///
/// CelesTrak refreshes its data about every two hours and allows one download per update,
/// so this asks at most once every 12 hours, and after any failure waits 12 hours before
/// asking again (CelesTrak blocks clients that retry on errors).
enum CatalogStore {
    static let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle")!
    static let refreshAge: TimeInterval = 12 * 3600
    static let retryAfterFailure: TimeInterval = 12 * 3600
    /// Older than this, the elements are too stale to place satellites usefully.
    static let maxAge: TimeInterval = 30 * 86_400

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("celestrak-active.tle")
    }
    private static let fetchedKey = "catalog.fetchedAt"
    private static let nextKey = "catalog.nextAllowed"

    static var fetchedAt: Date? {
        let t = UserDefaults.standard.double(forKey: fetchedKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Time to ask: the copy we have is over 12 h old (or missing), and we're not backing off.
    static var shouldFetch: Bool {
        if let f = fetchedAt, Date().timeIntervalSince(f) < refreshAge { return false }
        return Date().timeIntervalSince1970 >= UserDefaults.standard.double(forKey: nextKey)
    }

    /// The cached text, if it exists and isn't hopelessly old.
    static func cached() -> String? {
        guard let f = fetchedAt, Date().timeIntervalSince(f) < maxAge else { return nil }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// One polite download. Returns the text on success, otherwise nil. Never retries by
    /// itself: after a reply from CelesTrak that isn't the data (e.g. 403, "not updated since
    /// your last download") it waits 12 h; after no reply at all (offline) it waits 10 min.
    static func download() async -> String? {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        d.set(now + 600, forKey: nextKey)
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Orbitakt/1.0 (iOS; one download per 12 h)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        d.set(now + retryAfterFailure, forKey: nextKey)
        // (Checked on the raw bytes: CelesTrak sends CRLF, and "\r\n" is one Character in Swift.)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              data.range(of: Data("\n1 ".utf8)) != nil,
              let text = String(data: data, encoding: .utf8) else { return nil }
        try? data.write(to: fileURL, options: .atomic)
        d.set(Date().timeIntervalSince1970, forKey: fetchedKey)
        return text
    }

    /// NORAD catalog number, including the Alpha-5 form used past 99999 ("A0001" = 100001).
    static func catalogNumber(_ field: Substring) -> Int32 {
        let f = field.trimmingCharacters(in: .whitespaces)
        if let n = Int32(f) { return n }
        guard let first = f.first, let rest = Int32(f.dropFirst()) else { return -1 }
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        guard let i = letters.firstIndex(of: first) else { return -1 }
        return Int32(10 + i) * 10_000 + rest
    }

    /// Parse 3-line TLE text (name, line 1, line 2) into satellites.
    static func parse(_ text: String) -> [Satellite] {
        var out: [Satellite] = []
        out.reserveCapacity(16_000)
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }
        var i = 0
        while i + 1 < lines.count {
            let l1 = lines[i], l2 = lines[i + 1]
            guard l1.hasPrefix("1 "), l2.hasPrefix("2 ") else { i += 1; continue }
            var name = ""
            if i > 0 {
                let prev = lines[i - 1]
                if !prev.hasPrefix("1 ") && !prev.hasPrefix("2 ") {
                    name = prev.trimmingCharacters(in: .whitespaces)
                    if name.hasPrefix("0 ") { name.removeFirst(2) }
                }
            }
            i += 2
            guard let s = SGP4(line1: l1, line2: l2), s.isUsable else { continue }
            let catnr = catalogNumber(l1.dropFirst(2).prefix(5))
            let fam = Family.classify(name: name, periodMinutes: s.periodMinutes, eccentricity: s.eccentricity)
            out.append(Satellite(id: catnr, name: name, family: fam, orbit: .tle(s)))
        }
        return out
    }
}

// MARK: - The simulated sky

/// A stand-in sky, used before the real catalog arrives or with no connection: the same
/// constellations, shell by shell, as Walker patterns (Starlink's shells, OneWeb, Iridium,
/// Kuiper, the navigation constellations, the geostationary belt, two crewed stations,
/// and a scatter of other low orbits). Positions are invented; densities are realistic.
enum SimulatedCatalog {
    static func make() -> [Satellite] {
        var rng = SplitMix(seed: 0x0B17_A472)
        let epoch: TimeInterval = 1_792_195_200     // 2026-10-17 00:00 UTC
        var out: [Satellite] = []
        var nextID: Int32 = 90_000

        func add(_ name: String, _ fam: Family, alt: Double, inc: Double, raan: Double, u: Double) {
            let o = CircularOrbit(altitudeKm: alt, inclinationDeg: inc, raan: raan, u: u, epoch: epoch)
            out.append(Satellite(id: nextID, name: name, family: fam, orbit: .circular(o)))
            nextID += 1
        }
        func walker(_ name: String, _ fam: Family, alt: Double, inc: Double,
                    planes: Int, perPlane: Int, phasing: Int) {
            let off = rng.next() * 2 * .pi
            for j in 0..<planes {
                for k in 0..<perPlane {
                    let raan = off + 2 * .pi * Double(j) / Double(planes)
                    let u = 2 * .pi * Double(k) / Double(perPlane)
                        + 2 * .pi * Double(phasing * j) / Double(planes * perPlane)
                    add(name, fam, alt: alt, inc: inc, raan: raan, u: u)
                }
            }
        }

        walker("STARLINK", .swarm, alt: 550, inc: 53, planes: 72, perPlane: 22, phasing: 17)
        walker("STARLINK", .swarm, alt: 540, inc: 53.2, planes: 72, perPlane: 22, phasing: 13)
        walker("STARLINK", .swarm, alt: 570, inc: 70, planes: 36, perPlane: 20, phasing: 11)
        walker("STARLINK", .swarm, alt: 560, inc: 97.6, planes: 10, perPlane: 52, phasing: 5)
        walker("STARLINK", .swarm, alt: 525, inc: 43, planes: 28, perPlane: 120, phasing: 7)
        walker("ONEWEB", .leo, alt: 1200, inc: 87.9, planes: 12, perPlane: 49, phasing: 3)
        walker("IRIDIUM", .leo, alt: 780, inc: 86.4, planes: 6, perPlane: 11, phasing: 2)
        walker("KUIPER", .leo, alt: 630, inc: 51.9, planes: 10, perPlane: 20, phasing: 3)
        for _ in 0..<1800 {
            let r = rng.next()
            let inc: Double, alt: Double
            if r < 0.45 { inc = 97.4 + rng.next() * 1.2; alt = 480 + rng.next() * 320 }
            else if r < 0.6 { inc = 51.6; alt = 400 + rng.next() * 150 }
            else { inc = 30 + rng.next() * 70; alt = 400 + rng.next() * 800 }
            add("LEO", .leo, alt: alt, inc: inc, raan: rng.next() * 2 * .pi, u: rng.next() * 2 * .pi)
        }
        walker("NAVSTAR", .nav, alt: 20_180, inc: 55, planes: 6, perPlane: 5, phasing: 1)
        walker("GALILEO", .nav, alt: 23_222, inc: 56, planes: 3, perPlane: 8, phasing: 1)
        walker("GLONASS", .nav, alt: 19_130, inc: 64.8, planes: 3, perPlane: 8, phasing: 1)
        walker("BEIDOU", .nav, alt: 21_528, inc: 55, planes: 3, perPlane: 8, phasing: 1)
        for _ in 0..<560 {
            add("GEO", .belt, alt: 35_786, inc: rng.next() * 3, raan: rng.next() * 2 * .pi,
                u: rng.next() * 2 * .pi)
        }
        add("ISS (ZARYA)", .crew, alt: 420, inc: 51.64, raan: rng.next() * 2 * .pi, u: rng.next() * 2 * .pi)
        add("CSS (TIANHE)", .crew, alt: 385, inc: 41.47, raan: rng.next() * 2 * .pi, u: rng.next() * 2 * .pi)
        return out
    }
}

/// Small deterministic generator (so the simulated sky is the same every launch).
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1)
    mutating func next() -> Double { Double(nextUInt() >> 11) / Double(1 << 53) }
}
