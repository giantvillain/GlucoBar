import AppKit
import Combine
import SwiftUI

@MainActor
final class GlucoBarAppDelegate: NSObject, NSApplicationDelegate {
    let service: LibreLinkUpService = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") { return .preview() }
        #endif
        return LibreLinkUpService()
    }()
    private(set) var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !GLUCOBAR_PREVIEW
        menuBar = MenuBarController(service: service)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            // Give visual previews an immediately accessible window.
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                self.menuBar?.showPanel()
                self.menuBar?.showSettings()
            }
        }
        #endif
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Owns the panel's lifetime so opening another GlucoBar window does not dismiss it.
@MainActor
final class MenuBarController: NSObject {
    private let service: LibreLinkUpService
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var updates: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    init(service: LibreLinkUpService) {
        self.service = service
        super.init()
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        // Use the native status-item title so macOS supplies its usual menu-bar
        // typography, contrast and compact sizing, just as MenuBarExtra did.
        button.font = .menuBarFont(ofSize: 0)
        button.image = nil
        updateLabel()
        updates = service.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateLabel()
        }

        popover.behavior = .applicationDefined
        let content = NSHostingController(rootView:
            MenuContent(openSettings: { [weak self] in self?.showSettings() },
                        openHistory: { [weak self] in self?.showHistory() })
                .environmentObject(service)
                .onExitCommand { [weak self] in self?.popover.performClose(nil) }
        )
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        NotificationCenter.default.addObserver(self, selector: #selector(closePanel),
            name: NSApplication.didResignActiveNotification, object: NSApp)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    private func updateLabel() {
        guard let button = statusItem.button else { return }
        button.title = service.menuBarDisplayText
        button.setAccessibilityLabel(service.privacyMode ? "GlucoBar, privacy mode" :
            "GlucoBar, glucose \(service.menuBarValueText) \(service.displayUnitLabel), trend \(service.trendDescription)")
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func closePanel() { popover.performClose(nil) }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Settings", content: SettingsView().environmentObject(service),
                size: NSSize(width: 700, height: 610), resizable: false)
        }
        show(settingsWindow)
    }

    private func showHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(title: "Glucose History", content: HistoryView().environmentObject(service),
                size: NSSize(width: 920, height: 650), resizable: true)
            historyWindow?.minSize = NSSize(width: 760, height: 540)
        }
        show(historyWindow)
    }

    private func makeWindow<Content: View>(title: String, content: Content, size: NSSize, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)
        window.center()
        return window
    }

    private func show(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
