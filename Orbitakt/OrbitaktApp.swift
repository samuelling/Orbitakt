import SwiftUI
import AVKit

@main
struct OrbitaktApp: App {
    var body: some Scene {
        WindowGroup { OrbitContentView() }
    }
}

private let pitchNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

struct OrbitContentView: View {
    @StateObject private var model = RhythmModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.02, blue: 0.06), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    DomeView(model: model)
                        .padding(.horizontal, 2)
                    readings
                    VStack(spacing: 8) {
                        ForEach(RhythmModel.specs.indices, id: \.self) { TrackRow(model: model, index: $0) }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
                    playButton
                    Text(model.dataNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            OrbitSettingsView(model: model).presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ORBITAKT")
                    .font(.system(size: 22, weight: .light, design: .monospaced))
                    .tracking(6)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let partner = model.linkName {
                    Label("Listening to \(partner)", systemImage: "link")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
                if let crew = model.crewNote {
                    Label(crew, systemImage: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(RhythmModel.crewColor)
                }
            }
            Spacer()
            OrbitAirPlayButton().frame(width: 30, height: 30)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
            .tint(.white)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 8)
    }

    private var readings: some View {
        let counts = model.snapshot.counts
        return HStack {
            reading("\(model.snapshot.blips.count)", "overhead")
            reading("\(counts[.swarm] ?? 0)", "starlink")
            reading("\(counts[.nav] ?? 0)", "nav")
            reading("\(counts[.belt] ?? 0)", "geo")
            reading(String(format: "%.1f", model.effectiveBPM), "bpm")
        }
    }

    private func reading(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.body, design: .monospaced))
            Text(label).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }

    private var playButton: some View {
        Button(action: model.togglePlay) {
            Label(model.isPlaying ? "Stop" : "Play the sky",
                  systemImage: model.isPlaying ? "stop.fill" : "dot.radiowaves.up.forward")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isPlaying ? Color.white.opacity(0.15) : Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.8))
    }
}

private struct OrbitSettingsView: View {
    @ObservedObject var model: RhythmModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sky", selection: $model.useLive) {
                        Text("Live").tag(true)
                        Text("Simulated").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !model.dataNote.isEmpty {
                        Text(model.dataNote).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Sky")
                } footer: {
                    Text("Orbital elements from CelesTrak (celestrak.org), fetched at most twice a day and positioned on your phone with SGP4. Simulated uses the real constellations' shells and densities with invented positions.")
                }

                ForEach(RhythmModel.specs.indices, id: \.self) { i in
                    TrackSettings(model: model, index: i)
                }

                Section {
                    VStack(alignment: .leading) {
                        Text(String(format: "Zenith pings within %.0f° of straight up", model.pingRadius))
                        Slider(value: $model.pingRadius, in: 1...10, step: 0.5)
                    }
                    Toggle("Gong while a crewed station is up", isOn: $model.gongOn)
                } header: {
                    Text("Events")
                } footer: {
                    Text("Anything that passes almost directly overhead rings a glass bar, pitched by its catalog number. While the ISS or Tiangong is above the horizon, a gong sounds every four bars.")
                }

