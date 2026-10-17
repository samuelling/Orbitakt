import Foundation
import MultipeerConnectivity

/// The message both apps exchange. Every field is optional; each app fills in what it owns.
///
/// Division of labour (by timescale):
///  • Bellweather (sky, hours)   → harmony: root pitch class and scale.
///  • Aether (radio room, secs)  → time: tempo and the shared chord timeline.
///  • Both                       → a short summary of their environment.
struct DuoState: Codable, Equatable {
    var role: String                 // "aether" | "bellweather"
    var seq: Int = 0

    // Harmony (Bellweather leads)
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
}

/// Finds the partner app nearby (Bluetooth or peer-to-peer Wi-Fi, no router needed),
/// connects automatically, and keeps both sides informed. If the partner goes quiet for
/// 10 s it is dropped, and each app simply carries on solo until they find each other again.
///
/// Roles: Aether and Bellweathered are the two *leads*; they pair with each other as before.
/// Any other role (Leitmotif, Orbitakt) is a *listener*: it never invites and never sends, and both
/// leads invite it into their sessions, so it hears everything without changing the duo.
///
/// Not actor-isolated: every callback hops to the main queue before touching state, and
/// `onState` is always called on the main queue.
final class DuoLink: NSObject, ObservableObject {
    static let serviceType = "aether-duo"      // must match NSBonjourServices in Info.plist
    static let leadRoles: Set<String> = ["aether", "bellweather"]

    /// "aether-1A2B3C" → "aether"
    static func role(of peer: MCPeerID) -> String {
        String(peer.displayName.split(separator: "-").first ?? "")
    }

    static func appName(of role: String) -> String {
        switch role {
        case "aether": return "Aether"
        case "bellweather": return "Bellweathered"
        case "leitmotif": return "Leitmotif"
        case "orbitakt": return "Orbitakt"
        default: return role
        }
    }

    enum Phase: Equatable { case off, searching, connected, paused }

    @Published private(set) var partnerName: String?
    @Published private(set) var partner: DuoState?
    @Published private(set) var phase: Phase = .off
    /// When the current search gives up (nil = searching indefinitely, or not searching).
    @Published private(set) var searchEnds: Date?
    /// Listener apps (Leitmotif) currently connected to us, by app name. Leads only.
    @Published private(set) var listeners: [String] = []
    /// User settings, persisted.
    @Published private(set) var enabled: Bool
    @Published private(set) var timeoutMinutes: Int       // 0 = never stop looking

    /// Called on the main queue whenever a partner's state arrives.
    var onState: ((DuoState) -> Void)?
    /// Called on the main queue when the partner disconnects or times out.
    var onLost: (() -> Void)?

    var isConnected: Bool { partner != nil }

    private let role: String
    /// Roles whose state this app wants: the other lead, or (for a listener) both leads.
    private let listens: Set<String>
    private var isListener: Bool { !DuoLink.leadRoles.contains(role) }
    private let peer: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// Stopped advertisers/browsers are never reused or freed. Restarting one object, or
    /// freeing it while its cancel is still in flight, is what crashed inside Multipeer
    /// (_BrowserCancel → CFRunLoopSourceInvalidate). Each search gets fresh objects instead.
    private var retired: [NSObject] = []
    private var radiosOn = false
    private var lastStop = Date.distantPast
    private var lastHeard = Date.distantPast
    /// Partner-app peers the browser has seen and not lost (main queue only), with the time
    /// we last invited each.
    private var discovered: [MCPeerID: Date] = [:]
    private var watchdog: Timer?
    private var seq = 0

