import Foundation

/// Mirrors cars/cars.json (shared with the web showroom).
struct CarCatalog: Decodable { let cars: [CarSpec] }

struct CarSpec: Decodable {
    struct Engine: Decodable {
        let type: String
        let cyl: Int?
        let lope: Float?
        let sub: Float?
        let scream: Float?
        let idle: Double
        let limit: Double
        let gearTop: [Double]
        let accel: [Double]
        let vmax: Double
        var isEV: Bool { type == "ev" }
    }
    struct Axle: Decodable { let x: Float; let track: Float }
    struct Arch: Decodable { let r: Float; let y: Float }
    struct Glass: Decodable { let windshield: Float; let rear: [Float]; let side: Float }
    struct Dims: Decodable {
        let xMin: Float, xMax: Float, wheelR: Float, wheelY: Float
        let front: Axle, rear: Axle, arch: Arch
        let door: [Float], cabin: [Float]
        let glass: Glass
        let frontBlackY: Float, rearBlackY: Float
    }
    struct Curves: Decodable { let W: [[Float]]; let BELT: [[Float]]; let HOOD: [[Float]]; let ROOF: [[Float]]; let BOTTOM: [[Float]] }
    struct Parts: Decodable { let wing: String; let exhaust: String; let lights: String; let louvres: Bool; let hoodVents: Bool }
    struct Layout: Decodable {
        let headX: Float, headZ: Float, mirrorX: Float, wingX: Float, ventX: Float, louvreX: Float
        let tailY: Float, badgeY: Float, exhaustY: Float, cabinX: Float
    }

    let id: String
    let name: String
    let tagline: String
    let spec: String
    let paint: String
    let stripe: Bool
    let engine: Engine
    let dims: Dims
    let curves: Curves
    let parts: Parts
    let layout: Layout

    static let all: [CarSpec] = {
        guard let url = Bundle.main.url(forResource: "cars", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let cat = try? JSONDecoder().decode(CarCatalog.self, from: data), !cat.cars.isEmpty
        else { fatalError("cars.json missing from the app bundle") }
        return cat.cars
    }()

    static func byId(_ id: String?) -> CarSpec { all.first { $0.id == id } ?? all[0] }
}
