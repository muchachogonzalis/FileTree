import AppKit
import FileTreeCore
import UniformTypeIdentifiers

@MainActor
enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    static func exactBytes(_ value: Int64) -> String {
        "\(count(value)) bytes"
    }

    static func count<Number: BinaryInteger>(_ value: Number) -> String {
        numberFormatter.string(from: NSNumber(value: Int64(value))) ?? "\(value)"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    static func date(_ seconds: Int64) -> String {
        seconds > 0 ? dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds))) : ""
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let total = Int(seconds.rounded())
        return String(format: "%d min %02d s", total / 60, total % 60)
    }

    static func errorDescription(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Icons and kind names, cached because the same few types repeat thousands of times.
@MainActor
enum FileAppearance {
    static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    static let volumeIcon = NSWorkspace.shared.icon(for: .volume)
    static let documentIcon = NSWorkspace.shared.icon(for: .data)
    static let symlinkIcon = NSWorkspace.shared.icon(for: .symbolicLink)
    // The abstract disk image type has only a blank document icon.
    static let diskImageIcon = NSWorkspace.shared.icon(for: UTType(filenameExtension: "dmg") ?? .diskImage)
    static let warningIcon: NSImage = {
        let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Could not be read")
            ?? NSImage()
        return symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange])) ?? symbol
    }()
    static let cloudIcon: NSImage = {
        let symbol = NSImage(systemSymbolName: "icloud", accessibilityDescription: "In iCloud") ?? NSImage()
        return symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemBlue])) ?? symbol
    }()

    private static var iconsByExtension: [String: NSImage] = [:]
    private static var iconsByPath: [String: NSImage] = [:]
    private static var kindsByExtension: [String: String] = [:]
    private static var packageExtensions: [String: Bool] = [:]

    /// A folder icon; packages such as apps get their own icon.
    static func folderIcon(named name: String, path: @autoclosure () -> String) -> NSImage {
        guard isPackage(named: name) else { return folderIcon }
        let path = path()
        if let icon = iconsByPath[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconsByPath[path] = icon
        return icon
    }

    static func fileIcon(named name: String) -> NSImage {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return documentIcon }
        if let icon = iconsByExtension[fileExtension] { return icon }
        let icon = UTType(filenameExtension: fileExtension).map { NSWorkspace.shared.icon(for: $0) } ?? documentIcon
        iconsByExtension[fileExtension] = icon
        return icon
    }

    static func iconForExtension(_ fileExtension: String) -> NSImage {
        fileExtension.isEmpty ? documentIcon : fileIcon(named: "file." + fileExtension)
    }

    static func kind(ofFileNamed name: String) -> String {
        kind(ofExtension: (name as NSString).pathExtension.lowercased())
    }

    static func kind(ofExtension fileExtension: String) -> String {
        guard !fileExtension.isEmpty else { return "Document" }
        if let kind = kindsByExtension[fileExtension] { return kind }
        var kind = "\(fileExtension.uppercased()) file"
        if let type = UTType(filenameExtension: fileExtension), !type.isDynamic, let description = type.localizedDescription {
            kind = description.prefix(1).uppercased() + description.dropFirst()
        }
        kindsByExtension[fileExtension] = kind
        return kind
    }

    static func kind(ofFolderNamed name: String) -> String {
        isPackage(named: name) ? kind(ofPackageNamed: name) : "Folder"
    }

    static func isPackage(named name: String) -> Bool {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return false }
        if let known = packageExtensions[fileExtension] { return known }
        let isPackage = UTType(filenameExtension: fileExtension, conformingTo: .directory)
            .map { !$0.isDynamic && $0.conforms(to: .package) } ?? false
        packageExtensions[fileExtension] = isPackage
        return isPackage
    }

    private static func kind(ofPackageNamed name: String) -> String {
        let fileExtension = (name as NSString).pathExtension
        guard let description = UTType(filenameExtension: fileExtension, conformingTo: .directory)?.localizedDescription
        else { return "Package" }
        return description.prefix(1).uppercased() + description.dropFirst()
    }
}

/// How a scanned folder is labeled in the lists.
@MainActor
enum FolderPresentation {
    static func icon(for folder: FolderNode) -> NSImage {
        switch folder.status {
        case .accessDenied, .privacyProtected, .unreadable: return FileAppearance.warningIcon
        case .inCloud: return FileAppearance.cloudIcon
        case .otherVolume: return FileAppearance.volumeIcon
        case .diskImageContents: return FileAppearance.diskImageIcon
        case .ok, .notScanned, .vanished: return FileAppearance.folderIcon(named: folder.name, path: folder.path)
        }
    }

