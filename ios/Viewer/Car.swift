import SceneKit
import UIKit
import simd

// APEX 9R — procedural car, native SceneKit port of js/car.js.
// The body is a loft of ~300 cross-sections; doors and glass are carved out of
// the same vertex grid so every panel lines up and the doors can hinge open.

// MARK: - Profile curves

struct Curve {
    let xs: [Float], ys: [Float], ms: [Float]

    init(_ pts: [(Float, Float)]) {
        let lx = pts.map { $0.0 }, ly = pts.map { $0.1 }
        let n = pts.count
        var d = [Float]()
        for i in 0..<(n - 1) { d.append((ly[i + 1] - ly[i]) / (lx[i + 1] - lx[i])) }
        var m = [Float](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]; m[i + 1] = t * b * d[i]
            }
        }
        xs = lx; ys = ly; ms = m
    }

    func callAsFunction(_ x: Float) -> Float {
        let n = xs.count
        if x <= xs[0] { return ys[0] }
        if x >= xs[n - 1] { return ys[n - 1] }
        var i = 0
        while x > xs[i + 1] { i += 1 }
        let h: Float = xs[i + 1] - xs[i]
        let t: Float = (x - xs[i]) / h
        let t2: Float = t * t, t3: Float = t2 * t
        let h00: Float = 2 * t3 - 3 * t2 + 1
        let h10: Float = t3 - 2 * t2 + t
        let h01: Float = -2 * t3 + 3 * t2
        let h11: Float = t3 - t2
        let a: Float = h00 * ys[i] + h10 * h * ms[i]
        let b: Float = h01 * ys[i + 1] + h11 * h * ms[i + 1]
        return a + b
    }
}

@inline(__always) func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }

/// The selected car's dimensions (set by `configure(_:)` from cars.json).
enum Dim {
    static var xMin: Float = -2.30, xMax: Float = 2.32
    static var wheelR: Float = 0.355, wheelY: Float = 0.355
    static var frontX: Float = 1.42, frontTrack: Float = 0.79
    static var rearX: Float = -1.38, rearTrack: Float = 0.835
    static var archR: Float = 0.45, archY: Float = 0.34
    static var door0: Float = -0.86, door1: Float = 0.9
    static var cabin0: Float = -2.04, cabin1: Float = 0.96
    static var glassWindshield: Float = 0.14, glassRear0: Float = -1.5, glassRear1: Float = -0.72, glassSide: Float = -1.28
    static var frontBlackY: Float = 0.43, rearBlackY: Float = 0.56
}

enum Profile {
    private static func c(_ pts: [[Float]]) -> Curve { Curve(pts.map { ($0[0], $0[1]) }) }
    static var W = Curve([(0, 0), (1, 0)])
    static var BELT = Curve([(0, 0), (1, 0)])
    static var HOOD = Curve([(0, 0), (1, 0)])
    static var ROOF = Curve([(0, 0), (1, 0)])
    static var BOTTOM = Curve([(0, 0), (1, 0)])

    /// Select which car the generator builds.
    static func configure(_ s: CarSpec) {
        let d = s.dims
        Dim.xMin = d.xMin; Dim.xMax = d.xMax; Dim.wheelR = d.wheelR; Dim.wheelY = d.wheelY
        Dim.frontX = d.front.x; Dim.frontTrack = d.front.track; Dim.rearX = d.rear.x; Dim.rearTrack = d.rear.track
        Dim.archR = d.arch.r; Dim.archY = d.arch.y
        Dim.door0 = d.door[0]; Dim.door1 = d.door[1]; Dim.cabin0 = d.cabin[0]; Dim.cabin1 = d.cabin[1]
        Dim.glassWindshield = d.glass.windshield; Dim.glassRear0 = d.glass.rear[0]; Dim.glassRear1 = d.glass.rear[1]; Dim.glassSide = d.glass.side
        Dim.frontBlackY = d.frontBlackY; Dim.rearBlackY = d.rearBlackY
        W = c(s.curves.W); BELT = c(s.curves.BELT); HOOD = c(s.curves.HOOD); ROOF = c(s.curves.ROOF); BOTTOM = c(s.curves.BOTTOM)
    }

    static func archY(_ x: Float) -> Float? {
        for cx in [Dim.frontX, Dim.rearX] {
            let dx = x - cx
            if abs(dx) < Dim.archR { return Dim.archY + (Dim.archR * Dim.archR - dx * dx).squareRoot() }
        }
        return nil
    }

    /// Right-half cross-section at station x: 14 points (z, y), bottom-centre → top-centre.
    static func section(_ x: Float) -> [SIMD2<Float>] {
        let w = W(x), belt = BELT(x), hood = HOOD(x), yb = BOTTOM(x)
        let inCabin = x > Dim.cabin0 && x < Dim.cabin1
        let roof: Float = inCabin ? max(hood, ROOF(x)) : hood
        let c: Float = clamp01((roof - hood) / 0.08)
        let gb: Float = min(0.75, w - 0.2)
        let gt: Float = min(0.585, gb - 0.1)
        let ya: Float = archY(x) ?? (yb + 0.05)
        let wi: Float = 0.56
        let yLow: Float = ya + 0.05
        let yShoulder: Float = max(belt - 0.075, yLow + 0.02)
        var p = [SIMD2<Float>]()
        p.reserveCapacity(14)
        p.append(SIMD2<Float>(0, yb))
        p.append(SIMD2<Float>(wi, yb))
        p.append(SIMD2<Float>(wi, ya))
        p.append(SIMD2<Float>(w - 0.07, ya))
        p.append(SIMD2<Float>(w, yLow))
        p.append(SIMD2<Float>(w + 0.014, lerpf(yLow, yShoulder, 0.5)))
        p.append(SIMD2<Float>(w, yShoulder))
        p.append(SIMD2<Float>(w - 0.075, belt))
        p.append(SIMD2<Float>(gb + (w - 0.075 - gb) * 0.45, lerpf(hood, belt, 0.62)))
        p.append(SIMD2<Float>(gb, hood))
        p.append(SIMD2<Float>(lerpf(gb, gt, c), roof - 0.055 * c))
        p.append(SIMD2<Float>(gt - 0.09 * c, roof))
        p.append(SIMD2<Float>(0.17, roof + 0.008 * c))
        p.append(SIMD2<Float>(0, roof + 0.01 * c))
        return p
    }
}

