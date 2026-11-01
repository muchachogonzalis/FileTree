import AppKit
import FileTreeCore

extension NSToolbarItem.Identifier {
    static let chooseFolder = Self("chooseFolder")
    static let scanDisk = Self("scanDisk")
    static let rescan = Self("rescan")
    static let stopScan = Self("stopScan")
    static let showInFinder = Self("showInFinder")
}

/// The main window: start screen, scan progress or results, with the volume bar on top and
/// the status bar below.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
    NSToolbarItemValidation {
    let results = ResultsViewController()
    private let start = StartViewController()
    private let progressView = ScanProgressViewController()
    private let volumeBar = VolumeBar()
    private let volumeSeparator = NSBox()
    private let statusBar = StatusBar()
    private let contentContainer = NSView()
    private var currentContent: NSViewController?

    private var scanner: FolderScanner?
    private var scanStart = Date()
    /// Rescans one folder of the current result.
    private var folderScanner: FolderScanner?
    private(set) var result: ScanResult?
    private var progressTimer: Timer?

    var isScanning: Bool { scanner != nil }
    var isBusy: Bool { scanner != nil || folderScanner != nil }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "FileTree"
        window.minSize = NSSize(width: 780, height: 480)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        buildToolbar(for: window)
        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("MainWindow")
        connectControllers()
        setContent(start)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func buildContent(in window: NSWindow) {
        let root = DropTargetView()
        root.onDrop = { [weak self] url in self?.scan(url) }
        volumeSeparator.boxType = .separator
        let statusSeparator = NSBox()
        statusSeparator.boxType = .separator
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [volumeBar, volumeSeparator, contentContainer, statusSeparator, statusBar] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        contentContainer.setContentHuggingPriority(.init(1), for: .vertical)
        contentContainer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        showVolume(of: nil)
    }

    private func buildToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    private func connectControllers() {
        start.onScan = { [weak self] url in self?.scan(url) }
        start.onChooseFolder = { [weak self] in self?.chooseFolder(nil) }
        progressView.onStop = { [weak self] in self?.stopScan(nil) }
        statusBar.onStop = { [weak self] in self?.stopScan(nil) }
        results.onRescan = { [weak self] folder in self?.rescanFolder(folder) }
        results.onScanSeparately = { [weak self] folder in self?.scan(URL(fileURLWithPath: folder.path)) }
        results.onSelectionChange = { [weak self] folder in self?.window?.subtitle = folder?.path ?? "" }
    }

    private func setContent(_ controller: NSViewController) {
        guard currentContent !== controller else { return }
        currentContent?.view.removeFromSuperview()
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        currentContent = controller
    }

    private func showVolume(of path: String?) {
        volumeBar.show(path: path)
        volumeSeparator.isHidden = volumeBar.isHidden
    }

    // MARK: Scanning

    /// Scans a folder or disk, replacing the current results.
    func scan(_ url: URL) {
        cancelScans()
        let path = FileSystem.canonicalPath(url.path)
        let name = VolumeInfo.displayName(for: path)
        let scanner = FolderScanner(path: path, rootName: name)
        self.scanner = scanner
        scanStart = Date()
        result = nil
        results.show(nil)
        results.isBusy = true
        window?.title = name
        window?.subtitle = path
        showVolume(of: path)
        progressView.start(name: name)
        setContent(progressView)
        statusBar.showSummary("", problems: 0)
        startProgressTimer()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = scanner.run()
            Task { @MainActor [weak self] in
                self?.scanFinished(result, scanner: scanner)
            }
        }
    }

    private func scanFinished(_ result: ScanResult, scanner: FolderScanner) {
        guard self.scanner === scanner else { return }
        self.scanner = nil
        results.isBusy = false
        progressView.finish()
        self.result = result
        setContent(results)
        results.show(result)
        showVolume(of: result.rootPath)
        updateStatus()
        window?.makeFirstResponder(results.tree.outlineView)
    }

    /// Scans one folder of the current results again, e.g. after deleting files in the Finder.
    func rescanFolder(_ folder: FolderNode) {
        guard let result, !isBusy else { return }
        // A context menu may still hold a folder that an earlier rescan replaced.
        guard folder.isInside(result.root) else { return }
        guard !folder.isRoot else {
            scan(URL(fileURLWithPath: result.rootPath))
            return
        }
        let released = result.sharedData.release(inside: folder)
        let scanner = FolderScanner(path: folder.path, rootName: folder.name, boundary: result.boundary,
                                    sharedData: result.sharedData)
        folderScanner = scanner
        results.isBusy = true
        statusBar.showActivity("Rescanning “\(folder.name)”…")
        startProgressTimer()
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = scanner.run()
            Task { @MainActor [weak self] in
                self?.folderRescanFinished(fresh, replacing: folder, released: released, scanner: scanner)
            }
        }
    }

    private func folderRescanFinished(_ fresh: ScanResult, replacing folder: FolderNode,
                                      released: SharedDataRegistry.ReleasedClaims, scanner: FolderScanner) {
        guard folderScanner === scanner, let result else { return }
        folderScanner = nil
        results.isBusy = false
        statusBar.hideActivity()
        let applied = results.finishRescan(of: folder, with: fresh, released: released, sharedData: result.sharedData)
        volumeBar.refresh()
        updateStatus(notice: applied ? nil : "Rescan of “\(folder.name)” stopped, earlier results kept")
    }

    private func cancelScans() {
        scanner?.cancel()
        scanner = nil
        folderScanner?.cancel()
        folderScanner = nil
        results.isBusy = false
        statusBar.hideActivity()
    }

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
    }

    private func updateProgress() {
        if let scanner {
            progressView.update(scanner.progress, elapsed: Date().timeIntervalSince(scanStart))
        }
        if let folderScanner {
            let progress = folderScanner.progress
            statusBar.showActivity("Rescanning… \(Format.count(progress.filesFound)) files, \(Format.bytes(progress.allocatedSize))")
        }
        if !isBusy {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func updateStatus(notice: String? = nil) {
        guard let result else {
            statusBar.showSummary("", problems: 0)
            return
        }
        let root = result.root
        var text = "\(Format.bytes(root.allocatedSize)) on disk in \(Format.count(root.fileCount)) files"
            + " and \(Format.count(root.folderCount)) folders"
        if result.wasCancelled {
            text = "Scan stopped after \(Format.duration(result.duration)), the results are incomplete · " + text
        } else {
            text += " · scanned in \(Format.duration(result.duration))"
        }
        if let notice {
            text = notice + " · " + text
        }
        let privacyProblems = root.problemCount > 0
            ? FolderTree.countFolders(in: root) { $0.status == .privacyProtected } : 0
        statusBar.showSummary(text, problems: root.problemCount, privacyProblems: privacyProblems)
    }

    // MARK: Actions

    // The commands of the menu bar and the toolbar. They have no target and reach this controller through the
    // responder chain, so no view or view controller of the window may have an action of the same name.

    @objc func chooseFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to scan."
        if let path = result?.rootPath {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.scan(url)
            }
        }
    }

    @objc func scanVolume(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        scan(url)
    }

    @objc func scanHomeFolder(_ sender: Any?) {
        scan(FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func rescan(_ sender: Any?) {
        guard let result else { return }
        scan(URL(fileURLWithPath: result.rootPath))
    }

    @objc func rescanSelectedFolder(_ sender: Any?) {
        guard let folder = results.selectedFolder else { return }
        rescanFolder(folder)
    }

    @objc func stopScan(_ sender: Any?) {
        scanner?.cancel()
        folderScanner?.cancel()
    }

    @objc func showInFinder(_ sender: Any?) {
        FileActions.reveal(results.focusedPaths)
    }

    @objc func openSelection(_ sender: Any?) {
        FileActions.open(results.focusedPaths)
    }

    @objc func copy(_ sender: Any?) {
        FileActions.copy(results.focusedPaths)
    }

    @objc func showContentsTab(_ sender: Any?) {
        results.details.selectTab(0)
    }

    @objc func showFileTypesTab(_ sender: Any?) {
        results.details.selectTab(1)
    }

    @objc func openFullDiskAccessSettings(_ sender: Any?) {
        FileActions.openFullDiskAccessSettings()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isEnabled(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isEnabled(item.action)
    }

    private func isEnabled(_ action: Selector?) -> Bool {
        let showingResults = currentContent === results && result != nil
        switch action {
        case #selector(rescan(_:)):
            return result != nil && !isBusy
        case #selector(rescanSelectedFolder(_:)):
            guard showingResults, !isBusy, let folder = results.selectedFolder else { return false }
            return folder.status != .otherVolume && folder.status != .diskImageContents
        case #selector(stopScan(_:)):
            return isBusy
        case #selector(showInFinder(_:)), #selector(openSelection(_:)), #selector(copy(_:)):
            return showingResults && !results.focusedPaths.isEmpty
        case #selector(showContentsTab(_:)), #selector(showFileTypesTab(_:)):
            return showingResults
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        cancelScans()
    }

    // MARK: NSToolbarDelegate

    /// The toolbar, left to right.
    static let toolbarItemIdentifiers: [NSToolbarItem.Identifier] =
        [.chooseFolder, .scanDisk, .rescan, .stopScan, .flexibleSpace, .showInFinder]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarItemIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        Self.makeToolbarItem(identifier)
    }

    /// The buttons have no target: like the menu commands, they go up the responder chain to this controller.
    static func makeToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .chooseFolder:
            return button(identifier, label: "Choose Folder", symbol: "folder.badge.plus",
                          action: #selector(MainWindowController.chooseFolder(_:)), toolTip: "Choose a folder to scan")
        case .scanDisk:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Scan Disk"
            item.paletteLabel = "Scan Disk"
            item.toolTip = "Scan a disk or your home folder"
            item.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Scan Disk")
            item.menu = VolumesMenu.shared.makeMenu()
            return item
        case .rescan:
            // With the top folder selected, everything is scanned again.
            return button(identifier, label: "Rescan Selected Folder", symbol: "arrow.clockwise",
                          action: #selector(MainWindowController.rescanSelectedFolder(_:)),
                          toolTip: "Scan the selected folder again")
        case .stopScan:
            return button(identifier, label: "Stop", symbol: "stop.circle",
                          action: #selector(MainWindowController.stopScan(_:)), toolTip: "Stop scanning")
        case .showInFinder:
            return button(identifier, label: "Show in Finder", symbol: "arrow.up.forward.app",
                          action: #selector(MainWindowController.showInFinder(_:)),
                          toolTip: "Show the selected item in the Finder")
        default:
            return nil
        }
    }

    private static func button(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector,
                               toolTip: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.isBordered = true
        return item
    }
}
