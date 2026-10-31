import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var windowController: MainWindowController?
    /// A folder opened (dropped on the Dock icon, "Open With") before the window existed.
    private var pendingURL: URL?
    private var automation: SnapshotAutomation?

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Snapshot runs stay out of the Dock and the menu bar.
        NSApp.setActivationPolicy(options.snapshotDirectory == nil ? .regular : .accessory)
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Volumes.shared.refresh()
        let controller = MainWindowController()
        windowController = controller
        if let directory = options.snapshotDirectory {
            let automation = SnapshotAutomation(directory: directory, controller: controller, stopAfter: options.stopAfter,
                                                selectPath: options.selectPath)
            self.automation = automation
            automation.run(scanPath: options.scanPath)
            return
        }
        controller.showWindow(nil)
        NSApp.activate()
        if let url = pendingURL ?? options.scanPath.map({ URL(fileURLWithPath: $0) }) {
            controller.scan(url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: \.hasDirectoryPath) else { return }
        if let windowController {
            windowController.showWindow(nil)
            windowController.scan(url)
        } else {
            pendingURL = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu("FileTree", [
            item("About FileTree", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide FileTree", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit FileTree", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        let scanDisk = NSMenuItem(title: "Scan Disk", action: nil, keyEquivalent: "")
        scanDisk.submenu = VolumesMenu.shared.makeMenu()
        let down = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
        menu.addItem(submenu("File", [
            item("Choose Folder…", #selector(MainWindowController.chooseFolder(_:)), "o"),
            scanDisk,
            item("Scan Home Folder", #selector(MainWindowController.scanHomeFolder(_:)), "h", [.command, .shift]),
            .separator(),
            item("Rescan", #selector(MainWindowController.rescan(_:)), "r"),
            item("Rescan Selected Folder", #selector(MainWindowController.rescanSelectedFolder(_:)), "r", [.command, .shift]),
            item("Stop Scanning", #selector(MainWindowController.stopScan(_:)), "."),
            .separator(),
            item("Show in Finder", #selector(MainWindowController.showInFinder(_:)), "r", [.command, .option]),
            item("Open", #selector(MainWindowController.openSelection(_:)), down),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        menu.addItem(submenu("Edit", [
            item("Copy Path", #selector(MainWindowController.copy(_:)), "c"),
        ]))
        menu.addItem(submenu("View", [
            item("Contents", #selector(MainWindowController.showContentsTab(_:)), "1"),
            item("File Types", #selector(MainWindowController.showFileTypesTab(_:)), "2"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        menu.addItem(window)
        NSApp.windowsMenu = window.submenu
        menu.addItem(submenu("Help", [
            item("Full Disk Access Settings…", #selector(MainWindowController.openFullDiskAccessSettings(_:))),
        ]))
        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for child in items {
            menu.addItem(child)
        }
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

/// Lists the mounted disks, for the Scan Disk menus.
@MainActor
final class VolumesMenu: NSObject, NSMenuDelegate {
    static let shared = VolumesMenu()

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        Volumes.shared.refresh()
        for volume in Volumes.shared.mounted {
            let item = NSMenuItem(title: "\(volume.name) — \(Format.bytes(volume.availableCapacity)) free",
                                  action: #selector(MainWindowController.scanVolume(_:)), keyEquivalent: "")
            item.representedObject = volume.url
            if let icon = NSWorkspace.shared.icon(forFile: volume.url.path).copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Home Folder", action: #selector(MainWindowController.scanHomeFolder(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Choose Folder…", action: #selector(MainWindowController.chooseFolder(_:)), keyEquivalent: ""))
    }

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }
}
