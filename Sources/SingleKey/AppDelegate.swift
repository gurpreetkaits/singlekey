import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let peers = PeerManager()
    private let capture = InputCapture()
    private let injector = InputInjector()
    private let hud = HUD()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    /// The Mac currently receiving this Mac's input; nil means this Mac.
    private var target: Peer?
    /// Peer currently driving this Mac, if any.
    private var controller: Peer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        capture.onHotkey = { [weak self] in self?.cycleTarget() }
        capture.onHotkeyRecorded = { [weak self] hotkey in
            Settings.hotkey = hotkey
            self?.hud.show("Shortcut: \(hotkey.displayString)", symbol: "keyboard")
        }

        peers.onPeersChanged = { [weak self] in self?.peersChanged() }
        peers.onMessage = { [weak self] peer, message in self?.received(message, from: peer) }

        startCaptureWhenPermitted()

        if Settings.pairingCode.isEmpty {
            DispatchQueue.main.async { self.promptForPairingCode() }
        } else {
            peers.start(passcode: Settings.pairingCode)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        switchTo(nil, announce: false)
    }

    // MARK: - Switching

    private func cycleTarget() {
        let order: [Peer?] = [nil] + peers.peers.sorted { $0.name < $1.name }
        guard order.count > 1 else {
            hud.show("No other Mac connected", symbol: "exclamationmark.triangle")
            return
        }
        let index = order.firstIndex { $0 === target } ?? 0
        switchTo(order[(index + 1) % order.count])
    }

    private func switchTo(_ peer: Peer?, announce: Bool = true) {
        if peer === target { return }
        if let old = target {
            old.send(.releaseAll)
            old.send(.control(active: false))
        }
        target = peer
        if let peer {
            peer.send(.control(active: true))
            capture.forward = { [weak peer] in peer?.send($0) }
            capture.setCapturing(true)
            if announce { hud.show(peer.name, symbol: "arrow.right.circle.fill") }
        } else {
            capture.forward = nil
            capture.setCapturing(false)
            if announce { hud.show(peers.myName, symbol: "laptopcomputer") }
        }
        updateIcon()
    }

    private func received(_ message: Message, from peer: Peer) {
        switch message {
        case .control(let active):
            if active {
                // Two Macs can't drive each other at once; hand back our own control first.
                if target != nil { switchTo(nil, announce: false) }
                controller = peer
            } else if controller === peer {
                controller = nil
                injector.releaseAll()
            }
            updateIcon()
        default:
            if controller === peer { injector.handle(message) }
        }
    }

    private func peersChanged() {
        if let target, !peers.peers.contains(where: { $0 === target }) {
            switchTo(nil, announce: false)
            hud.show("Lost connection — back on \(peers.myName)", symbol: "wifi.exclamationmark")
        }
        if let controller, !peers.peers.contains(where: { $0 === controller }) {
            injector.releaseAll()
            self.controller = nil
        }
        updateIcon()
    }

    // MARK: - Permissions

    private func startCaptureWhenPermitted() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }

        if capture.start() { log("keyboard capture running"); return updateIcon() }
        log("keyboard capture blocked: accessibility=\(AXIsProcessTrusted()) inputMonitoring=\(CGPreflightListenEventAccess()) postEvents=\(CGPreflightPostEventAccess())")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.capture.start() else { return }
            timer.invalidate()
            log("keyboard capture running")
            self.updateIcon()
        }
    }

    // MARK: - Menu

    private func updateIcon() {
        let symbol: String
        if !capture.isRunning || Settings.pairingCode.isEmpty { symbol = "keyboard.badge.exclamationmark" }
        else if target != nil { symbol = "arrow.right.square.fill" }
        else if controller != nil { symbol = "arrow.left.square.fill" }
        else if peers.peers.isEmpty { symbol = "keyboard" }
        else { symbol = "keyboard.fill" }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SingleKey")
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "SingleKey")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !capture.isRunning {
            info("⚠️ Needs Accessibility & Input Monitoring permission")
            menu.addItem(item("Open Privacy Settings…", #selector(openPrivacySettings)))
            menu.addItem(.separator())
        }
        if Settings.pairingCode.isEmpty {
            info("⚠️ Set a pairing code to connect")
        }
        if let controller { info("Being controlled by \(controller.name)") }
        if let error = peers.lastError { info(error) }

        info("Send keyboard & mouse to:")
        let local = item("\(peers.myName) (this Mac)", #selector(selectTarget(_:)))
        local.state = target == nil ? .on : .off
        menu.addItem(local)
        for peer in peers.peers.sorted(by: { $0.name < $1.name }) {
            let entry = item(peer.name, #selector(selectTarget(_:)))
            entry.representedObject = peer
            entry.state = target === peer ? .on : .off
            menu.addItem(entry)
        }
        if peers.peers.isEmpty && !Settings.pairingCode.isEmpty {
            info("Searching for other Macs…")
        }

        menu.addItem(.separator())
        let shortcut = capture.isRecordingHotkey
            ? "Press the new shortcut (Esc to cancel)…"
            : "Switch shortcut: \(Settings.hotkey.displayString)"
        info(shortcut)
        menu.addItem(item("Change Shortcut…", #selector(recordShortcut)))
        menu.addItem(item("Set Pairing Code…", #selector(promptForPairingCode)))

        let mouse = item("Also Send Mouse", #selector(toggleForwardMouse))
        mouse.state = capture.forwardMouse ? .on : .off
        menu.addItem(mouse)

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit SingleKey", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        switchTo(sender.representedObject as? Peer)
    }

    @objc private func recordShortcut() {
        capture.isRecordingHotkey = true
        hud.show("Press the new shortcut…", symbol: "keyboard")
    }

    @objc private func promptForPairingCode() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pairing Code"
        alert.informativeText = "Enter the same code on every Mac you want to share this keyboard and mouse with. It encrypts the connection, so pick something hard to guess."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = Settings.pairingCode
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let code = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        Settings.pairingCode = code
        switchTo(nil, announce: false)
        peers.start(passcode: code)
        updateIcon()
    }

    @objc private func toggleForwardMouse() {
        capture.forwardMouse.toggle()
        Settings.forwardMouse = capture.forwardMouse
    }

    @objc private func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
