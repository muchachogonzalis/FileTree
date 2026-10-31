import AppKit
import FileTreeCore

enum ColumnID {
    static let name = NSUserInterfaceItemIdentifier("name")
    static let allocated = NSUserInterfaceItemIdentifier("allocated")
    static let percent = NSUserInterfaceItemIdentifier("percent")
    static let logical = NSUserInterfaceItemIdentifier("logical")
    static let files = NSUserInterfaceItemIdentifier("files")
    static let folders = NSUserInterfaceItemIdentifier("folders")
    static let modified = NSUserInterfaceItemIdentifier("modified")
    static let kind = NSUserInterfaceItemIdentifier("kind")
    static let average = NSUserInterfaceItemIdentifier("average")
    static let largestSize = NSUserInterfaceItemIdentifier("largestSize")
    static let largestPath = NSUserInterfaceItemIdentifier("largestPath")
}

enum SortKey {
    static let name = "name"
    static let allocated = "allocated"
    /// Same order as `allocated`; a key of its own so that only the clicked column shows the arrow.
    static let percent = "percent"
    static let logical = "logical"
    static let files = "files"
    static let folders = "folders"
    static let modified = "modified"
    static let kind = "kind"
    static let average = "average"
    static let largestSize = "largestSize"
    static let largestPath = "largestPath"
}

/// Orders values for a sort descriptor; ties are broken by name, A to Z.
enum Ordering {
    static func compare<Value: Comparable>(_ a: Value, _ b: Value) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    static func isOrdered(_ order: ComparisonResult, ascending: Bool, names: (String, String)) -> Bool {
        if order == .orderedSame {
            return names.0.localizedStandardCompare(names.1) == .orderedAscending
        }
        return ascending ? order == .orderedAscending : order == .orderedDescending
    }

    static func sortFolders(_ folders: [FolderNode], by descriptor: NSSortDescriptor?) -> [FolderNode] {
        let key = descriptor?.key ?? SortKey.allocated
        let ascending = descriptor?.ascending ?? false
        return folders.sorted { a, b in
            let order: ComparisonResult
            switch key {
            case SortKey.name: order = a.name.localizedStandardCompare(b.name)
            case SortKey.logical: order = compare(a.logicalSize, b.logicalSize)
            case SortKey.files: order = compare(a.fileCount, b.fileCount)
            case SortKey.folders: order = compare(a.folderCount, b.folderCount)
            case SortKey.modified: order = compare(a.latestModification, b.latestModification)
            default: order = compare(a.allocatedSize, b.allocatedSize)
            }
            return isOrdered(order, ascending: ascending, names: (a.name, b.name))
        }
    }
}

@MainActor
func makeColumn(_ identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat = 50,
                alignment: NSTextAlignment = .right, sortKey: String, ascending: Bool = false) -> NSTableColumn {
    let column = NSTableColumn(identifier: identifier)
    column.title = title
    column.width = width
    column.minWidth = minWidth
    column.headerCell.alignment = alignment
    column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: ascending)
    column.resizingMask = .userResizingMask
    return column
}

@MainActor
func makeScrollView(for table: NSTableView) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.documentView = table
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    return scrollView
}

/// Reusable table cells.
@MainActor
enum Cells {
    static func name(in table: NSTableView) -> NameCellView {
        if let cell = table.makeView(withIdentifier: ColumnID.name, owner: nil) as? NameCellView { return cell }
        let cell = NameCellView()
        cell.identifier = ColumnID.name
        return cell
    }

    static func text(in table: NSTableView, column: NSUserInterfaceItemIdentifier, value: String, toolTip: String? = nil,
                     alignment: NSTextAlignment = .right, truncation: NSLineBreakMode = .byTruncatingTail) -> NSTableCellView {
        let cell: NSTableCellView
        if let reused = table.makeView(withIdentifier: column, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = column
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.alignment = alignment
            field.lineBreakMode = truncation
            field.font = alignment == .right
                ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.systemFontSize)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = value
        cell.toolTip = toolTip
        return cell
    }

    static func percent(in table: NSTableView, fraction: Double?) -> PercentCellView {
        let cell = table.makeView(withIdentifier: ColumnID.percent, owner: nil) as? PercentCellView ?? {
            let cell = PercentCellView()
            cell.identifier = ColumnID.percent
            return cell
        }()
        cell.fraction = fraction
        return cell
    }
}

