import SwiftUI

/// The sky above you, seen from above like a map: zenith in the middle, horizon at the rim,
/// north up and east to the right. Every satellite above the horizon is a dot in its
/// family's colour; each track's cone is a ring around the zenith, and the dots inside a
/// cone are lit. The radar beam is the playhead: each lit dot flashes as the beam reaches it,
/// at the moment it plays.
struct DomeView: View {
    @ObservedObject var model: RhythmModel

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                draw(&ctx, size: size, date: timeline.date)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Sky dome: \(model.snapshot.blips.count) satellites above the horizon")
    }

    private func color(_ f: Family) -> Color {
        switch f {
        case .nav: return RhythmModel.specs[0].color
        case .leo: return RhythmModel.specs[1].color
        case .swarm: return RhythmModel.specs[2].color
        case .belt: return RhythmModel.specs[3].color
        case .crew: return RhythmModel.crewColor
        case .other: return .gray
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, date: Date) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) / 2 - 14
        let up = ProcessInfo.processInfo.systemUptime

        func circle(_ p: CGPoint, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        func point(az: Double, zenith: Double) -> CGPoint {
            let r = R * CGFloat(min(90, max(0, zenith)) / 90)
            let a = az * .pi / 180
            return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
        }

        // Horizon, elevation rings at 30° and 60°, compass
        ctx.fill(circle(c, R), with: .radialGradient(
            Gradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.16), Color(red: 0.01, green: 0.01, blue: 0.04)]),
            center: c, startRadius: 0, endRadius: R))
        ctx.stroke(circle(c, R), with: .color(.white.opacity(0.18)), lineWidth: 1)
        // A dub throw lights the horizon in the rimshot's colour while the echo spirals
        if model.throwLevel > 0.02 {
            let th = model.throwLevel
            ctx.stroke(circle(c, R), with: .color(RhythmModel.specs[1].color.opacity(0.55 * th)),
                       lineWidth: 1 + 3 * CGFloat(th))
        }
        for z in [30.0, 60.0] {
            ctx.stroke(circle(c, R * CGFloat(z / 90)), with: .color(.white.opacity(0.06)), lineWidth: 1)
        }
        for (label, az) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
            let a = az * .pi / 180
            let p = CGPoint(x: c.x + (R + 8) * CGFloat(sin(a)), y: c.y - (R + 8) * CGFloat(cos(a)))
            ctx.draw(Text(label).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45)), at: p)
        }

        // Cones, one ring per track
        for (i, t) in model.tracks.enumerated() {
            let col = RhythmModel.specs[i].color
            let r = R * CGFloat(min(90, t.cone) / 90)
            ctx.stroke(circle(c, r), with: .color(col.opacity(t.muted ? 0.12 : 0.35)),
                       style: StrokeStyle(lineWidth: 1, dash: t.auto ? [] : [3, 3]))
        }

        // The beam: the playhead itself, from north, clockwise
        let sweep = model.sweepPhase
        if model.isPlaying {
            let a = sweep * 2 * .pi
            var trail = Path()
            trail.move(to: c)
            trail.addArc(center: c, radius: R, startAngle: .radians(a - .pi / 2 - 0.5),
                         endAngle: .radians(a - .pi / 2), clockwise: false)
            trail.closeSubpath()
            ctx.fill(trail, with: .color(.white.opacity(0.035)))
            var line = Path()
            line.move(to: c)
            line.addLine(to: CGPoint(x: c.x + R * CGFloat(sin(a)), y: c.y - R * CGFloat(cos(a))))
            ctx.stroke(line, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }

        // Satellites
        let cones = model.tracks.map(\.cone)
        for b in model.snapshot.blips {
            let p = point(az: Double(b.az), zenith: Double(b.zenith))
            let col = color(b.family)
            let ti = b.family.rawValue
            let lit = ti < cones.count && Double(b.zenith) <= cones[ti]
            switch b.family {
            case .crew:
                ctx.fill(circle(p, 9), with: .radialGradient(Gradient(colors: [col.opacity(0.6), .clear]),
                                                               center: p, startRadius: 0, endRadius: 9))
                ctx.fill(circle(p, 3.2), with: .color(col))
            case .other:
                ctx.fill(circle(p, 0.8), with: .color(.white.opacity(0.25)))
            default:
                let r: CGFloat = b.family == .swarm ? 1.1 : 1.6
                if lit {
                    // Flash as the beam passes (fading over ~5% of a revolution)
                    var flash = 0.0
                    if model.isPlaying && !model.tracks[ti].muted {
                        let since = (sweep - model.firePhase(Double(b.az) / 360) + 1).truncatingRemainder(dividingBy: 1)
                        if since < 0.05 { flash = 1 - since / 0.05 }
                    }
                    let gr = r * (3 + 4 * CGFloat(flash))
                    ctx.fill(circle(p, gr), with: .radialGradient(Gradient(colors: [col.opacity(0.5 + 0.4 * flash), .clear]),
                                                                center: p, startRadius: 0, endRadius: gr))
                    ctx.fill(circle(p, r + 0.6 + 1.6 * CGFloat(flash)), with: .color(col))
                } else {
                    ctx.fill(circle(p, r), with: .color(col.opacity(0.4)))
                }
            }
        }

        // Zenith pings: a ring spreading from where it passed overhead
        for ping in model.pings {
            let age = up - ping.t
            guard age >= 0, age < 6 else { continue }
            let p = point(az: ping.az, zenith: 90 - ping.el)
            ctx.stroke(circle(p, 4 + CGFloat(age) * 18), with: .color(.white.opacity(0.6 * (1 - age / 6))),
                       lineWidth: 1.2)
        }
        let pingR = R * CGFloat(model.pingRadius / 90)
        ctx.stroke(circle(c, max(2, pingR)), with: .color(.white.opacity(0.25)), lineWidth: 0.8)
        ctx.fill(circle(c, 1.6), with: .color(.white.opacity(0.7)))
    }
}

