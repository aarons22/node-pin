import SwiftUI

@main struct NodePinApp: App {
    @State private var location: LocationGate
    @State private var wifi: WiFiService

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
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(location: location, wifi: wifi)
        } label: {
            MenuBarLabel(location: location, wifi: wifi)
        }
        .menuBarExtraStyle(.window)

        Window("NodePin Settings", id: "settings") {
            SettingsView(wifi: wifi)
        }
        .windowResizability(.contentSize)
    }
}
