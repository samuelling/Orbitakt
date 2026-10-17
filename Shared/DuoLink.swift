import Foundation
import MultipeerConnectivity

/// The message every app in the set exchanges. Every field is optional; each app fills in
/// what it owns, and ignores fields it doesn't know (so older apps keep working).
///
/// Division of labour (by timescale):
///  • Bellweathered (sky, hours)     → harmony: root pitch class and scale.
///  • Aether (radio room, seconds)   → time: tempo and the shared chord timeline.
///  • Orbitakt (orbits, minutes)     → follows both; reports the satellites overhead.
///  • Everyone                       → a short summary of their environment.
struct DuoState: Codable, Equatable {
    var role: String                 // "aether" | "bellweather" | "orbitakt" | …
    var seq: Int = 0

    // Harmony (Bellweathered leads)
    var rootPC: Int?                 // 0 = C … 11 = B
    var scaleSteps: [Int]?           // semitone steps, e.g. [0, 2, 4, 7, 9]

    // Time (Aether leads)
    var bpm: Double?
    var chordDegree: Int?            // scale degree of the current chord root
    var chordSerial: Int?            // increments at every chord change
    var chordSeconds: Double?

    // Environment summaries
    var day: Double?                 // 0 night … 1 full day
    var cloud: Double?               // 0…100 %
    var precip: Double?              // 0…1 chance
    var wind: Double?                // mph
    var tempF: Double?
    var place: String?
    var devices: Int?                // Bluetooth emitters heard
    var air: Double?                 // 0…1 how much the radio field is moving
    var satellites: Int?             // satellites above the horizon
    var crewOverhead: Bool?          // a crewed station is up
}

/// Finds the other apps nearby (Bluetooth or peer-to-peer Wi-Fi, no router needed),
/// connects automatically, and keeps everyone informed. Works as a small mesh: one phone
/// per app, all in one session. Anyone who goes quiet for 10 s is dropped, and each app
/// simply carries on until they find each other again.
///
/// Not actor-isolated: every callback hops to the main queue before touching state, and
/// `onState` / `onLost` are always called on the main queue.
final class DuoLink: NSObject, ObservableObject {
    static let serviceType = "aether-duo"      // must match NSBonjourServices in Info.plist

    enum Phase: Equatable { case off, searching, connected, paused }

    /// "Aether + Bellweathered", or nil when alone.
    @Published private(set) var partnerName: String?
    /// The latest state from each partner, by role.
    @Published private(set) var partners: [String: DuoState] = [:]
    @Published private(set) var phase: Phase = .off
    /// When the current search gives up (nil = searching indefinitely, or not searching).
    @Published private(set) var searchEnds: Date?
    /// User settings, persisted.
    @Published private(set) var enabled: Bool
    @Published private(set) var timeoutMinutes: Int       // 0 = never stop looking

    /// Called on the main queue whenever a partner's state arrives.
    var onState: ((DuoState) -> Void)?
    /// Called on the main queue with a partner's role when it disconnects or times out.
    var onLost: ((String) -> Void)?

    var isConnected: Bool { !partners.isEmpty }

    static func displayName(role: String) -> String {
        switch role {
        case "aether": return "Aether"
        case "bellweather": return "Bellweathered"
        case "orbitakt": return "Orbitakt"
        default: return role.capitalized
        }
    }

    private let role: String
    private let peer: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// Stopped advertisers/browsers are never reused or freed. Restarting one object, or
    /// freeing it while its cancel is still in flight, crashed inside Multipeer
    /// (_BrowserCancel → CFRunLoopSourceInvalidate). Each search gets fresh objects instead.
    private var retired: [NSObject] = []
    private var radiosOn = false
    private var lastStop = Date.distantPast
    private var lastHeard: [String: Date] = [:]
    /// Other-app peers the browser has seen and not lost (main queue only), with the time
    /// we last invited each.
    private var discovered: [MCPeerID: Date] = [:]
    private var watchdog: Timer?
    private var seq = 0

