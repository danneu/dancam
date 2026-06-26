import UIKit

final class HomeViewController: UIViewController, UITableViewDataSource {
    private let dependencies: AppDependencies
    private let previewViewController: PreviewViewController
    private let recordingStore: Store<RecordingFeature.State, RecordingFeature.Action, AppDependencies>
    private let statusStore: Store<StatusFeature.State, StatusFeature.Action, AppDependencies>
    private let clipsStore: Store<ClipsFeature.State, ClipsFeature.Action, AppDependencies>

    private var recordingObservation: StoreObservation?
    private var statusObservation: StoreObservation?
    private var clipsObservation: StoreObservation?

    private let cameraLabel = UILabel()
    private let tempLabel = UILabel()
    private let storageLabel = UILabel()
    private let memLabel = UILabel()
    private let statusErrorLabel = UILabel()
    private let recordButton = UIButton(type: .system)
    private let recDot = UIView()
    private let recLabel = UILabel()
    private let recIndicator = UIStackView()
    private let recordingControls = UIStackView()
    private let clipsTableView = UITableView(frame: .zero, style: .plain)

    private var recordingState = RecordingFeature.State.unknown
    private var clips: [Clip] = []

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        previewViewController = PreviewViewController(dependencies: dependencies)
        recordingStore = Store(
            initialState: .unknown,
            dependencies: dependencies,
            reduce: RecordingFeature.reduce
        )
        statusStore = Store(
            initialState: .idle,
            dependencies: dependencies,
            reduce: StatusFeature.reduce
        )
        clipsStore = Store(
            initialState: .idle,
            dependencies: dependencies,
            reduce: ClipsFeature.reduce
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HomeViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "DanCam"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Debug",
            style: .plain,
            target: self,
            action: #selector(debugTapped)
        )

        addChild(previewViewController)
        configureViews()
        previewViewController.didMove(toParent: self)

        recordingObservation = recordingStore.observe { [weak self] state in
            self?.renderRecording(state)
        }
        statusObservation = statusStore.observe { [weak self] state in
            self?.renderStatus(state)
        }
        clipsObservation = clipsStore.observe { [weak self] state in
            self?.renderClips(state)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        recordingStore.send(.onAppear)
        statusStore.send(.onAppear)
        clipsStore.send(.onAppear)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        statusStore.send(.onDisappear)
        clipsStore.send(.onDisappear)
    }

