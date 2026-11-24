import SwiftUI
import SceneKit

@main
struct APEXViewerApp: App {
    var body: some Scene {
        WindowGroup { ShowroomView() }
    }
}

private let muted = Color(red: 0.55, green: 0.58, blue: 0.63)
private let glassFill = Color(red: 0.055, green: 0.063, blue: 0.086).opacity(0.62)
private let lineC = Color.white.opacity(0.12)

struct SceneContainer: UIViewRepresentable {
    let showroom: Showroom

    func makeCoordinator() -> Coordinator { Coordinator(showroom) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = showroom.scene
        v.pointOfView = showroom.cameraNode
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 60
        v.rendersContinuously = true
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.target = SCNVector3(0, 0.62, 0)
        v.defaultCameraController.maximumVerticalAngle = 38
        v.defaultCameraController.minimumVerticalAngle = -1
        v.cameraControlConfiguration.allowsTranslation = false
        let g = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touched))
        g.cancelsTouchesInView = false
        g.delegate = context.coordinator
        v.addGestureRecognizer(g)
        showroom.view = v
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let showroom: Showroom
        init(_ s: Showroom) { showroom = s }
        @objc func touched() { showroom.userInteracted() }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

struct ShowroomView: View {
    @StateObject private var room = Showroom()
    @State private var panel: String? = "key"
    @State private var serverField = ""

    var body: some View {
        ZStack {
            SceneContainer(showroom: room).ignoresSafeArea()

            if room.film {
                VStack { Color.black.frame(height: 70); Spacer(); Color.black.frame(height: 70) }.ignoresSafeArea().allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                HStack(alignment: .top) {
                    Spacer()
                    if !room.film, let p = panel { panelView(p).frame(width: 320).transition(.opacity.combined(with: .move(edge: .top))) }
                }
                .padding(.trailing, 28).padding(.top, 10)
                Spacer()
                HStack(alignment: .bottom) {
                    if !room.film { hero }
                    Spacer()
                    Gauge(rpm: room.rpmUI, gear: room.gearUI, speed: room.speedUI, t100: room.t100, limit: room.limitUI)
                        .frame(width: 220, height: 220)
                        .opacity(room.gaugeOn ? 1 : 0).scaleEffect(room.gaugeOn ? 1 : 0.92)
                        .animation(.easeOut(duration: 0.5), value: room.gaugeOn)
                }
                .padding(.horizontal, 44).padding(.bottom, 40)
            }

            if let c = room.countdown {
                Text(c).font(.system(size: 300, weight: .heavy)).tracking(-12)
                    .foregroundColor(c == "GO" ? .white : .white.opacity(0.4))
                    .id(c)
                    .transition(.asymmetric(insertion: .scale(scale: 1.25).combined(with: .opacity), removal: .opacity))
                    .allowsHitTesting(false)
            }

            if let t = room.toast {
                VStack {
                    Text(t).font(.system(size: 14, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.92)))
                        .padding(.top, 84)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.3), value: room.toast)
        .animation(.easeOut(duration: 0.35), value: room.countdown)
        .animation(.easeOut(duration: 0.3), value: panel)
        .animation(.easeOut(duration: 0.6), value: room.film)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; serverField = room.server }
        .onChange(of: room.showPair) { v in if !v && panel == "key" { panel = nil } }
    }

    // MARK: top bar

    private var topBar: some View {
        HStack {
            (Text(room.spec.name).font(.system(size: 15, weight: .bold)) + Text(room.spec.engine.isEV ? "  EV" : "  GT").font(.system(size: 12, weight: .medium)).foregroundColor(muted))
                .opacity(room.film ? 0 : 1)
            Spacer()
            HStack(spacing: 4) {
                ForEach(["drive", "body", "paint", "key"], id: \.self) { t in
                    Button { panel = panel == t ? nil : t } label: {
                        Text(t == "body" ? "Car" : t.capitalized).font(.system(size: 13, weight: .medium))
                            .foregroundColor(panel == t ? .white : muted)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Capsule().fill(panel == t ? Color.white.opacity(0.12) : .clear))
                    }.buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(glassFill)).overlay(Capsule().stroke(lineC))
            .opacity(room.film ? 0 : 1)
            Spacer()
            HStack(spacing: 8) {
                chip(room.film ? "Exit film" : "Film mode", on: room.film) { room.film.toggle() }
                chip(!room.soundOn ? "Sound off" : room.audioOK ? "Sound on" : "Sound ⚠︎ tap", on: room.soundOn && room.audioOK) {
                    if room.soundOn && !room.audioOK { room.setSound(true) } else { room.setSound(!room.soundOn) }
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 18)
    }

    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .medium))
                .foregroundColor(on ? .black : .white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(on ? Color.white : glassFill))
                .overlay(Capsule().stroke(lineC))
        }.buttonStyle(.plain)
    }

    // MARK: hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(room.title).font(.system(size: 92, weight: .bold)).tracking(-4)
                .id(room.title).transition(.opacity.combined(with: .offset(y: 14)))
            Text(room.hint).font(.system(size: 16)).foregroundColor(Color(white: 0.78)).frame(maxWidth: 460, alignment: .leading)
            HStack(spacing: 8) {
                Circle().fill(room.remotes > 0 ? Color.green : Color.gray).frame(width: 7, height: 7)
                    .shadow(color: room.remotes > 0 ? .green : .clear, radius: 4)
                Text(room.remotes == 0 ? "No key connected" : room.remotes == 1 ? "Key connected" : "\(room.remotes) keys connected")
                    .font(.system(size: 12)).foregroundColor(room.remotes > 0 ? .white : muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(glassFill)).overlay(Capsule().stroke(lineC))
        }
        .animation(.easeOut(duration: 0.45), value: room.title)
        .allowsHitTesting(false)
    }

    // MARK: panels

    @ViewBuilder private func panelView(_ p: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(p == "key" ? "PHONE KEY" : p.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundColor(muted)
            switch p {
            case "key": keyPanel
            case "drive": drivePanel
            case "body": bodyPanel
            default: paintPanel
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial).opacity(0.9))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(lineC))
    }

    private var keyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                if let img = room.qrImage() {
                    Image(uiImage: img).interpolation(.none).resizable().frame(width: 132, height: 132)
                        .padding(8).background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan with the APEX Key app or your iPhone camera.").font(.system(size: 12))
                    Text("Code").font(.system(size: 12)).foregroundColor(muted)
                    Text(room.code).font(.system(size: 22, weight: .bold, design: .monospaced)).tracking(4)
                    Text(room.remotes > 0 ? "Phone connected." : room.linkOpen ? "Waiting for your phone…" : "Connecting to server…")
                        .font(.system(size: 12)).foregroundColor(muted)
                }
            }
            Divider().background(lineC)
            Text("SERVER").font(.system(size: 10, weight: .semibold)).foregroundColor(muted)
            HStack {
                TextField(Server.defaultHost, text: $serverField)
                    .font(.system(size: 12, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { room.setServer(serverField) }
                Button("New code") { room.newCode() }.font(.system(size: 12, weight: .semibold))
            }
        }
    }

    private var drivePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            let cmds: [(String, String)] = [("Unlock", "unlock"), ("Lock", "lock"), ("Doors", "doors"), ("Lights", "lights"), ("Engine", "engine"), ("Launch", "launch")]
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(cmds, id: \.1) { c in
                    Button { room.cmd(c.1) } label: {
                        Text(c.0).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(lineC))
                    }.buttonStyle(.plain)
                }
            }
            Text("Hold to rev").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(lineC))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in room.setLocalThrottle(1) }
                    .onEnded { _ in room.setLocalThrottle(0) })
            Text("Drag the car to orbit, pinch to zoom.").font(.system(size: 12)).foregroundColor(muted)
        }
    }

    private var bodyPanel: some View {
        VStack(spacing: 6) {
            VStack(spacing: 8) {
                ForEach(CarSpec.all, id: \.id) { c in
                    Button { room.cmd("car", c.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.system(size: 14, weight: .bold))
                            Text(c.tagline).font(.system(size: 12)).foregroundColor(Color(white: 0.78))
                            Text(c.spec).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(room.carId == c.id ? 0.12 : 0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(room.carId == c.id ? Color.white : lineC))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)
            Toggle("Swan-neck wing", isOn: Binding(get: { room.wing }, set: { room.cmd("wing", $0) }))
            Toggle("Centre stripe", isOn: Binding(get: { room.livery }, set: { room.cmd("livery", $0) }))
            HStack {
                Text("Wheels")
                Spacer()
                ForEach(["#1a1b1f", "#b9bcc4", "#c9a24a", "#e8e8ea"], id: \.self) { hex in
                    Circle().fill(Color(uiColor: UIColor(hex: hex))).frame(width: 24, height: 24)
                        .onTapGesture { room.cmd("rim", hex) }
                }
            }
        }
        .font(.system(size: 14)).tint(Color(red: 0.5, green: 0.7, blue: 1))
    }

    private var paintPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                ForEach(paintChoices, id: \.hex) { p in
                    Circle().fill(Color(uiColor: UIColor(hex: p.hex))).frame(width: 54, height: 54)
                        .overlay(Circle().stroke(Color.white, lineWidth: room.paint == p.hex ? 2 : 0))
                        .onTapGesture { room.cmd("paint", p.hex) }
                }
            }
            Text(paintChoices.first { $0.hex == room.paint }?.name ?? "").font(.system(size: 12)).foregroundColor(muted)
        }
    }
}

