import AppKit

private extension NSToolbarItem.Identifier {
    static let tabs = NSToolbarItem.Identifier("tabs")
}

/// Running copy, move and date operations of the tabs (and their undo). Quitting cancels them and waits until
/// they have stopped after the current file – otherwise a file being copied to another volume could remain
/// half-written under its final name.
@MainActor
enum FileOperations {
    private static var running: [Int: Task<Void, Never>] = [:]
    private static var lastID = 0

    static var isRunning: Bool { !running.isEmpty }

    /// Runs `operation` on the main actor and keeps track of it until it ends.
    @discardableResult
    static func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        lastID += 1
        let id = lastID
        let task = Task { @MainActor in
            await operation()
            running[id] = nil
        }
        running[id] = task
        return task
    }

    static func cancelAll(then completion: @escaping @MainActor () -> Void) {
        let tasks = Array(running.values)
        tasks.forEach { $0.cancel() }
        Task { @MainActor in
            for task in tasks { await task.value }
            completion()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var window: NSWindow?
    private var controller: MainViewController?
    /// Four independent tabs in alphabetical order: Apple Photos export, date fix, duplicates, folder sync.
    private let tabs = NSTabViewController()
    private var tabSwitcher: TabStrip?
    private var tabTitles: [String] { tabs.tabViewItems.map(\.label) }
    /// Stores a fixed identifier rather than index or title, which change when tabs are added or renamed.
    private static let selectedTabKey = "selectedTab"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Darcula.applyAppearance()
        let controller = MainViewController(model: model)
        let sorter = SortViewController()
        tabs.tabStyle = .unspecified
        tabs.transitionOptions = []
        let pages: [(id: String, viewController: NSViewController)] = [
            ("export", sorter),
            ("dates", DateFixViewController()),
            ("duplicates", controller),
            ("sync", FolderSyncViewController()),
        ]
        for page in pages {
            let item = NSTabViewItem(viewController: page.viewController)
            item.identifier = page.id
            item.label = page.viewController.title ?? ""
            tabs.addTabViewItem(item)
        }
        let duplicatesTab = tabs.tabViewItems.firstIndex { $0.viewController === controller } ?? 0
        sorter.onFindDuplicates = { [weak self, weak controller] folder in
            self?.selectTab(duplicatesTab)
            controller?.useFolder(folder)
        }
        let storedTab = UserDefaults.standard.string(forKey: Self.selectedTabKey)
        tabs.selectedTabViewItemIndex = tabs.tabViewItems.firstIndex { $0.identifier as? String == storedTab } ?? duplicatesTab

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "PhotoHub"
        // Kept alive after closing: running operations may still finish before the app quits.
        window.isReleasedWhenClosed = false
        window.backgroundColor = Darcula.background
        // Otherwise the toolbar keeps the system's darker grey above the Darcula background.
        window.titlebarAppearsTransparent = true
        window.contentViewController = tabs
        let toolbar = NSToolbar(identifier: "PhotoHubToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        if #available(macOS 14, *) {
            toolbar.centeredItemIdentifiers = [.tabs]
        } else {
            toolbar.centeredItemIdentifier = .tabs
        }
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 1040, height: 520)
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.center()
        window.setFrameAutosaveName("PhotoHubMainWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.controller = controller

        NSApp.mainMenu = makeMainMenu(controller: controller)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func selectTab(_ index: Int) {
        tabs.selectedTabViewItemIndex = index
        tabSwitcher?.selectedIndex = index
        UserDefaults.standard.set(tabs.tabViewItems[index].identifier as? String, forKey: Self.selectedTabKey)
    }

    @objc fileprivate func showTab(_ sender: NSMenuItem) {
        selectTab(sender.tag)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard FileOperations.isRunning else { return .terminateNow }
        FileOperations.cancelAll { NSApp.terminate(nil) }
        return .terminateCancel
    }

    private func makeMainMenu(controller: MainViewController) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Über PhotoHub", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "PhotoHub ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Andere ausblenden", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Alle einblenden", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "PhotoHub beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: mainMenu)

        let fileMenu = NSMenu(title: "Ablage")
        fileMenu.addItem(withTitle: "Ordner wählen …", action: #selector(MainViewController.chooseFolder(_:)), keyEquivalent: "o").target = controller
        fileMenu.addItem(withTitle: "Scannen", action: #selector(MainViewController.startScan(_:)), keyEquivalent: "r").target = controller
        fileMenu.addItem(withTitle: "Scan abbrechen", action: #selector(MainViewController.cancelScan(_:)), keyEquivalent: ".").target = controller
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Markierte in den Papierkorb …", action: #selector(MainViewController.confirmTrash(_:)), keyEquivalent: "\u{8}").target = controller
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Scan-Cache leeren", action: #selector(MainViewController.clearScanCache(_:)), keyEquivalent: "").target = controller
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Fenster schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(fileMenu, to: mainMenu)

        let selectionMenu = NSMenu(title: "Auswahl")
        selectionMenu.addItem(withTitle: "Rückgängig: Papierkorb", action: #selector(MainViewController.undoTrash(_:)), keyEquivalent: "z").target = controller
        selectionMenu.addItem(.separator())
        selectionMenu.addItem(withTitle: "Vorschlag übernehmen", action: #selector(MainViewController.applySuggestions(_:)), keyEquivalent: "").target = controller
        selectionMenu.addItem(withTitle: "Alle Markierungen entfernen", action: #selector(MainViewController.clearMarks(_:)), keyEquivalent: "").target = controller
        addSubmenu(selectionMenu, to: mainMenu)

        let viewMenu = NSMenu(title: "Darstellung")
        for (index, title) in tabTitles.enumerated() {
            let item = viewMenu.addItem(withTitle: title, action: #selector(showTab(_:)), keyEquivalent: "\(index + 1)")
            item.tag = index
            item.target = self
        }
        addSubmenu(viewMenu, to: mainMenu)
        addSubmenu(StudioMenu.make(), to: mainMenu)

        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoomen", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        addSubmenu(windowMenu, to: mainMenu)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private func addSubmenu(_ menu: NSMenu, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        mainMenu.addItem(item)
    }
}

extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .tabs, .flexibleSpace] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .tabs] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == .tabs else { return nil }
        let strip = TabStrip(titles: tabTitles, selectedIndex: tabs.selectedTabViewItemIndex)
        strip.onSelect = { [weak self] in self?.selectTab($0) }
        tabSwitcher = strip
        let item = NSToolbarItem(itemIdentifier: .tabs)
        item.view = strip
        item.label = "Bereiche"
        return item
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showTab(_:)) { menuItem.state = menuItem.tag == tabs.selectedTabViewItemIndex ? .on : .off }
        return true
    }
}
