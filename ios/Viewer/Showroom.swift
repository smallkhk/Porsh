import SceneKit
import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// Owns the 3D scene, the car simulation, the engine audio and the link to phone keys.
final class Showroom: NSObject, ObservableObject {
    // UI state (published ~20×/s)
    @Published var title = "Locked."
    @Published var hint = "Scan the code with your phone to get the key, then unlock the car."
    @Published var remotes = 0
    @Published var gaugeOn = false
    @Published var rpmUI = 0
    @Published var gearUI = "N"
    @Published var speedUI = 0
    @Published var t100: Double?
    @Published var countdown: String?
    @Published var toast: String?
    @Published var linkOpen = false
    @Published var code: String
    @Published var server: String
    @Published var paint = paintChoices[0].hex
    @Published var wing = true
    @Published var livery = true
    @Published var soundOn = true
    @Published var film = false
    @Published var showPair = true

    let scene = SCNScene()
    let cameraNode = SCNNode()
    let car = Car()
    let synth = EngineSynth()
    weak var view: SCNView?

    // sim
    private let IDLE = 950.0, LIMIT = 9000.0
    private let gearTop: [Double] = [0, 72, 118, 162, 207, 252, 305]
    private var locked = true, doors = false, lights = 0
    private var running = false, starting = false
    private var rpm = 0.0, thr = 0.0, thrInput = 0.0, thrAt = Date.distantPast, localThr = 0.0
    private var gear = "N", speed = 0.0, mode = "idle", modeT = 0.0, cut = 0.0, shiftCut = 0.0
    private var lastThr = 0.0, prevSpeed = 0.0, roll = 0.0, pitch = 0.0
    private var crackle: [(t: CFTimeInterval, s: Float)] = []
    private var limiterAt: CFTimeInterval = 0
    private var idleT = 0.0, uiAcc = 0.0, stateAcc = 0.0
    private var lastCountdown: String?

    // link
    private var relay: RelayClient?
    private var presence: [String: Date] = [:]
    private var seenIds: [String] = []
    private var seenSet = Set<String>()
    private var timers: [Timer] = []
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    // scene bits
    private let floorMat = SCNMaterial()
    private var floorOffset: Float = 0
    private var streaks: [SCNNode] = []
    private let streakMat = SCNMaterial()

    init() {
        let d = UserDefaults.standard
        server = d.string(forKey: "server") ?? Server.defaultHost
        code = d.string(forKey: "carCode") ?? makeCode()
        d.set(code, forKey: "carCode")
        super.init()
        buildScene()
        startLink()
        setStatus()
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFramesPerSecond = 60
        l.add(to: .main, forMode: .common)
        link = l
        synth.start()
        runDemoIfRequested()
    }

    // MARK: - Scene