enum Part: String, CaseIterable {
    case paint, stripe, glass, under, doorR, doorRGlass, doorL, doorLGlass
}

private func tagFor(_ x: Float, _ seg: Int, _ side: Int) -> Part {
    let inDoor = x > Dim.door0 && x < Dim.door1 && seg >= 3 && seg <= 9
    let windshield = x > Dim.glassWindshield && x < Dim.cabin1
    let rearGlass = x > Dim.glassRear0 && x < Dim.glassRear1
    let sideGlass = x > Dim.glassSide && x < Dim.cabin1
    if seg <= 2 { return .under }
    if inDoor {
        let glass = seg == 9 && sideGlass
        if side > 0 { return glass ? .doorRGlass : .doorR }
        return glass ? .doorLGlass : .doorL
    }
    switch seg {
    case 9: return sideGlass ? .glass : .paint
    case 10: return windshield ? .glass : .paint
    case 11: return windshield || rearGlass ? .glass : .paint
    case 12: return windshield || rearGlass ? .glass : .stripe
    default: return .paint
    }
}

// MARK: - Body mesh

struct BodyMesh {
    var positions: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var groups: [Part: [UInt32]] = [:]
}

func buildBody() -> BodyMesh {
    // stations: dense, plus exact break points so panel boundaries are crisp
    var xs: [Float] = []
    var x = Dim.xMin
    while x <= Dim.xMax + 1e-6 { xs.append(x); x += 0.016 }
    var bps: [Float] = [Dim.door0, Dim.door1, Dim.cabin0, Dim.cabin1, Dim.glassWindshield, Dim.glassRear0, Dim.glassRear1, Dim.glassSide, Dim.xMin, Dim.xMax]
    let fs: [Float] = [-1, -0.995, -0.98, -0.95, -0.9, 0.9, 0.95, 0.98, 0.995, 1]
    for cx in [Dim.frontX, Dim.rearX] { for f in fs { bps.append(cx + f * Dim.archR) } }
    xs = xs.filter { v in !bps.contains { abs(v - $0) < 0.004 } } + bps
    xs.sort()
    var stations: [Float] = []
    for v in xs where stations.last.map({ abs($0 - v) > 1e-5 }) ?? true { stations.append(v) }

    var rings: [[SIMD3<Float>]] = stations.map { sx in
        let r = Profile.section(sx)
        var full = r
        for j in stride(from: 12, through: 1, by: -1) { full.append(SIMD2<Float>(-r[j].x, r[j].y)) }
        return full.map { SIMD3<Float>(sx, $0.y, $0.x) }
    }
    let R = rings[0].count // 26

    // rounded end caps
    func cap(_ ring: [SIMD3<Float>], dir: Float, depth: Float) -> (rings: [[SIMD3<Float>]], center: SIMD3<Float>) {
        let ymin = ring.map { $0.y }.min()!, ymax = ring.map { $0.y }.max()!
        let cy = (ymin + ymax) / 2, x0 = ring[0].x
        var out: [[SIMD3<Float>]] = []
        for a: Float in [0.22, 0.45, 0.68, 0.9, 1.1, 1.28, 1.42, 1.52] {
            let s = cos(a), dx = sin(a) * depth * dir
            out.append(ring.map { SIMD3<Float>(x0 + dx, cy + ($0.y - cy) * s, $0.z * s) })
        }
        return (out, SIMD3<Float>(x0 + depth * dir, cy, 0))
    }
    let rearCap = cap(rings[0], dir: -1, depth: 0.05)
    let frontCap = cap(rings[rings.count - 1], dir: 1, depth: 0.07)
    let nCap = rearCap.rings.count
    rings = Array(rearCap.rings.reversed()) + rings + frontCap.rings
    let stationX: [Float] = Array(repeating: Dim.xMin - 0.01, count: nCap) + stations + Array(repeating: Dim.xMax + 0.01, count: nCap)

    var pos: [SIMD3<Float>] = rings.flatMap { $0 }
    let rearC = UInt32(pos.count); pos.append(rearCap.center)
    let frontC = UInt32(pos.count); pos.append(frontCap.center)

    var groups: [Part: [UInt32]] = [:]
    func add(_ p: Part, _ idx: UInt32...) { groups[p, default: []].append(contentsOf: idx) }
    func segOf(_ k: Int) -> (Int, Int) { k <= 12 ? (k, 1) : (25 - k, -1) }

    for i in 0..<(rings.count - 1) {
        let xm = (stationX[i] + stationX[i + 1]) / 2
        let isCap = i < nCap || i >= rings.count - 1 - nCap
        for k in 0..<R {
            let a = UInt32(i * R + k), b = UInt32((i + 1) * R + k)
            let c = UInt32((i + 1) * R + (k + 1) % R), d = UInt32(i * R + (k + 1) % R)
            let (seg, side) = segOf(k)
            var tag: Part = isCap ? .paint : tagFor(xm, seg, side)
            let qy = (pos[Int(a)].y + pos[Int(b)].y + pos[Int(c)].y + pos[Int(d)].y) / 4
            let qz = abs(pos[Int(a)].z + pos[Int(c)].z) / 2
            if tag == .paint && xm > Dim.xMax - 0.2 && qy < Dim.frontBlackY && qz < 0.7 { tag = .under }      // nose intake
            if tag == .paint && xm < Dim.xMin + 0.02 && qy < Dim.rearBlackY && qz < 0.8 { tag = .under } // diffuser band
            add(tag, a, b, d, b, c, d)
        }
    }
    let last = rings.count - 1
    for k in 0..<R {
        let k2 = (k + 1) % R
        add(rings[0][k].y < Dim.rearBlackY ? .under : .paint, rearC, UInt32(k2), UInt32(k))
        add(rings[last][k].y < Dim.frontBlackY ? .under : .paint, frontC, UInt32(last * R + k), UInt32(last * R + k2))
    }

    // smooth normals over the whole shell
    var nrm = [SIMD3<Float>](repeating: .zero, count: pos.count)
    for (_, idx) in groups {
        var t = 0
        while t + 2 < idx.count {
            let i0 = Int(idx[t]), i1 = Int(idx[t + 1]), i2 = Int(idx[t + 2])
            let n = simd_cross(pos[i1] - pos[i0], pos[i2] - pos[i0])
            nrm[i0] += n; nrm[i1] += n; nrm[i2] += n
            t += 3
        }
    }
    var mesh = BodyMesh()
    mesh.positions = pos.map { SCNVector3($0.x, $0.y, $0.z) }
    mesh.normals = nrm.map { n in
        let l = simd_length(n)
        let u = l > 1e-8 ? n / l : SIMD3<Float>(0, 1, 0)
        return SCNVector3(u.x, u.y, u.z)
    }
    mesh.groups = groups
    return mesh
}

