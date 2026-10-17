import SwiftUI

/// Rows for a Form section: turn the partner search on or off, choose how long to keep
/// looking, and see where things stand. Shared by Aether and Bellweathered.
struct DuoControls: View {
    @ObservedObject var duo: DuoLink
    let partnerName: String

    var body: some View {
        Toggle("Look for \(partnerName)", isOn: Binding(get: { duo.enabled },
                                                       set: { duo.setEnabled($0) }))
        if duo.enabled {
            Picker("Stop looking after", selection: Binding(get: { duo.timeoutMinutes },
                                                            set: { duo.setTimeout(minutes: $0) })) {
                Text("2 minutes").tag(2)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("Never").tag(0)
            }
        }
        HStack {
            Text("Status")
            Spacer()
            status.foregroundStyle(duo.phase == .connected ? Color.cyan : Color.secondary)
        }
        if !duo.listeners.isEmpty {
            HStack {
                Text("Listening in")
                Spacer()
                Text(duo.listeners.joined(separator: ", ")).foregroundStyle(Color.pink)
            }
        }
        if duo.phase == .paused {
            Button("Search again") { duo.searchAgain() }
        }
    }

    @ViewBuilder private var status: some View {
        switch duo.phase {
        case .off:
            Text("Off")
        case .connected:
            Text("Playing with \(duo.partnerName ?? partnerName)")
        case .paused:
            Text("Not found, stopped looking")
        case .searching:
            if let end = duo.searchEnds, end > Date() {
                HStack(spacing: 4) {
                    Text("Looking…")
                    Text(timerInterval: Date()...end, countsDown: true).monospacedDigit()
                }
            } else {
                Text("Looking…")
            }
        }
    }
}
