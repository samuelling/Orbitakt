import AVFoundation

/// AVAudioEngine graph:
///
///   OrbitDSP dry bus ────────────────────────────────────────────── main out
///   OrbitDSP send bus ── delay (dotted eighth) ── hall reverb ── EQ ─┘
///
/// The two buses come from one DSP through two source nodes; the dry node renders both and
/// the send node hands over what it rendered. The reverb return is high-passed so the kick's
/// tail never muddies the room.
final class OrbitEngine {
    let params = OrbitParams()

    private let engine = AVAudioEngine()
    private let delay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private var dryNode: AVAudioSourceNode?
    private var sendNode: AVAudioSourceNode?
    private var dsp: OrbitDSP?
    private var wantsRunning = false
    private var stopToken = 0
    private var observers: [NSObjectProtocol] = []
    private var lastDelay = 0.0, lastSpace = -1.0

    init() {
        delay.delayTime = 0.5
        delay.feedback = 38
        delay.lowPassCutoff = 3800
        delay.wetDryMix = 42
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = 100
        let hp = eq.bands[0]
        hp.filterType = .highPass
        hp.frequency = 220
        hp.bypass = false
        let lp = eq.bands[1]
        lp.filterType = .lowPass
        lp.frequency = 7500
        lp.bypass = false
        eq.globalGain = 0
        [delay, reverb, eq].forEach { engine.attach($0) }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.resumeIfNeeded()
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: .main) { [weak self] _ in
            self?.resumeIfNeeded()
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    var isRunning: Bool { engine.isRunning }

    /// Echo on a dotted eighth (0.75 beat), inside AVAudioUnitDelay's 2 s limit.
    func setTempo(_ bpm: Double) {
        let t = min(2.0, max(0.05, 60 / max(20, bpm) * 0.75))
        if abs(t - lastDelay) > 0.005 { lastDelay = t; delay.delayTime = t }
    }

    /// 0…1: how big the space is (reverb return level and echo feedback).
    func setSpace(_ x: Double) {
        guard abs(x - lastSpace) > 0.01 else { return }
        lastSpace = x
        eq.globalGain = Float(20 * log10(max(0.05, 0.35 + 0.9 * x)))
        delay.feedback = Float(20 + 30 * x)
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        if dryNode == nil { buildGraph() }
        wantsRunning = true
        stopToken += 1
        params[.master] = 0.7
        if !engine.isRunning { try engine.start() }
    }

    func stop() {
        wantsRunning = false
        params[.master] = 0
        stopToken += 1
        let token = stopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, token == self.stopToken, !self.wantsRunning else { return }
            self.engine.pause()
        }
    }

    private func resumeIfNeeded() {
        guard wantsRunning, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    private func buildGraph() {
        var sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 48_000 }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let dsp = OrbitDSP(sampleRate: Float(sampleRate), params: params)
        let dry = AVAudioSourceNode(format: format) { _, _, frameCount, ablPointer in
            let buffers = UnsafeMutableAudioBufferListPointer(ablPointer)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            dsp.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        let send = AVAudioSourceNode(format: format) { _, _, frameCount, ablPointer in
            let buffers = UnsafeMutableAudioBufferListPointer(ablPointer)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            dsp.copySend(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(dry)
        engine.attach(send)
        let mixer = engine.mainMixerNode
        engine.connect(dry, to: mixer, format: format)
        engine.connect(send, to: delay, format: format)
        engine.connect(delay, to: reverb, format: format)
        engine.connect(reverb, to: eq, format: format)
        engine.connect(eq, to: mixer, format: format)
        mixer.outputVolume = 0.9
        engine.prepare()
        dryNode = dry
        sendNode = send
        self.dsp = dsp
    }
}
