import Foundation
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

enum BitratePreset: String, CaseIterable, Identifiable {
    case low = "Low", balanced = "Balanced", high = "High"
    var id: String { rawValue }
    var bps: Int {
        switch self {
        case .low: return 40_000_000
        case .balanced: return 80_000_000
        case .high: return 150_000_000
        }
    }
}

enum TransportChoice: String, CaseIterable, Identifiable {
    case usb = "USB (AOA)", adb = "adb forward (dev)"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    enum Status: Equatable {
        case needsPermissions, waiting, connecting, connected(String), error(String)
    }

    @Published var status: Status = .waiting
    @Published var screenRecordingGranted = false
    @Published var accessibilityGranted = false
    @Published var snapshot = Stats.Snapshot()
    @Published var clockRTT: Double?
    @Published var installTargets: [InstallTarget] = []
    var adbBusy = false
    /// ADB operations in progress: accessory auto-connect waits (switching the tablet into
    /// accessory mode re-enumerates it on USB and would cut the ADB connection).
    var adbOperations = 0

    @AppStorage("displayMode") var mode: DisplayMode = .sharpest { didSet { applyDisplaySettings() } }
    @AppStorage("refresh") var refresh: Int = 120 { didSet { applyDisplaySettings() } }
    @AppStorage("bitrate") var bitrate: BitratePreset = .balanced { didSet { session?.updateBitrate(bitrate.bps) } }
    @AppStorage("transport") var transportChoice: TransportChoice = .usb
    @AppStorage("autoConnect") var autoConnect = true
    @AppStorage("idleRefinement") var idleRefinement = true

