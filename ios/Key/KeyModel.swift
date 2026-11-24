import SwiftUI
import UIKit

enum Haptics {
    private static let gLight = UIImpactFeedbackGenerator(style: .light)
    private static let gMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let gHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let gRigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let gNotify = UINotificationFeedbackGenerator()

    static func tap() { gLight.impactOccurred() }
    static func medium(_ i: CGFloat = 1) { gMedium.impactOccurred(intensity: i) }
    static func heavy() { gHeavy.impactOccurred() }
    static func rev() { gRigid.impactOccurred(intensity: 0.7) }
    static func warning() { gNotify.notificationOccurred(.warning) }
    static func success() { gNotify.notificationOccurred(.success) }
}

final class KeyModel: ObservableObject {
    @Published var state: CarState?
    @Published var connected = false
    @Published var status = "Connecting…"
    @Published var paired: Bool
    @Published var flash: String?
    @Published var throttle: Double = 0

    private(set) var host: String
    private(set) var code: String

    private var relay: RelayClient?
    private let rid = makeCode(6)
    private var seq = 0
    private var lastHost = Date.distantPast
    private var timers: [Timer] = []
    private var thrTimer: Timer?
    private var flashTimer: Timer?

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "server") ?? Server.defaultHost
        code = d.string(forKey: "code") ?? ""
        paired = !code.isEmpty
        if ProcessInfo.processInfo.arguments.contains("-preview") {
            // screenshot/demo mode: fake a running car
            paired = true; connected = true; status = "Connected"
            var s = CarState(); s.locked = false; s.running = true; s.rpm = 6850; s.lights = 1
            state = s
            return
        }
        if paired { start() }
    }

    // MARK: pairing

    func pair(host newHost: String, code newCode: String) {
        host = Server.clean(newHost).isEmpty ? Server.defaultHost : Server.clean(newHost)
        code = cleanCode(newCode)
        guard code.count >= 4 else { return }
        UserDefaults.standard.set(host, forKey: "server")
        UserDefaults.standard.set(code, forKey: "code")
        paired = true
        Haptics.success()
        start()
    }

    /// QR codes contain https://<host>/remote.html#CODE
    func pair(scanned text: String) {
        if let url = URL(string: text), let frag = url.fragment, let h = url.host {
            pair(host: h, code: frag)
        } else {
            pair(host: host, code: text)
        }
    }

    func unpair() {
        stop()
        code = ""
        UserDefaults.standard.removeObject(forKey: "code")
        paired = false
    }

    // MARK: link

    private func start() {
        stop()
        status = "Connecting…"
        relay = RelayClient(host: host, room: code, role: .remote)
        relay?.onOpenChange = { [weak self] open in
            guard let self = self else { return }
            if !self.connected { self.status = open ? "Looking for the car…" : "Reconnecting…" }
            if open { self.send(["t": "hb"]) }
        }
        relay?.onMessage = { [weak self] m in self?.handle(m) }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.send(["t": "hb"]) },
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.checkLink() },
        ]
    }

    private func stop() {
        relay?.close(); relay = nil
        timers.forEach { $0.invalidate() }; timers = []
        thrTimer?.invalidate(); thrTimer = nil
        connected = false
        state = nil
    }

    private func checkLink() {
        let ok = Date().timeIntervalSince(lastHost) < 2.5
        guard ok != connected else { return }
        connected = ok
        if ok { status = "Connected"; Haptics.medium() }
        else { status = relay?.isOpen == true ? "Looking for the car…" : "Reconnecting…" }
    }

    private func handle(_ m: [String: Any]) {
        lastHost = Date()
        switch m["t"] as? String {
        case "state":
            state = CarState(m)
            if !connected { checkLink() }
        case "evt":
            switch m["kind"] as? String {
            case "limiter": Haptics.rev()
            case "shift": Haptics.heavy()
            case "deny":
                Haptics.warning()
                show(m["text"] as? String ?? "")
            default: break
            }
        default: break
        }
    }

    private func show(_ text: String) {
        flash = text
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in self?.flash = nil }
    }

    // MARK: sending

    func send(_ msg: [String: Any]) {
        var m = msg
        seq += 1
        m["rid"] = rid
        m["id"] = "\(rid):\(seq)"
        relay?.send(m)
    }

    func cmd(_ c: String, _ v: Any? = nil) {
        var m: [String: Any] = ["t": "cmd", "c": c]
        if let v = v { m["v"] = v }
        send(m)
    }

    /// Streams the throttle at 20 Hz while held (the car zeroes it if we go quiet).
    func setThrottle(_ v: Double) {
        let was = throttle
        throttle = v
        if v > 0 {
            if thrTimer == nil {
                thrTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.send(["t": "thr", "v": self.throttle])
                }
            }
            if abs(v - was) > 0.02 { send(["t": "thr", "v": v]) }
        } else {
            thrTimer?.invalidate(); thrTimer = nil
            send(["t": "thr", "v": 0])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.send(["t": "thr", "v": 0]) }
        }
    }
}
