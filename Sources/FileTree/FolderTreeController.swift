import AppKit
import FileTreeCore

@MainActor
protocol FolderTreeControllerDelegate: AnyObject {
    func folderTree(_ controller: FolderTreeController, didSelect folder: FolderNode?)
    func folderTree(_ controller: FolderTreeController, rescan folder: FolderNode)
    func folderTree(_ controller: FolderTreeController, scanSeparately folder: FolderNode)
}

/// The tree of scanned folders, biggest first.
@MainActor
final class FolderTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSMenuItemValidation {
    weak var delegate: FolderTreeControllerDelegate?
    /// While a scan runs, rescanning is not offered.
    var isBusy = false

    let outlineView = NSOutlineView()
    private(set) var root: FolderNode?
    private var sortedChildren: [ObjectIdentifier: [FolderNode]] = [:]
    private var columnMenu: ColumnVisibilityMenu?
    private var columnFitter: ColumnFitter?

    override func loadView() {
        configureOutline()
        let scrollView = makeScrollView(for: outlineView)
        let fitter = ColumnFitter(table: outlineView, in: scrollView, flexibleColumn: ColumnID.name)
        columnFitter = fitter
        columnMenu = ColumnVisibilityMenu(table: outlineView) { fitter.fit() }
        view = scrollView
    }

    private func configureOutline() {
        let columns = [
            makeColumn(ColumnID.name, title: "Name", width: 230, minWidth: 120, alignment: .left, sortKey: SortKey.name, ascending: true),
            makeColumn(ColumnID.allocated, title: "On Disk", width: 80, sortKey: SortKey.allocated),
            makeColumn(ColumnID.percent, title: "% of Parent", width: 110, minWidth: 60, alignment: .left, sortKey: SortKey.percent),
            makeColumn(ColumnID.logical, title: "Size", width: 80, sortKey: SortKey.logical),
            makeColumn(ColumnID.files, title: "Files", width: 70, sortKey: SortKey.files),
            makeColumn(ColumnID.folders, title: "Folders", width: 70, sortKey: SortKey.folders),
            makeColumn(ColumnID.modified, title: "Last Modified", width: 150, alignment: .left, sortKey: SortKey.modified),
        ]
        for column in columns {
            column.isHidden = column.identifier == ColumnID.folders || column.identifier == ColumnID.modified
            outlineView.addTableColumn(column)
        }
        outlineView.outlineTableColumn = columns[0]
        outlineView.autoresizesOutlineColumn = false
        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsColumnReordering = true
        outlineView.indentationPerLevel = 14
        outlineView.sortDescriptors = [NSSortDescriptor(key: SortKey.allocated, ascending: false)]
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(toggleClickedFolder(_:))
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.autosaveName = "FolderTree"
        outlineView.autosaveTableColumns = true
    }

    // MARK: Showing and updating the tree

    func show(_ root: FolderNode?) {
        _ = view
        self.root = root
        sortedChildren.removeAll()
        outlineView.reloadData()
        guard let root else { return }
        outlineView.expandItem(root)
        select(root)
    }

    var selectedFolder: FolderNode? {
        outlineView.item(atRow: outlineView.selectedRow) as? FolderNode
    }

