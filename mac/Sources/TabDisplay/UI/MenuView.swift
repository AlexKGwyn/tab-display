import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarIcon.image(connected: isConnected)).foregroundStyle(isConnected ? Color.accentColor : .secondary)
                Text("Tab Display").font(.headline)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(statusColor).lineLimit(2).multilineTextAlignment(.trailing)
            }

            if !model.permissionsOK { permissions }

            if let w = model.versionWarning {
                Label(w.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            if isConnected {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latency  \(ms(model.snapshot.totalP50))  ·  p95 \(ms(model.snapshot.totalP95))")
                        .font(.system(.body, design: .monospaced))
                    Text("\(Int(model.snapshot.fps)) fps  ·  \(String(format: "%.0f", model.snapshot.mbps)) Mbps  ·  pen \(ms(model.snapshot.penP50))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if model.permissionsOK && model.session == nil {
                devicesSection
            }

            if model.canInstall && !model.installTargets.isEmpty && (model.session == nil || model.versionWarning?.tabletOutdated == true) {
                installSection
            }

            Divider()
            Picker("Display", selection: $model.mode) {
                ForEach(DisplayMode.allCases) { m in
                    Text(model.modeLabel(m)).tag(m)
                }
            }
            Picker("Quality", selection: $model.bitrate) {
                ForEach(BitratePreset.allCases) { Text("\($0.rawValue) (\($0.bps / 1_000_000) Mbps)").tag($0) }
            }
            Toggle("Connect automatically", isOn: $model.autoConnect)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Refresh", selection: $model.refresh) {
                        Text("Up to 120 Hz").tag(120)
                        Text("60 Hz").tag(60)
                    }
                    Toggle("Sharpen text when idle", isOn: $model.idleRefinement)
                    Picker("Link", selection: $model.transportChoice) {
                        ForEach(TransportChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("Latency details…") {
                        openWindow(id: "latency")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .padding(.top, 6)
            }

            Divider()
            HStack {
                if model.session != nil {
                    Button("Disconnect") { model.disconnect() }
                } else if model.transportChoice == .adb {
                    Button("Connect") { model.connect(nil) }.disabled(!model.permissionsOK || model.status == .connecting)
                }
                Spacer()
                Button("About") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: AppModel.credits])
                }
                Button("Quit") {
                    model.disconnect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.refreshInstallTargets() }
    }

    /// Debuggable tablets (USB debugging on): install or update the bundled Android app.
    private var installSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tablet app").font(.caption).foregroundStyle(.secondary)
            ForEach(model.installTargets) { t in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.device.name).lineLimit(1)
                        Text(installDetail(t.status)).font(.caption).foregroundStyle(installColor(t.status))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    installButton(t)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder private func installButton(_ t: InstallTarget) -> some View {
        switch t.status {
        case .notInstalled: Button("Install") { model.install(t) }
        case .outdated: Button("Update") { model.install(t) }
        case .needsAuthorization: Button("Allow…") { model.authorize(t) }
        case .failed: Button("Retry") { model.refreshInstallTargets() }
        case .installing(let p): ProgressView(value: p).frame(width: 60)
        case .checking, .waitingForAllow: ProgressView().controlSize(.small)
        default: EmptyView()
        }
    }

    private func installDetail(_ s: InstallTarget.Status) -> String {
        switch s {
        case .checking: return "Checking…"
        case .needsAuthorization: return "Allow this Mac to install apps (USB debugging)"
        case .waitingForAllow: return "Tap Allow on the tablet"
        case .notInstalled: return "Tab Display isn't installed"
        case .outdated(let v): return "Tab Display \(v) installed, \(AppInfo.version) available"
        case .current: return "Tab Display \(AppInfo.version) installed"
        case .newer(let v): return "Tab Display \(v) installed (newer than this Mac app)"
        case .installing: return "Installing \(AppInfo.version)…"
        case .installed: return "Installed \(AppInfo.version). Open Tab Display on the tablet."
        case .failed(let e): return e
        }
    }

    private func installColor(_ s: InstallTarget.Status) -> Color {
        switch s {
        case .failed: return .red
        case .outdated, .newer, .needsAuthorization: return .orange
        default: return .secondary
        }
    }

    private var isConnected: Bool {
        if case .connected = model.status { return true }
        return false
    }

    @ViewBuilder private var devicesSection: some View {
        if model.devices.isEmpty {
            Text("Connect an Android tablet with a USB cable and open Tab Display on it. To install the tablet app from this Mac, turn on USB debugging on the tablet.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.devices, id: \.self) { d in
                    HStack {
                        Image(systemName: "ipad.landscape")
                        Text(model.displayName(d)).lineLimit(1)
                        Spacer()
                        Button("Connect") { model.connect(d) }.disabled(model.status == .connecting)
                    }
                }
                if !model.newDevices.isEmpty {
                    Text("The tablet needs the Tab Display app. The first time, allow it to open for this accessory.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tab Display needs two permissions before it can connect.").font(.callout)
            HStack {
                Image(systemName: model.screenRecordingGranted ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(model.screenRecordingGranted ? .green : .red)
                Text("Screen Recording")
                Spacer()
                if !model.screenRecordingGranted { Button("Grant…") { model.requestScreenRecording() } }
            }
            HStack {
                Image(systemName: model.accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(model.accessibilityGranted ? .green : .red)
                Text("Accessibility (pen & touch)")
                Spacer()
                if !model.accessibilityGranted { Button("Grant…") { model.requestAccessibility() } }
            }
            Text("After granting Screen Recording, quit and reopen Tab Display.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    private var statusText: String {
        switch model.status {
        case .needsPermissions: return "Permissions needed"
        case .waiting: return model.devices.isEmpty ? "No tablet connected" : "Ready"
        case .connecting: return "Connecting…"
        case .connected(let s): return s
        case .error(let e): return e
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: return .secondary
        case .error: return .red
        case .connecting: return .orange
        default: return .secondary
        }
    }
}

func ms(_ v: Double?) -> String { v.map { String(format: "%.1f ms", $0) } ?? "–" }
