import UIKit

/// The `(id, etag)` a cell is currently showing -- the *same* representation boundary the
/// loader, thumb cache, and prefetch handles key on, not `id` alone. Comparing the whole
/// pair is what lets a recycled cell (different `id`) or a re-represented clip (same `id`,
/// new `etag`) drop a stale in-flight result instead of painting the wrong clip's frame.
nonisolated struct ClipThumbnailIdentity: Hashable, Sendable {
    let id: Int
    let etag: String

    init(_ clip: Clip) {
        id = clip.id
        etag = clip.etag
    }

    init(id: Int, etag: String) {
        self.id = id
        self.etag = etag
    }
}

/// Cell-scoped guard that answers "is a just-finished thumbnail load still the one this cell
/// wants to paint?" It discriminates on the whole `ClipThumbnailIdentity`, mirroring the
/// extracted, unit-tested shape of `PreviewDecodeState` but keyed on `(id, etag)` rather
/// than a bare generation counter. The apply decision runs on the MainActor *after* the
/// load's `await`, by which point a reused or re-represented cell may show a different clip;
/// this drops that superseded result.
nonisolated struct ThumbnailDisplayState {
    private(set) var identity: ClipThumbnailIdentity?

    /// Point the cell at a clip. Returns `true` when this is a *new* identity (the caller
    /// must cancel any in-flight load, reset to the placeholder, and start a fresh load) and
    /// `false` when it is the identity already shown (the caller keeps what it has).
    mutating func show(_ newIdentity: ClipThumbnailIdentity) -> Bool {
        guard identity != newIdentity else { return false }
        identity = newIdentity
        return true
    }

    mutating func clear() {
        identity = nil
    }

    /// May a result generated for `resultIdentity` be painted now? Only if the cell still
    /// shows that exact `(id, etag)`.
    func accepts(_ resultIdentity: ClipThumbnailIdentity) -> Bool {
        identity == resultIdentity
    }
}

/// A finished-clip row: a leading first-frame thumbnail plus the segment filename and
/// time/duration metadata. Modeled on `LiveClipCell` (programmatic, unavailable
/// `init?(coder:)`). Thumbnail resolution is view-driven through an injected
/// `ThumbnailLoader`; the cell owns exactly one in-flight `loadTask` and a monotonic load
/// token so reconfigure churn (a full `reloadData()` or an in-place visible-row refresh)
/// never stacks a second load or lets a stale completion null a fresh handle.
final class ClipThumbnailCell: UITableViewCell {
    private let thumbnailView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    private var displayState = ThumbnailDisplayState()
    private var loadTask: Task<Void, Never>?
    /// Bumped immediately before every `loadTask` assignment *and* in `cancelLoad()`, so the
    /// token always names the single currently-live load attempt. A completion may only null
    /// the handle when its captured token is still current.
    private var loadToken = 0
    /// Whether a real thumbnail (not the placeholder) is currently painted for the shown
    /// identity. Distinguishes the same-identity no-op (keep the painted frame) from the
    /// same-identity retry (a prior load finished `nil` or was cancelled -- nothing painted).
    private var hasThumbnail = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipThumbnailCell is programmatic.")
    }

    func configure(clip: Clip, loader: ThumbnailLoader, preservedThumbnail: UIImage? = nil) {
        titleLabel.text = String(format: "seg_%05d.ts", clip.id)
        let subtitle = Formatters.clipListLine(clip)
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        accessibilityLabel = [titleLabel.text, subtitle.isEmpty ? nil : subtitle]
            .compactMap { $0 }
            .joined(separator: ", ")

        if displayState.show(ClipThumbnailIdentity(clip)) {
            // (b) different identity: a reused cell or a same-id/new-etag update. Cancel the
            // in-flight load, blank to the placeholder, and start exactly one fresh load.
            cancelLoad()
            resetToPlaceholder()
            if let preservedThumbnail {
                thumbnailView.image = preservedThumbnail
                hasThumbnail = true
            } else {
                startLoad(clip: clip, loader: loader)
            }
        } else if loadTask == nil, hasThumbnail == false {
            // (a) same identity, nothing in flight and nothing painted: a prior load finished
            // `nil` or was cancelled by `cancelLoad()`. Retry once, cheaply (cache-first,
            // single-flighted). A same identity with a live load or a painted frame is a no-op.
            if let preservedThumbnail {
                thumbnailView.image = preservedThumbnail
                hasThumbnail = true
            } else {
                startLoad(clip: clip, loader: loader)
            }
        }
    }

    /// Quiet an in-flight load without disturbing the shown image or identity, so the
    /// controller can relieve the link when Home goes offscreen (or a row scrolls off) while
    /// keeping an already-painted thumbnail. Advancing the token first ensures the cancelled
    /// load's stale completion can no longer null the handle of a same-identity retry.
    func cancelLoad() {
        loadToken += 1
        loadTask?.cancel()
        loadTask = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoad()
        displayState.clear()
        resetToPlaceholder()
    }

    var currentThumbnailImage: UIImage? {
        thumbnailView.image
    }

    var displayedImageForTesting: UIImage? {
        currentThumbnailImage
    }

    var isLoadingForTesting: Bool {
        loadTask != nil
    }

    var subtitleTextForTesting: String? {
        subtitleLabel.text
    }

    private func startLoad(clip: Clip, loader: ThumbnailLoader) {
        loadToken += 1
        let token = loadToken
        let identity = ClipThumbnailIdentity(clip)
        loadTask = Task { [weak self] in
            let result = await loader.thumbnail(clip)
            guard let self else { return }
            applyLoadResult(result, identity: identity, token: token)
        }
    }

    private func applyLoadResult(_ result: ThumbnailImage?, identity: ClipThumbnailIdentity, token: Int) {
        // Paint only if the cell still shows the identity this result was generated for.
        if displayState.accepts(identity), let image = result?.image {
            thumbnailView.image = image
            hasThumbnail = true
        }
        // Clear the handle only if this load still owns it -- a stale completion (a cancelled
        // load resuming after a newer load was installed) must not null the live task's handle.
        if token == loadToken {
            loadTask = nil
        }
    }

    private func resetToPlaceholder() {
        hasThumbnail = false
        thumbnailView.image = nil
    }

    private func configureViews() {
        selectionStyle = .default

        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 6
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.backgroundColor = .secondarySystemFill
        thumbnailView.isAccessibilityElement = false
        thumbnailView.setContentHuggingPriority(.required, for: .horizontal)
        thumbnailView.setContentCompressionResistancePriority(.required, for: .horizontal)
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle

        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.lineBreakMode = .byWordWrapping

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.alignment = .fill
        labels.spacing = 2

        let stack = UIStackView(arrangedSubviews: [thumbnailView, labels])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: 80),
            thumbnailView.heightAnchor.constraint(equalToConstant: 45),

            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }
}