    init(role: String) {
        self.role = role
        listens = DuoLink.leadRoles.contains(role) ? DuoLink.leadRoles.subtracting([role]) : DuoLink.leadRoles
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

    /// Call once at launch. Searches if the user has the duo turned on.
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
            dropPartner()
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

    /// Send our current state to the partner (cheap; call on change and as a heartbeat).
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

    private func deadline() -> Date? {
        timeoutMinutes > 0 ? Date().addingTimeInterval(Double(timeoutMinutes) * 60) : nil
    }

    private func beginSearch() {
        guard enabled else { return }
        radiosOnIfNeeded()
        if partner != nil {
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
        if partner != nil && Date().timeIntervalSince(lastHeard) > 10 { dropPartner() }
        guard phase == .searching, !hasPartnerPeer else { return }
        if let end = searchEnds, Date() >= end {
            // Nobody turned up: stop advertising and listening until asked again.
            radiosOff()
            phase = .paused
            searchEnds = nil
            return
        }
        // Re-invite any partner we can still see (the browser keeps running).
        for p in Array(discovered.keys) { inviteIfNeeded(p) }
    }

    /// A connected peer whose state we care about (a listener connected to us doesn't count).
    private var hasPartnerPeer: Bool {
        session.connectedPeers.contains { listens.contains(DuoLink.role(of: $0)) }
    }

    /// Exactly one side of each pair invites: a lead always invites a listener; between
    /// the leads, the lower display name invites. Listeners never invite.
    private func shouldInvite(_ p: MCPeerID) -> Bool {
        if isListener { return false }
        if !DuoLink.leadRoles.contains(DuoLink.role(of: p)) { return true }
        return peer.displayName < p.displayName
    }

    /// Main queue only. At most one invite per peer every 12 s.
    fileprivate func inviteIfNeeded(_ p: MCPeerID) {
        guard radiosOn, let browser, shouldInvite(p) else { return }
        guard !session.connectedPeers.contains(where: { $0.displayName == p.displayName }) else { return }
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

    private func dropPartner() {
        let had = partner != nil
        partner = nil
        partnerName = nil
        if had {
            onLost?()
            // Lost them: look again for a fresh window.
            if enabled { beginSearch() }
        }
    }

    fileprivate func received(_ data: Data, from name: String) {
        guard enabled,
              let s = try? JSONDecoder().decode(DuoState.self, from: data), listens.contains(s.role) else { return }
        lastHeard = Date()
        partner = s
        partnerName = DuoLink.appName(of: s.role)
        phase = .connected
        searchEnds = nil
        onState?(s)
    }

    fileprivate func peerDisconnected() {
        refreshListeners()
        if !hasPartnerPeer { dropPartner() }
    }

    fileprivate func refreshListeners() {
        guard !isListener else { return }
        let names = Set(session.connectedPeers.map { DuoLink.role(of: $0) }
            .filter { !DuoLink.leadRoles.contains($0) }
            .map { DuoLink.appName(of: $0) })
        let sorted = names.sorted()
        if sorted != listeners { listeners = sorted }
    }

    fileprivate var acceptsInvites: Bool { enabled && radiosOn }
}

// MARK: - Multipeer delegates (arrive on background queues)

extension DuoLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .notConnected {
            DispatchQueue.main.async { [weak self] in self?.peerDisconnected() }
        } else if state == .connected {
            DispatchQueue.main.async { [weak self] in self?.refreshListeners() }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let name = peerID.displayName
        DispatchQueue.main.async { [weak self] in self?.received(data, from: name) }
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
        // Only pair with the *other* app; the invite itself happens on the main queue.
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
        // Accept unless we're already paired with a different app of the same role (a second
        // Aether, say). A relaunched partner keeps its name, so a stale entry for the same
        // name doesn't block the new invite; a listener happily joins both leads.
        let name = peerID.displayName
        let theirRole = DuoLink.role(of: peerID)
        DispatchQueue.main.async { [weak self] in
            guard let self else { invitationHandler(false, nil); return }
            let ok = self.acceptsInvites && !self.session.connectedPeers.contains {
                DuoLink.role(of: $0) == theirRole && $0.displayName != name
            }
            invitationHandler(ok, ok ? self.session : nil)
        }
    }
}

/// Scale vocabulary both apps understand (matched by semitone steps).
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
