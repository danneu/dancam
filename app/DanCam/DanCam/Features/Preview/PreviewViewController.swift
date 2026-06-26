import UIKit

final class PreviewViewController: UIViewController {
    private let store: Store<PreviewFeature.State, PreviewFeature.Action, AppDependencies>
    private let recordingStore: Store<RecordingFeature.State, RecordingFeature.Action, AppDependencies>
    private var observation: StoreObservation?
    private var recordingObservation: StoreObservation?

    private let imageView = UIImageView()
    private let statusLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let recordButton = UIButton(type: .system)
    private let recDot = UIView()
    private let recLabel = UILabel()

    private var decodeState = PreviewDecodeState()
    private var recordingState = RecordingFeature.State.unknown

    init(dependencies: AppDependencies) {
        store = Store(
            initialState: .idle,
            dependencies: dependencies,
            reduce: PreviewFeature.reduce
        )
        recordingStore = Store(
            initialState: .unknown,
            dependencies: dependencies,
            reduce: RecordingFeature.reduce
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Live Preview"
        view.backgroundColor = .systemBackground
        configureViews()
        observation = store.observe { [weak self] state in
            self?.render(state)
        }
        recordingObservation = recordingStore.observe { [weak self] state in
            self?.renderRecording(state)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.send(.onAppear)
        recordingStore.send(.onAppear)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        store.send(.onDisappear)
    }

    private func configureViews() {
        imageView.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0

        startButton.setTitle("Start", for: .normal)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)

        stopButton.setTitle("Stop", for: .normal)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)

        recordButton.setTitle("Record", for: .normal)
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)

        recDot.backgroundColor = .systemRed
        recDot.layer.cornerRadius = 5
        recDot.translatesAutoresizingMaskIntoConstraints = false
        recDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        recDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        recLabel.text = "REC"
        recLabel.font = .preferredFont(forTextStyle: .caption1)
        recLabel.adjustsFontForContentSizeCategory = true

        let recIndicator = UIStackView(arrangedSubviews: [recDot, recLabel])
        recIndicator.axis = .horizontal
        recIndicator.alignment = .center
        recIndicator.spacing = 6

        let controls = UIStackView(arrangedSubviews: [startButton, stopButton])
        controls.axis = .horizontal
        controls.spacing = 16
        controls.distribution = .fillEqually

        let recordingControls = UIStackView(arrangedSubviews: [recordButton, recIndicator])
        recordingControls.axis = .horizontal
        recordingControls.alignment = .center
        recordingControls.spacing = 16
        recordingControls.distribution = .fillProportionally

        let stack = UIStackView(arrangedSubviews: [imageView, statusLabel, controls, recordingControls])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 0.75),
        ])
    }

    private func render(_ state: PreviewFeature.State) {
        switch state {
        case .idle:
            statusLabel.text = "Idle"
            startButton.isEnabled = true
            stopButton.isEnabled = false
        case .connecting:
            statusLabel.text = "Connecting..."
            startButton.isEnabled = false
            stopButton.isEnabled = true
            decodeState.beginNewStream()
        case .streaming(let frame):
            statusLabel.text = "Streaming"
            startButton.isEnabled = false
            stopButton.isEnabled = true
            enqueueDecode(frame)
        case .stopped:
            statusLabel.text = "Stopped"
            startButton.isEnabled = true
            stopButton.isEnabled = false
        case .failed(let message):
            statusLabel.text = message
            startButton.isEnabled = true
            stopButton.isEnabled = false
        }
    }

    private func renderRecording(_ state: RecordingFeature.State) {
        recordingState = state

        switch state {
        case .unknown:
            recordButton.setTitle("Record", for: .normal)
            recordButton.isEnabled = false
            recDot.isHidden = true
            recLabel.isHidden = true
        case .idle:
            recordButton.setTitle("Record", for: .normal)
            recordButton.isEnabled = true
            recDot.isHidden = true
            recLabel.isHidden = true
        case .starting:
            recordButton.setTitle("Starting", for: .normal)
            recordButton.isEnabled = false
            recDot.isHidden = false
            recLabel.isHidden = false
        case .recording:
            recordButton.setTitle("Stop Recording", for: .normal)
            recordButton.isEnabled = true
            recDot.isHidden = false
            recLabel.isHidden = false
        case .stopping:
            recordButton.setTitle("Stopping", for: .normal)
            recordButton.isEnabled = false
            recDot.isHidden = false
            recLabel.isHidden = false
        case .failed:
            recordButton.setTitle("Record", for: .normal)
            recordButton.isEnabled = true
            recDot.isHidden = true
            recLabel.isHidden = true
        }
    }

    private func enqueueDecode(_ frame: PreviewFrame) {
        decodeState.enqueue(frame)
        startNextDecodeIfNeeded()
    }

    private func startNextDecodeIfNeeded() {
        guard let decode = decodeState.startNextDecode() else { return }

        let generation = decode.generation
        let jpeg = decode.frame.jpeg
        let sequence = decode.frame.sequence

        Task.detached { [weak self] in
            let image = await UIImage(data: jpeg)?.byPreparingForDisplay()
            await MainActor.run {
                self?.finishDecode(generation: generation, sequence: sequence, image: image)
            }
        }
    }

    private func finishDecode(generation: Int, sequence: Int, image: UIImage?) {
        if decodeState.finishDecode(generation: generation, sequence: sequence) {
            imageView.image = image
        }

        startNextDecodeIfNeeded()
    }

    @objc private func startTapped() {
        store.send(.startTapped)
    }

    @objc private func stopTapped() {
        store.send(.stopTapped)
    }

    @objc private func recordTapped() {
        switch recordingState {
        case .recording:
            recordingStore.send(.stopTapped)
        case .unknown, .idle, .failed:
            recordingStore.send(.startTapped)
        case .starting, .stopping:
            break
        }
    }
}

nonisolated struct PreviewDecodeState {
    struct Decode {
        var generation: Int
        var frame: PreviewFrame
    }

    private(set) var generation = 0
    private(set) var latestRenderedSequence = -1
    private(set) var pendingDecode: Decode?
    private var isDecoding = false

    mutating func beginNewStream() {
        generation += 1
        latestRenderedSequence = -1
        pendingDecode = nil
    }

    mutating func enqueue(_ frame: PreviewFrame) {
        guard frame.sequence > latestRenderedSequence else { return }
        pendingDecode = Decode(generation: generation, frame: frame)
    }

    mutating func startNextDecode() -> Decode? {
        guard isDecoding == false, let decode = pendingDecode else { return nil }

        pendingDecode = nil
        isDecoding = true

        return decode
    }

    mutating func finishDecode(generation decodeGeneration: Int, sequence: Int) -> Bool {
        isDecoding = false

        guard decodeGeneration == generation, sequence > latestRenderedSequence else {
            return false
        }

        latestRenderedSequence = sequence
        return true
    }
}