// MARK: - Tachometer

struct Gauge: View {
    let rpm: Int, gear: String, speed: Int, t100: Double?, limit: Double
    private let sweep = 0.75 // 270°
    private var maxRpm: Double { limit > 10000 ? (ceil((limit + 2000) / 2000) * 2000) : 10000 }
    private var stepRpm: Double { maxRpm > 10000 ? 2000 : 1000 }

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: sweep).stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: sweep * (limit > 10000 ? 1 : (limit - 1000) / maxRpm), to: sweep).stroke(Color.red.opacity(0.35), lineWidth: 10)
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: sweep * min(1, Double(rpm) / maxRpm))
                .stroke(AngularGradient(colors: [Color(red: 0.5, green: 0.7, blue: 1), .white, Color(red: 1, green: 0.35, blue: 0.35)],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: Double(rpm) > limit - 150 && limit < 10000 ? .red : Color(red: 0.5, green: 0.7, blue: 1).opacity(0.6), radius: Double(rpm) > limit - 150 ? 10 : 6)
            ForEach(0...Int(maxRpm / stepRpm), id: \.self) { i in
                let a = Angle.degrees(135 + Double(i) * stepRpm / maxRpm * 270)
                Text("\(Int(Double(i) * stepRpm / 1000))").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(muted)
                    .offset(x: cos(a.radians) * 62, y: sin(a.radians) * 62)
            }
            VStack(spacing: 4) {
                Text(gear).font(.system(size: 56, weight: .bold, design: .monospaced))
                Text("\(rpm.formatted()) rpm").font(.system(size: 13, weight: .medium, design: .monospaced))
                Text("\(speed) km/h").font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(muted)
            }
            if let t = t100 {
                Text(String(format: "0–100 in %.2f s", t)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.green).offset(y: 124)
            }
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}