    private func configureViews() {
        for label in [cameraLabel, tempLabel, storageLabel, memLabel, statusErrorLabel] {
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        statusErrorLabel.textColor = .systemRed

        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)

        recDot.backgroundColor = .systemRed
        recDot.layer.cornerRadius = 5
        recDot.translatesAutoresizingMaskIntoConstraints = false

        recLabel.text = "REC"
        recLabel.font = .preferredFont(forTextStyle: .caption1)
        recLabel.adjustsFontForContentSizeCategory = true

        recIndicator.addArrangedSubview(recDot)
        recIndicator.addArrangedSubview(recLabel)
        recIndicator.axis = .horizontal
        recIndicator.alignment = .center
        recIndicator.spacing = 6

        recordingControls.addArrangedSubview(recordButton)
        recordingControls.axis = .horizontal
        recordingControls.alignment = .center
        recordingControls.spacing = 16
        recordingControls.distribution = .fillProportionally

        clipsTableView.dataSource = self
        clipsTableView.register(UITableViewCell.self, forCellReuseIdentifier: "clip")
        clipsTableView.translatesAutoresizingMaskIntoConstraints = false

        let statusStack = UIStackView(arrangedSubviews: [
            cameraLabel,
            tempLabel,
            storageLabel,
            memLabel,
            statusErrorLabel,
        ])
        statusStack.axis = .vertical
        statusStack.spacing = 4

        let stack = UIStackView(arrangedSubviews: [
            statusStack,
            previewViewController.view,
            recordingControls,
            clipsTableView,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            recDot.widthAnchor.constraint(equalToConstant: 10),
            recDot.heightAnchor.constraint(equalToConstant: 10),

            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            previewViewController.view.heightAnchor.constraint(
                equalTo: previewViewController.view.widthAnchor,
                multiplier: 0.75
            ),
            clipsTableView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    private func renderStatus(_ state: StatusFeature.State) {
        statusErrorLabel.isHidden = true
        statusErrorLabel.text = nil

        switch state {
        case .idle:
            renderStatusFields(response: nil)
        case .loading:
            renderStatusFields(response: nil)
            cameraLabel.text = "Camera: loading"
        case .loaded(let response):
            renderStatusFields(response: response)
        case .failed(let message):
            renderStatusFields(response: nil)
            cameraLabel.text = "Camera: unavailable"
            statusErrorLabel.isHidden = false
            statusErrorLabel.text = message
        }
    }

    private func renderStatusFields(response: StatusResponse?) {
        cameraLabel.text = "Camera: \(response?.cameraState.rawValue ?? "--")"
        tempLabel.text = "SoC: \(formatTemp(response?.tempC.soc))"
        storageLabel.text = "Storage: \(formatStorage(response?.storage))"
        memLabel.text = "Memory: \(formatMemory(response?.mem))"
    }

    private func renderRecording(_ state: RecordingFeature.State) {
        let previous = recordingState
        recordingState = state

        if HomeCoordination.shouldRefreshClips(from: previous, to: state) {
            clipsStore.send(.refresh)
        }

        switch state {
        case .unknown:
            recordButton.setTitle("Start Recording", for: .normal)
            recordButton.isEnabled = false
            setRecordingIndicatorVisible(false)
        case .idle:
            recordButton.setTitle("Start Recording", for: .normal)
            recordButton.isEnabled = true
            setRecordingIndicatorVisible(false)
        case .starting:
            recordButton.setTitle("Starting", for: .normal)
            recordButton.isEnabled = false
            setRecordingIndicatorVisible(true)
        case .recording:
            recordButton.setTitle("Stop Recording", for: .normal)
            recordButton.isEnabled = true
            setRecordingIndicatorVisible(true)
        case .stopping:
            recordButton.setTitle("Stopping", for: .normal)
            recordButton.isEnabled = false
            setRecordingIndicatorVisible(true)
        case .failed:
            recordButton.setTitle("Start Recording", for: .normal)
            recordButton.isEnabled = true
            setRecordingIndicatorVisible(false)
        }
    }

    private func renderClips(_ state: ClipsFeature.State) {
        switch state {
        case .idle, .loading:
            clips = []
        case .loaded(let clips):
            self.clips = clips
        case .failed:
            clips = []
        }

        clipsTableView.reloadData()
    }

    private func setRecordingIndicatorVisible(_ isVisible: Bool) {
        let isArranged = recordingControls.arrangedSubviews.contains(recIndicator)

        if isVisible && isArranged == false {
            recordingControls.addArrangedSubview(recIndicator)
        } else if isVisible == false && isArranged {
            recordingControls.removeArrangedSubview(recIndicator)
            recIndicator.removeFromSuperview()
        }
    }

    private func formatTemp(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f C", value)
    }

    private func formatStorage(_ storage: Storage?) -> String {
        guard let storage else { return "--" }
        return "\(storage.used) / \(storage.total) bytes"
    }

    private func formatMemory(_ mem: Mem?) -> String {
        guard let mem else { return "--" }
        return "\(mem.available) / \(mem.total) bytes"
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

    @objc private func debugTapped() {
        navigationController?.pushViewController(
            HealthViewController(dependencies: dependencies),
            animated: true
        )
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        clips.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clip", for: indexPath)
        let clip = clips[indexPath.row]
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        let filename = String(format: "seg_%05d.ts", clip.id)
        cell.textLabel?.text = "\(filename) - \(clip.bytes) bytes"
        cell.selectionStyle = .none
        return cell
    }
}
