import UIKit

final class PreviewViewController: UIViewController {
    private let store: Store<PreviewFeature.State, PreviewFeature.Action, AppDependencies>
    private var observation: StoreObservation?
    private var streamObservation: StoreObservation?

    private let imageView = UIImageView()
    private let statusPill = StatusPillView()

    private var decodeState = PreviewDecodeState()

    init(dependencies: AppDependencies) {
        store = Store(
            initialState: PreviewFeature.State(),
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
        streamObservation = store.observe(\.streamGeneration) { [weak self] generation in
            guard generation > 0 else { return }
            self?.decodeState.beginNewStream()
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

    func reconnect() {
        store.send(.reconnectNow)
    }

    func reconnectIfNeeded() {
        store.send(.reconnectIfNeeded)
    }

    private func configureViews() {
        imageView.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false

        statusPill.isHidden = true
        statusPill.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)
        view.addSubview(statusPill)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusPill.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            statusPill.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -10),
            statusPill.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])
    }

    private func render(_ state: PreviewFeature.State) {
        switch state.phase {
        case .idle:
            statusPill.isHidden = true
        case .connecting:
            statusPill.configure(caption: "Connecting", dotColor: .systemOrange, backgroundStyle: .material)
            statusPill.isHidden = false
        case .streaming(let frame):
            statusPill.configure(caption: "Live", dotColor: .systemGreen, backgroundStyle: .material)
            statusPill.isHidden = false
            enqueueDecode(frame)
        case .stopped:
            statusPill.isHidden = true
        case .failed:
            statusPill.configure(caption: "Preview offline", dotColor: .systemRed, backgroundStyle: .material)
            statusPill.isHidden = false
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
