import SwiftUI

@main
struct TabDisplayApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image(connected: isConnected))
        }
        .menuBarExtraStyle(.window)

        Window("Tab Display Latency", id: "latency") {
            LatencyView(model: model)
        }
    }

    private var isConnected: Bool {
        if case .connected = model.status { return true }
        return false
    }
}
