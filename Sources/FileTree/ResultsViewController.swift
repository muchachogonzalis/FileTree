import AppKit
import FileTreeCore

/// Scan results: the folder tree on the left, the selected folder on the right.
@MainActor
final class ResultsViewController: NSSplitViewController, FolderTreeControllerDelegate, ContentsControllerDelegate {
    let tree = FolderTreeController()
    let details = DetailsViewController()

    var onRescan: ((FolderNode) -> Void)?
    var onScanSeparately: ((FolderNode) -> Void)?
    var onSelectionChange: ((FolderNode?) -> Void)?
    var isBusy = false {
        didSet { tree.isBusy = isBusy }
    }

    private var hasPositionedDivider = false
    /// Whether an earlier run saved the divider position. Read before `autosaveName` is set: the
    /// split view can save its first layout before the divider is placed, which then looked like a
    /// saved position and left the tree at its minimum width.
    private var hasSavedDividerPosition = false

    override func viewDidLoad() {
        super.viewDidLoad()
        hasSavedDividerPosition = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames ResultsSplit") != nil
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let treeItem = NSSplitViewItem(viewController: tree)
        treeItem.minimumThickness = 320
        treeItem.canCollapse = false
        let detailsItem = NSSplitViewItem(viewController: details)
        detailsItem.minimumThickness = 340
        addSplitViewItem(treeItem)
        addSplitViewItem(detailsItem)
        // After the items: the split view restores the saved position when the name is set, and
        // with no panes yet there is nothing to restore it to.
        splitView.autosaveName = "ResultsSplit"
        tree.delegate = self
        details.contents.delegate = self
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Place the divider at the first layout in the window. At viewDidAppear the view can still have
        // its size from before it was added, which put the divider at the tree's minimum width.
        guard !hasPositionedDivider, view.window != nil else { return }
        hasPositionedDivider = true
        if !hasSavedDividerPosition {
            splitView.setPosition((view.bounds.width * 0.52).rounded(), ofDividerAt: 0)
        }
    }

    func show(_ result: ScanResult?) {
        _ = view
        details.setScan(result)
        tree.show(result?.root)
        if result == nil {
            details.show(nil)
        }
    }

    var selectedFolder: FolderNode? { tree.selectedFolder }

    /// Paths selected in whichever list has the keyboard focus.
    var focusedPaths: [String] {
        let responder = view.window?.firstResponder
        if responder === details.contents.tableView {
            return details.contents.selectedPaths
        }
        if responder === details.fileTypes.tableView {
            return details.fileTypes.selectedPaths
        }
        return tree.selectedFolder.map { [$0.path] } ?? []
    }

    /// Puts the result of rescanning `old` into the tree. Returns false when the rescan was
    /// stopped and the earlier results stay.
    func finishRescan(of old: FolderNode, with fresh: ScanResult, released: SharedDataRegistry.ReleasedClaims,
                      sharedData: SharedDataRegistry) -> Bool {
        let wasExpanded = tree.isExpanded(old)
        let parent = old.parent
        let outcome = FolderTree.finishRescan(of: old, with: fresh, released: released, sharedData: sharedData)
        // Forget before the selection moves, so nothing is analyzed under a stale folder.
        switch outcome {
        case .kept:
            return false
        case .replaced(let new):
            details.treeChanged()
            tree.didReplace(old, with: new, wasExpanded: wasExpanded)
        case .removed:
            details.treeChanged()
            if let parent {
                tree.didRemove(old, from: parent)
            }
        }
        return true
    }

    func folderTree(_ controller: FolderTreeController, didSelect folder: FolderNode?) {
        details.show(folder)
        onSelectionChange?(folder)
    }

    func folderTree(_ controller: FolderTreeController, rescan folder: FolderNode) {
        onRescan?(folder)
    }

    func folderTree(_ controller: FolderTreeController, scanSeparately folder: FolderNode) {
        onScanSeparately?(folder)
    }

    func contents(_ controller: ContentsController, showInTree folder: FolderNode) {
        tree.select(folder)
        view.window?.makeFirstResponder(tree.outlineView)
    }
}

/// The selected folder: a summary on top and two tabs, Contents and File Types.
@MainActor
final class DetailsViewController: NSViewController, NSTabViewDelegate {
    let contents = ContentsController()
    let fileTypes = FileTypesController()

    private let tabView = NSTabView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private var folder: FolderNode?

    override func loadView() {
        addChild(contents)
        addChild(fileTypes)
        let contentsItem = NSTabViewItem(viewController: contents)
        contentsItem.label = "Contents"
        contentsItem.identifier = "contents"
        let typesItem = NSTabViewItem(viewController: fileTypes)
        typesItem.label = "File Types"
        typesItem.identifier = "types"
        tabView.addTabViewItem(contentsItem)
        tabView.addTabViewItem(typesItem)
        tabView.delegate = self

        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [titleLabel, summaryLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let header = NSStackView(views: [iconView, labels])
        header.orientation = .horizontal
        header.spacing = 10

        let container = NSView()
        for view in [header, tabView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            tabView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        view = container
        show(nil)
    }

    func setScan(_ result: ScanResult?) {
        contents.duplicateSources = result?.boundary.duplicateSources ?? [:]
        contents.sharedData = result?.sharedData
        fileTypes.boundary = result?.boundary
        fileTypes.sharedData = result?.sharedData
        fileTypes.forgetReports()
    }

    func show(_ folder: FolderNode?) {
        self.folder = folder
        updateHeader()
        contents.show(folder)
        fileTypes.setFolder(folder)
    }

    /// The tree was changed by a rescan: sizes and files may differ now.
    func treeChanged() {
        fileTypes.forgetReports()
    }

    func selectTab(_ index: Int) {
        tabView.selectTabViewItem(at: index)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        fileTypes.isActive = tabViewItem?.identifier as? String == "types"
    }

    private func updateHeader() {
        guard let folder else {
            iconView.image = nil
            titleLabel.stringValue = ""
            summaryLabel.stringValue = ""
            return
        }
        iconView.image = FolderPresentation.icon(for: folder)
        titleLabel.stringValue = folder.isRoot ? folder.name : folder.path
        titleLabel.toolTip = folder.path
        guard folder.isMeasured else {
            summaryLabel.stringValue = FolderPresentation.note(for: folder).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
            return
        }
        var parts = [
            "\(Format.bytes(folder.allocatedSize)) on disk",
            "\(Format.bytes(folder.logicalSize)) in size",
            "\(Format.count(folder.fileCount)) files",
            "\(Format.count(folder.folderCount)) folders",
        ]
        if folder.problemCount > 0 {
            parts.append("\(Format.count(folder.problemCount)) unreadable")
        }
        summaryLabel.stringValue = parts.joined(separator: " · ")
        summaryLabel.toolTip = FolderPresentation.tooltip(for: folder)
    }
}
