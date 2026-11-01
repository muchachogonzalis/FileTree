import AppKit
import ObjectiveC
import Testing
@testable import FileTree

/// The commands of the menu bar and of the toolbar have no target. AppKit gives each one to the first object on
/// the responder chain that answers it: the focused list, the views above it with their view controllers, the
/// window, and then the window's delegate, `MainWindowController`, which carries the commands out.
@Suite("Commands of the menu bar and the toolbar")
@MainActor
struct CommandRoutingTests {
    /// The tree once had a context menu action named `rescan(_:)`. Whenever the tree had the focus, it took the
    /// Rescan command of the toolbar and of ⌘R, found no folder in the sender and did nothing.
    @Test func noViewOrViewControllerTakesAWindowCommand() {
        let commands = windowCommands()
        for command in [#selector(MainWindowController.rescan(_:)), #selector(MainWindowController.rescanSelectedFolder(_:)),
                        #selector(MainWindowController.showInFinder(_:)), #selector(MainWindowController.copy(_:))] {
            #expect(commands.contains(command), "\(NSStringFromSelector(command)) is not among the commands found")
        }
        let responders = appResponderClasses() + appKitRespondersOnTheChain
        #expect(responders.contains { $0 == FolderTreeController.self })
        for responder in responders {
            for command in commands.sorted(by: { NSStringFromSelector($0) < NSStringFromSelector($1) }) {
                #expect(!class_respondsToSelector(responder, command),
                        "\(NSStringFromClass(responder)) answers \(NSStringFromSelector(command)), so it takes that command from the window")
            }
        }
    }

    /// After deleting something in a folder, the person selects the folder and clicks Rescan: that folder is
    /// scanned again, and with the top folder selected, everything.
    @Test func rescanButtonRescansTheSelectedFolder() throws {
        let item = try #require(MainWindowController.makeToolbarItem(.rescan))
        #expect(item.target == nil)
        #expect(item.action == #selector(MainWindowController.rescanSelectedFolder(_:)))
    }

    /// The commands of the main menu and of the toolbar that `MainWindowController` carries out.
    private func windowCommands() -> Set<Selector> {
        _ = NSApplication.shared
        let toolbar = MainWindowController.toolbarItemIdentifiers.compactMap(MainWindowController.makeToolbarItem)
        // The Scan Disk menus get their items when they open; the items of the disks send scanVolume(_:).
        var found = commands(in: MainMenu.make()) + [#selector(MainWindowController.scanVolume(_:))]
        found += toolbar.compactMap { $0.target == nil ? $0.action : nil }
        found += toolbar.compactMap { ($0 as? NSMenuToolbarItem)?.menu }.flatMap(commands(in:))
        return Set(found.filter { class_respondsToSelector(MainWindowController.self, $0) })
    }

    private func commands(in menu: NSMenu) -> [Selector] {
        menu.items.flatMap { item in
            (item.submenu.map(commands(in:)) ?? []) + (item.target == nil ? [item.action].compactMap { $0 } : [])
        }
    }

    /// Every responder class of the app (its views and view controllers) except the window controller.
    private func appResponderClasses() -> [AnyClass] {
        guard let image = class_getImageName(MainWindowController.self) else { return [] }
        var count: UInt32 = 0
        guard let names = objc_copyClassNamesForImage(image, &count) else { return [] }
        defer { free(names) }
        return (0..<Int(count)).compactMap { objc_getClass(names[$0]) as? AnyClass }.filter { candidate in
            candidate != MainWindowController.self
                && sequence(first: candidate, next: { class_getSuperclass($0) }).contains { $0 == NSResponder.self }
        }
    }

    /// The AppKit classes between a focused list and the window controller.
    private let appKitRespondersOnTheChain: [AnyClass] = [
        NSOutlineView.self, NSTableView.self, NSClipView.self, NSScrollView.self, NSTabView.self, NSSplitView.self,
        NSStackView.self, NSView.self, NSWindow.self,
    ]
}