    init(role: String) {
        self.role = role
        let d = UserDefaults.standard
        // A stable name per install keeps the invite tie-break deterministic.
        let key = "duo.peerSuffix"
        let suffix = d.string(forKey: key) ?? {
            let s = String(UUID().uuidString.prefix(6))
            d.set(s, forKey: key)
            return s
        }()
        enabled = d.object(forKey: "duo.enabled") as? Bool ?? true
        timeoutMinutes = d.object(forKey: "duo.timeoutMinutes") as? Int ?? 5
        peer = MCPeerID(displayName: "\(role)-\(suffix)")
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    deinit {
        watchdog?.invalidate()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
    }

    /// Call once at launch. Searches if the user has the link turned on.
    func start() {
        watchdog?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkAlive() }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
        if enabled { beginSearch() }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: "duo.enabled")
        if on {
            beginSearch()
        } else {
            radiosOff()
            session.disconnect()
            for r in Array(partners.keys) { drop(role: r) }
            phase = .off
            searchEnds = nil
        }
    }

    func setTimeout(minutes: Int) {
        timeoutMinutes = max(0, minutes)
        UserDefaults.standard.set(timeoutMinutes, forKey: "duo.timeoutMinutes")
        if phase == .searching { searchEnds = deadline() }
    }

    /// After a timeout, look again for a fresh window.
    func searchAgain() { beginSearch() }

    /// Send our current state to everyone (cheap; call on change and as a heartbeat).
    func send(_ state: DuoState) {
        guard !session.connectedPeers.isEmpty else { return }
        var s = state
        s.role = role
        seq += 1
        s.seq = seq
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    // MARK: Private

    private static func role(of p: MCPeerID) -> String {
        String(p.displayName.split(separator: "-").first ?? "")
    }

    private func deadline() -> Date? {
        timeoutMinutes > 0 ? Date().addingTimeInterval(Double(timeoutMinutes) * 60) : nil
    }

    private func beginSearch() {
        guard enabled else { return }
        radiosOnIfNeeded()
        if !partners.isEmpty {
            phase = .connected
            searchEnds = nil
        } else {
            phase = .searching
            searchEnds = deadline()
        }
    }

    private func radiosOnIfNeeded() {
        guard !radiosOn else { return }
        // Never start right on the heels of a stop (e.g. the toggle flicked off and on).
        let wait = 3 - Date().timeIntervalSince(lastStop)
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.enabled, self.phase == .searching || self.phase == .connected else { return }
                self.radiosOnIfNeeded()
            }
            return
        }
        let a = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["role": role],
                                          serviceType: DuoLink.serviceType)
        let b = MCNearbyServiceBrowser(peer: peer, serviceType: DuoLink.serviceType)
        a.delegate = self
        b.delegate = self
        advertiser = a
        browser = b
        radiosOn = true
        a.startAdvertisingPeer()
        b.startBrowsingForPeers()
    }

    private func radiosOff() {
        guard radiosOn else { return }
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        if let a = advertiser { retired.append(a) }
        if let b = browser { retired.append(b) }
        advertiser = nil
        browser = nil
        radiosOn = false
        lastStop = Date()
        discovered.removeAll()
    }

    private func checkAlive() {
        let now = Date()
        for (r, t) in lastHeard where partners[r] != nil && now.timeIntervalSince(t) > 10 { drop(role: r) }
        if phase == .searching, partners.isEmpty, let end = searchEnds, now >= end {
            // Nobody turned up: stop advertising and listening until asked again.
            radiosOff()
            phase = .paused
            searchEnds = nil
            return
        }
        // Re-invite any app we can still see but aren't connected to (the browser keeps
        // running while connected, so a third or fourth app can still join).
        for p in Array(discovered.keys) { inviteIfNeeded(p) }
    }

    /// Main queue only. Exactly one side invites (the lower display name), at most every
    /// 12 s, and only if we aren't already connected to a phone running that app.
    fileprivate func inviteIfNeeded(_ p: MCPeerID) {
        guard radiosOn, let browser, peer.displayName < p.displayName else { return }
        let theirRole = DuoLink.role(of: p)
        guard !session.connectedPeers.contains(where: { DuoLink.role(of: $0) == theirRole }) else { return }
        let last = discovered[p] ?? .distantPast
        guard Date().timeIntervalSince(last) > 12 else { return }
        discovered[p] = Date()
        browser.invitePeer(p, to: session, withContext: nil, timeout: 10)
    }

    fileprivate func found(_ p: MCPeerID, by b: MCNearbyServiceBrowser) {
        guard b === browser else { return }          // a stopped browser's late report
        if discovered[p] == nil { discovered[p] = .distantPast }
        inviteIfNeeded(p)
    }

    fileprivate func lost(_ p: MCPeerID) {
        discovered[p] = nil
    }

    private func drop(role r: String) {
        guard partners[r] != nil else { return }
        partners[r] = nil
        lastHeard[r] = nil
        updateName()
        onLost?(r)
        if partners.isEmpty && enabled { beginSearch() }   // alone again: look for a fresh window
    }

    private func updateName() {
        let order = ["bellweather", "aether", "orbitakt"]
        let roles = partners.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }
        partnerName = roles.isEmpty ? nil : roles.map(DuoLink.displayName(role:)).joined(separator: " + ")
    }

    fileprivate func received(_ data: Data) {
        guard enabled,
              let s = try? JSONDecoder().decode(DuoState.self, from: data), s.role != role else { return }
        lastHeard[s.role] = Date()
        let isNew = partners[s.role] == nil
        partners[s.role] = s
        if isNew { updateName() }
        phase = .connected
        searchEnds = nil
        onState?(s)
    }

    fileprivate func peerDisconnected(_ name: String) {
        let r = String(name.split(separator: "-").first ?? "")
        // Only if no other phone of that app is still with us.
        if !session.connectedPeers.contains(where: { DuoLink.role(of: $0) == r }) { drop(role: r) }
    }

    /// Accept unless we're already connected to a different phone running the inviter's app.
    /// A relaunched partner keeps its name, so a stale entry for the same name doesn't block it.
    fileprivate func accepts(_ name: String) -> Bool {
        guard enabled && radiosOn else { return false }
        let r = String(name.split(separator: "-").first ?? "")
        guard r != role else { return false }
        return !session.connectedPeers.contains { DuoLink.role(of: $0) == r && $0.displayName != name }
    }

    fileprivate var mcSession: MCSession { session }
}

