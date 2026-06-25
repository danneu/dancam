import UIKit

final class PreviewViewController: UIViewController {
    private let store: Store<PreviewFeature.State, PreviewFeature.Action, AppDependencies>
    private var observation: StoreObservation?

    private let imageView = UIImageView()
    private let statusLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)

    private var pendingFrame: PreviewFrame?
    private var isDecoding = false
    private var latestRenderedSequence = -1

    init(dependencies: AppDependencies) {
        store = Store(
            initialState: .idle,
            dependencies: dependencies,
            reduce: PreviewFeature.reduce
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.send(.onAppear)
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

        let controls = UIStackView(arrangedSubviews: [startButton, stopButton])
        controls.axis = .horizontal
        controls.spacing = 16
        controls.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [imageView, statusLabel, controls])
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

    private func enqueueDecode(_ frame: PreviewFrame) {
        guard frame.sequence > latestRenderedSequence else { return }

        pendingFrame = frame
        startNextDecodeIfNeeded()
    }

    private func startNextDecodeIfNeeded() {
        guard isDecoding == false, let frame = pendingFrame else { return }

        pendingFrame = nil
        isDecoding = true

        let jpeg = frame.jpeg
        let sequence = frame.sequence

        Task.detached { [weak self] in
            let image = await UIImage(data: jpeg)?.byPreparingForDisplay()
            await MainActor.run {
                self?.finishDecode(sequence: sequence, image: image)
            }
        }
    }

    private func finishDecode(sequence: Int, image: UIImage?) {
        isDecoding = false

        if sequence > latestRenderedSequence {
            latestRenderedSequence = sequence
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
}