                Section {
                    Picker("Scale", selection: $model.scaleIndex) {
                        ForEach(DuoScales.all.indices, id: \.self) { Text(DuoScales.all[$0].name).tag($0) }
                    }
                    Picker("Root", selection: $model.rootPC) {
                        ForEach(0..<12, id: \.self) { Text(pitchNames[$0]).tag($0) }
                    }
                    Picker("Tempo", selection: $model.tempoSource) {
                        ForEach(TempoSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if model.tempoSource == .manual {
                        VStack(alignment: .leading) {
                            Text(String(format: "%.0f BPM", model.manualBPM))
                            Slider(value: $model.manualBPM, in: 50...140, step: 1)
                        }
                    } else {
                        Text(String(format: "Orbit tempo: %.1f BPM", model.orbitBPM))
                            .foregroundStyle(.secondary)
                    }
                    Picker("Sweep", selection: $model.division) {
                        Text("Every 2 bars").tag(2)
                        Text("Every bar").tag(4)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Literal")
                            Spacer()
                            Text(String(format: "Quantize %.0f%%", model.quantize * 100)).foregroundStyle(.secondary)
                            Spacer()
                            Text("Grid")
                        }
                        Slider(value: $model.quantize, in: 0...1)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Swing: %.0f%%", model.swing * 100))
                        Slider(value: $model.swing, in: 0...0.3)
                    }
                } header: {
                    Text("Music")
                } footer: {
                    Text("Orbit tempo is the period of the low orbits overhead, thirteen octaves up: a 95-minute orbit × 2¹³ ≈ 86 BPM. The beam goes round your sky once per sweep, starting at north, and every satellite in a cone plays as the beam passes it. Literal plays each one exactly at its bearing; Grid snaps them to 16 slots per sweep (eighths when a sweep is two bars). Swing applies to the grid.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text(String(format: "Dub echo feedback: %.0f%%", model.dub * 100))
                        Slider(value: $model.dub, in: 0...0.85)
                    }
                    VStack(alignment: .leading) {
                        Text("Plate")
                        Slider(value: $model.space, in: 0...1)
                    }
                    Toggle("Dust", isOn: $model.dustOn)
                } header: {
                    Text("Dub")
                } footer: {
                    Text("A ping-pong echo on a dotted eighth, darker and rounder with every repeat. Rimshots and pings go mostly into it, the kick hardly at all. Whenever a low-orbit satellite crosses into its cone, or something passes straight overhead, the echo send is thrown open for a few seconds. Dust is a breath of hiss and crackle that thickens with the crowd overhead.")
                }

                Section {
                    DuoControls(duo: model.duo, partnerName: "Aether & Bellweathered")
                    if let summary = model.partnerSummary {
                        Text(summary).font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Follow Aether's tempo", isOn: $model.followTempo)
                    Toggle("Follow the sky's key", isOn: $model.followKey)
                } header: {
                    Text("Together")
                } footer: {
                    Text("With Aether or Bellweathered on other iPhones nearby, Orbitakt listens in automatically, no Wi-Fi network needed: Bellweathered's sky sets the key, Aether's radio room sets the tempo, and the orbits keep the rhythm. Like Leitmotif, it only listens, so the duo plays exactly as before.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct TrackSettings: View {
    @ObservedObject var model: RhythmModel
    let index: Int

    var body: some View {
        let spec = RhythmModel.specs[index]
        let t = model.tracks[index]
        Section {
            Toggle("Adaptive cone", isOn: Binding(get: { t.auto },
                                                  set: { model.setCone($0 ? nil : t.cone, track: index) }))
            VStack(alignment: .leading) {
                Text(String(format: "Cone: %.0f° from the zenith · %d inside", t.cone, t.inCone))
                    .foregroundStyle(t.auto ? .secondary : .primary)
                Slider(value: Binding(get: { t.cone }, set: { model.setCone($0, track: index) }),
                       in: 2...90)
                    .disabled(t.auto)
            }
            Toggle("Mute", isOn: Binding(get: { t.muted }, set: { model.setMuted($0, track: index) }))
        } header: {
            Text("\(spec.family.label) · \(spec.sound)").foregroundStyle(spec.color)
        } footer: {
            Text(footer(spec.family))
        }
    }

    private func footer(_ f: Family) -> String {
        switch f {
        case .nav: return "GPS, Galileo, GLONASS and BeiDou, 20,000 km up. The cone holds about four on average; each kicks as the beam passes its bearing. They cross the sky in hours, so the kick pattern shifts slowly. A deep kick on the root."
        case .leo: return "Low orbits other than Starlink: OneWeb, Iridium, weather and science satellites. About two in the cone; each crosses the sky in roughly ten minutes, so you hear its hit slide through the sweep. A tuned rimshot, mostly into the echo, and each new arrival throws the echo open."
        case .swarm: return "Starlink. Thousands of them, so the cone is narrow and hats drift, flam and merge as satellites cross. Metallic hats that brighten as more of the swarm is up; higher ones play louder."
        case .belt: return "The geostationary belt: a fixed arc across your sky, to the south in the northern hemisphere. It never moves, so these hits stay put: your location's fingerprint. A soft breath of air with no pitch: darker for satellites in the east, airier toward the west."
        default: return ""
        }
    }
}

private struct OrbitAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