/// Icon, name and an optional dimmed remark ("no access", "other volume").
final class NameCellView: NSTableCellView {
    private var name = ""
    private var note: String?
    private var isDimmed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(image)
        addSubview(field)
        imageView = image
        textField = field
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    func configure(name: String, note: String?, icon: NSImage, dimmed: Bool) {
        self.name = name
        self.note = note
        isDimmed = dimmed
        imageView?.image = icon
        render()
    }

    private static let singleLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private func render() {
        let selected = backgroundStyle == .emphasized
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor
                : isDimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        if let note {
            text.append(NSAttributedString(string: "  " + note, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.tertiaryLabelColor,
            ]))
        }
        text.addAttribute(.paragraphStyle, value: Self.singleLine, range: NSRange(location: 0, length: text.length))
        textField?.attributedStringValue = text
    }
}

/// A bar showing a share of the parent folder, colored from green (small) to red (most of it).
final class PercentCellView: NSTableCellView {
    /// nil when the size is unknown.
    var fraction: Double? {
        didSet {
            if fraction != oldValue { needsDisplay = true }
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let fraction else { return }
        let selected = backgroundStyle == .emphasized
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor,
        ]
        let label = String(format: "%.1f%%", fraction * 100) as NSString
        let labelSize = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.maxX - labelSize.width - 4, y: (bounds.height - labelSize.height) / 2),
                   withAttributes: attributes)

        let track = NSRect(x: 4, y: (bounds.height - 9) / 2, width: max(0, bounds.width - 54), height: 9)
        guard track.width > 4 else { return }
        (selected ? NSColor.white.withAlphaComponent(0.25) : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        guard fraction > 0 else { return }
        var filled = track
        filled.size.width = max(3, track.width * min(1, fraction))
        barColor(for: fraction).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
    }

    private func barColor(for fraction: Double) -> NSColor {
        switch fraction {
        case 0.5...: return .systemRed
        case 0.25..<0.5: return .systemOrange
        case 0.1..<0.25: return .systemYellow
        default: return .systemGreen
        }
    }
}

/// Keeps one column as wide as the space the other columns leave, as the Finder does with Name.
///
/// The width follows the scroll view's size only, never which scroll bars are showing. Scroll
/// bars that take space ("Show scroll bars: Always", or a mouse attached) are left room for even
/// while hidden. Fitting the columns to the visible area instead made the scroll bars and the
/// columns resize each other in turns, until AppKit gave up on laying out the window and ended
/// the app.
@MainActor
final class ColumnFitter {
    private weak var table: NSTableView?
    private let flexibleColumn: NSUserInterfaceItemIdentifier
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    init(table: NSTableView, in scrollView: NSScrollView, flexibleColumn: NSUserInterfaceItemIdentifier) {
        self.table = table
        self.flexibleColumn = flexibleColumn
        table.columnAutoresizingStyle = .noColumnAutoresizing
        scrollView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit() }
        })
        // Attaching or removing a mouse switches the kind of scroll bars.
        observers.append(center.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            // Once the scroll view has switched its own scroll bars.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.fit() }
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func fit() {
        guard let table, let scrollView = table.enclosingScrollView,
              let flexible = table.tableColumn(withIdentifier: flexibleColumn), !flexible.isHidden
        else { return }
        let visible = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
        guard let first = visible.first, let last = visible.last else { return }
        let available = NSScrollView.contentSize(
            forFrameSize: scrollView.frame.size, horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self,
            borderType: scrollView.borderType, controlSize: .regular,
            scrollerStyle: scrollView.verticalScroller?.scrollerStyle ?? scrollView.scrollerStyle).width
        // The columns plus the margins the table style adds before the first and after the last one.
        let used = table.rect(ofColumn: last).maxX + table.rect(ofColumn: first).minX
        let width = max(flexible.minWidth, (flexible.width + available - used).rounded(.down))
        if abs(width - flexible.width) >= 1 {
            flexible.width = width
        }
    }
}

/// The table header's context menu: show or hide columns.
@MainActor
final class ColumnVisibilityMenu: NSObject, NSMenuDelegate {
    private weak var table: NSTableView?
    private let menu = NSMenu()
    private let onChange: () -> Void

    init(table: NSTableView, onChange: @escaping () -> Void) {
        self.table = table
        self.onChange = onChange
        super.init()
        menu.delegate = self
        table.headerView?.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in table?.tableColumns ?? [] where column.identifier != ColumnID.name {
            let item = NSMenuItem(title: column.title, action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column
            item.state = column.isHidden ? .off : .on
            menu.addItem(item)
        }
    }

    @objc private func toggle(_ item: NSMenuItem) {
        guard let column = item.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
        onChange()
    }
}

/// Name, capacity meter and free space of the volume being looked at.
@MainActor
final class VolumeBar: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let meter = NSLevelIndicator()
    private let detailLabel = NSTextField(labelWithString: "")
    private var path: String?

