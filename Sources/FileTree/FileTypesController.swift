import AppKit
import FileTreeCore

/// Space used by each file type (extension) inside the selected folder, all levels deep.
/// Computed when the tab is visible, since it walks the folder on disk again.
@MainActor
final class FileTypesController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// The rules of the scan, so the analysis counts the same files.
    var boundary: ScanBoundary?
    /// Where the scan counted shared data, so the analysis attributes it the same way.
    var sharedData: SharedDataRegistry?
    /// True while the tab is on screen.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { refresh() } else { cancelAnalysis() }
        }
    }
    /// The report for the current folder is on screen.
    private(set) var isLoaded = false

    let tableView = NSTableView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let footer = NSTextField(labelWithString: "")
    private var columnMenu: ColumnVisibilityMenu?
    private var columnFitter: ColumnFitter?
    private var types: [FileTypeStats] = []
    private var folder: FolderNode?
    private var displayedPath: String?
    private var analyzer: FileTypeAnalyzer?
    private var progressTimer: Timer?
    private var reports: [String: FileTypeReport] = [:]

    override func loadView() {
        let columns = [
            makeColumn(ColumnID.name, title: "Type", width: 100, minWidth: 70, alignment: .left, sortKey: SortKey.name, ascending: true),
            makeColumn(ColumnID.kind, title: "Kind", width: 140, alignment: .left, sortKey: SortKey.kind, ascending: true),
            makeColumn(ColumnID.files, title: "Files", width: 64, sortKey: SortKey.files),
            makeColumn(ColumnID.allocated, title: "On Disk", width: 80, sortKey: SortKey.allocated),
            makeColumn(ColumnID.logical, title: "Size", width: 80, sortKey: SortKey.logical),
            makeColumn(ColumnID.average, title: "Average", width: 76, sortKey: SortKey.average),
            makeColumn(ColumnID.largestSize, title: "Largest", width: 76, sortKey: SortKey.largestSize),
            makeColumn(ColumnID.largestPath, title: "Largest File", width: 300, alignment: .left, sortKey: SortKey.largestPath, ascending: true),
        ]
        for column in columns {
            column.isHidden = column.identifier == ColumnID.kind || column.identifier == ColumnID.logical
            tableView.addTableColumn(column)
        }
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = true
        tableView.sortDescriptors = [NSSortDescriptor(key: SortKey.allocated, ascending: false)]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(showClickedLargestFile(_:))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        tableView.autosaveName = "FileTypes"
        tableView.autosaveTableColumns = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let container = NSView()
        let scrollView = makeScrollView(for: tableView)
        let fitter = ColumnFitter(table: tableView, in: scrollView, flexibleColumn: ColumnID.largestPath)
        columnFitter = fitter
        columnMenu = ColumnVisibilityMenu(table: tableView) { fitter.fit() }
        let status = NSStackView(views: [spinner, placeholder])
        status.orientation = .horizontal
        status.spacing = 8
        for view in [scrollView, status, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            status.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        view = container
    }

    // MARK: Analysis

    func setFolder(_ folder: FolderNode?) {
        self.folder = folder
        if isActive {
            refresh()
        }
    }

    /// Forgets earlier reports because the tree changed. The next `setFolder`, or showing the
    /// tab, analyzes again.
    func forgetReports() {
        cancelAnalysis()
        reports.removeAll()
        displayedPath = nil
        isLoaded = false
    }

    private func refresh() {
        guard let folder, let boundary else {
            cancelAnalysis()
            display(nil, message: "Select a folder to see which kinds of files take up its space.")
            return
        }
        let path = folder.path
        if path == displayedPath && (isLoaded || analyzer != nil) { return }
        cancelAnalysis()
        displayedPath = path
        guard folder.isMeasured else {
            display(nil, message: folder.status == .diskImageContents
                ? "These are the contents of macOS disk images, counted in the cryptex1 folder of this volume."
                : "This folder was not scanned.")
            return
        }
        if let report = reports[path] {
            display(report, message: nil)
            return
        }

        types = []
        tableView.reloadData()
        isLoaded = false
        footer.stringValue = ""
        placeholder.stringValue = "Looking at the files…"
        placeholder.isHidden = false
        spinner.startAnimation(nil)
        // Decided here, on the main thread that owns the tree, not by the analysis threads.
        let analyzer = FileTypeAnalyzer(path: path, boundary: boundary,
                                        sharedData: sharedData?.snapshot(countedInside: folder))
        self.analyzer = analyzer
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.placeholder.stringValue = "Looking at the files… \(Format.count(analyzer.progress))"
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let report = analyzer.run()
            Task { @MainActor [weak self] in
                self?.analysisFinished(report, path: path, analyzer: analyzer)
            }
        }
    }

    private func analysisFinished(_ report: FileTypeReport, path: String, analyzer: FileTypeAnalyzer) {
        guard self.analyzer === analyzer else { return }
        self.analyzer = nil
        stopProgress()
        guard !report.wasCancelled else { return }
        reports[path] = report
        display(report, message: nil)
    }

    private func cancelAnalysis() {
        analyzer?.cancel()
        analyzer = nil
        stopProgress()
        if !isLoaded {
            displayedPath = nil
        }
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        spinner.stopAnimation(nil)
    }

    private func display(_ report: FileTypeReport?, message: String?) {
        types = sorted(report?.types ?? [])
        tableView.reloadData()
        isLoaded = true
        if let report {
            footer.stringValue = "\(Format.count(report.fileCount)) files of \(Format.count(report.types.count)) types"
        } else {
            footer.stringValue = ""
        }
        let text = message ?? (types.isEmpty ? "There are no files in this folder." : nil)
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
    }

    private func sorted(_ types: [FileTypeStats]) -> [FileTypeStats] {
        let descriptor = tableView.sortDescriptors.first
        let key = descriptor?.key ?? SortKey.allocated
        let ascending = descriptor?.ascending ?? false
        return types.sorted { a, b in
            let order: ComparisonResult
            switch key {
            case SortKey.name: order = a.fileExtension.localizedStandardCompare(b.fileExtension)
            case SortKey.kind: order = kind(of: a).localizedStandardCompare(kind(of: b))
            case SortKey.files: order = Ordering.compare(a.fileCount, b.fileCount)
            case SortKey.logical: order = Ordering.compare(a.logicalSize, b.logicalSize)
            case SortKey.average: order = Ordering.compare(a.averageAllocatedSize, b.averageAllocatedSize)
            case SortKey.largestSize: order = Ordering.compare(a.largestFileSize, b.largestFileSize)
            case SortKey.largestPath: order = a.largestFilePath.localizedStandardCompare(b.largestFilePath)
            default: order = Ordering.compare(a.allocatedSize, b.allocatedSize)
            }
            return Ordering.isOrdered(order, ascending: ascending, names: (a.fileExtension, b.fileExtension))
        }
    }

    private func title(of type: FileTypeStats) -> String {
        type.fileExtension.isEmpty ? "(none)" : "." + type.fileExtension
    }

    private func kind(of type: FileTypeStats) -> String {
        type.fileExtension.isEmpty ? "No extension" : FileAppearance.kind(ofExtension: type.fileExtension)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        types.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier, types.indices.contains(row) else { return nil }
        let type = types[row]
        switch column {
        case ColumnID.name:
            let cell = Cells.name(in: tableView)
            cell.configure(name: title(of: type), note: nil, icon: FileAppearance.iconForExtension(type.fileExtension), dimmed: false)
            cell.toolTip = kind(of: type)
            return cell
        case ColumnID.kind:
            return Cells.text(in: tableView, column: column, value: kind(of: type), alignment: .left)
        case ColumnID.files:
            return Cells.text(in: tableView, column: column, value: Format.count(type.fileCount))
        case ColumnID.allocated:
            return Cells.text(in: tableView, column: column, value: Format.bytes(type.allocatedSize),
                              toolTip: Format.exactBytes(type.allocatedSize) + " on disk")
        case ColumnID.logical:
            return Cells.text(in: tableView, column: column, value: Format.bytes(type.logicalSize),
                              toolTip: Format.exactBytes(type.logicalSize))
        case ColumnID.average:
            return Cells.text(in: tableView, column: column, value: Format.bytes(type.averageAllocatedSize))
        case ColumnID.largestSize:
            return Cells.text(in: tableView, column: column, value: Format.bytes(max(0, type.largestFileSize)))
        case ColumnID.largestPath:
            return Cells.text(in: tableView, column: column, value: type.largestFilePath, toolTip: type.largestFilePath,
                              alignment: .left, truncation: .byTruncatingMiddle)
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        types = sorted(types)
        tableView.reloadData()
    }

    // MARK: Actions

    private var targetType: FileTypeStats? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        return types.indices.contains(row) ? types[row] : nil
    }

    @objc private func showClickedLargestFile(_ sender: Any?) {
        guard tableView.clickedRow >= 0, let type = targetType, !type.largestFilePath.isEmpty else { return }
        FileActions.reveal([type.largestFilePath])
    }

    var selectedPaths: [String] {
        guard types.indices.contains(tableView.selectedRow) else { return [] }
        let path = types[tableView.selectedRow].largestFilePath
        return path.isEmpty ? [] : [path]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let type = targetType, !type.largestFilePath.isEmpty else { return }
        for (title, action) in [("Show Largest File in Finder", #selector(showLargestFile(_:))),
                                ("Copy Path of Largest File", #selector(copyLargestFilePath(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = type.largestFilePath
            menu.addItem(item)
        }
    }

    @objc private func showLargestFile(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { FileActions.reveal([$0]) }
    }

    @objc private func copyLargestFilePath(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { FileActions.copy([$0]) }
    }
}
