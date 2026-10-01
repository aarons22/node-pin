import SwiftUI

@main struct NodePinApp: App {
    @State private var location: LocationGate
    @State private var wifi: WiFiService
    @State private var diagnostics: Diagnostics
    private let updater = Updater()

    init() {
        let gate = LocationGate()
        let service = WiFiService(store: NodeStore())
        gate.onAuthorizationChange = {
            service.refreshCurrent()
            Task { await service.scan(force: true) }
        }
        service.start()
        _location = State(initialValue: gate)
        _wifi = State(initialValue: service)
        _diagnostics = State(initialValue: Diagnostics(wifi: service))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(location: location, wifi: wifi, diagnostics: diagnostics, updater: updater)
        } label: {
            MenuBarLabel(location: location, wifi: wifi)
        }
        .menuBarExtraStyle(.window)

        Window("NodePin Settings", id: "settings") {
            SettingsView(wifi: wifi, diagnostics: diagnostics)
        }
        .windowResizability(.contentSize)

        Window("NodePin Analytics", id: "analytics") {
            AnalyticsView(diagnostics: diagnostics)
        }
        .defaultSize(width: 900, height: 720)
    }
}