    init() {
        super.init(frame: .zero)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        meter.levelIndicatorStyle = .continuousCapacity
        meter.minValue = 0
        meter.maxValue = 100
        meter.warningValue = 85
        meter.criticalValue = 95
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [iconView, nameLabel, meter, detailLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            meter.widthAnchor.constraint(equalToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows the volume holding `path`, or hides the bar for nil.
    func show(path: String?) {
        self.path = path
        isHidden = path == nil
        refresh()
    }

    /// Reads the free space again, off the main thread.
    func refresh() {
        guard let path else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let volume = VolumeInfo.at(path: path)
            Task { @MainActor [weak self] in
                guard let self, self.path == path else { return }
                self.display(volume)
            }
        }
    }

    private func display(_ volume: VolumeInfo?) {
        guard let volume else {
            nameLabel.stringValue = ""
            detailLabel.stringValue = "The capacity of this volume is not known."
            return
        }
        iconView.image = NSWorkspace.shared.icon(forFile: volume.url.path)
        nameLabel.stringValue = volume.name
        meter.doubleValue = volume.usedFraction * 100
        var detail = "\(Format.bytes(volume.usedCapacity)) used of \(Format.bytes(volume.totalCapacity))"
            + " · \(Format.bytes(volume.availableCapacity)) free"
        if volume.availableForImportantUsage - volume.availableCapacity > 100_000_000 {
            detail += " (\(Format.bytes(volume.availableForImportantUsage)) counting purgeable space)"
        }
        detailLabel.stringValue = detail
        toolTip = "Purgeable space is space macOS frees by itself when needed: caches, local Time Machine snapshots."
    }
}

/// Totals of the scan, problems, and progress of a folder being rescanned.
@MainActor
final class StatusBar: NSView {
    var onStop: (() -> Void)?

    private let summaryLabel = NSTextField(labelWithString: "")
    private let problemButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let activityLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        problemButton.bezelStyle = .inline
        problemButton.image = FileAppearance.warningIcon
        problemButton.imagePosition = .imageLeading
        problemButton.target = self
        problemButton.action = #selector(openPrivacySettings)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        activityLabel.textColor = .secondaryLabelColor
        stopButton.controlSize = .small
        stopButton.bezelStyle = .push
        stopButton.target = self
        stopButton.action = #selector(stop)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [summaryLabel, spacer, problemButton, spinner, activityLabel, stopButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        hideActivity()
        showSummary("", problems: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// - Parameter privacyProblems: how many of the `problems` macOS privacy protection caused;
    ///   only those can be fixed, with Full Disk Access.
    func showSummary(_ text: String, problems: Int, privacyProblems: Int = 0) {
        summaryLabel.stringValue = text
        problemButton.isHidden = problems == 0
        problemButton.title = problems == 1 ? "1 folder could not be read" : "\(Format.count(problems)) folders could not be read"
        problemButton.isEnabled = privacyProblems > 0
        if privacyProblems > 0 {
            problemButton.toolTip = "The sizes shown may be too small. \(Format.count(privacyProblems)) of these folders are"
                + " protected by macOS: click to open the Full Disk Access settings and add FileTree there."
        } else {
            problemButton.toolTip = "The sizes shown may be too small. Only the system or their owners may read these"
                + " folders; Full Disk Access does not change that."
        }
    }

    func showActivity(_ text: String) {
        activityLabel.stringValue = text
        activityLabel.isHidden = false
        stopButton.isHidden = false
        spinner.startAnimation(nil)
    }

    func hideActivity() {
        activityLabel.isHidden = true
        stopButton.isHidden = true
        spinner.stopAnimation(nil)
    }

    @objc private func stop() {
        onStop?()
    }

    @objc private func openPrivacySettings() {
        FileActions.openFullDiskAccessSettings()
    }
}

/// Accepts a folder dropped from the Finder.
final class DropTargetView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        folderURL(in: sender) == nil ? [] : .generic
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = folderURL(in: sender) else { return false }
        onDrop?(url)
        return true
    }

    private func folderURL(in info: any NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let url = urls?.first else { return nil }
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue ? url : nil
    }
}