// MARK: - Helpers

func pbr(_ color: UIColor, metal: CGFloat, rough: CGFloat, clear: CGFloat = 0, clearRough: CGFloat = 0.05, double: Bool = false) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = color
    m.metalness.contents = metal
    m.roughness.contents = rough
    if clear > 0 {
        m.clearCoat.contents = clear
        m.clearCoatRoughness.contents = clearRough
    }
    m.isDoubleSided = double
    return m
}

func glowMaterial(_ color: UIColor = .black) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = UIColor.black
    m.emission.contents = color
    return m
}

/// Sets an HDR emissive colour (components may exceed 1 → bloom).
func setGlow(_ m: SCNMaterial, _ r: Float, _ g: Float, _ b: Float) {
    let k = max(r, g, b, 0.0001)
    m.emission.contents = UIColor(red: CGFloat(r / k), green: CGFloat(g / k), blue: CGFloat(b / k), alpha: 1)
    m.emission.intensity = CGFloat(k)
}

func node(_ g: SCNGeometry, _ m: SCNMaterial, _ p: SCNVector3 = SCNVector3Zero) -> SCNNode {
    g.materials = [m]
    let n = SCNNode(geometry: g)
    n.position = p
    return n
}

func box(_ w: Float, _ h: Float, _ l: Float, _ m: SCNMaterial, chamfer: Float = 0) -> SCNNode {
    node(SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(l), chamferRadius: CGFloat(chamfer)), m)
}

/// three.js-style Euler (order "XYZ" by default).
func setEuler(_ n: SCNNode, x: Float = 0, y: Float = 0, z: Float = 0, order: String = "XYZ") {
    let qx = simd_quatf(angle: x, axis: SIMD3<Float>(1, 0, 0))
    let qy = simd_quatf(angle: y, axis: SIMD3<Float>(0, 1, 0))
    let qz = simd_quatf(angle: z, axis: SIMD3<Float>(0, 0, 1))
    switch order {
    case "YXZ": n.simdOrientation = qy * qx * qz
    case "YZX": n.simdOrientation = qy * qz * qx
    default: n.simdOrientation = qx * qy * qz
    }
}

func textImage(_ size: CGSize, draw: (CGContext, CGSize) -> Void) -> UIImage {
    let f = UIGraphicsImageRendererFormat()
    f.scale = 1
    f.opaque = false
    return UIGraphicsImageRenderer(size: size, format: f).image { ctx in draw(ctx.cgContext, size) }
}

// MARK: - Car

final class Car {
    let root = SCNNode()
    let chassis = SCNNode()