    private func buildScene() {
        let bg = UIColor(red: 0.027, green: 0.031, blue: 0.043, alpha: 1)
        scene.background.contents = bg
        scene.lightingEnvironment.contents = Showroom.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.4
        scene.fogColor = bg
        scene.fogStartDistance = 9
        scene.fogEndDistance = 30

        // floor with a scrolling "rolling road" texture
        let floor = SCNFloor()
        floor.reflectivity = 0.12
        floor.reflectionFalloffEnd = 2.5
        floorMat.lightingModel = .physicallyBased
        floorMat.diffuse.contents = Showroom.floorTexture()
        floorMat.diffuse.wrapS = .repeat
        floorMat.diffuse.wrapT = .repeat
        floorMat.roughness.contents = 0.4
        floorMat.metalness.contents = 0.3
        floor.materials = [floorMat]
        scene.rootNode.addChildNode(SCNNode(geometry: floor))
        updateFloorTransform()

        // soft contact shadow
        let shadowImg = textImage(CGSize(width: 256, height: 256)) { ctx, _ in
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [UIColor(white: 0, alpha: 0.85).cgColor, UIColor(white: 0, alpha: 0.45).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray,
                               locations: [0, 0.6, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: 128, y: 128), startRadius: 10, endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
        }
        let sm = SCNMaterial(); sm.lightingModel = .constant; sm.diffuse.contents = shadowImg; sm.writesToDepthBuffer = false
        let contact = node(SCNPlane(width: 6.2, height: 2.9), sm, SCNVector3(0, 0.003, 0))
        setEuler(contact, x: -.pi / 2)
        scene.rootNode.addChildNode(contact)

        // speed streaks
        streakMat.lightingModel = .constant
        streakMat.diffuse.contents = UIColor.black
        streakMat.emission.contents = UIColor(red: 0.8, green: 0.85, blue: 1, alpha: 1)
        streakMat.emission.intensity = 2
        streakMat.blendMode = .add
        streakMat.writesToDepthBuffer = false
        streakMat.transparency = 0
        for _ in 0..<40 {
            let s = node(SCNPlane(width: CGFloat.random(in: 3...7), height: 0.025), streakMat)
            setEuler(s, x: -.pi / 2)
            let side: Float = Bool.random() ? 1 : -1
            s.position = SCNVector3(Float.random(in: -20...20), 0.01 + Float.random(in: 0...0.02), side * Float.random(in: 2...8))
            scene.rootNode.addChildNode(s)
            streaks.append(s)
        }

        // key light with soft shadows
        let key = SCNLight()
        key.type = .spot
        key.intensity = 1600
        key.spotInnerAngle = 30
        key.spotOuterAngle = 75
        key.castsShadow = true
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowSampleCount = 8
        key.shadowRadius = 6
        key.shadowColor = UIColor(white: 0, alpha: 0.65)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(0.5, 9, 1.5)
        keyNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyNode)

        scene.rootNode.addChildNode(car.root)

        // camera: HDR + bloom so the LEDs and flames glow
        let cam = SCNCamera()
        cam.fieldOfView = 32
        cam.zNear = 0.1
        cam.zFar = 120
        cam.wantsHDR = true
        cam.bloomIntensity = 0.9
        cam.bloomThreshold = 1.0
        cam.bloomBlurRadius = 14
        cam.wantsExposureAdaptation = false
        cam.vignettingIntensity = 0.6
        cam.vignettingPower = 0.8
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(5.4, 1.55, 4.4)
        cameraNode.look(at: SCNVector3(0, 0.62, 0))
        scene.rootNode.addChildNode(cameraNode)
    }

