import Darwin

/// Whether a folder's contents were measured.
public enum FolderStatus: Sendable, Equatable {
    case ok
    /// The file permissions keep others out (typically folders only the system may read).
    case accessDenied
    /// macOS privacy protection keeps apps out until they get Full Disk Access.
    case privacyProtected
    /// Listing failed or stopped early with this errno; the size may be incomplete.
    case unreadable(errno: Int32)
    /// Stored in iCloud and not downloaded: takes no space on this Mac. Not opened, so that
    /// scanning does not download it.
    case inCloud
    /// Another file system is mounted here. It is not part of this scan.
    case otherVolume
    /// Shows the contents of disk images stored elsewhere in the scanned folder (the cryptexes
    /// of macOS). Not opened: the image files are counted where they are stored.
    case diskImageContents
    /// The scan was stopped before it reached this folder.
    case notScanned
    /// The folder disappeared before it could be read.
    case vanished

    init(errno code: Int32) {
        switch code {
        case EACCES: self = .accessDenied
        case EPERM: self = .privacyProtected
        // What the kernel answers when listing a folder would mean downloading it from iCloud.
        case EDEADLK: self = .inCloud
        case ENOENT, ENOTDIR: self = .vanished
        default: self = .unreadable(errno: code)
        }
    }

    /// The folder exists, but its contents could not be (completely) measured.
    public var isProblem: Bool {
        switch self {
        case .accessDenied, .privacyProtected, .unreadable: return true
        case .ok, .inCloud, .otherVolume, .diskImageContents, .notScanned, .vanished: return false
        }
    }
}

/// A folder in the scanned tree. Only folders are kept in memory; files are summed into
/// their folder, which keeps a whole-disk scan to a few hundred megabytes.
///
/// During a scan each node is written by the one worker thread that lists it, and read by
/// others only after the scan has finished. After that the tree belongs to the main thread.
public final class FolderNode: @unchecked Sendable {
    public let name: String
    public internal(set) weak var parent: FolderNode?
    public internal(set) var children: [FolderNode] = []
    public internal(set) var status: FolderStatus = .ok
    /// Absolute path of the folder; set only on the root of a tree.
    var rootPath: String?

    // Files directly inside this folder.
    var ownFileCount = 0
    var ownLogicalSize: Int64 = 0
    var ownAllocatedSize: Int64 = 0
    /// Newest modification time of this folder itself and of its own files.
    var ownLatestModification: Int64 = 0

    // Totals for the folder and everything below it.
    public internal(set) var logicalSize: Int64 = 0
    public internal(set) var allocatedSize: Int64 = 0
    public internal(set) var fileCount = 0
    public internal(set) var folderCount = 0
    public internal(set) var latestModification: Int64 = 0
    /// Folders in this subtree, this one included, whose contents could not be measured.
    public internal(set) var problemCount = 0

    init(name: String, parent: FolderNode?) {
        self.name = name
        self.parent = parent
    }

    public var isRoot: Bool { parent == nil }

    public var path: String {
        var names: [String] = []
        var node = self
        while true {
            if let rootPath = node.rootPath {
                return names.reversed().reduce(rootPath, FolderTree.join)
            }
            names.append(node.name)
            guard let parent = node.parent else {
                return "/" + names.reversed().joined(separator: "/")
            }
            node = parent
        }
    }

    /// True if this folder is `folder` or lies somewhere below it.
    public func isInside(_ folder: FolderNode) -> Bool {
        var node: FolderNode? = self
        while let current = node {
            if current === folder { return true }
            node = current.parent
        }
        return false
    }

    /// True if the totals of this folder are real measurements (possibly incomplete).
    public var isMeasured: Bool {
        switch status {
        case .ok, .accessDenied, .privacyProtected, .unreadable, .inCloud: return true
        case .otherVolume, .diskImageContents, .notScanned, .vanished: return false
        }
    }

    /// Recomputes the totals from this folder's own files and its children's totals.
    func recalculateTotals() {
        var logical = ownLogicalSize
        var allocated = ownAllocatedSize
        var files = ownFileCount
        var folders = 0
        var latest = ownLatestModification
        var problems = status.isProblem ? 1 : 0
        for child in children {
            logical = logical.addingSaturated(child.logicalSize)
            allocated = allocated.addingSaturated(child.allocatedSize)
            files += child.fileCount
            problems += child.problemCount
            if child.status != .otherVolume {
                folders += 1 + child.folderCount
                latest = max(latest, child.latestModification)
            }
        }
        logicalSize = logical
        allocatedSize = allocated
        fileCount = files
        folderCount = folders
        latestModification = latest
        problemCount = problems
    }
}

extension Int64 {
    /// Sizes are added without trapping: sparse files may claim absurd logical sizes
    /// (APFS allows 2^55 bytes per file), and a few hundred of them would overflow.
    func addingSaturated(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}