// MARK: - Multipeer delegates (arrive on background queues)

extension DuoLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .notConnected {
            let name = peerID.displayName
            DispatchQueue.main.async { [weak self] in self?.peerDisconnected(name) }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in self?.received(data) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                 fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension DuoLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        // Only pair with *other* apps; the invite itself happens on the main queue.
        guard let theirRole = info?["role"], theirRole != role else { return }
        DispatchQueue.main.async { [weak self] in self?.found(peerID, by: browser) }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in self?.lost(peerID) }
    }
}

extension DuoLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let name = peerID.displayName
        DispatchQueue.main.async { [weak self] in
            guard let self else { invitationHandler(false, nil); return }
            let ok = self.accepts(name)
            invitationHandler(ok, ok ? self.mcSession : nil)
        }
    }
}

/// Scale vocabulary all the apps understand (matched by semitone steps).
enum DuoScales {
    static let all: [(name: String, steps: [Int])] = [
        ("Major pentatonic", [0, 2, 4, 7, 9]),
        ("Minor pentatonic", [0, 3, 5, 7, 10]),
        ("Major", [0, 2, 4, 5, 7, 9, 11]),
        ("Natural minor", [0, 2, 3, 5, 7, 8, 10]),
        ("Dorian", [0, 2, 3, 5, 7, 9, 10]),
        ("Lydian", [0, 2, 4, 6, 7, 9, 11]),
        ("Whole tone", [0, 2, 4, 6, 8, 10]),
        ("Hirajoshi", [0, 2, 3, 7, 8]),
        ("Suspended", [0, 2, 5, 7, 10]),
    ]
}
