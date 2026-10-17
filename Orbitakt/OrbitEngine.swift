import AVFoundation

/// AVAudioEngine graph:
///
///   OrbitDSP dry bus (drums + dub echoes) ─────────────── main out
///   OrbitDSP plate send ────────── plate reverb ── EQ ───┘
///
/// The dub delay runs inside OrbitDSP (it needs feedback filtering, saturation and wow that
/// AVAudioUnitDelay can't do). The two buses come from one DSP through two source nodes; the
/// dry node renders both and the send node hands over what it rendered. The plate return is
/// high-passed so the kick's tail never muddies it.
final class OrbitEngine {
    let params = OrbitParams()

    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private var dryNode: AVAudioSourceNode?
    private var sendNode: AVAudioSourceNode?
    private var dsp: OrbitDSP?
    private var wantsRunning = false
    private var stopToken = 0
    private var observers: [NSObjectProtocol] = []
    private var lastSpace = -1.0

    init() {
        reverb.loadFactoryPreset(.plate)
        reverb.wetDryMix = 100
        let hp = eq.bands[0]
        hp.filterType = .highPass
        hp.frequency = 320
        hp.bypass = false
        let lp = eq.bands[1]
        lp.filterType = .lowPass
        lp.frequency = 6000
        lp.bypass = false
        eq.globalGain = 0
        [reverb, eq].forEach { engine.attach($0) }

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

    /// 0…1: how much plate.
    func setSpace(_ x: Double) {
        guard abs(x - lastSpace) > 0.01 else { return }
        lastSpace = x
        params[.reverbSend] = Float(0.2 + 0.8 * x)
        eq.globalGain = Float(20 * log10(max(0.05, 0.5 + 0.7 * x)))
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        if dryNode == nil { buildGraph() }
        wantsRunning = true
        stopToken += 1
        params[.master] = 0.85
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
        engine.connect(send, to: reverb, format: format)
        engine.connect(reverb, to: eq, format: format)
        engine.connect(eq, to: mixer, format: format)
        mixer.outputVolume = 0.9
        engine.prepare()
        dryNode = dry
        sendNode = send
        self.dsp = dsp
    }
}
