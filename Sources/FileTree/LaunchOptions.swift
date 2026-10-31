import Foundation

/// Command line arguments. A folder path opens and scans it; the other flags are for
/// development and testing.
struct LaunchOptions {
    /// Folder to scan right after launch.
    var scanPath: String?
    /// `--snapshot <dir>`: scan `scanPath`, save PNG snapshots of the window there, then quit.
    var snapshotDirectory: String?
    /// `--stop-after <seconds>`: in a snapshot run, press Stop this long after the scan starts.
    var stopAfter: Double?
    /// `--select <path>`: in a snapshot run, the folder to select after the scan.
    var selectPath: String?
    /// `--benchmark <path>`: scan without UI, print the results and timing, then quit.
    var benchmarkPath: String?
    /// `--threads <n>`: scanner threads (benchmark only).
    var threadCount: Int?
    /// `--exclude <path>`: leave a folder out (benchmark only; may repeat).
    var excludedPaths: [String] = []
    /// `--depth <n>`: how many levels of folders the benchmark prints.
    var depth = 1

    init(arguments: [String]) {
        var remaining = arguments.dropFirst().makeIterator()
        while let argument = remaining.next() {
            switch argument {
            case "--snapshot": snapshotDirectory = remaining.next()
            case "--stop-after": stopAfter = remaining.next().flatMap { Double($0) }
            case "--select": selectPath = remaining.next()
            case "--benchmark": benchmarkPath = remaining.next()
            case "--threads": threadCount = remaining.next().flatMap { Int($0) }
            case "--exclude": remaining.next().map { excludedPaths.append($0) }
            case "--depth": depth = remaining.next().flatMap { Int($0) } ?? depth
            default:
                if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                    _ = remaining.next() // A user-defaults override with its value, e.g. "-NSQuitAlwaysKeepsWindows NO".
                } else if !argument.hasPrefix("-"), scanPath == nil {
                    scanPath = argument
                }
            }
        }
    }
}
