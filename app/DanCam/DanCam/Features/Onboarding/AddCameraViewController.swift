import AVFoundation
import UIKit

nonisolated private final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.danneu.dancam.onboarding.capture")

    func start() {
        queue.async { [self] in
            if session.isRunning == false { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

final class AddCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let onboarding: OnboardingClient
    private let capture = CaptureSessionBox()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var joinTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private let statusLabel = UILabel()
    private var handledCode = false
    private var captureConfigured = false
    private var viewVisible = false

    init(onboarding: OnboardingClient) {
        self.onboarding = onboarding
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("AddCameraViewController is programmatic.") }

    deinit {
        joinTask?.cancel()
        permissionTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Add Camera"
        view.backgroundColor = .black
        statusLabel.text = "Scan the setup QR from your DanCam recovery record."
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        permissionTask = Task { [weak self] in
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                self?.statusLabel.text = "Camera access is required to scan the setup QR."
                return
            }
            guard Task.isCancelled == false else { return }
            self?.configureCapture()
            if self?.viewVisible == true { self?.capture.start() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewVisible = true
        if captureConfigured { capture.start() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        viewVisible = false
        capture.stop()
    }

    private func configureCapture() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              capture.session.canAddInput(input) else {
            statusLabel.text = "Camera access is required to scan the setup QR."
            return
        }
        capture.session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard capture.session.canAddOutput(output) else { return }
        capture.session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: capture.session)
        layer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        captureConfigured = true
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard handledCode == false,
              let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              let record = try? WiFiQRCode.parse(value) else { return }
        handledCode = true
        capture.stop()
        statusLabel.text = "Joining \(record.ssid)..."
        joinTask = Task { [weak self, onboarding] in
            do {
                try await onboarding.join(record)
                try Task.checkCancellation()
                self?.navigationController?.popViewController(animated: true)
            } catch is CancellationError {
                return
            } catch {
                self?.handledCode = false
                self?.statusLabel.text = "Could not save this camera. Check the QR and try again."
                if self?.viewVisible == true { self?.capture.start() }
            }
        }
    }
}
