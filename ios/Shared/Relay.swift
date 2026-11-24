import Foundation
import UIKit

// MARK: - Server + codes

enum Server {
    /// Your VPS. Changeable in both apps.
    static let defaultHost = "posh.162.35.37.67.sslip.io"

    /// Accepts "host", "https://host/anything", "wss://host/relay" → "host"
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "wss://", "ws://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let i = s.firstIndex(where: { $0 == "/" || $0 == "#" || $0 == "?" }) { s = String(s[..<i]) }
        return s
    }
}

private let codeAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
func makeCode(_ n: Int = 5) -> String { String((0..<n).map { _ in codeAlphabet.randomElement()! }) }
func cleanCode(_ s: String) -> String { String(s.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(12)) }

// MARK: - WebSocket relay client (same protocol as the web app)

/// Connects to wss://<host>/relay?room=CODE&role=host|remote and reconnects forever.
/// Everything is delivered on the main queue.
final class RelayClient: NSObject, URLSessionWebSocketDelegate {
    enum Role: String { case host, remote }

    var onMessage: (([String: Any]) -> Void)?
    var onOpenChange: ((Bool) -> Void)?
    private(set) var isOpen = false

    private let url: URL
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var retry = 0
    private var closed = false

    init?(host: String, room: String, role: Role) {
        let h = Server.clean(host)
        guard !h.isEmpty, !room.isEmpty,
              let u = URL(string: "wss://\(h)/relay?room=\(room)&role=\(role.rawValue)") else { return nil }
        url = u
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        connect()
    }

    private func connect() {
        guard !closed else { return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        listen(t)
    }

    private func listen(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self = self, t === self.task else { return }
            switch result {
            case .success(let message):
                var data: Data?
                switch message {
                case .string(let s): data = s.data(using: .utf8)
                case .data(let d): data = d
                @unknown default: data = nil
                }
                if let d = data, let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    self.onMessage?(obj)
                }
                self.listen(t)
            case .failure:
                self.dropped(t)
            }
        }
    }

    private func dropped(_ t: URLSessionWebSocketTask) {
        guard t === task else { return }
        task = nil
        if isOpen { isOpen = false; onOpenChange?(false) }
        t.cancel()
        guard !closed else { return }
        let delay = min(8.0, 0.6 * pow(2.0, Double(retry)))
        retry += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        retry = 0
        isOpen = true
        onOpenChange?(true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        dropped(webSocketTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let ws = task as? URLSessionWebSocketTask { dropped(ws) }
    }

    func send(_ obj: [String: Any]) {
        guard isOpen, let t = task,
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }

    func close() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }
}

// MARK: - Car state (what the showroom broadcasts ~16×/s)

struct CarState {
    var locked = true
    var doors = false
    var lights = 0
    var running = false
    var starting = false
    var rpm = 0
    var gear = "N"
    var speed = 0
    var mode = "idle"
    var t100: Double? = nil
    var paint = "#1b55e0"
    var wing = true
    var livery = true
    var hint = ""
    var cd: Int? = nil
    var car = ""
    var carName = ""
    var limit = 9000
    var ev = false
    var cars: [(id: String, name: String, tagline: String)] = []

    init() {}

    init(_ d: [String: Any]) {
        locked = d["locked"] as? Bool ?? true
        doors = d["doors"] as? Bool ?? false
        lights = (d["lights"] as? NSNumber)?.intValue ?? 0
        running = d["running"] as? Bool ?? false
        starting = d["starting"] as? Bool ?? false
        rpm = (d["rpm"] as? NSNumber)?.intValue ?? 0
        if let g = d["gear"] as? String { gear = g } else if let n = d["gear"] as? NSNumber { gear = n.stringValue }
        speed = (d["speed"] as? NSNumber)?.intValue ?? 0
        mode = d["mode"] as? String ?? "idle"
        t100 = (d["t100"] as? NSNumber)?.doubleValue
        paint = d["paint"] as? String ?? paint
        wing = d["wing"] as? Bool ?? true
        livery = d["livery"] as? Bool ?? true
        hint = d["hint"] as? String ?? ""
        cd = (d["cd"] as? NSNumber)?.intValue
        car = d["car"] as? String ?? ""
        carName = d["carName"] as? String ?? ""
        limit = (d["limit"] as? NSNumber)?.intValue ?? 9000
        ev = d["ev"] as? Bool ?? false
        if let list = d["cars"] as? [[String: Any]] {
            cars = list.compactMap { c in
                guard let id = c["id"] as? String, let name = c["name"] as? String else { return nil }
                return (id, name, c["tagline"] as? String ?? "")
            }
        }
    }

    var dict: [String: Any] {
        var d: [String: Any] = [
            "t": "state", "locked": locked, "doors": doors, "lights": lights, "running": running,
            "starting": starting, "rpm": rpm, "speed": speed, "mode": mode, "paint": paint,
            "wing": wing, "livery": livery, "hint": hint,
        ]
        d["gear"] = Int(gear) ?? (gear as Any)
        d["t100"] = t100 ?? NSNull()
        d["cd"] = cd ?? NSNull()
        d["car"] = car; d["carName"] = carName; d["limit"] = limit; d["ev"] = ev
        d["cars"] = cars.map { ["id": $0.id, "name": $0.name, "tagline": $0.tagline] }
        return d
    }
}

// MARK: - Colours

let paintChoices: [(name: String, hex: String)] = [
    ("Voltage Blue", "#1b55e0"), ("Lava Orange", "#ff5a1f"), ("Signal Red", "#c8101e"), ("Chalk", "#d9d6cf"),
    ("Acid Green", "#9fe01b"), ("Obsidian", "#0d0e12"), ("Ultraviolet", "#5a2bd6"), ("Arctic Silver", "#a9b0bb"),
    ("Racing Green", "#123d2b"), ("Sunset Gold", "#c9922e"), ("Midnight", "#16213e"), ("Rosso", "#9e0f1c"),
]

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
