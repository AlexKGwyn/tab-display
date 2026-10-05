import Foundation
import SwiftUI

/// A debuggable tablet and what we know about Tab Display on it.
struct InstallTarget: Identifiable, Equatable {
    enum Status: Equatable {
        case checking
        case needsAuthorization      // USB debugging prompt not accepted for this Mac yet
        case waitingForAllow         // prompt shown on the tablet
        case notInstalled
        case outdated(String)        // installed version
        case current
        case newer(String)           // tablet has a newer app than the one bundled here
        case installing(Double)
        case installed
        case failed(String)
    }
    var device: ADBDevice
    var status: Status
    var id: String { device.serial }
}

extension AppModel {
    /// The Android app bundled with this Mac app.
    var canInstall: Bool { ADB.bundledAPK != nil }

    /// Re-scans debuggable tablets. Runs when the menu opens; cheap when nothing is plugged in.
    func refreshInstallTargets() {
        guard canInstall, !adbBusy, status != .connecting else { return }
        adbBusy = true
        adbOperations += 1
        Task.detached(priority: .utility) {
            let devices = ADB.devices()
            let targets = devices.map { d -> InstallTarget in
                let status = AppModel.status(of: d, allowPrompt: false)
                // Once we can talk to it, show the tablet's own name ("Galaxy Tab S9").
                var device = d
                if status != .needsAuthorization, let name = ADB.deviceName(d) {
                    device = ADBDevice(serial: d.serial, name: name, state: d.state, path: d.path)
                }
                return InstallTarget(device: device, status: status)
            }
            await MainActor.run {
                // Keep in-progress rows as they are.
                self.installTargets = targets.map { t in
                    if let old = self.installTargets.first(where: { $0.id == t.id }) {
                        switch old.status { case .installing, .waitingForAllow, .installed, .failed: return old; default: break }
                    }
                    return t
                }
                self.adbBusy = false
                self.adbOperations -= 1
            }
        }
    }

    nonisolated private static func status(of d: ADBDevice, allowPrompt: Bool) -> InstallTarget.Status {
        if d.state == .unauthorized { return .needsAuthorization }
        if d.state == .offline { return .failed("Tablet is offline; unplug and reconnect it") }
        do {
            guard let code = try ADB.installedVersionCode(d, allowPrompt: allowPrompt) else { return .notInstalled }
            let bundled = AppInfo.versionCode(AppInfo.version)
            if code < bundled { return .outdated(AppInfo.versionName(code: code)) }
            if code > bundled { return .newer(AppInfo.versionName(code: code)) }
            return .current
        } catch ADBError.unauthorized {
            return .needsAuthorization
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Asks the tablet to trust this Mac for USB debugging (shows "Allow USB debugging?").
    func authorize(_ t: InstallTarget) {
        setStatus(t.id, .waitingForAllow)
        adbOperations += 1
        Task.detached(priority: .userInitiated) {
            let s = AppModel.status(of: t.device, allowPrompt: true)
            await MainActor.run {
                self.adbOperations -= 1
                self.setStatus(t.id, s == .needsAuthorization ? .failed("Not allowed on the tablet") : s)
            }
        }
    }

    func install(_ t: InstallTarget) {
        guard let apk = ADB.bundledAPK else { return }
        setStatus(t.id, .installing(0))
        adbOperations += 1
        Task.detached(priority: .userInitiated) {
            defer { Task { @MainActor in self.adbOperations -= 1 } }
            do {
                try ADB.install(t.device, apk: apk) { p in
                    Task { @MainActor in self.setStatus(t.id, .installing(p)) }
                }
                Log.info("adb: installed Tab Display \(AppInfo.version) on \(t.device.name)")
                await MainActor.run { self.setStatus(t.id, .installed) }
            } catch {
                Log.info("adb: install failed: \(error.localizedDescription)")
                await MainActor.run { self.setStatus(t.id, .failed(error.localizedDescription)) }
            }
        }
    }

    private func setStatus(_ id: String, _ s: InstallTarget.Status) {
        if let i = installTargets.firstIndex(where: { $0.id == id }) { installTargets[i].status = s }
    }

    /// Mismatch between this app and the connected tablet's app, if any.
    var versionWarning: (text: String, tabletOutdated: Bool)? {
        guard let p = session?.peer, case .connected = status, !p.appVersion.isEmpty else { return nil }
        switch AppInfo.compare(p.appVersion, AppInfo.version) {
        case -1: return ("The tablet app (\(p.appVersion)) is older than this Mac app (\(AppInfo.version)).", true)
        case 1: return ("The tablet app (\(p.appVersion)) is newer. Update Tab Display on this Mac.", false)
        default: return nil
        }
    }
}
