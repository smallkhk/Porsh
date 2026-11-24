import AVFoundation
import UIKit

// Procedural flat-six, synthesized sample-by-sample on the audio thread.
// Same recipe as the web version (js/engine-audio.js):
//   wavetable at half crank frequency (one 4-stroke cycle) with strong 6th-order
//   firing harmonics → asymmetric tanh drive → rpm/throttle-dependent low-pass,
//   + intake noise + high-rpm scream, + one-shot voices (pops, starter, chirps…).
// Loudness rises ~20 dB from idle to redline, ~10 dB more under throttle.

private struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    mutating func lowpass(_ f: Float, _ q: Float, _ sr: Float) {
        let w = 2 * Float.pi * min(f, sr * 0.45) / sr
        let c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0
        a1 = -2 * c / a0; a2 = (1 - al) / a0
    }

    mutating func bandpass(_ f: Float, _ q: Float, _ sr: Float) {
        let w = 2 * Float.pi * min(f, sr * 0.45) / sr
        let c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        b0 = al / a0; b1 = 0; b2 = -al / a0
        a1 = -2 * c / a0; a2 = (1 - al) / a0
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

private struct Voice {
    enum Kind { case pop, starter, beep, thud, horn }
    var kind: Kind
    var t: Float = 0          // seconds since start (negative = delayed)
    var dur: Float
    var a: Float = 1          // strength / level
    var b: Float = 1          // freq / pitch
    var phase: Float = 0
    var phase2: Float = 0
    var filter = Biquad()
    var filter2 = Biquad()
}

final class EngineSynth {
    // parameters written on the main thread, read on the audio thread
    var rpm: Float = 0
    var load: Float = 0
    var on = false
    var hornOn = false
    var volume: Float = 0.85

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let lock = NSLock()
    private var pending: [Voice] = []
    private(set) var running = false

    // DSP state (audio thread only)
    private var sr: Float = 48000
    private var table = [Float](repeating: 0, count: 4096)
    private var phA: Float = 0, phB: Float = 0, phSub: Float = 0, phScr: Float = 0
    private var rpmS: Float = 0, loadS: Float = 0, onS: Float = 0, volS: Float = 0, masterS: Float = 0
    private var tone = Biquad(), intake = Biquad(), scream = Biquad()
    private var noiseLast: Float = 0
    private var voices: [Voice] = []
    private var counter = 0
    private var rng: UInt32 = 0x1234_5678

    init() {
        buildTable()
        voices.reserveCapacity(64)
        pending.reserveCapacity(64)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.start()
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            if let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, v == AVAudioSession.InterruptionType.ended.rawValue {
                self?.restart()
            }
        }
    }

    private func buildTable() {
        let N = 48
        func amp(_ k: Int) -> Float {
            let kf = Float(k)
            var a: Float = 0.05 / kf
            if k % 6 == 0 { a += 1.0 / (kf / 6) }
            if k % 3 == 0 { a += 0.28 / kf.squareRoot() }
            if k % 2 == 0 { a += 0.12 / kf.squareRoot() }
            return a
        }
        var peak: Float = 0
        for i in 0..<table.count {
            let x = Float(i) / Float(table.count) * 2 * Float.pi
            var v: Float = 0
            for k in 1..<N {
                let a = amp(k)
                let im = a * (k % 4 == 1 ? -1 : 1), re = a * 0.3
                v += re * cos(Float(k) * x) + im * sin(Float(k) * x)
            }
            table[i] = v
            peak = max(peak, abs(v))
        }
        for i in 0..<table.count { table[i] /= peak }
    }

    // MARK: lifecycle

    /// Last audio error, shown on screen so problems aren't silent.
    private(set) var lastError: String?
    var isRunning: Bool { engine.isRunning }

    private func attachSource(_ fmt: AVAudioFormat) {
        let src = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard let l = bufs[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = bufs.count > 1 ? bufs[1].mData?.assumingMemoryBound(to: Float.self) : nil
            self.render(l, r, Int(frameCount))
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 1
        source = src
    }

    /// Safe to call any time; retries until the audio engine is really running.
    @discardableResult
    func start() -> Bool {
        if engine.isRunning { running = true; return true }
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback: plays even with the silent switch on, like a game would
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            lastError = "Audio session: \(error.localizedDescription)"
        }
        if source == nil {
            let hw = session.sampleRate
            sr = Float(hw > 0 ? hw : 48000)
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 2) else { return false }
            attachSource(fmt)
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
            lastError = nil
        } catch {
            running = false
            lastError = "Audio engine: \(error.localizedDescription)"
        }
        return running
    }

    func stop() { engine.pause(); running = false }

    private func restart() {
        engine.stop()
        running = false
        start()
    }

    /// Rebuilds the graph from scratch (after iOS resets media services).
    private func rebuild() {
        engine.stop()
        if let s = source { engine.detach(s) }
        source = nil
        running = false
        start()
    }

    /// Renders the engine offline (no speakers) and reports loudness per rpm.
    /// Used by the CI self-test to prove the DSP makes sound.
    static func selfTest() -> String {
        let s = EngineSynth()
        return s.runOfflineTest()
    }

    private func runOfflineTest() -> String {
        sr = 48000
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else { return "no format" }
        do { try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096) }
        catch { return "manual rendering unavailable: \(error.localizedDescription)" }
        attachSource(fmt)
        do { try engine.start() } catch { return "engine start failed: \(error.localizedDescription)" }
        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { return "no buffer" }
        var out: [String] = []
        for (r, l) in [(1000, 0), (3000, 1), (6000, 1), (9000, 1)] {
            rpm = Float(r); load = Float(l); on = true
            var sum = 0.0, n = 0, nan = false
            for block in 0..<36 {
                guard (try? engine.renderOffline(4096, to: buf)) == .success, let d = buf.floatChannelData?[0] else { continue }
                if block < 18 { continue } // let it settle
                for i in 0..<Int(buf.frameLength) {
                    let v = Double(d[i])
                    if v.isNaN { nan = true }
                    sum += v * v; n += 1
                }
            }
            let rms = n > 0 ? (sum / Double(n)).squareRoot() : 0
            out.append(nan ? "\(r)rpm NaN!" : String(format: "%drpm load%d %.1f dB", r, l, 20 * log10(max(rms, 1e-9))))
        }
        engine.stop()
        return out.joined(separator: " | ")
    }

    // MARK: one-shots (main thread)

    private func push(_ v: Voice) {
        lock.lock(); pending.append(v); lock.unlock()
    }

    func pop(_ strength: Float = 1) {
        var v = Voice(kind: .pop, dur: 0.16, a: strength, b: Float.random(in: 500...2100))
        v.t = -Float.random(in: 0...0.01)
        v.filter.bandpass(v.b, 0.8, sr)
        push(v)
    }

    func starter(_ dur: Float = 1.0) {
        var v = Voice(kind: .starter, dur: dur)
        v.filter.lowpass(900, 0.7, sr)
        push(v)
    }

    func chirp(_ kind: String) {
        let beeps: [(Float, Float)] = kind == "lock" ? [(0, 1900)] : kind == "unlock" ? [(0, 1700), (0.14, 2100)] : [(0, 1200)]
        for (delay, f) in beeps { var v = Voice(kind: .beep, dur: 0.1, b: f); v.t = -delay; push(v) }
    }

    func thud(_ level: Float = 1, pitch: Float = 1) {
        var v = Voice(kind: .thud, dur: 0.2, a: level, b: pitch)
        v.filter.lowpass(1200 * pitch, 0.7, sr)
        push(v)
    }

    func click() { thud(0.25, pitch: 4) }

    func horn(_ down: Bool) {
        hornOn = down
        if down {
            var v = Voice(kind: .horn, dur: 30)
            v.filter.bandpass(1100, 0.7, sr)
            push(v)
        }
    }

    // MARK: audio thread

    @inline(__always) private func noise() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng) / Float(UInt32.max) * 2 - 1
    }

    @inline(__always) private func wave(_ ph: Float) -> Float {
        let p = ph * Float(table.count)
        let i = Int(p)
        let f = p - Float(i)
        let a = table[i & 4095], b = table[(i + 1) & 4095]
        return a + (b - a) * f
    }

    private func render(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>?, _ n: Int) {
        if lock.try() {
            if !pending.isEmpty { voices.append(contentsOf: pending); pending.removeAll(keepingCapacity: true) }
            lock.unlock()
        }
        let tRpm = rpm, tLoad = load, tOn: Float = on ? 1 : 0, tMaster = volume
        let k: Float = 1 - exp(-1 / (0.025 * sr))
        let dt = 1 / sr

        for i in 0..<n {
            rpmS += (tRpm - rpmS) * k
            loadS += (tLoad - loadS) * k
            onS += (tOn - onS) * k * 0.5
            masterS += (tMaster - masterS) * k

            let crank = max(rpmS, 1) / 60
            let cycle = crank / 2
            let r = min(1, rpmS / 9000)

            if counter & 31 == 0 {
                tone.lowpass(260 + r * 2600 + loadS * 1700, 1.4, sr)
                intake.bandpass(500 + crank * 9, 1.8, sr)
                scream.bandpass(crank * 6, 3, sr)
            }
            counter &+= 1

            phA += cycle * dt; if phA >= 1 { phA -= 1 }
            phB += cycle * 1.0052 * dt; if phB >= 1 { phB -= 1 }
            phSub += crank * 1.5 * dt; if phSub >= 1 { phSub -= 1 }
            phScr += crank * 3 * dt; if phScr >= 1 { phScr -= 1 }

            let sub = 4 * abs(phSub - 0.5) - 1
            let subGain = 0.55 * (1 - r) + 0.1
            let x = (0.55 * wave(phA) + 0.35 * wave(phB) + subGain * sub) * (0.9 + loadS * 1.6)
            var sh = tanh(2.6 * x)
            if sh < 0 { sh *= 0.86 }
            let body = tone.process(sh)

            let vTarget = onS * (0.055 + 0.32 * pow(r, 1.3) + 0.3 * loadS * (0.35 + 0.65 * r)) * min(1, rpmS / 500)
            volS += (vTarget - volS) * k
            var out = body * volS

            noiseLast = noiseLast * 0.6 + noise() * 0.4
            out += intake.process(noiseLast) * onS * loadS * (0.02 + 0.3 * r * r) * 2.5

            let s = max(0, (r - 0.55) / 0.45)
            out += scream.process(2 * phScr - 1) * onS * s * s * (0.05 + 0.09 * loadS)

            out += voicesSample(dt)
            out = tanh(out * masterS * 1.1)

            L[i] = out
            R?[i] = out
        }
        if voices.count > 0 { voices.removeAll { $0.t > $0.dur } }
    }

    private func voicesSample(_ dt: Float) -> Float {
        var sum: Float = 0
        for j in voices.indices {
            voices[j].t += dt
            let t = voices[j].t
            if t < 0 || t > voices[j].dur { continue }
            switch voices[j].kind {
            case .pop:
                let env: Float = t < 0.003 ? t / 0.003 : exp(-(t - 0.003) / 0.022)
                let nz = voices[j].filter.process(noise()) * env * 0.7 * voices[j].a * 3
                let f = 140 * pow(40.0 / 140.0, min(1, t / 0.08))
                voices[j].phase += f * dt
                let thump = sin(2 * .pi * voices[j].phase) * 0.7 * voices[j].a * exp(-t / 0.03)
                sum += nz + thump
            case .starter:
                let u = t / voices[j].dur
                let f = 90 + 60 * u
                voices[j].phase += f * dt; if voices[j].phase >= 1 { voices[j].phase -= 1 }
                voices[j].phase2 += (7 + 6 * u) * dt
                let env: Float = min(1, t / 0.05) * min(1, (voices[j].dur - t) / 0.06)
                let saw = 2 * voices[j].phase - 1
                let am = 1 + 0.35 * sin(2 * .pi * voices[j].phase2)
                sum += voices[j].filter.process(saw) * 0.32 * env * am
            case .beep:
                voices[j].phase += voices[j].b * dt; if voices[j].phase >= 1 { voices[j].phase -= 1 }
                let env: Float = min(1, t / 0.005) * min(1, (voices[j].dur - t) / 0.02)
                sum += (voices[j].phase < 0.5 ? 0.06 : -0.06) * env
            case .thud:
                let p = voices[j].b
                let f = 110 * p * pow(45.0 / 110.0, min(1, t / 0.12))
                voices[j].phase += f * dt
                sum += sin(2 * .pi * voices[j].phase) * 0.5 * voices[j].a * exp(-t / 0.04)
                sum += voices[j].filter.process(noise()) * 0.25 * voices[j].a * exp(-t / 0.015)
            case .horn:
                if !hornOn && voices[j].dur > t + 0.15 { voices[j].dur = t + 0.15 }
                let release = min(1, max(0, (voices[j].dur - t) / 0.15))
                voices[j].phase += 415 * dt; if voices[j].phase >= 1 { voices[j].phase -= 1 }
                voices[j].phase2 += 495 * dt; if voices[j].phase2 >= 1 { voices[j].phase2 -= 1 }
                let s1: Float = voices[j].phase < 0.5 ? 1 : -1
                let s2: Float = voices[j].phase2 < 0.5 ? 1 : -1
                let sq = s1 + s2
                sum += voices[j].filter.process(sq) * 0.16 * min(1, t / 0.03) * release
            }
        }
        return sum
    }
}
