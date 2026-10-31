import AppKit
import FileTreeCore

@MainActor
protocol ContentsControllerDelegate: AnyObject {
    func contents(_ controller: ContentsController, showInTree folder: FolderNode)
}

/// Everything directly inside the selected folder: subfolders with their scanned totals and
/// files as they are on disk now.
@MainActor
final class ContentsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    struct Row {
        let name: String
        let path: String
        let kind: EntryKind
        /// The scanned subfolder, for folders.
        let folder: FolderNode?
        /// nil when the size is not known.
        let allocatedSize: Int64?
        let logicalSize: Int64?
        let modificationTime: Int64
        let note: String?
        let linkCount: UInt32
        let isClone: Bool
        /// The folder where the scan counted this file's shared data, when that is another folder.
        let countedIn: FolderNode?
        let isMountPoint: Bool

        /// The part of `allocatedSize` included in the folder's total.
        var countedSize: Int64? { countedIn == nil ? allocatedSize : 0 }
    }

    weak var delegate: ContentsControllerDelegate?
    /// Folders skipped by the scan because they are counted at another path.
    var duplicateSources: [String: String] = [:]
    /// Tells where the scan counted data shared by several files.
    var sharedData: SharedDataRegistry?
    /// The listing of the current folder is on screen.
    private(set) var isLoaded = false

    let tableView = NSTableView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private var columnMenu: ColumnVisibilityMenu?
    private var columnFitter: ColumnFitter?
    private var rows: [Row] = []
    /// The rows the open context menu acts on, fixed when it opened.
    private var menuTargets: [Row] = []
    private var folder: FolderNode?
    private var generation = 0

    override func loadView() {
        let columns = [
            makeColumn(ColumnID.name, title: "Name", width: 210, minWidth: 120, alignment: .left, sortKey: SortKey.name, ascending: true),
            makeColumn(ColumnID.allocated, title: "On Disk", width: 80, sortKey: SortKey.allocated),
            makeColumn(ColumnID.percent, title: "% of Folder", width: 100, minWidth: 60, alignment: .left, sortKey: SortKey.percent),
            makeColumn(ColumnID.logical, title: "Size", width: 80, sortKey: SortKey.logical),
            makeColumn(ColumnID.kind, title: "Kind", width: 120, alignment: .left, sortKey: SortKey.kind, ascending: true),
            makeColumn(ColumnID.modified, title: "Date Modified", width: 140, alignment: .left, sortKey: SortKey.modified),
        ]
        for column in columns {
            column.isHidden = column.identifier == ColumnID.modified
            tableView.addTableColumn(column)
        }
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.sortDescriptors = [NSSortDescriptor(key: SortKey.allocated, ascending: false)]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        tableView.autosaveName = "FolderContents"
        tableView.autosaveTableColumns = true

        let container = NSView()
        let scrollView = makeScrollView(for: tableView)
        let fitter = ColumnFitter(table: tableView, in: scrollView, flexibleColumn: ColumnID.name)
        columnFitter = fitter
        columnMenu = ColumnVisibilityMenu(table: tableView) { fitter.fit() }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.isHidden = true
        container.addSubview(scrollView)
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        view = container
    }

    // MARK: Loading

    func show(_ folder: FolderNode?) {
        self.folder = folder
        generation += 1
        isLoaded = false
        rows = []
        tableView.reloadData()
        guard let folder else {
            finish(placeholder: "Select a folder to see what is inside.")
            return
        }
        switch folder.status {
        case .otherVolume:
            finish(placeholder: "Another volume is mounted here and is not part of this scan.\n"
                + "Choose “Scan This Volume” in its context menu to measure it.")
            return
        case .inCloud:
            finish(placeholder: "This folder is stored in iCloud and not downloaded to this Mac,"
                + " so it takes no space here.")
            return
        case .diskImageContents:
            finish(placeholder: "macOS shows the contents of its disk images (cryptexes) here. The images are counted"
                + " in the cryptex1 folder of this volume, so this folder is not measured again.\n"
                + "Choose “Scan Only This Folder” in its context menu to look inside.")
            return
        case .vanished:
            finish(placeholder: "This folder no longer exists.")
            return
        case .ok, .accessDenied, .privacyProtected, .unreadable, .notScanned:
            break
        }
        placeholder.isHidden = true
        let path = folder.path
        let generation = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let listing = DirectoryListing.items(in: path)
            Task { @MainActor [weak self] in
                self?.listingLoaded(listing.items, error: listing.error, path: path, generation: generation)
            }
        }
    }

    /// Shows the folder again with fresh sizes, e.g. after a rescan.
    func reload() {
        show(folder)
    }

    private func listingLoaded(_ items: [DirectoryItem], error: Int32, path: String, generation: Int) {
        guard generation == self.generation, let folder else { return }
        let subfolders = Dictionary(folder.children.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        rows = sorted(items.map { row(for: $0, in: path, subfolders: subfolders) })
        tableView.reloadData()
        if !rows.isEmpty {
            finish(placeholder: nil)
        } else if error == EPERM {
            finish(placeholder: "macOS keeps apps out of this folder.\n"
                + "Add FileTree to Full Disk Access in System Settings → Privacy & Security.")
        } else if error == EACCES {
            finish(placeholder: "Only the system or the folder’s owner may look inside this folder.")
        } else if error == EDEADLK {
            finish(placeholder: "This folder is stored in iCloud and not downloaded to this Mac.")
        } else if error != 0 {
            finish(placeholder: "This folder could not be read: \(Format.errorDescription(error)).")
        } else {
            finish(placeholder: "This folder is empty.")
        }
    }

    private func finish(placeholder text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
        isLoaded = true
    }

    private func row(for item: DirectoryItem, in path: String, subfolders: [String: FolderNode]) -> Row {
        let itemPath = FolderTree.join(path, item.name)
        guard item.kind == .directory else {
            let countedIn = folder.flatMap { folder in
                sharedData.flatMap { item.dataCountedElsewhere(than: folder, in: $0) }
            }
            let note = countedIn.map { "counted in “\($0.name)”" } ?? (item.isClone ? "clone" : nil)
            return Row(name: item.name, path: itemPath, kind: item.kind, folder: nil,
                       allocatedSize: item.allocatedSize, logicalSize: item.logicalSize,
                       modificationTime: item.modificationTime, note: note, linkCount: item.linkCount,
                       isClone: item.isClone, countedIn: countedIn, isMountPoint: false)
        }
        if let folder = subfolders[item.name] {
            let measured = folder.isMeasured
            return Row(name: item.name, path: itemPath, kind: .directory, folder: folder,
                       allocatedSize: measured ? folder.allocatedSize : nil, logicalSize: measured ? folder.logicalSize : nil,
                       modificationTime: measured ? folder.latestModification : item.modificationTime,
                       note: FolderPresentation.note(for: folder), linkCount: 1, isClone: false, countedIn: nil,
                       isMountPoint: folder.status == .otherVolume)
        }
        let note: String
        if let source = duplicateSources[itemPath] {
            note = "counted at \(source)"
        } else if item.isMountPoint {
            note = "other volume, not scanned"
        } else {
            note = "not measured, rescan to include"
        }
        return Row(name: item.name, path: itemPath, kind: .directory, folder: nil, allocatedSize: nil, logicalSize: nil,
                   modificationTime: item.modificationTime, note: note, linkCount: 1, isClone: false, countedIn: nil,
                   isMountPoint: item.isMountPoint)
    }

    private func sorted(_ rows: [Row]) -> [Row] {
        let descriptor = tableView.sortDescriptors.first
        let key = descriptor?.key ?? SortKey.allocated
        let ascending = descriptor?.ascending ?? false
        return rows.sorted { a, b in
            let order: ComparisonResult
            switch key {
            case SortKey.name: order = a.name.localizedStandardCompare(b.name)
            case SortKey.logical: order = Ordering.compare(a.logicalSize ?? -1, b.logicalSize ?? -1)
            case SortKey.kind: order = kind(of: a).localizedStandardCompare(kind(of: b))
            case SortKey.modified: order = Ordering.compare(a.modificationTime, b.modificationTime)
            default: order = Ordering.compare(a.allocatedSize ?? -1, b.allocatedSize ?? -1)
            }
            return Ordering.isOrdered(order, ascending: ascending, names: (a.name, b.name))
        }
    }

    // MARK: Presentation

    private func kind(of row: Row) -> String {
        switch row.kind {
        case .directory: return row.isMountPoint ? "Volume" : FileAppearance.kind(ofFolderNamed: row.name)
        case .file: return FileAppearance.kind(ofFileNamed: row.name)
        case .symlink: return "Symbolic link"
        case .other: return "Special file"
        }
    }

    private func icon(for row: Row) -> NSImage {
        switch row.kind {
        case .directory:
            if row.isMountPoint { return FileAppearance.volumeIcon }
            if let folder = row.folder { return FolderPresentation.icon(for: folder) }
            return FileAppearance.folderIcon(named: row.name, path: row.path)
        case .file: return FileAppearance.fileIcon(named: row.name)
        case .symlink: return FileAppearance.symlinkIcon
        case .other: return FileAppearance.documentIcon
        }
    }

    private func toolTip(for row: Row) -> String {
        if let folder = row.folder { return FolderPresentation.tooltip(for: folder) }
        var lines = [row.path]
        if row.linkCount > 1 {
            lines.append("This file has \(row.linkCount) hard links; the folder sizes count it only once.")
        }
        if row.isClone {
            lines.append("An APFS clone: it shares disk space with other copies of the same data, so deleting"
                + " it may free little or nothing. The folder sizes count shared data only once.")
        }
        if let countedIn = row.countedIn {
            lines.append("Its data is counted in “\(countedIn.path)”, so it is not part of this folder’s size.")
        }
        return lines.joined(separator: "\n")
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let column = tableColumn?.identifier, rows.indices.contains(index) else { return nil }
        let row = rows[index]
        switch column {
        case ColumnID.name:
            let cell = Cells.name(in: tableView)
            cell.configure(name: row.name, note: row.note, icon: icon(for: row), dimmed: row.allocatedSize == nil)
            cell.toolTip = toolTip(for: row)
            return cell
        case ColumnID.allocated:
            return Cells.text(in: tableView, column: column, value: row.allocatedSize.map(Format.bytes) ?? "—",
                              toolTip: row.allocatedSize.map { Format.exactBytes($0) + " on disk" })
        case ColumnID.percent:
            let total = folder?.allocatedSize ?? 0
            return Cells.percent(in: tableView, fraction: row.countedSize.map { total > 0 ? min(1, Double($0) / Double(total)) : 0 })
        case ColumnID.logical:
            return Cells.text(in: tableView, column: column, value: row.logicalSize.map(Format.bytes) ?? "—",
                              toolTip: row.logicalSize.map(Format.exactBytes))
        case ColumnID.kind:
            return Cells.text(in: tableView, column: column, value: kind(of: row), alignment: .left)
        case ColumnID.modified:
            return Cells.text(in: tableView, column: column, value: Format.date(row.modificationTime), alignment: .left)
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let selectedPaths = Set(selectedPaths)
        rows = sorted(rows)
        tableView.reloadData()
        let indexes = IndexSet(rows.indices.filter { selectedPaths.contains(rows[$0].path) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    // MARK: Actions

    var selectedPaths: [String] {
        tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].path : nil }
    }

    /// The rows a context menu acts on: the clicked row, or the selection if it was clicked.
    private var targetRows: [Row] {
        let clicked = tableView.clickedRow
        if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked), rows.indices.contains(clicked) {
            return [rows[clicked]]
        }
        return tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    @objc private func openClickedRow(_ sender: Any?) {
        let index = tableView.clickedRow
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        if let folder = row.folder, folder.status != .otherVolume {
            delegate?.contents(self, showInTree: folder)
        } else {
            FileActions.reveal([row.path])
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let targets = targetRows
        menuTargets = targets
        guard !targets.isEmpty else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if targets.count == 1, let folder = targets[0].folder, folder.status != .otherVolume {
            add("Show in Tree", #selector(showInTree(_:)))
            menu.addItem(.separator())
        }
        add("Show in Finder", #selector(showInFinder(_:)))
        add("Open", #selector(openItems(_:)))
        add(targets.count == 1 ? "Copy Path" : "Copy Paths", #selector(copyPaths(_:)))
    }

    @objc private func showInTree(_ sender: Any?) {
        // Selecting a folder that a rescan has replaced meanwhile does nothing.
        guard let folder = menuTargets.first?.folder else { return }
        delegate?.contents(self, showInTree: folder)
    }

    @objc private func showInFinder(_ sender: Any?) {
        FileActions.reveal(menuTargets.map(\.path))
    }

    @objc private func openItems(_ sender: Any?) {
        FileActions.open(menuTargets.map(\.path))
    }

    @objc private func copyPaths(_ sender: Any?) {
        FileActions.copy(menuTargets.map(\.path))
    }
}
