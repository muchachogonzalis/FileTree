import AppKit
import FileTreeCore

/// Shown before the first scan: the disks to scan, the home folder, or any other folder.
@MainActor
final class StartViewController: NSViewController {
    var onScan: ((URL) -> Void)?
    var onChooseFolder: (() -> Void)?

    private let volumesStack = NSStackView()

    override func loadView() {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "FileTree")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Find out which folders take up the space on your disks.")
        subtitle.textColor = .secondaryLabelColor

        volumesStack.orientation = .vertical
        volumesStack.alignment = .leading
        volumesStack.spacing = 6

        let homeButton = NSButton(title: "Scan Home Folder", target: self, action: #selector(scanHomeFolder))
        let chooseButton = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        let buttons = NSStackView(views: [homeButton, chooseButton])
        buttons.spacing = 12

        let hint = NSTextField(wrappingLabelWithString: "macOS keeps some folders private. To measure everything,"
            + " add FileTree to Full Disk Access in System Settings → Privacy & Security. You can also drop a folder"
            + " on this window.")
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let settingsButton = NSButton(title: "Open Full Disk Access Settings…", target: self, action: #selector(openSettings))
        settingsButton.controlSize = .small

        let stack = NSStackView(views: [icon, title, subtitle, volumesStack, buttons, hint, settingsButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(26, after: subtitle)
        stack.setCustomSpacing(18, after: volumesStack)
        stack.setCustomSpacing(28, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 88),
            icon.heightAnchor.constraint(equalToConstant: 88),
            hint.widthAnchor.constraint(equalToConstant: 470),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: 20),
        ])
        self.view = view
        Volumes.shared.observe { [weak self] in self?.reloadVolumes() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadVolumes()
        Volumes.shared.refresh()
    }

    private func reloadVolumes() {
        for row in volumesStack.arrangedSubviews {
            row.removeFromSuperview()
        }
        for volume in Volumes.shared.mounted {
            let row = VolumeRow(volume: volume) { [weak self] in self?.onScan?(volume.url) }
            volumesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 470).isActive = true
        }
    }

    @objc private func scanHomeFolder() {
        onScan?(FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc private func chooseFolder() {
        onChooseFolder?()
    }

    @objc private func openSettings() {
        FileActions.openFullDiskAccessSettings()
    }
}

/// One disk on the start screen.
@MainActor
private final class VolumeRow: NSView {
    private let onScan: () -> Void

    init(volume: VolumeInfo, onScan: @escaping () -> Void) {
        self.onScan = onScan
        super.init(frame: .zero)
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: volume.url.path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: volume.name)
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: "\(Format.bytes(volume.availableCapacity)) free of \(Format.bytes(volume.totalCapacity))")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let meter = NSLevelIndicator()
        meter.levelIndicatorStyle = .continuousCapacity
        meter.maxValue = 100
        meter.warningValue = 85
        meter.criticalValue = 95
        meter.doubleValue = volume.usedFraction * 100
        let button = NSButton(title: "Scan", target: nil, action: nil)
        button.target = self
        button.action = #selector(scan)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [icon, labels, spacer, meter, button])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            meter.widthAnchor.constraint(equalToConstant: 120),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func scan() {
        onScan()
    }
}

/// Shown while a folder is being scanned.
@MainActor
final class ScanProgressViewController: NSViewController {
    var onStop: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")

    override func loadView() {
        spinner.style = .spinning
        spinner.controlSize = .regular
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        countsLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.alignment = .center
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let stopButton = NSButton(title: "Stop", target: self, action: #selector(stop))
        stopButton.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [spinner, titleLabel, countsLabel, pathLabel, elapsedLabel, stopButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: elapsedLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
        ])
        self.view = view
    }

    func start(name: String) {
        _ = view
        titleLabel.stringValue = "Scanning “\(name)”…"
        countsLabel.stringValue = " "
        pathLabel.stringValue = " "
        elapsedLabel.stringValue = " "
        spinner.startAnimation(nil)
    }

    func update(_ progress: ScanProgress, elapsed: TimeInterval) {
        countsLabel.stringValue = "\(Format.count(progress.filesFound)) files in \(Format.count(progress.foldersScanned)) folders"
            + " · \(Format.bytes(progress.allocatedSize))"
        pathLabel.stringValue = progress.currentPath
        elapsedLabel.stringValue = Format.duration(elapsed)
    }

    func finish() {
        spinner.stopAnimation(nil)
    }

    @objc private func stop() {
        onStop?()
    }
}
