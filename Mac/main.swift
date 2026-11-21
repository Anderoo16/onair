import AppKit
import Foundation
import OSLog
import ServiceManagement

final class Companion: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var indicator: SignIndicator!
    private var timer: Timer?
    private let client = SignClient()
    private let logger = Logger(subsystem: "com.steppedstudio.onair", category: "sign")
    private let detectionQueue = DispatchQueue(label: "onair.capture.activity", qos: .utility)
    private let setupQueue = DispatchQueue(label: "onair.usb.setup", qos: .userInitiated)

    private let microphone = NSMenuItem(title: "Microphone: checking", action: nil, keyEquivalent: "")
    private let camera = NSMenuItem(title: "Camera: checking", action: nil, keyEquivalent: "")
    private let connection = NSMenuItem(title: "Sign: Not set up", action: nil, keyEquivalent: "")
    private let light = NSMenuItem(title: "Light: Unconfirmed", action: nil, keyEquivalent: "")
    private let auto = NSMenuItem(title: "Automatic", action: #selector(enableAuto), keyEquivalent: "")
    private let pause = NSMenuItem(title: "Pause", action: #selector(pauseAuto), keyEquivalent: "")
    private let test = NSMenuItem(title: "Test Light for 10 Seconds", action: #selector(testLight), keyEquivalent: "")
    private let setupItem = NSMenuItem(title: "Set Up Sign…", action: #selector(setUpSign), keyEquivalent: "")
    private let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let brightness = NSMenu()

    private var pairing = Pairing.load()
    private var capture: CaptureActivity?
    private var sampling = false
    private var paused = UserDefaults.standard.bool(forKey: "paused")
    private var level = UserDefaults.standard.object(forKey: "level") as? Int ?? 30
    private var lastActivity: TimeInterval = -.infinity
    private var testUntil: TimeInterval = -.infinity
    private var sentAt: TimeInterval = -.infinity
    private var lastSent: Int?
    private var sending = false
    private var setupInProgress = false
    private var signStatus: SignStatus?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = status.button { indicator = SignIndicator(button) }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in [connection, light] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for item in [microphone, camera] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for item in [auto, pause, test] {
            item.target = self
            menu.addItem(item)
        }
        let brightnessItem = NSMenuItem(title: "Brightness", action: nil, keyEquivalent: "")
        for percent in [15, 30, 50, 75, 100] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(changeBrightness(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            brightness.addItem(item)
        }
        brightnessItem.submenu = brightness
        menu.addItem(brightnessItem)
        menu.addItem(.separator())
        for item in [setupItem, login] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ON AIR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        status.menu = menu
        showSignStatus(pairing == nil ? .unpaired : .connecting)
        updateMenu()
        if ProcessInfo.processInfo.arguments.contains("--menu-smoke") {
            print(menu.items.map(\.title).joined(separator: "\n"))
            print("Default brightness: \(level)%")
            NSApp.terminate(nil)
            return
        }
        let poll = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
            self?.sampleAndSync()
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                         name: NSWorkspace.didWakeNotification, object: nil)
        sampleAndSync()
    }

    private func showSignStatus(_ state: SignStatus) {
        guard signStatus != state else { return }
        signStatus = state
        connection.title = state.connectionTitle
        connection.toolTip = state.detail
        light.title = state.lightTitle
        indicator?.show(state)
        logger.notice("\(state.connectionTitle, privacy: .public) | \(state.lightTitle, privacy: .public)")
    }

    @objc private func didWake(_ notification: Notification) {
        guard pairing != nil, !setupInProgress else { return }
        lastSent = nil
        sentAt = -.infinity
        showSignStatus(.connecting)
        sampleAndSync()
    }

    private func updateMenu() {
        auto.state = paused ? .off : .on
        pause.state = paused ? .on : .off
        test.isEnabled = pairing != nil && !setupInProgress
        setupItem.isEnabled = !setupInProgress
        for item in brightness.items { item.state = item.tag == level ? .on : .off }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func enableAuto() {
        paused = false
        testUntil = -.infinity
        UserDefaults.standard.set(false, forKey: "paused")
        updateMenu()
        sync()
    }

    @objc private func pauseAuto() {
        paused = true
        testUntil = -.infinity
        UserDefaults.standard.set(true, forKey: "paused")
        updateMenu()
        sync()
    }

    @objc private func testLight() {
        testUntil = ProcessInfo.processInfo.systemUptime + 10
        sync()
    }

    @objc private func changeBrightness(_ sender: NSMenuItem) {
        level = sender.tag
        UserDefaults.standard.set(level, forKey: "level")
        updateMenu()
        sync()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    alert("Allow ON AIR to open at login",
                          "Enable Stepped Studio ON AIR under Login Items in System Settings.")
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            alert("Could not update Open at Login", error.localizedDescription)
        }
        updateMenu()
    }

    private func sampleAndSync() {
        guard !sampling else { sync(); return }
        sampling = true
        detectionQueue.async { [weak self] in
            let next = CaptureActivity.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampling = false
                self.capture = next
                if next.microphone || next.camera {
                    self.lastActivity = ProcessInfo.processInfo.systemUptime
                }
                self.microphone.title = next.microphone ? "Microphone: in use" : "Microphone: idle"
                self.camera.title = next.camera ? "Camera: in use" : "Camera: idle"
                self.sync()
            }
        }
    }

    private func sync() {
        guard let pairing, !setupInProgress else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let active = capture?.microphone == true || capture?.camera == true || now - lastActivity < 2
        let desired = now < testUntil || (!paused && active) ? level : 0
        guard !sending, now - sentAt >= 0.6, lastSent != desired || now - sentAt >= 4 else { return }
        sending = true
        sentAt = now
        client.send(desired, to: pairing) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sending = false
                guard pairing == self.pairing, !self.setupInProgress else { return }
                switch result {
                case .success:
                    self.lastSent = desired
                    self.showSignStatus(.connected(desired))
                case .failure(let error):
                    self.lastSent = nil
                    // Retry on the heartbeat, including after sleep or a Wi-Fi reconnect.
                    self.sentAt = ProcessInfo.processInfo.systemUptime + 2.5
                    let detail = error.localizedDescription
                    self.showSignStatus(error is SignClient.PairingRejected ? .needsPairing(detail) : .offline(detail))
                }
            }
        }
    }

    @objc private func setUpSign() {
        guard !setupInProgress else { return }
        NSApp.activate(ignoringOtherApps: true)

        let ports = USBSetup.ports()
        guard !ports.isEmpty else {
            alert("Connect the XIAO by USB",
                  "Unplug the sign’s wall power and both LED plugs. Connect the Mac to the USB-C socket on the XIAO itself with a data cable, then choose Set Up Sign again.")
            return
        }

        let window = NSAlert()
        window.messageText = "Set up your ON AIR sign"
        window.informativeText = "Leave wall power and both LED plugs disconnected. Choose the XIAO you’re using for this sign. First-time setup replaces the program on that board and saves its Wi-Fi settings over USB."
        window.addButton(withTitle: "Install & Pair")
        window.addButton(withTitle: "Cancel")

        let ssid = NSTextField()
        ssid.placeholderString = "2.4 GHz Wi-Fi network name"
        let password = NSSecureTextField()
        password.placeholderString = "Wi-Fi password (blank for an open network)"
        let portMenu = NSPopUpButton()
        portMenu.addItems(withTitles: ports.map { URL(fileURLWithPath: $0).lastPathComponent })
        let fields = NSStackView(views: [
            NSTextField(labelWithString: "XIAO USB port"), portMenu,
            NSTextField(labelWithString: "Wi-Fi network name (case sensitive)"), ssid,
            NSTextField(labelWithString: "Wi-Fi password"), password
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 7
        for field in [ssid, password, portMenu] as [NSView] {
            field.widthAnchor.constraint(equalToConstant: 345).isActive = true
        }
        fields.frame = NSRect(x: 0, y: 0, width: 345, height: 162)
        window.accessoryView = fields
        window.window.initialFirstResponder = ssid
        guard window.runModal() == .alertFirstButtonReturn else { return }

        let networkName = ssid.stringValue
        let networkPassword = password.stringValue
        let port = ports[portMenu.indexOfSelectedItem]
        do {
            try USBSetup.validateWiFi(ssid: networkName, password: networkPassword)
        } catch {
            alert("Check your Wi-Fi settings", error.localizedDescription)
            return
        }

        setupInProgress = true
        showSignStatus(.settingUp("Sign: Checking USB…"))
        updateMenu()
        setupQueue.async { [weak self] in
            let result = Result {
                try USBSetup.installAndPair(port: port, ssid: networkName, password: networkPassword) { message in
                    DispatchQueue.main.async { self?.showSignStatus(.settingUp(message)) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.setupInProgress = false
                self.sentAt = -.infinity
                self.lastSent = nil
                switch result {
                case .success(let setup):
                    self.pairing = setup.pairing
                    if setup.joinedWiFi {
                        self.showSignStatus(.connecting)
                        self.alert("USB setup complete",
                                   "Unplug the Mac cable before reconnecting the LED plugs and the sign’s wall power. Allow local network access if macOS asks. Then choose Test Light for 10 Seconds.")
                    } else {
                        self.showSignStatus(.offline("Wi-Fi could not be confirmed during USB setup."))
                        self.alert("Saved, but Wi-Fi did not connect",
                                   "Check the Wi-Fi name and password and make sure the network supports 2.4 GHz. Keep the XIAO connected and try Set Up Sign again.")
                    }
                case .failure(let error):
                    self.showSignStatus(self.pairing == nil ? .unpaired : .connecting)
                    self.alert("Could not finish setup", error.localizedDescription)
                }
                self.updateMenu()
                self.sync()
            }
        }
    }

    private func alert(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSAlert()
        panel.messageText = title
        panel.informativeText = detail
        panel.runModal()
    }
}

if CommandLine.arguments.contains("--probe") {
    let data = try JSONEncoder().encode(CaptureActivity.read())
    print(String(decoding: data, as: UTF8.self))
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Companion()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