/// One track's radar line: each satellite in its cone is a dot at the point in the sweep where
/// it plays (its bearing, pulled toward the grid by Quantize), sized by how high it is. The
/// playhead is the beam; dots flash as it passes.
struct TrackRow: View {
    @ObservedObject var model: RhythmModel
    let index: Int

    var body: some View {
        let spec = RhythmModel.specs[index]
        let t = model.tracks[index]
        HStack(spacing: 10) {
            Button { model.setMuted(!t.muted, track: index) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.family.label)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(t.muted ? Color.white.opacity(0.3) : spec.color)
                    Text("\(t.hits.count) \(spec.sound)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(t.muted ? 0.25 : 0.6))
                }
                .frame(width: 74, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(spec.family.label) \(spec.sound), \(t.hits.count) satellites\(t.muted ? ", muted" : "")")
            .accessibilityHint("Double tap to \(t.muted ? "unmute" : "mute")")

            TimelineView(.animation) { _ in
                let sweep = model.sweepPhase
                let playing = model.isPlaying
                Canvas { ctx, size in
                    let w = size.width, y = size.height / 2
                    // Grid: 16 slots, beats stronger
                    for s in 0...OrbitParams.gridSlots {
                        let x = w * CGFloat(s) / CGFloat(OrbitParams.gridSlots)
                        var tick = Path()
                        let h: CGFloat = s % 4 == 0 ? 7 : 3
                        tick.move(to: CGPoint(x: x, y: y - h))
                        tick.addLine(to: CGPoint(x: x, y: y + h))
                        ctx.stroke(tick, with: .color(.white.opacity(s % 4 == 0 ? 0.18 : 0.08)), lineWidth: 1)
                    }
                    var base = Path()
                    base.move(to: CGPoint(x: 0, y: y))
                    base.addLine(to: CGPoint(x: w, y: y))
                    ctx.stroke(base, with: .color(.white.opacity(0.08)), lineWidth: 1)
                    for h in t.hits {
                        let f = model.firePhase(h.phase)
                        let x = w * CGFloat(f)
                        var flash = 0.0
                        if playing && !t.muted {
                            let since = (sweep - f + 1).truncatingRemainder(dividingBy: 1)
                            if since < 0.04 { flash = 1 - since / 0.04 }
                        }
                        let r = 2.5 + 3 * CGFloat(h.vel) + 3 * CGFloat(flash)
                        let pt = CGPoint(x: x, y: y)
                        if flash > 0 {
                            ctx.fill(Path(ellipseIn: CGRect(x: x - r * 2, y: y - r * 2, width: r * 4, height: r * 4)),
                                     with: .radialGradient(Gradient(colors: [spec.color.opacity(0.5 * flash), .clear]),
                                                           center: pt, startRadius: 0, endRadius: r * 2))
                        }
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: .color(spec.color.opacity(t.muted ? 0.2 : 0.55 + 0.45 * flash)))
                    }
                    if playing {
                        var head = Path()
                        let x = w * CGFloat(sweep)
                        head.move(to: CGPoint(x: x, y: 1))
                        head.addLine(to: CGPoint(x: x, y: size.height - 1))
                        ctx.stroke(head, with: .color(.white.opacity(0.5)), lineWidth: 1)
                    }
                }
            }
            .frame(height: 22)
        }
    }
}
