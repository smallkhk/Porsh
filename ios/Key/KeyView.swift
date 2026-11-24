import SwiftUI

private let bg = Color(red: 0.04, green: 0.043, blue: 0.063)
private let line = Color.white.opacity(0.16)
private let muted = Color(red: 0.54, green: 0.56, blue: 0.61)
private let red = Color(red: 1, green: 0.23, blue: 0.23)

struct KeyRootView: View {
    @StateObject private var model = KeyModel()

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.09, green: 0.1, blue: 0.15), bg], center: .top, startRadius: 0, endRadius: 600)
                .ignoresSafeArea()
            if model.paired { KeyView(model: model) } else { PairView(model: model) }
        }
        .preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }
}

// MARK: - Main controller

struct KeyView: View {
    @ObservedObject var model: KeyModel
    @State private var garageOpen = false

    private var s: CarState { model.state ?? CarState() }

    var body: some View {
        ScrollView(showsIndicators: false) {
            header.padding(.horizontal, 20)
            VStack(alignment: .leading, spacing: 0) {
                readout.padding(.top, 22)
                ShiftLights(rpm: s.rpm, running: s.running).padding(.top, 14)
                roundButtons.padding(.top, 24)
                HStack(spacing: 14) {
                    EngineButton(running: s.running || s.starting) { model.cmd("engine") }
                    ThrottlePad(value: model.throttle) { model.setThrottle($0) }
                }
                .frame(height: 170)
                .padding(.top, 20)
                launchButton.padding(.top, 14)
                Text(model.flash ?? hint)
                    .font(.system(size: 14)).foregroundColor(model.flash != nil ? .white : muted)
                    .padding(.top, 14).frame(minHeight: 40, alignment: .top)
                garage.padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
            .disabled(!model.connected)
            .opacity(model.connected ? 1 : 0.4)
            .animation(.easeOut(duration: 0.3), value: model.connected)
        }
    }

    private var header: some View {
        HStack {
            Text("APEX 9R").font(.system(size: 15, weight: .bold)) + Text("  GT").font(.system(size: 13, weight: .medium)).foregroundColor(muted)
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    .shadow(color: model.connected ? .green : .clear, radius: 4)
                Text(model.status).font(.system(size: 13)).foregroundColor(model.connected ? .white : muted)
            }
        }
        .padding(.top, 8)
    }

    private var title: String {
        if s.locked { return "Locked" }
        if s.starting { return "Starting" }
        if s.mode == "arm" { return (s.cd ?? 0) > 0 ? "\(s.cd!)" : "GO" }
        if s.mode == "run" || s.mode == "coast" { return "\(s.speed)" }
        if s.running { return s.rpm.formatted() }
        return "Unlocked"
    }
    private var unit: String {
        if s.locked || s.starting || s.mode == "arm" { return "" }
        if s.mode == "run" || s.mode == "coast" { return "km/h" }
        return s.running ? "rpm" : ""
    }
    private var sub: String {
        if s.mode == "run" || s.mode == "coast" {
            var t = "GEAR \(s.gear) · \(s.rpm.formatted()) RPM"
            if let t100 = s.t100 { t += String(format: " · 0–100 %.2fs", t100) }
            return t
        }
        if s.running { return s.t100.map { String(format: "Last launch: 0–100 in %.2f s", $0) } ?? "Idle · neutral" }
        return " "
    }
    private var hint: String {
        if !model.connected { return "Open the showroom on your iPad. The key connects by itself." }
        if s.locked { return "Unlock the car to begin." }
        if s.running { return s.mode == "idle" ? "Hold the throttle to rev. Tap Launch for a full launch run." : "Hold on…" }
        return "Hold the engine button to start it."
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 64, weight: .bold)).monospacedDigit().tracking(-2)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(unit).font(.system(size: 18, weight: .medium)).foregroundColor(muted)
            }
            Text(sub).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(muted)
        }
    }

    private var roundButtons: some View {
        HStack(spacing: 0) {
            RoundButton(icon: "lock.open", label: "Unlock", on: !s.locked) { model.cmd("unlock") }
            RoundButton(icon: "lock", label: "Lock", on: s.locked) { model.cmd("lock") }
            RoundButton(icon: "door.left.hand.open", label: "Doors", on: s.doors) { model.cmd("doors") }
            RoundButton(icon: s.lights == 2 ? "headlight.high.beam" : "headlight.low.beam",
                        label: s.lights == 2 ? "High" : "Lights", on: s.lights > 0) { model.cmd("lights") }
        }
    }

    private var launchButton: some View {
        let armed = s.mode == "arm" || s.mode == "run"
        let ready = s.running && s.mode == "idle"
        return Button {
            Haptics.medium(); model.cmd("launch")
        } label: {
            Text(s.mode == "arm" ? "Armed — tap to abort" : s.mode == "run" ? "Abort" : "Launch")
                .font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .foregroundColor(ready ? .black : .white)
                .background(RoundedRectangle(cornerRadius: 16).fill(armed ? red : ready ? Color.white : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(armed ? red : line, lineWidth: 1.5))
                .shadow(color: armed ? red.opacity(0.7) : .clear, radius: 14)
        }
        .buttonStyle(.plain)
    }

    private var garage: some View {
        VStack(spacing: 0) {
            Divider().background(line)
            Button { withAnimation { garageOpen.toggle() } } label: {
                HStack { Text("Garage").font(.system(size: 14, weight: .semibold)); Spacer(); Image(systemName: garageOpen ? "minus" : "plus") }
                    .foregroundColor(Color(white: 0.82)).padding(.vertical, 12)
            }.buttonStyle(.plain)
            if garageOpen {
                VStack(spacing: 14) {
                    HStack {
                        Text("Paint")
                        Spacer()
                        HStack(spacing: 8) {
                            ForEach(paintChoices, id: \.hex) { p in
                                Circle().fill(Color(uiColor: UIColor(hex: p.hex))).frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(Color.white, lineWidth: s.paint == p.hex ? 2 : 0))
                                    .onTapGesture { Haptics.tap(); model.cmd("paint", p.hex) }
                            }
                        }
                    }
                    Toggle("Rear wing", isOn: Binding(get: { s.wing }, set: { model.cmd("wing", $0) }))
                    Toggle("Centre stripe", isOn: Binding(get: { s.livery }, set: { model.cmd("livery", $0) }))
                    HStack {
                        Text("Horn"); Spacer()
                        HoldButton(label: "Hold") { down in model.cmd("horn", down); if down { Haptics.heavy() } }
                    }
                    HStack {
                        Text("Car \(model.code) · \(model.host)").font(.system(size: 12, design: .monospaced)).foregroundColor(muted)
                        Spacer()
                        Button("Change car") { model.unpair() }.font(.system(size: 13, weight: .semibold))
                    }
                }
                .font(.system(size: 14))
                .tint(Color(red: 0.31, green: 0.55, blue: 1))
                .padding(.bottom, 10)
            }
        }
    }
}

