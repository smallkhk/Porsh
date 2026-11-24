import SwiftUI
import AVFoundation

struct PairView: View {
    @ObservedObject var model: KeyModel
    @State private var host = UserDefaults.standard.string(forKey: "server") ?? Server.defaultHost
    @State private var code = ""
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            (Text("APEX ").font(.system(size: 15, weight: .bold)) + Text("9R").font(.system(size: 15, weight: .medium)).foregroundColor(.gray))
            Text("Pair your key").font(.system(size: 40, weight: .bold)).tracking(-1.5).padding(.top, 26)
            Text("Open the showroom on your iPad, then scan its QR code or type the 5-letter code. You only pair once.")
                .font(.system(size: 16)).foregroundColor(.gray).padding(.top, 10)

            Button { scanning = true } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
            }
            .padding(.top, 28)

            HStack(spacing: 10) {
                TextField("ABCDE", text: $code)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .padding(14).background(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.16), lineWidth: 1.5))
                    .onChange(of: code) { v in code = cleanCode(v) }
                Button("Connect") { model.pair(host: host, code: code) }
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 20).frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.16), lineWidth: 1.5))
                    .disabled(code.count < 4)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 6) {
                Text("SERVER").font(.system(size: 11, weight: .semibold)).foregroundColor(.gray)
                TextField(Server.defaultHost, text: $host)
                    .font(.system(size: 14, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            .padding(.top, 26)
            Spacer()
        }
        .padding(.horizontal, 22)
        .fullScreenCover(isPresented: $scanning) {
            ZStack(alignment: .bottom) {
                QRScanner { text in scanning = false; model.pair(scanned: text) }.ignoresSafeArea()
                RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: 250, height: 250).frame(maxHeight: .infinity)
                VStack(spacing: 16) {
                    Text("Point at the QR code on the showroom screen").font(.system(size: 15, weight: .medium))
                    Button("Cancel") { scanning = false }
                        .font(.system(size: 16, weight: .semibold)).padding(.horizontal, 28).padding(.vertical, 12)
                        .background(Capsule().fill(.ultraThinMaterial))
                }
                .padding(.bottom, 40)
            }
            .background(Color.black)
        }
    }
}

/// Native camera QR reader (AVFoundation).
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController(); c.onCode = onCode; return c
    }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var fired = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !fired, let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        fired = true
        Haptics.success()
        onCode?(text)
    }
}