    /// Selects a folder, expanding the folders above it, and scrolls to it.
    func select(_ folder: FolderNode) {
        var ancestors: [FolderNode] = []
        var node = folder.parent
        while let current = node {
            ancestors.append(current)
            node = current.parent
        }
        for ancestor in ancestors.reversed() {
            outlineView.expandItem(ancestor)
        }
        let row = outlineView.row(forItem: folder)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    /// Call after `FolderTree.replace(old, with: new)`.
    func didReplace(_ old: FolderNode, with new: FolderNode, wasExpanded: Bool) {
        let selected = selectedFolder
        sortedChildren.removeAll()
        outlineView.reloadData()
        if wasExpanded {
            outlineView.expandItem(new)
        }
        if let selected, selected.isInside(old) {
            select(new)
        } else if let selected {
            select(selected)
        }
        delegate?.folderTree(self, didSelect: selectedFolder)
    }

    /// Call after `FolderTree.remove(folder)`.
    func didRemove(_ folder: FolderNode, from parent: FolderNode) {
        let selected = selectedFolder
        sortedChildren.removeAll()
        outlineView.reloadData()
        if let selected, selected.isInside(folder) || selected === parent {
            select(parent)
        } else if let selected {
            select(selected)
        }
        delegate?.folderTree(self, didSelect: selectedFolder)
    }

    func isExpanded(_ folder: FolderNode) -> Bool {
        outlineView.isItemExpanded(folder)
    }

    private func children(of folder: FolderNode) -> [FolderNode] {
        let key = ObjectIdentifier(folder)
        if let sorted = sortedChildren[key] { return sorted }
        let sorted = Ordering.sortFolders(folder.children, by: outlineView.sortDescriptors.first)
        sortedChildren[key] = sorted
        return sorted
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard root != nil else { return 0 }
        guard let folder = item as? FolderNode else { return 1 }
        return children(of: folder).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let folder = item as? FolderNode else { return root as Any }
        return children(of: folder)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FolderNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let selected = selectedFolder
        sortedChildren.removeAll()
        outlineView.reloadData()
        if let selected {
            select(selected)
        }
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let folder = item as? FolderNode, let column = tableColumn?.identifier else { return nil }
        let measured = folder.isMeasured
        switch column {
        case ColumnID.name:
            let cell = Cells.name(in: outlineView)
            cell.configure(name: folder.name, note: FolderPresentation.note(for: folder),
                           icon: FolderPresentation.icon(for: folder), dimmed: !measured)
            cell.toolTip = FolderPresentation.tooltip(for: folder)
            return cell
        case ColumnID.allocated:
            return Cells.text(in: outlineView, column: column, value: measured ? Format.bytes(folder.allocatedSize) : "—",
                              toolTip: measured ? Format.exactBytes(folder.allocatedSize) + " on disk" : nil)
        case ColumnID.percent:
            return Cells.percent(in: outlineView, fraction: measured ? shareOfParent(folder) : nil)
        case ColumnID.logical:
            return Cells.text(in: outlineView, column: column, value: measured ? Format.bytes(folder.logicalSize) : "—",
                              toolTip: measured ? Format.exactBytes(folder.logicalSize) : nil)
        case ColumnID.files:
            return Cells.text(in: outlineView, column: column, value: measured ? Format.count(folder.fileCount) : "—")
        case ColumnID.folders:
            return Cells.text(in: outlineView, column: column, value: measured ? Format.count(folder.folderCount) : "—")
        case ColumnID.modified:
            return Cells.text(in: outlineView, column: column, value: Format.date(folder.latestModification), alignment: .left)
        default:
            return nil
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        delegate?.folderTree(self, didSelect: selectedFolder)
    }

    private func shareOfParent(_ folder: FolderNode) -> Double {
        guard let parent = folder.parent else { return 1 }
        return parent.allocatedSize > 0 ? Double(folder.allocatedSize) / Double(parent.allocatedSize) : 0
    }

    @objc private func toggleClickedFolder(_ sender: Any?) {
        guard let folder = outlineView.item(atRow: outlineView.clickedRow) as? FolderNode else { return }
        if outlineView.isItemExpanded(folder) {
            outlineView.collapseItem(folder)
        } else {
            outlineView.expandItem(folder)
        }
    }

    // MARK: Context menu

    private var clickedFolder: FolderNode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        return outlineView.item(atRow: row) as? FolderNode
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let folder = clickedFolder else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = folder
            menu.addItem(item)
        }
        if folder.status == .otherVolume {
            add("Scan This Volume", #selector(scanSeparately(_:)))
            menu.addItem(.separator())
        }
        add("Show in Finder", #selector(showInFinder(_:)))
        add("Open", #selector(openFolder(_:)))
        add("Copy Path", #selector(copyPath(_:)))
        guard folder.status != .otherVolume else { return }
        menu.addItem(.separator())
        // A rescan would leave it unopened again.
        if folder.status != .diskImageContents {
            add("Rescan This Folder", #selector(rescan(_:)))
        }
        if folder.parent != nil {
            add("Scan Only This Folder", #selector(scanSeparately(_:)))
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(rescan(_:)), #selector(scanSeparately(_:)): return !isBusy
        default: return true
        }
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FolderNode else { return }
        FileActions.reveal([folder.path])
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FolderNode else { return }
        FileActions.open([folder.path])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FolderNode else { return }
        FileActions.copy([folder.path])
    }

    @objc private func rescan(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FolderNode else { return }
        delegate?.folderTree(self, rescan: folder)
    }

    @objc private func scanSeparately(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? FolderNode else { return }
        delegate?.folderTree(self, scanSeparately: folder)
    }
}
