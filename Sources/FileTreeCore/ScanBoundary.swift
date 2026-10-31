import Foundation

/// Decides which folders belong to a scan, so that nothing is counted twice and other disks
/// are left alone.
///
/// On macOS the startup disk is two APFS volumes: the read-only system volume mounted at "/"
/// and the data volume mounted at /System/Volumes/Data. Firmlinks such as /Users or
/// /Applications show data-volume folders inside "/". Scanning "/" therefore reaches the same
/// folders twice: through the firmlink and inside /System/Volumes/Data. The copies inside
/// /System/Volumes/Data are skipped and counted at the firmlink instead.
///
/// Other volumes mounted inside the scanned folder are included when they live in the same
/// APFS container as the scanned folder (they share its free space: the VM swap volume,
/// Preboot, a Nix store), and skipped otherwise (external disks, disk images, network shares).
///
/// macOS 13 and later graft the contents of their cryptexes (signed disk images with parts of
/// macOS, mainly the shared cache of system libraries) into Preboot/Cryptexes. The image files
/// are stored elsewhere on Preboot, so a scan holding all of Preboot lists that folder without
/// opening it.
///
/// The mount table is read once, without asking the file systems themselves: a network share
/// whose server is gone can block such a question for minutes, and the scan with it.
public struct ScanBoundary: Sendable {
    public static let dataVolumeMountPoint = "/System/Volumes/Data"
    public static let prebootMountPoint = "/System/Volumes/Preboot"

    public struct Firmlink: Sendable, Equatable {
        public let source: String
        public let target: String
    }

    /// A folder in which macOS shows the contents of disk images stored inside `imagesFolder`.
    struct DiskImageViews: Sendable, Equatable {
        let viewsPath: String
        let imagesFolder: String
    }

    /// The cryptex images are kept in Preboot/<volume group UUID>/cryptex1. Nothing tells their
    /// grafted contents from ordinary files (same volume, paths and file IDs), so the folder is
    /// recognized by where it is.
    static let cryptexViews = DiskImageViews(viewsPath: prebootMountPoint + "/Cryptexes", imagesFolder: prebootMountPoint)

    public let rootPath: String
    /// Folders skipped because their contents are counted elsewhere in the same scan:
    /// skipped path → path where the same contents are counted.
    public let duplicateSources: [String: String]
    /// Folders left out on request.
    public let excludedPaths: Set<String>
    /// Folders that only show the contents of disk images counted elsewhere in this scan: listed,
    /// but not opened.
    public let diskImageViews: Set<String>
    /// The APFS container ("disk3") holding the scanned folder, if it is on a local disk.
    public let rootContainer: String?
    /// Mount point → device it is mounted from, e.g. "/System/Volumes/VM" → "/dev/disk3s6".
    let mountSources: [String: String]

    /// - Parameter rootPath: canonical absolute path of the scanned folder.
    public init(rootPath: String, excludedPaths: Set<String> = []) {
        // A firmlink listed for a folder that does not exist leaves its copy as the only one.
        let firmlinks = Self.readFirmlinks(at: "/usr/share/firmlinks").filter { Self.isDirectory($0.source) }
        self.init(rootPath: rootPath, excludedPaths: excludedPaths, firmlinks: firmlinks,
                  mountSources: Self.readMountTable())
    }

    init(rootPath: String, excludedPaths: Set<String>, firmlinks: [Firmlink], mountSources: [String: String],
         imageViews: [DiskImageViews] = [cryptexViews]) {
        self.rootPath = rootPath
        self.excludedPaths = excludedPaths
        self.mountSources = mountSources
        self.rootContainer = Self.mountSource(of: rootPath, in: mountSources).flatMap(Self.container(ofMountSource:))
        self.duplicateSources = Self.duplicates(rootPath: rootPath, firmlinks: firmlinks)
        // Only when the images themselves are in the scan; scanning just the views measures them.
        self.diskImageViews = Set(imageViews.filter { Self.isPath($0.imagesFolder, inside: rootPath) }.map(\.viewsPath))
    }

    /// True if the folder at `path` must not be scanned.
    public func skips(_ path: String) -> Bool {
        duplicateSources[path] != nil || excludedPaths.contains(path)
    }

    /// True if the folder at `path` only shows the contents of disk images counted elsewhere in
    /// this scan.
    public func showsDiskImageContents(_ path: String) -> Bool {
        diskImageViews.contains(path)
    }

    /// Whether to scan the volume mounted at `path`. Volumes mounted after the scan started
    /// are left out.
    func includesVolume(mountedAt path: String) -> Bool {
        guard let rootContainer, let source = mountSources[path] else { return false }
        return Self.container(ofMountSource: source) == rootContainer
    }

    /// The device holding `path`: the one mounted at the longest mount point containing it.
    static func mountSource(of path: String, in mountSources: [String: String]) -> String? {
        mountSources
            .filter { isPath(path, inside: $0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    static func duplicates(rootPath: String, firmlinks: [Firmlink]) -> [String: String] {
        var result: [String: String] = [:]
        for link in firmlinks {
            let copy = FolderTree.join(dataVolumeMountPoint, link.target)
            if isPath(link.source, inside: rootPath) && isPath(copy, inside: rootPath) {
                result[copy] = link.source
            }
        }
        return result
    }

    static func isPath(_ path: String, inside root: String) -> Bool {
        root == "/" ? path.hasPrefix("/") : path == root || path.hasPrefix(root + "/")
    }

    /// Parses /usr/share/firmlinks: one "source<TAB>target" pair per line, where `target` is
    /// relative to the data volume.
    static func parseFirmlinks(_ text: String) -> [Firmlink] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { return nil }
            let source = trimmedPath(fields[0])
            let target = trimmedPath(fields[1])
            guard source.hasPrefix("/"), source.count > 1, !target.isEmpty, !target.hasPrefix("/") else { return nil }
            return Firmlink(source: source, target: target)
        }
    }

    /// Without surrounding whitespace and without trailing slashes.
    private static func trimmedPath(_ field: Substring) -> String {
        var path = field.trimmingCharacters(in: .whitespaces)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func readFirmlinks(at path: String) -> [Firmlink] {
        parseFirmlinks((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    /// "/dev/disk3s1s1" → "disk3": the APFS container (or whole disk) a volume belongs to.
    static func container(ofMountSource source: String) -> String? {
        let prefix = "/dev/disk"
        guard source.hasPrefix(prefix) else { return nil }
        let digits = source.dropFirst(prefix.count).prefix(while: \.isASCIIDigit)
        return digits.isEmpty ? nil : "disk" + digits
    }

    /// Reads the mount table from the kernel's cache (MNT_NOWAIT), never from the file systems.
    private static func readMountTable() -> [String: String] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [:] }
        var table: [statfs] = Array(repeating: statfs(), count: Int(count) + 16)
        let filled = table.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        var sources: [String: String] = [:]
        for var info in table.prefix(Int(max(0, filled))) {
            let mountedOn = withUnsafeBytes(of: &info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            sources[mountedOn] = withUnsafeBytes(of: &info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return sources
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