    let paint = pbr(UIColor(hex: "#1b55e0"), metal: 0.5, rough: 0.26, clear: 1, clearRough: 0.07, double: true)
    let stripe = pbr(UIColor(hex: "#b8913a"), metal: 0.7, rough: 0.32, clear: 1, clearRough: 0.07, double: true)
    let glass = pbr(UIColor(red: 0.01, green: 0.012, blue: 0.02, alpha: 1), metal: 0.1, rough: 0.08, clear: 1, clearRough: 0.1, double: true)
    let under = pbr(UIColor(red: 0.03, green: 0.035, blue: 0.045, alpha: 1), metal: 0, rough: 0.9, double: true)
    let carbon = pbr(UIColor(red: 0.07, green: 0.07, blue: 0.085, alpha: 1), metal: 0.3, rough: 0.35, clear: 0.8)
    let trimDark = pbr(UIColor(red: 0.08, green: 0.085, blue: 0.1, alpha: 1), metal: 0.6, rough: 0.5)
    let tyre = pbr(UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1), metal: 0, rough: 0.82)
    let rim = pbr(UIColor(hex: "#1a1b1f"), metal: 0.9, rough: 0.28)
    let chrome = pbr(UIColor(white: 0.87, alpha: 1), metal: 1, rough: 0.12)
    let disc = pbr(UIColor(white: 0.42, alpha: 1), metal: 0.9, rough: 0.42)
    let caliper = pbr(UIColor(hex: "#d0202a"), metal: 0.3, rough: 0.35)
    let interior = pbr(UIColor(red: 0.07, green: 0.075, blue: 0.09, alpha: 1), metal: 0, rough: 0.8)
    let alcantara = pbr(UIColor(red: 0.11, green: 0.115, blue: 0.13, alpha: 1), metal: 0, rough: 0.95)
    let accent = pbr(UIColor(hex: "#c81e2c"), metal: 0, rough: 0.6)
    let housing = pbr(UIColor(red: 0.02, green: 0.025, blue: 0.03, alpha: 1), metal: 0.4, rough: 0.12, clear: 1, clearRough: 0.1)

    private let drlMat = glowMaterial(), ledMat = glowMaterial(), indMat = glowMaterial()
    private var tailMats: [SCNMaterial] = []
    private var doors: [(pivot: SCNNode, side: Float)] = []
    private var beams: [SCNLight] = []
    private var coneMats: [SCNMaterial] = []
    private var flames: [SCNNode] = []
    private let flameLight = SCNLight()
    private let tailGlow = SCNLight()
    private let cabinLight = SCNLight()
    private let puddleMat = SCNMaterial()
    private var wheels: [(spin: SCNNode, steer: SCNNode, front: Bool, left: Bool)] = []
    private var stripeNode: SCNNode!
    let wing = SCNNode()
    private let ducktail = SCNNode()

    // animated state
    private var doorTarget: Float = 0, door: Float = 0
    private var lightsTarget: Float = 0, lightLevel: Float = 0
    private var drlTarget: Float = 0, drl: Float = 0
    var brake: Float = 0
    private var hazardCount: Float = 0, hazardT: Float = 0
    private var sweepT: Float = -1, sweepDir: Float = 1
    private var flame: Float = 0
    private var wheelAngle: Float = 0
    private(set) var livery = true

    private static let SEG = 34

    let spec: CarSpec
    private var L: CarSpec.Layout { spec.layout }

    init(spec: CarSpec) {
        self.spec = spec
        Profile.configure(spec)
        root.addChildNode(chassis)
        buildShell()
        buildDoors()
        buildInterior()
        buildAero()
        buildExhaust()
        buildLights()
        buildWheels()
        buildCourtesy()
    }

    // MARK: build

    private var mesh: BodyMesh!
    private var sources: [SCNGeometrySource] = []

    private func part(_ p: Part, _ m: SCNMaterial) -> SCNNode? {
        guard let idx = mesh.groups[p], !idx.isEmpty else { return nil }
        let g = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.castsShadow = true
        return n
    }

    private func buildShell() {
        mesh = buildBody()
        sources = [SCNGeometrySource(vertices: mesh.positions), SCNGeometrySource(normals: mesh.normals)]
        for (p, m) in [(Part.paint, paint), (.glass, glass), (.under, under)] {
            if let n = part(p, m) { chassis.addChildNode(n) }
        }
        stripeNode = part(.stripe, stripe)
        if let s = stripeNode { chassis.addChildNode(s) }
    }

    private func buildDoors() {
        for side: Float in [1, -1] {
            let hx: Float = Dim.door1 - 0.02, hy: Float = 0.93, hz = side * Profile.W(hx)
            let pivot = SCNNode()
            pivot.position = SCNVector3(hx, hy, hz)
            let inner = SCNNode()
            inner.position = SCNVector3(-hx, -hy, -hz)
            pivot.addChildNode(inner)
            if let p = part(side > 0 ? .doorR : .doorL, paint) { inner.addChildNode(p) }
            if let g = part(side > 0 ? .doorRGlass : .doorLGlass, glass) { inner.addChildNode(g) }
            // mirror
            let mx: Float = L.mirrorX, wz = Profile.W(mx), belt = Profile.BELT(mx)
            let stalk = box(0.07, 0.11, 0.02, carbon)
            stalk.position = SCNVector3(mx + 0.02, belt + 0.04, side * (wz - 0.02))
            setEuler(stalk, x: side * 0.9)
            inner.addChildNode(stalk)
            let mirror = node(SCNSphere(radius: 1), paint, SCNVector3(mx, belt + 0.09, side * (wz + 0.07)))
            mirror.scale = SCNVector3(0.11, 0.055, 0.085)
            inner.addChildNode(mirror)
            let mg = node(SCNPlane(width: 2, height: 2), chrome, SCNVector3(mx - 0.085, belt + 0.09, side * (wz + 0.07)))
            mg.scale = SCNVector3(0.045, 0.075, 1)
            setEuler(mg, y: -.pi / 2)
            inner.addChildNode(mg)
            chassis.addChildNode(pivot)
            doors.append((pivot, side))
        }
    }

    private func buildInterior() {
        let cab = SCNNode(); cab.position = SCNVector3(L.cabinX, 0, 0); chassis.addChildNode(cab)
        cab.addChildNode({ let f = box(1.9, 0.04, 1.6, interior); f.position = SCNVector3(-0.05, 0.3, 0); return f }())
        for z: Float in [-0.37, 0.37] {
            let seat = SCNNode()
            let base = box(0.5, 0.1, 0.46, alcantara); base.position = SCNVector3(0, 0.05, 0)
            let back = box(0.1, 0.62, 0.46, alcantara); back.position = SCNVector3(-0.25, 0.33, 0); setEuler(back, z: 0.22)
            let b1 = box(0.42, 0.14, 0.06, accent); b1.position = SCNVector3(0, 0.1, 0.22)
            let b2 = box(0.42, 0.14, 0.06, accent); b2.position = SCNVector3(0, 0.1, -0.22)
            [base, back, b1, b2].forEach { seat.addChildNode($0) }
            seat.position = SCNVector3(-0.35, 0.32, z)
            cab.addChildNode(seat)
        }
        let dash = box(0.3, 0.16, 1.5, interior); dash.position = SCNVector3(0.55, 0.76, 0); cab.addChildNode(dash)
        let wheel = node(SCNTorus(ringRadius: 0.17, pipeRadius: 0.022), alcantara, SCNVector3(0.3, 0.82, -0.37))
        setEuler(wheel, z: .pi / 2 + 0.35)
        cab.addChildNode(wheel)
    }

    private func buildAero() {
        let splitter = box(0.3, 0.02, 1.5, carbon); splitter.position = SCNVector3(Dim.xMax - 0.02, 0.2, 0); chassis.addChildNode(splitter)
        let midX = (Dim.frontX + Dim.rearX) / 2, skirtLen = Dim.frontX - Dim.rearX - 2 * Dim.archR - 0.08
        for s: Float in [1, -1] {
            let skirt = box(skirtLen, 0.05, 0.06, carbon); skirt.position = SCNVector3(midX, 0.24, s * (Profile.W(midX) + 0.01)); chassis.addChildNode(skirt)
            if spec.parts.hoodVents {
                let vx = L.ventX
                let vent = box(0.34, 0.02, 0.2, under)
                vent.position = SCNVector3(vx, Profile.HOOD(vx), s * 0.3)
                setEuler(vent, z: atan2(Profile.HOOD(vx + 0.15) - Profile.HOOD(vx - 0.15), 0.3))
                chassis.addChildNode(vent)
            }
        }
        let diff = box(0.42, 0.03, 1.5, carbon); diff.position = SCNVector3(Dim.xMin + 0.18, 0.255, 0); setEuler(diff, z: -0.18); chassis.addChildNode(diff)
        for i in -3...3 {
            let fin = box(0.4, 0.1, 0.012, carbon); fin.position = SCNVector3(Dim.xMin + 0.16, 0.24, Float(i) * 0.2); setEuler(fin, z: -0.18)
            chassis.addChildNode(fin)
        }
        for i in 0..<(spec.parts.louvres ? 6 : 0) {
            let x: Float = L.louvreX - Float(i) * 0.07
            let l = box(0.03, 0.012, 0.9, carbon)
            l.position = SCNVector3(x, max(Profile.HOOD(x), Profile.ROOF(x)) + 0.005, 0)
            setEuler(l, z: atan2(Profile.ROOF(x + 0.05) - Profile.ROOF(x - 0.05), 0.1))
            chassis.addChildNode(l)
        }
        // swan-neck wing
        let foil = SCNShape(path: Car.airfoil(chord: 0.4, thick: 0.12), extrusionDepth: 1.86)
        let wx = L.wingX + 1.92
        let foilNode = node(foil, carbon, SCNVector3(-1.92 + wx, 1.36, 0))
        setEuler(foilNode, z: .pi + 0.1)
        wing.addChildNode(foilNode)
        for s: Float in [1, -1] {
            let plate = box(0.44, 0.13, 0.012, carbon); plate.position = SCNVector3(-2.12 + wx, 1.345, s * 0.935); wing.addChildNode(plate)
            let neck = box(0.1, 0.42, 0.018, carbon); neck.position = SCNVector3(-2.0 + wx, 1.17, s * 0.42); setEuler(neck, z: -0.28); wing.addChildNode(neck)
        }
        chassis.addChildNode(wing)
        ducktail.geometry = SCNBox(width: 0.14, height: 0.022, length: 1.5, chamferRadius: 0)
        ducktail.geometry?.materials = [carbon]
        ducktail.position = SCNVector3(Dim.xMin + 0.06, Profile.HOOD(Dim.xMin + 0.06) + 0.005, 0); setEuler(ducktail, z: 0.25)
        wing.isHidden = spec.parts.wing != "swan"
        ducktail.isHidden = spec.parts.wing != "ducktail"
        chassis.addChildNode(ducktail)
    }

    static func airfoil(chord: CGFloat, thick: CGFloat) -> UIBezierPath {
        let n = 24
        var top: [CGPoint] = [], bot: [CGPoint] = []
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let x = (1 - cos(t * .pi)) / 2
            let p1: CGFloat = 0.2969 * sqrt(x) - 0.126 * x
            let p2: CGFloat = -0.3516 * x * x + 0.2843 * x * x * x - 0.1036 * x * x * x * x
            let yt = 5 * thick * (p1 + p2)
            let camber = 0.06 * sin(x * .pi)
            top.append(CGPoint(x: x * chord, y: (camber + yt) * chord))
            bot.append(CGPoint(x: x * chord, y: (camber - yt) * chord))
        }
        let path = UIBezierPath()
        path.move(to: top[0])
        top.dropFirst().forEach { path.addLine(to: $0) }
        bot.reversed().forEach { path.addLine(to: $0) }
        path.close()
        path.flatness = 0.002
        return path
    }

    private func buildExhaust() {
        let ey = L.exhaustY
        let pipes: [Float] = spec.parts.exhaust == "quad" ? [-0.34, -0.2, 0.2, 0.34] : spec.parts.exhaust == "twin" ? [-0.13, 0.13] : []
        for z in pipes {
            let tip = node(SCNTube(innerRadius: 0.046, outerRadius: 0.055, height: 0.14), chrome, SCNVector3(Dim.xMin + (pipes.count > 2 ? 0.03 : -0.02), ey, z))
            setEuler(tip, z: .pi / 2)
            chassis.addChildNode(tip)
            let inner = node(SCNPlane(width: 0.095, height: 0.095), under, SCNVector3(Dim.xMin, ey, z))
            setEuler(inner, y: -.pi / 2)
            chassis.addChildNode(inner)

            let flame = SCNNode()
            for (r, h, x, col) in [(Float(0.06), Float(0.55), Float(-0.27), UIColor(red: 1, green: 0.35, blue: 0.06, alpha: 1)),
                                   (0.035, 0.3, -0.15, UIColor(red: 0.15, green: 0.3, blue: 1, alpha: 1))] {
                let m = glowMaterial(col)
                m.emission.intensity = 4
                m.blendMode = .add
                m.writesToDepthBuffer = false
                m.isDoubleSided = true
                let c = node(SCNCone(topRadius: 0, bottomRadius: CGFloat(r), height: CGFloat(h)), m, SCNVector3(x, 0, 0))
                setEuler(c, z: .pi / 2)
                flame.addChildNode(c)
            }
            flame.position = SCNVector3(Dim.xMin - 0.08, ey, z)
            flame.isHidden = true
            chassis.addChildNode(flame)
            flames.append(flame)
        }
        flameLight.type = .omni
        flameLight.color = UIColor(red: 1, green: 0.48, blue: 0.16, alpha: 1)
        flameLight.intensity = 0
        flameLight.attenuationEndDistance = 4
        let fl = SCNNode(); fl.light = flameLight; fl.position = SCNVector3(Dim.xMin - 0.4, ey + 0.05, 0)
        chassis.addChildNode(fl)
    }

    private func buildLights() {
        // headlight pods: glossy housing, DRL ring, four LED projectors, indicator
        if spec.parts.lights == "strip" {
            // slim full-width LED strip across the nose
            let sx = L.headX, sy = Profile.BELT(sx) - 0.035
            let tilt = atan2(Profile.BELT(sx + 0.05) - Profile.BELT(sx - 0.05), 0.1) * 0.6
            let bar = box(0.03, 0.022, L.headZ * 2.1, drlMat); bar.position = SCNVector3(sx, sy, 0); setEuler(bar, z: tilt); chassis.addChildNode(bar)
            let barH = box(0.04, 0.045, L.headZ * 2.1 + 0.04, housing); barH.position = SCNVector3(sx - 0.012, sy, 0); setEuler(barH, z: tilt); chassis.addChildNode(barH)
            for s: Float in [1, -1] {
                for i in 0..<3 {
                    let led = box(0.02, 0.018, 0.05, ledMat); led.position = SCNVector3(sx + 0.005, sy - 0.04, s * (L.headZ - 0.06 - Float(i) * 0.07)); chassis.addChildNode(led)
                }
                let ind = box(0.03, 0.02, 0.1, indMat); ind.position = SCNVector3(sx, sy, s * (L.headZ * 1.05 + 0.08)); chassis.addChildNode(ind)
            }
        }
        for s: Float in [1, -1] {
            let hx: Float = L.headX, hz = s * L.headZ, hy = Profile.BELT(hx) - 0.03
            let pod = SCNNode()
            pod.isHidden = spec.parts.lights != "pods"
            pod.position = SCNVector3(hx, hy, hz)
            setEuler(pod, z: atan2(Profile.BELT(hx + 0.1) - Profile.BELT(hx - 0.1), 0.2) * 0.8)
            let housingNode = node(SCNSphere(radius: 1), housing)
            housingNode.scale = SCNVector3(0.2, 0.072, 0.14)
            pod.addChildNode(housingNode)
            let ring = node(SCNTorus(ringRadius: 0.105, pipeRadius: 0.011), drlMat, SCNVector3(0.13, 0, 0))
            ring.scale = SCNVector3(0.62, 1, 1)
            setEuler(ring, z: .pi / 2)
            pod.addChildNode(ring)
            for i in 0..<4 {
                let led = node(SCNSphere(radius: 0.019), ledMat,
                               SCNVector3(0.15, (i < 2 ? 1 : -1) * 0.022, (i % 2 == 1 ? 1 : -1) * 0.032))
                pod.addChildNode(led)
            }
            let ind = box(0.03, 0.018, 0.12, indMat); ind.position = SCNVector3(0.13, -0.065, s * 0.03); pod.addChildNode(ind)
            chassis.addChildNode(pod)

            // real light that hits the floor
            let beam = SCNLight()
            beam.type = .spot
            beam.color = UIColor(red: 0.91, green: 0.94, blue: 1, alpha: 1)
            beam.intensity = 0
            beam.spotInnerAngle = 18
            beam.spotOuterAngle = 46
            beam.attenuationEndDistance = 30
            let ln = SCNNode(); ln.light = beam; ln.position = SCNVector3(hx + 0.14, hy, hz)
            let target = SCNNode(); target.position = SCNVector3(9, 0, s * 1.0)
            ln.constraints = [SCNLookAtConstraint(target: target)]
            chassis.addChildNode(ln); chassis.addChildNode(target)
            beams.append(beam)

            // faint volumetric cone
            let cm = glowMaterial(UIColor(red: 0.8, green: 0.88, blue: 1, alpha: 1))
            cm.blendMode = .add; cm.writesToDepthBuffer = false; cm.isDoubleSided = true; cm.transparency = 0
            let cone = node(SCNCone(topRadius: 0, bottomRadius: 1.4, height: 6), cm, SCNVector3(0, -3, 0))
            let holder = SCNNode(); holder.position = SCNVector3(hx + 0.14, hy + 0.02, hz)
            setEuler(holder, y: -s * 0.04, z: .pi / 2 + 0.07, order: "YXZ")
            holder.addChildNode(cone)
            chassis.addChildNode(holder)
            coneMats.append(cm)
        }

        // full-width tail light bar, one material per segment so it can animate
        let span: Float = 1.62, segW = span / Float(Car.SEG)
        let tailX: Float = Dim.xMin - 0.035, tailY: Float = L.tailY
        for i in 0..<Car.SEG {
            let z = -span / 2 + segW * (Float(i) + 0.5)
            let t = abs(z) / (span / 2)
            let m = glowMaterial()
            let seg = box(0.03, 0.035, segW * 0.82, m)
            seg.position = SCNVector3(tailX + 0.02 * t * t, tailY, z)
            chassis.addChildNode(seg)
            tailMats.append(m)
        }
        let th = box(0.03, 0.06, span + 0.04, housing); th.position = SCNVector3(tailX + 0.012, tailY, 0); chassis.addChildNode(th)
        tailGlow.type = .omni; tailGlow.color = UIColor.red; tailGlow.intensity = 0; tailGlow.attenuationEndDistance = 3
        let tg = SCNNode(); tg.light = tailGlow; tg.position = SCNVector3(Dim.xMin - 0.6, 0.5, 0); chassis.addChildNode(tg)

        // rear lettering
        let badgeImg = textImage(CGSize(width: 512, height: 64)) { _, size in
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: UIColor(white: 0.92, alpha: 1), .kern: 22, .paragraphStyle: p]
            ("APEX" as NSString).draw(in: CGRect(x: 0, y: 4, width: size.width, height: size.height), withAttributes: attrs)
        }
        let bm = SCNMaterial(); bm.lightingModel = .constant; bm.diffuse.contents = badgeImg; bm.isDoubleSided = false
        let badge = node(SCNPlane(width: 0.5, height: 0.0625), bm, SCNVector3(Dim.xMin - 0.04, L.badgeY, 0))
        setEuler(badge, y: -.pi / 2)
        chassis.addChildNode(badge)
    }

    private func buildWheels() {
        for (ax, track, front) in [(Dim.frontX, Dim.frontTrack, true), (Dim.rearX, Dim.rearTrack, false)] {
            for s: Float in [1, -1] {
                let steer = SCNNode()
                steer.position = SCNVector3(ax, Dim.wheelY, s * track)
                let wheel = SCNNode()
                if s < 0 { setEuler(wheel, y: .pi) } // outer face towards -z
                let spin = buildWheel(into: wheel)
                steer.addChildNode(wheel)
                root.addChildNode(steer)
                wheels.append((spin, steer, front, s < 0))
            }
        }
    }

    private func buildWheel(into g: SCNNode) -> SCNNode {
        let spin = SCNNode(); g.addChildNode(spin)
        let w: Float = 0.29, rr: Float = 0.245
        let t = node(SCNTorus(ringRadius: 0.29, pipeRadius: 0.065), tyre)
        t.scale = SCNVector3(1, 2.2, 1)
        setEuler(t, x: .pi / 2)
        t.castsShadow = true
        spin.addChildNode(t)
        let barrel = node(SCNTube(innerRadius: CGFloat(rr - 0.01), outerRadius: CGFloat(rr), height: CGFloat(w - 0.05)), trimDark)
        setEuler(barrel, x: .pi / 2)
        spin.addChildNode(barrel)
        let lip = node(SCNTorus(ringRadius: CGFloat(rr), pipeRadius: 0.012), rim, SCNVector3(0, 0, w / 2 - 0.03))
        setEuler(lip, x: .pi / 2)
        spin.addChildNode(lip)
        for i in 0..<10 {
            let arm = SCNNode()
            setEuler(arm, x: -0.12, z: Float(i) / 10 * 2 * .pi, order: "XYZ")
            arm.position = SCNVector3(0, 0, w / 2 - 0.06)
            let spoke = box(0.034, rr - 0.05, 0.028, rim)
            spoke.position = SCNVector3(0, (rr - 0.05) / 2 + 0.045, 0)
            arm.addChildNode(spoke)
            spin.addChildNode(arm)
        }
        let hub = node(SCNCylinder(radius: 0.065, height: 0.06), rim, SCNVector3(0, 0, w / 2 - 0.05))
        setEuler(hub, x: .pi / 2)
        spin.addChildNode(hub)
        let nut = node(SCNCylinder(radius: 0.035, height: 0.03), chrome, SCNVector3(0, 0, w / 2 - 0.02))
        setEuler(nut, x: .pi / 2)
        spin.addChildNode(nut)
        let d = node(SCNCylinder(radius: 0.2, height: 0.03), disc)
        setEuler(d, x: .pi / 2)
        g.addChildNode(d)
        let cal = box(0.16, 0.08, 0.07, caliper); cal.position = SCNVector3(-0.1, 0.14, 0.03); setEuler(cal, z: 0.6)
        g.addChildNode(cal)
        return spin
    }

    private func buildCourtesy() {
        cabinLight.type = .omni
        cabinLight.color = UIColor(red: 1, green: 0.85, blue: 0.66, alpha: 1)
        cabinLight.intensity = 0
        cabinLight.attenuationEndDistance = 2.6
        let cl = SCNNode(); cl.light = cabinLight; cl.position = SCNVector3(-0.1 + L.cabinX, 1.0, 0)
        chassis.addChildNode(cl)

        let img = textImage(CGSize(width: 256, height: 256)) { ctx, _ in
            let cs = CGColorSpaceCreateDeviceRGB()
            let grad = CGGradient(colorsSpace: cs, colors: [UIColor(red: 1, green: 0.94, blue: 0.86, alpha: 0.55).cgColor,
                                                             UIColor(red: 1, green: 0.9, blue: 0.78, alpha: 0.22).cgColor,
                                                             UIColor(red: 1, green: 0.9, blue: 0.78, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 0.55, 1])!
            ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 128, y: 128), startRadius: 10, endCenter: CGPoint(x: 128, y: 128), endRadius: 120, options: [])
            ctx.setStrokeColor(UIColor(white: 1, alpha: 0.8).cgColor); ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: 50, y: 50, width: 156, height: 156))
            let p = NSMutableParagraphStyle(); p.alignment = .center
            ("APEX" as NSString).draw(in: CGRect(x: 0, y: 102, width: 256, height: 40),
                                      withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .heavy), .foregroundColor: UIColor.white, .paragraphStyle: p])
            ("9 R" as NSString).draw(in: CGRect(x: 0, y: 140, width: 256, height: 20),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor(white: 1, alpha: 0.7), .paragraphStyle: p])
        }
        puddleMat.lightingModel = .constant
        puddleMat.diffuse.contents = img
        puddleMat.blendMode = .add
        puddleMat.writesToDepthBuffer = false
        puddleMat.transparency = 0
        for s: Float in [1, -1] {
            let p = node(SCNPlane(width: 1.1, height: 1.1), puddleMat, SCNVector3((Dim.door0 + Dim.door1) / 2 + 0.23, 0.006, s * (Profile.W(0) + 0.55)))
            setEuler(p, x: -.pi / 2, z: s > 0 ? 0 : .pi)
            root.addChildNode(p)
        }
    }

    // MARK: API

    func setPaint(_ hex: String) { paint.diffuse.contents = UIColor(hex: hex); if !livery { stripeNode?.geometry?.materials = [paint] } }
    func setLivery(_ on: Bool) { livery = on; stripeNode?.geometry?.materials = [on ? stripe : paint] }
    func setRim(_ hex: String) { rim.diffuse.contents = UIColor(hex: hex) }
    func setWing(_ on: Bool) { wing.isHidden = !on; ducktail.isHidden = on || spec.parts.wing == "none" }
    func setDoors(_ open: Bool) { doorTarget = open ? 1 : 0 }
    func setLights(_ level: Int) { lightsTarget = Float(level) }
    func setDRL(_ on: Bool) { drlTarget = on ? 1 : 0 }
    func hazard(_ n: Float = 2) { hazardCount = n; hazardT = 0 }
    func sweep(_ dir: Float) { sweepT = 0; sweepDir = dir }
    func flames(_ power: Float) { flame = max(flame, power) }
    func spinWheels(_ da: Float) { wheelAngle += da }
    var doorAmount: Float { door }

    func update(_ dt: Float) {
        // doors (scissor: up and slightly out)
        door += (doorTarget - door) * (1 - exp(-dt * 4.2))
        for d in doors {
            let qy = simd_quatf(angle: d.side * door * 0.28, axis: SIMD3<Float>(0, 1, 0))
            let qz = simd_quatf(angle: -door * 1.05, axis: SIMD3<Float>(0, 0, 1))
            d.pivot.simdOrientation = qy * qz
        }
        cabinLight.intensity = CGFloat(door * 160)
        puddleMat.transparency = CGFloat(min(1, door * 1.3))

        // DRL & beams
        drl += (drlTarget - drl) * (1 - exp(-dt * 6))
        lightLevel += (lightsTarget - lightLevel) * (1 - exp(-dt * 10))
        let lv = lightLevel
        let drlI = max(drl, min(1, lv)) * 3.2
        setGlow(drlMat, drlI, drlI, drlI * 1.08)
        let ledI = lv * 2.4 + 0.02
        setGlow(ledMat, ledI * 0.95, ledI, ledI * 1.15)
        for b in beams {
            b.intensity = CGFloat(lv * 1600)
            b.spotOuterAngle = lv > 1.2 ? 38 : 46
        }
        for m in coneMats { m.transparency = CGFloat(max(0, lv - 0.2) * 0.022) }

        // hazards
        var blink: Float = 0
        if hazardCount > 0 {
            hazardT += dt
            blink = Int(hazardT / 0.35) % 2 == 0 ? 1 : 0
            if hazardT > hazardCount * 0.7 { hazardCount = 0 }
        }
        setGlow(indMat, blink * 4 + 0.001, blink * 2.2, blink * 0.15)

        // tail bar with welcome/goodbye sweep
        var st: Float = -1
        if sweepT >= 0 {
            sweepT += dt
            st = sweepT / 0.75
            if st > 1.6 { sweepT = -1; st = -1 }
        }
        let base = max(drl, min(1, lv))
        for (i, m) in tailMats.enumerated() {
            let u = abs((Float(i) + 0.5) / Float(Car.SEG) - 0.5) * 2
            var v = base * 2.4 + brake * 3.5
            if st >= 0 {
                let front = sweepDir > 0 ? st : 1 - st
                let sv: Float = u < front ? 3.4 * (1 - max(0, st - 1) / 0.6) : 0
                v = max(v, sv)
            }
            if blink > 0 && u > 0.82 { setGlow(m, 4, 1.9, 0.1) }
            else { setGlow(m, max(0.05, v), v * 0.04, v * 0.05) }
        }
        tailGlow.intensity = CGFloat(brake * 120)

        // flames
        flame = max(0, flame - dt * 9)
        for f in flames {
            f.isHidden = flame < 0.05
            let flick = Float.random(in: 0.7...1.3)
            f.scale = SCNVector3(flame * flick, 0.7 + flame * 0.5 * flick, 0.7 + flame * 0.5 * flick)
        }
        flameLight.intensity = flames.isEmpty ? 0 : CGFloat(flame * 400)

        // wheels: right side spins about -z, mirrored left side about +z
        for w in wheels { w.spin.eulerAngles = SCNVector3(0, 0, w.left ? wheelAngle : -wheelAngle) }
    }
}