    private func updateFloorTransform() {
        let s: Float = 0.3
        floorMat.diffuse.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(s, s, 1), SCNMatrix4MakeTranslation(floorOffset, 0, 0))
    }

    static func floorTexture() -> UIImage {
        textImage(CGSize(width: 512, height: 512)) { ctx, size in
            ctx.setFillColor(UIColor(red: 0.047, green: 0.051, blue: 0.067, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<5000 {
                let v = CGFloat.random(in: 0...0.05)
                ctx.setFillColor(UIColor(white: v, alpha: 0.5).cgColor)
                ctx.fill(CGRect(x: .random(in: 0...512), y: .random(in: 0...512), width: 2, height: 2))
            }
            ctx.setStrokeColor(UIColor(white: 1, alpha: 0.055).cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(CGRect(origin: .zero, size: size))
            ctx.setFillColor(UIColor(white: 1, alpha: 0.1).cgColor)
            ctx.fill(CGRect(x: 0, y: 252, width: 180, height: 8))
        }
    }

    /// Equirectangular car-studio: dark cyclorama, overhead softboxes, long side strips.
    static func studioEnvironment() -> UIImage {
        textImage(CGSize(width: 1024, height: 512)) { ctx, size in
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [UIColor(white: 0.09, alpha: 1).cgColor, UIColor(white: 0.03, alpha: 1).cgColor, UIColor(white: 0.01, alpha: 1).cgColor] as CFArray,
                               locations: [0, 0.5, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 8, width: size.width, height: 40))            // overhead softbox ring
            ctx.setFillColor(UIColor(white: 0.85, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 70, width: size.width, height: 10))
            ctx.fill(CGRect(x: 0, y: 92, width: size.width, height: 10))
            ctx.setFillColor(UIColor(white: 0.75, alpha: 1).cgColor)               // long side strips near the horizon
            ctx.fill(CGRect(x: 160, y: 215, width: 190, height: 14))
            ctx.fill(CGRect(x: 674, y: 215, width: 190, height: 14))
            ctx.setFillColor(UIColor(red: 0.55, green: 0.65, blue: 0.95, alpha: 1).cgColor) // cool rim
            ctx.fill(CGRect(x: 0, y: 150, width: 70, height: 110))
            ctx.fill(CGRect(x: 954, y: 150, width: 70, height: 110))
            ctx.setFillColor(UIColor(red: 0.95, green: 0.85, blue: 0.7, alpha: 1).cgColor)  // warm front
            ctx.fill(CGRect(x: 470, y: 160, width: 84, height: 100))
        }
    }

    // MARK: - Link to phone keys

    var remoteURL: String { "https://\(Server.clean(server))/remote.html#\(code)" }

    func qrImage() -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(remoteURL.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func startLink() {
        relay?.close()
        timers.forEach { $0.invalidate() }
        relay = RelayClient(host: server, room: code, role: .host)
        relay?.onOpenChange = { [weak self] open in self?.linkOpen = open }
        relay?.onMessage = { [weak self] m in self?.deliver(m) }
        timers = [Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkPresence() }]
    }

    func newCode() {
        code = makeCode()
        UserDefaults.standard.set(code, forKey: "carCode")
        presence = [:]
        startLink()
        showToast("New code. Paired keys must re-pair.")
    }

    func setServer(_ s: String) {
        let c = Server.clean(s)
        guard !c.isEmpty, c != server else { return }
        server = c
        UserDefaults.standard.set(c, forKey: "server")
        startLink()
    }

    private func checkPresence() {
        let now = Date()
        presence = presence.filter { now.timeIntervalSince($0.value) < 3.5 }
        if presence.count != remotes {
            let was = remotes
            remotes = presence.count
            if remotes > was { showToast("Phone key connected"); showPair = false }
            setStatus()
        }
    }

    private func deliver(_ m: [String: Any]) {
        if let rid = m["rid"] as? String {
            let isNew = presence[rid] == nil
            presence[rid] = Date()
            if isNew { checkPresence(); sendState() }
        }
        if let id = m["id"] as? String {
            if seenSet.contains(id) { return }
            seenSet.insert(id); seenIds.append(id)
            if seenIds.count > 400 { seenSet.remove(seenIds.removeFirst()) }
        }
        switch m["t"] as? String {
        case "cmd": cmd(m["c"] as? String ?? "", m["v"])
        case "thr": thrInput = max(0, min(1, (m["v"] as? NSNumber)?.doubleValue ?? 0)); thrAt = Date()
        default: break
        }
    }

    private func sendEvent(_ kind: String, _ text: String? = nil) {
        var m: [String: Any] = ["t": "evt", "kind": kind]
        if let t = text { m["text"] = t }
        relay?.send(m)
    }

    private func sendState() {
        var s = CarState()
        s.locked = locked; s.doors = doors; s.lights = lights; s.running = running; s.starting = starting
        s.rpm = Int(rpm.rounded()); s.gear = gear; s.speed = Int(speed.rounded()); s.mode = mode; s.t100 = t100
        s.paint = paint; s.wing = wing; s.livery = livery; s.hint = hint
        s.cd = mode == "arm" ? max(0, 3 - Int(modeT)) : nil
        relay?.send(s.dict)
    }

    // MARK: - Commands (from phone keys and on-screen buttons)

    func cmd(_ name: String, _ arg: Any? = nil) {
        switch name {
        case "unlock":
            guard locked else { return }
            locked = false
            synth.chirp("unlock"); synth.thud(0.6, pitch: 1.6)
            car.hazard(2); car.sweep(1); car.setDRL(true)
        case "lock":
            guard !locked else { return }
            if running || starting { stopEngine() }
            if doors { doors = false; car.setDoors(false); later(0.65) { self.synth.thud(1, pitch: 0.9) } }
            locked = true; lights = 0; car.setLights(0)
            synth.chirp("lock"); synth.thud(0.6, pitch: 1.6)
            car.hazard(1); car.sweep(-1)
            later(0.9) { if self.locked { self.car.setDRL(false) } }
        case "toggleLock": cmd(locked ? "unlock" : "lock")
        case "doors":
            if locked { return deny("Unlock the car first") }
            if mode == "run" || speed > 2 { return deny("Not while moving") }
            doors.toggle(); car.setDoors(doors)
            if doors { synth.thud(0.5, pitch: 1.3) } else { later(0.65) { self.synth.thud(1, pitch: 0.9) } }
        case "lights":
            if locked { return deny("Unlock the car first") }
            lights = (lights + 1) % 3; car.setLights(lights); synth.click()
        case "engine":
            if locked { return deny("Unlock the car first") }
            if running || starting { stopEngine() } else { startEngine() }
        case "throttle":
            thrInput = max(0, min(1, (arg as? NSNumber)?.doubleValue ?? 0)); thrAt = Date()
        case "launch":
            if mode == "arm" || mode == "run" { mode = "coast"; modeT = 0; countdown = nil; break }
            if !running { return deny(locked ? "Unlock and start the engine first" : "Start the engine first") }
            if doors { doors = false; car.setDoors(false); later(0.65) { self.synth.thud(1, pitch: 0.9) } }
            if lights == 0 { lights = 1; car.setLights(1) }
            mode = "arm"; modeT = 0; t100 = nil
        case "horn": synth.horn((arg as? Bool) ?? ((arg as? NSNumber)?.boolValue ?? false))
        case "paint":
            if let hex = arg as? String { paint = hex; car.setPaint(hex) }
        case "wing":
            wing = (arg as? Bool) ?? !wing; car.setWing(wing)
        case "livery":
            livery = (arg as? Bool) ?? !livery; car.setLivery(livery)
        case "rim":
            if let hex = arg as? String { car.setRim(hex) }
        default: return
        }
        setStatus()
        sendState()
    }

    private func deny(_ text: String) {
        showToast(text)
        sendEvent("deny", text)
    }

    private func startEngine() {
        starting = true; modeT = 0
        synth.starter(1.0)
        car.setDRL(true)
        later(1.0) {
            guard self.starting else { return }
            self.starting = false; self.running = true
            self.rpm = 2600
            self.popBurst(3, 0.3, 0.8)
            self.car.flames(0.6)
            self.setStatus(); self.sendState()
        }
    }

    private func stopEngine() {
        starting = false; running = false; mode = "idle"; gear = "N"; countdown = nil
    }

    private func popBurst(_ n: Int, _ spread: Double, _ strength: Float) {
        let now = CACurrentMediaTime()
        for _ in 0..<n { crackle.append((now + Double.random(in: 0...spread), strength * Float.random(in: 0.5...1.1))) }
    }

    private func later(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

    // MARK: - Simulation (port of the web step())

    private func step(_ dt: Double) {
        if Date().timeIntervalSince(thrAt) > 0.7 { thrInput = 0 }
        var t = max(thrInput, localThr)
        if !running { t = 0 }

        if starting {
            modeT += dt
            rpm = 180 + sin(CACurrentMediaTime() * 40) * 60 + modeT * 120
        } else if !running {
            rpm = max(0, rpm - dt * 2600)
        } else if mode == "idle" {
            gear = "N"
            let target = IDLE + pow(t, 1.15) * (LIMIT + 300 - IDLE)
            if cut > 0 { cut -= dt; t = 0; rpm -= dt * 9000 }
            else if rpm < target { rpm += min(target - rpm, dt * (6000 + 16000 * t)) }
            else { rpm -= min(rpm - target, dt * 6200) }
            if rpm >= LIMIT { rpm = LIMIT; cut = 0.055; limiterHit() }
            rpm += Double.random(in: -9...9)
            if lastThr > 0.45 && t < 0.1 && rpm > 4500 { popBurst(4 + Int.random(in: 0...4), 0.9, 1) }
        } else if mode == "arm" {
            modeT += dt
            let target = 5200.0
            if cut > 0 { cut -= dt; rpm -= dt * 8000 } else { rpm += min(target - rpm, dt * 14000) }
            if rpm >= target - 5 && cut <= 0 { cut = 0.07 + Double.random(in: 0...0.05); if Bool.random() { popBurst(1, 0.05, 0.7) } }
            t = 1
            let n = 3 - Int(modeT)
            setCountdown(n > 0 ? "\(n)" : "GO")
            if modeT >= 3 { mode = "run"; modeT = 0; gear = "1"; speed = 0; setStatus() }
        } else if mode == "run" {
            modeT += dt; t = 1
            let g = Int(gear) ?? 1
            let v = speed / 3.6, vmax = 330 / 3.6
            let accel: [Double] = [0, 10.5, 8.6, 7.0, 5.9, 4.9, 4.0]
            var a = accel[g] * (1 - pow(v / vmax, 2.2))
            if shiftCut > 0 { shiftCut -= dt; a = 0.4; t = 0.1 }
            speed += a * dt * 3.6
            let gearRpm = speed / gearTop[g] * LIMIT
            let slip = max(0, 1 - modeT / 0.55) * 5200
            let want = max(IDLE, gearRpm, slip)
            rpm += (want - rpm) * min(1, dt * (shiftCut > 0 ? 18 : 30))
            if rpm > 8750 && g < 6 && shiftCut <= 0 {
                gear = "\(g + 1)"; shiftCut = 0.11; popBurst(2, 0.12, 1.1); car.flames(1); sendEvent("shift")
            }
            if t100 == nil && speed >= 100 { t100 = modeT }
            if speed >= 280 || modeT > 14 { mode = "coast"; modeT = 0; popBurst(8, 1.2, 1.2); setStatus() }
        } else if mode == "coast" {
            modeT += dt; t = 0
            let v = speed / 3.6
            speed = max(0, speed - (7.5 + 0.0009 * v * v) * dt * 3.6)
            var g = Int(gear) ?? 1
            let r = speed / gearTop[g] * LIMIT
            if r < 3800 && g > 1 { g -= 1; gear = "\(g)"; popBurst(2, 0.25, 0.9); car.flames(0.7) }
            var target = max(IDLE, speed / gearTop[g] * LIMIT)
            if speed < 6 { target = IDLE }
            rpm += (target - rpm) * min(1, dt * 12)
            if speed <= 0.1 { speed = 0; mode = "idle"; gear = "N"; setStatus() }
        }
        thr += (t - thr) * min(1, dt * 20)
        lastThr = t
        rpm = max(0, rpm)

        let now = CACurrentMediaTime()
        var keep: [(t: CFTimeInterval, s: Float)] = []
        for p in crackle {
            if p.t > now { keep.append(p); continue }
            if running { synth.pop(p.s); car.flames(0.6 + p.s * 0.6) }
        }
        crackle = keep
        if running && mode == "idle" && t < 0.05 && rpm > 3200 && Double.random(in: 0...1) < dt * 6 {
            synth.pop(0.5); car.flames(0.35)
        }
    }

    private func limiterHit() {
        if Double.random(in: 0...1) < 0.6 { synth.pop(0.8); car.flames(0.9) }
        let n = CACurrentMediaTime()
        if n - limiterAt > 0.25 { limiterAt = n; sendEvent("limiter") }
    }

    private func setCountdown(_ s: String) {
        guard s != lastCountdown else { return }
        lastCountdown = s
        countdown = s
        if s == "GO" { synth.chirp("go"); later(0.9) { if self.countdown == "GO" { self.countdown = nil } } }
    }

    // MARK: - Status text

    func setStatus() {
        let (t, h) = statusText()
        if title != t { title = t }
        if hint != h { hint = h }
        if mode != "arm" && lastCountdown != nil && mode != "run" { lastCountdown = nil }
    }

    private func statusText() -> (String, String) {
        if locked { return ("Locked.", remotes > 0 ? "Tap Unlock on your phone." : "Scan the code with your phone to get the key, then unlock the car.") }
        if starting { return ("Starting…", "Ignition.") }
        if mode == "arm" { return ("Launch.", "Launch control armed. Hold tight.") }
        if mode == "run" { return ("Full send.", "Launching through the gears.") }
        if mode == "coast" { return ("Lifting.", "Coming back down.") }
        if running { return ("Running.", "Use the throttle pad to rev it. Tap Launch for a full launch run.") }
        return ("Unlocked.", "Open the doors, or hold the engine button on your key to start it.")
    }

    private var toastWork: DispatchWorkItem?
    func showToast(_ s: String) {
        toast = s
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }

    func setSound(_ on: Bool) {
        soundOn = on
        synth.volume = on ? 0.85 : 0
    }

    func setLocalThrottle(_ v: Double) { localThr = v }
    func userInteracted() { idleT = 0 }

    // MARK: - Frame loop

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 1.0 / 20)
        lastTick = now

        step(dt)
        synth.rpm = Float(rpm)
        synth.load = Float(thr)
        synth.on = running || starting

        // body dynamics: torque roll, launch squat, brake dive, idle shake
        let accel = (speed - prevSpeed) / max(dt, 1e-3) / 3.6
        prevSpeed = speed
        let torque = running ? thr * 0.012 + rpm / LIMIT * 0.004 : 0
        roll += (torque - roll) * min(1, dt * 8)
        pitch += (min(0.03, max(-0.025, accel * 0.0028)) - pitch) * min(1, dt * 5)
        let shake = running ? 0.0012 + thr * 0.0016 + (rpm < 1300 ? 0.0012 : 0) : starting ? 0.003 : 0
        car.chassis.position = SCNVector3(0, Float(Double.random(in: -0.5...0.5) * shake), 0)
        setEuler(car.chassis, x: Float(roll + Double.random(in: -0.5...0.5) * shake * 1.5), z: Float(pitch))
        car.brake = mode == "coast" ? 1 : 0

        // wheels + rolling road + streaks
        let v = speed / 3.6
        car.spinWheels(Float(v / Double(Dim.wheelR) * dt * (mode == "run" && modeT < 0.6 ? 1.6 : 1)))
        floorOffset -= Float(v * dt) * 0.3
        updateFloorTransform()
        streakMat.transparency = CGFloat(min(0.55, v / 50))
        if v > 0.1 {
            for s in streaks {
                s.position.x -= Float(v * dt)
                if s.position.x < -20 { s.position.x += 40 }
            }
        }
        car.update(Float(dt))

        // idle auto-orbit (and film mode)
        idleT += dt
        if let view = view, film || (idleT > 12 && mode == "idle") {
            view.defaultCameraController.rotateBy(x: film ? -0.25 : -0.1, y: 0)
        }

        uiAcc += dt
        if uiAcc > 1.0 / 20 {
            uiAcc = 0
            let on = running || starting || rpm > 50
            if gaugeOn != on { gaugeOn = on }
            rpmUI = Int(rpm.rounded()); gearUI = gear; speedUI = Int(speed.rounded())
        }
        stateAcc += dt
        if stateAcc > 0.06 { stateAcc = 0; sendState() }
    }

    // MARK: - Demo mode (used for automated screenshots)

    private func runDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoDoors") {
            later(1.5) { self.cmd("unlock") }
            later(2.5) { self.cmd("lights"); self.cmd("lights"); self.cmd("doors") }
        }
        if args.contains("-demoRev") {
            later(1.0) { self.cmd("unlock") }
            later(2.0) { self.cmd("lights"); self.cmd("engine") }
            later(4.0) { self.localThr = 0.85 }
        }
    }
}