// MARK: - Components

struct RoundButton: View {
    let icon: String, label: String, on: Bool, action: () -> Void
    var body: some View {
        Button { Haptics.tap(); action() } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 22, weight: .regular))
                    .frame(width: 70, height: 70)
                    .foregroundColor(on ? .black : .white)
                    .background(Circle().fill(on ? Color.white : Color.clear))
                    .overlay(Circle().stroke(on ? Color.white : line, lineWidth: 1.5))
                Text(label).font(.system(size: 13)).foregroundColor(on ? .white : Color(white: 0.8))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.93 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Hold for 0.65 s to start / stop.
struct EngineButton: View {
    let running: Bool
    let fire: () -> Void
    @State private var progress: CGFloat = 0
    @State private var holding = false
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(red: 0.11, green: 0.13, blue: 0.17), Color(red: 0.05, green: 0.06, blue: 0.08)],
                                         center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 110))
                .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
            Circle().stroke(running ? red : line, lineWidth: 3).shadow(color: running ? red : .clear, radius: 6).padding(4)
            Circle().trim(from: 0, to: progress).stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(4)
            VStack(spacing: 2) {
                Text("ENGINE").font(.system(size: 17, weight: .heavy)).tracking(0.7)
                Text("START STOP").font(.system(size: 11, weight: .bold)).tracking(0.9).foregroundColor(Color(white: 0.82))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .scaleEffect(holding ? 0.97 : 1)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !holding { begin() } }
            .onEnded { _ in end(fired: false) })
    }

    private func begin() {
        holding = true
        Haptics.tap()
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { _ in
            let p = min(1, Date().timeIntervalSince(start) / 0.65)
            progress = CGFloat(p)
            if p >= 1 { end(fired: true) }
        }
    }

    private func end(fired: Bool) {
        guard timer != nil || holding else { return }
        timer?.invalidate(); timer = nil
        if fired { Haptics.heavy(); fire() }
        withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
        holding = fired ? holding : false
    }
}

/// Hold to rev, slide up for more.
struct ThrottlePad: View {
    let value: Double
    let set: (Double) -> Void
    @State private var startY: CGFloat?
    @State private var lastTick = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.04))
                Rectangle()
                    .fill(LinearGradient(colors: [red.opacity(0.55), Color.white.opacity(0.18)], startPoint: .bottom, endPoint: .top))
                    .frame(height: geo.size.height * value)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Throttle").font(.system(size: 16, weight: .bold))
                    Text("Hold. Slide up for more.").font(.system(size: 13)).foregroundColor(Color(white: 0.8))
                }.padding(16)
                if value > 0 {
                    Text("\(Int(value * 100))%").font(.system(size: 14, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(14)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(startY != nil ? Color.white.opacity(0.5) : line, lineWidth: 1.5))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if startY == nil { startY = g.startLocation.y; Haptics.tap() }
                    let v = min(1, max(0.08, 0.4 + Double((startY! - g.location.y) / (geo.size.height * 0.55))))
                    let tick = Int(v * 10)
                    if tick != lastTick { lastTick = tick; Haptics.medium(0.4) }
                    set(v)
                }
                .onEnded { _ in startY = nil; lastTick = 0; set(0) })
        }
    }
}

struct ShiftLights: View {
    let rpm: Int, running: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let n = running ? max(0, min(10, Int(ceil(Double(rpm - 5000) / 380)))) : 0
            let flash = rpm > 8800 && Int(ctx.date.timeIntervalSinceReferenceDate * 14) % 2 == 0
            HStack(spacing: 5) {
                ForEach(0..<10, id: \.self) { i in
                    let c: Color = flash ? Color(red: 0.31, green: 0.55, blue: 1)
                        : i >= n ? Color.white.opacity(0.07)
                        : i < 4 ? Color.green : i < 7 ? Color.yellow : red
                    Capsule().fill(c).frame(height: 8).shadow(color: (flash || i < n) ? c : .clear, radius: 4)
                }
            }
        }
    }
}

struct HoldButton: View {
    let label: String
    let change: (Bool) -> Void
    @State private var down = false
    var body: some View {
        Text(label).font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 8)
            .foregroundColor(down ? .black : .white)
            .background(Capsule().fill(down ? Color.white : Color.clear))
            .overlay(Capsule().stroke(line, lineWidth: 1.5))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; change(true) } }
                .onEnded { _ in down = false; change(false) })
    }
}