    /// A short remark shown after the name, or nil.
    static func note(for folder: FolderNode) -> String? {
        switch folder.status {
        case .ok: return nil
        case .accessDenied: return "no permission"
        case .privacyProtected: return "protected by macOS"
        case .unreadable: return "read error"
        case .inCloud: return "in iCloud, not downloaded"
        case .otherVolume: return "other volume, not scanned"
        case .diskImageContents: return "disk images of macOS, counted in cryptex1"
        case .notScanned: return "not scanned"
        case .vanished: return "no longer exists"
        }
    }

    static func tooltip(for folder: FolderNode) -> String {
        var lines = [folder.path]
        switch folder.status {
        case .ok: break
        case .accessDenied:
            lines.append("Only the system or the folder’s owner may look inside, so FileTree cannot measure it."
                + " Full Disk Access does not change that.")
        case .privacyProtected:
            lines.append("macOS keeps apps out of this folder. Add FileTree to Full Disk Access in System Settings"
                + " → Privacy & Security to measure it.")
        case .unreadable(let code):
            lines.append("Reading this folder failed: \(Format.errorDescription(code)). Its size may be incomplete.")
        case .inCloud:
            lines.append("Stored in iCloud and not downloaded to this Mac, so it takes no space here."
                + " FileTree does not download it.")
        case .otherVolume:
            lines.append("A different volume is mounted here. It is not included; scan it separately.")
        case .diskImageContents:
            lines.append("macOS shows the contents of its cryptexes here: signed disk images with parts of the system,"
                + " mainly the shared cache of system libraries. The image files are stored in the cryptex1 folder"
                + " of this volume and counted there, so their contents are not counted again."
                + " Choose “Scan Only This Folder” to look inside.")
        case .notScanned:
            lines.append("The scan was stopped before reaching this folder.")
        case .vanished:
            lines.append("The folder was deleted before it could be measured.")
        }
        let problemsInside = folder.problemCount - (folder.status.isProblem ? 1 : 0)
        if problemsInside > 0 {
            lines.append("\(Format.count(problemsInside)) folder(s) inside could not be read, so the size may be larger.")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum FileActions {
    static func reveal(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    static func open(_ paths: [String]) {
        for path in paths {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    static func copy(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Capacity of the volume holding a path.
struct VolumeInfo {
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    /// Free space plus space macOS can free up by itself (purgeable caches and the like).
    let availableForImportantUsage: Int64

    var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }
    var usedFraction: Double { totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) : 0 }

    private static let keys: [URLResourceKey] = [
        .volumeURLKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
    ]

    static func at(path: String) -> VolumeInfo? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: Set(keys)),
              let volume = values.volume
        else { return nil }
        // The data volume of the startup disk goes by the startup disk's name, as in the Finder.
        if volume.path == ScanBoundary.dataVolumeMountPoint && path != "/" {
            return at(path: "/")
        }
        return VolumeInfo(
            url: volume,
            name: values.volumeLocalizedName ?? volume.lastPathComponent,
            totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
            availableCapacity: Int64(values.volumeAvailableCapacity ?? 0),
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        )
    }

    /// Volumes that the Finder shows. May block on an unreachable network volume: call it off
    /// the main thread (see `Volumes`).
    static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { at(path: $0.path) }
    }

    /// The name to show for a scanned folder: the volume name for a volume, else the folder name.
    static func displayName(for path: String) -> String {
        if let volume = at(path: path), volume.url.path == path {
            return volume.name
        }
        return path == "/" ? "/" : (path as NSString).lastPathComponent
    }
}

/// The mounted volumes, read off the main thread: asking an unreachable network volume for its
/// capacity can block for minutes.
@MainActor
final class Volumes: NSObject {
    static let shared = Volumes()

    private(set) var mounted: [VolumeInfo] = []
    private var observers: [() -> Void] = []
    private var isReading = false
    private var readAgain = false

    override private init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
    }

    /// Calls `observer` whenever the list changes.
    func observe(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    func refresh() {
        guard !isReading else {
            readAgain = true
            return
        }
        isReading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let volumes = VolumeInfo.mounted()
            Task { @MainActor in
                Volumes.shared.update(volumes)
            }
        }
    }

    private func update(_ volumes: [VolumeInfo]) {
        isReading = false
        mounted = volumes
        observers.forEach { $0() }
        if readAgain {
            readAgain = false
            refresh()
        }
    }

    @objc private func volumesChanged() {
        refresh()
    }
}
