import AppKit
import FileTreeCore

// Never download evicted iCloud files (or folders) just to measure them.
setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

FileSystem.raiseOpenFileLimit()

let options = LaunchOptions(arguments: CommandLine.arguments)
if let benchmarkPath = options.benchmarkPath {
    Benchmark.run(path: benchmarkPath, options: options)
}

let appDelegate = AppDelegate(options: options)
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