    private(set) var session: StreamSession?
    private var monitor: USBMonitor?
    private var statsTimer: Timer?
    private var permissionTimer: Timer?
    private var retryTimer: Timer?
    private var userDisconnected = false
    private var lastStatsLog = Date.distantPast
    private var lastCaptured = 0, lastSuperseded = 0

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--transport"), i + 1 < args.count {
            transportChoice = args[i + 1] == "tcp" ? .adb : .usb
        }
        refreshPermissions()
        if !permissionsOK {
            // First run: trigger the system prompts; the menu offers deep links if they were dismissed.
            if !screenRecordingGranted { _ = CGRequestScreenCaptureAccess() }
            if !accessibilityGranted {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        }
        monitor = USBMonitor()
        monitor?.onChange = { [weak self] in self?.usbChanged() }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        // Plug notifications can land while a session is still tearing down; poll as a backstop.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.usbChanged() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.usbChanged() }
        // Apply display settings however they change (menu, or `defaults write` while debugging).
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDisplaySettings() }
        }
        // Scripts/tests: `defaults write com.alexgwyn.tabdisplay.mac displayMode …` then post this
        // to make a running app pick the change up (external writes don't notify the app).
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.alexgwyn.tabdisplay.reloadSettings"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                UserDefaults.standard.synchronize()
                self?.objectWillChange.send()
                self?.applyDisplaySettings()
            }
        }
        // Development: open the menu (for README screenshots) and log its window number.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.alexgwyn.tabdisplay.showMenu"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.openMenuForScreenshot() }
        }
        // Quit from anywhere (Dock, ⌘Q, logout): say goodbye so the tablet shows it right away.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.stop(reason: "app quitting") }
        }
        // Sleep (system or displays): end the session cleanly and don't retry until wake.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { self?.goingToSleep(n.name.rawValue) }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { self?.wokeUp(n.name.rawValue) }
            }
        }
        // Development: `--adb list|install|authorize` exercises the menu's tablet-app actions.
        if let i = args.firstIndex(of: "--adb"), i + 1 < args.count { runADBDebug(args[i + 1]) }
        // Development: `--snapshot <dir>` renders the menu and menu bar icon to PNGs.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.writeSnapshots(to: dir) }
        }
    }

    static func openMenuForScreenshot() {
        func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? [] + v.subviews.flatMap(buttons) }
        let statusButton = NSApp.windows
            .filter { String(describing: type(of: $0)).contains("StatusBar") }
            .compactMap { $0.contentView }.flatMap(buttons).first
        statusButton?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            for w in NSApp.windows where w.isVisible && w.frame.width > 300 && !String(describing: type(of: w)).contains("StatusBar") {
                Log.info("menu window \(w.windowNumber) frame \(w.frame)")
            }
        }
    }

    private func runADBDebug(_ action: String) {
        refreshInstallTargets()
        func report(_ step: Int = 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Log.info("adb debug: \(self.installTargets.map { "\($0.device.name) [\($0.device.path)] \($0.status)" })")
                guard let t = self.installTargets.first, step < 120 else { return }
                switch (action, step, t.status) {
                case ("install", 0, _): self.install(t); report(1)
                case ("authorize", 0, _): self.authorize(t); report(1)
                case (_, _, .installing), (_, _, .waitingForAllow), (_, _, .checking): report(step + 1)
                default: if step == 0 && action != "list" { report(0) } else { Log.info("adb debug: done") }
                }
            }
        }
        report()
    }

    private func writeSnapshots(to dir: URL) {
        func png(_ img: NSImage?, _ name: String) {
            guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: dir.appendingPathComponent(name))
        }
        let menu = ImageRenderer(content: MenuView(model: self).background(Color(nsColor: .windowBackgroundColor)))
        menu.scale = 2
        png(menu.nsImage, "menu.png")
        for c in [false, true] {
            let icon = ImageRenderer(content: Image(nsImage: MenuBarIcon.image(connected: c)).padding(4).background(Color.white))
            icon.scale = 4
            png(icon.nsImage, "menubar-\(c ? "connected" : "idle").png")
        }
        Log.info("snapshots written to \(dir.path)")
    }

    var permissionsOK: Bool { screenRecordingGranted && accessibilityGranted }

    func refreshPermissions() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
        if !permissionsOK { if session == nil { status = .needsPermissions } }
        else if status == .needsPermissions { status = .waiting; usbChanged() }
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { Log.info("launch at login: \(error.localizedDescription)") }
            objectWillChange.send()
        }
    }

    /// Android devices on USB that haven't connected before; shown in the menu with a Connect button.
    @Published var newDevices: [AOATransport.Candidate] = []
    /// Every Android device currently on USB.
    @Published var devices: [AOATransport.Candidate] = []
    /// Devices that completed a session (serial → name the tablet reported): these connect automatically.
    @AppStorage("knownDevices") private var knownDevicesRaw = ""
    private var knownDevices: [String: String] {
        get {
            Dictionary(knownDevicesRaw.split(separator: "\n").map { line -> (String, String) in
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                return (parts[0], parts.count > 1 ? parts[1] : parts[0])
            }, uniquingKeysWith: { a, _ in a })
        }
        set { knownDevicesRaw = newValue.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n") }
    }
    /// Name to show for a device: what the tablet called itself last time, else its USB name.
    func displayName(_ d: AOATransport.Candidate) -> String { knownDevices[d.serial] ?? d.name }

    private var scanning = false
    /// Back-off after failed attempts (2, 4, 8 … 30 s) so a persistent failure doesn't spin.
    private var failures = 0
    private var nextAttempt = Date.distantPast
    /// The Mac or its displays are asleep: virtual displays can't be created or captured.
    private var asleep = false

    private func noteFailure() {
        failures += 1
        nextAttempt = Date().addingTimeInterval(min(30, pow(2, Double(failures))))
    }

    private func usbChanged() {
        guard session == nil, permissionsOK, status != .connecting, !scanning, !asleep, adbOperations == 0, Date() >= nextAttempt else { return }
        if transportChoice == .adb {
            if case .error = status { return }  // dev transport: connect manually after a failure
            if autoConnect && !userDisconnected { connect(nil) }
            return
        }
        scanning = true
        Task.detached(priority: .utility) {
            let found = AOATransport.candidates()  // probes new devices once (blocking USB control requests)
            await MainActor.run {
                self.scanning = false
                guard self.session == nil, self.status != .connecting else { return }
                if found.isEmpty { self.userDisconnected = false }  // unplugged: auto-connect again next time
                let known = self.knownDevices
                self.devices = found
                self.newDevices = found.filter { !$0.inAccessoryMode && known[$0.serial] == nil }
                if self.autoConnect, !self.userDisconnected,
                   let c = found.first(where: { $0.inAccessoryMode || known[$0.serial] != nil }) {
                    self.connect(c)
                } else if case .error = self.status {
                    // keep showing the error until the next change
                } else {
                    self.status = .waiting
                }
            }
        }
    }

    /// Connects to `device` over USB, or over the dev transport when that's selected.
    func connect(_ device: AOATransport.Candidate?) {
        guard session == nil, status != .connecting else { return }
        guard permissionsOK else { status = .needsPermissions; return }
        userDisconnected = false
        status = .connecting
        let choice = transportChoice
        Task.detached(priority: .userInitiated) {
            do {
                let t: Transport
                switch choice {
                case .usb:
                    guard let device else { throw NSError(domain: "USB", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Android device found"]) }
                    t = try AOATransport.connect(serial: device.serial)
                case .adb:
                    guard let tcp = TCPTransport.connect() else { throw NSError(domain: "TCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not reach the tablet via adb forward"]) }
                    t = tcp
                }
                await self.startSession(t, serial: device?.serial)
            } catch {
                await MainActor.run {
                    Log.info("connect failed: \(error.localizedDescription)")
                    self.noteFailure()
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }

    private func startSession(_ t: Transport, serial: String?) async {
        let cfg = SessionConfig(mode: mode, refresh: refresh, bitrate: bitrate.bps, codec: .hevc,
                                frameCapBytes: t is AOATransport ? 160_000 : 250_000, idleRefinement: idleRefinement)
        let s = StreamSession(transport: t, config: cfg)
        s.onPeer = { name in
            DispatchQueue.main.async {
                self.status = .connected("\(name) via \(t.name.uppercased())")
                self.failures = 0
                self.nextAttempt = .distantPast
                // The tablet app answered: remember this device so it connects automatically next time.
                if let serial, !serial.isEmpty {
                    self.knownDevices[serial] = name
                    self.newDevices.removeAll { $0.serial == serial }
                }
            }
        }
        s.onEnded = { [weak self] reason in
            guard let self else { return }
            self.session = nil
            self.status = self.userDisconnected ? .waiting : .error("Disconnected: \(reason)")
            // Replug or a transient USB error: try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if case .error = self?.status { self?.status = .waiting }
                self?.usbChanged()
            }
        }
        session = s
        status = .connecting
        do {
            try await s.start()
        } catch {
            Log.info("session start failed: \(error.localizedDescription)")
            noteFailure()
            s.stop(reason: error.localizedDescription)
            status = .error(error.localizedDescription == "tablet app not responding"
                            ? "Install and open Tab Display on the tablet" : error.localizedDescription)
        }
    }

    private func goingToSleep(_ why: String) {
        Log.info("sleep: \(why)")
        asleep = true
        if session != nil {
            session?.stop(reason: "Mac is going to sleep")
            session = nil
            status = .waiting
        }
    }

    private func wokeUp(_ why: String) {
        Log.info("wake: \(why)")
        asleep = false
        failures = 0
        nextAttempt = Date().addingTimeInterval(1.5)  // give WindowServer a moment
    }

    func disconnect() {
        userDisconnected = true
        session?.stop(reason: "user disconnected")
        session = nil
        status = .waiting
    }

    private func applyDisplaySettings() {
        session?.update(mode: mode, refresh: refresh)
    }

    private func tick() {
        guard let s = session else { return }
        snapshot = s.stats.snapshot(pen: s.injector.penLatency)
        clockRTT = s.clock.valid ? Double(s.clock.rtt) / 1e6 : nil
        if Date().timeIntervalSince(lastStatsLog) > 2 {
            let dt = Date().timeIntervalSince(lastStatsLog)
            lastStatsLog = Date()
            let cap = Double(s.capturedCount - lastCaptured) / dt, sup = Double(s.supersededCount - lastSuperseded) / dt
            lastCaptured = s.capturedCount; lastSuperseded = s.supersededCount
            func f(_ d: Double?) -> String { d.map { String(format: "%.2f", $0) } ?? "-" }
            let stages = snapshot.stages.map { "\($0.name) \(f($0.p50))/\(f($0.p95))" }.joined(separator: "  ")
            Log.info("stats: \(Int(snapshot.fps)) fps \(String(format: "%.1f", snapshot.mbps)) Mbps drop \(snapshot.dropped) kf \(snapshot.keyframes) | \(stages) | pen \(f(snapshot.penP50))/\(f(snapshot.penP95)) | rtt \(f(clockRTT)) | cap \(Int(cap))/s superseded \(Int(sup))/s refined \(s.refinedCount) | vt \(f(s.encoder?.encodeDuration.percentile(0.5)))/\(f(s.encoder?.encodeDuration.percentile(0.95)))")
        }
    }

    /// "Sharpest (1280 × 800)" once a tablet is connected, otherwise just the name.
    func modeLabel(_ m: DisplayMode) -> String {
        guard let p = session?.peer, session != nil, case .connected = status else { return m.rawValue }
        let pts = m.points(panel: p.panel)
        return "\(m.rawValue) (\(pts.w) × \(pts.h))"
    }

    static let credits: NSAttributedString = {
        let text = """
        Use an Android tablet as a low-latency second display, with pen and touch.

        Includes libusb (https://libusb.info), licensed under the GNU Lesser General Public License 2.1. \
        libusb is dynamically linked (Contents/Frameworks/libusb-1.0.0.dylib) and can be replaced; \
        its license and source location are in Contents/Resources/Acknowledgements.txt.
        """
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
    }()

    func exportCSV() {
        guard let s = session else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tabdisplay-latency.csv"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? s.stats.csv().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
