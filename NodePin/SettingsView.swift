import SwiftUI

struct SettingsView: View {
    let wifi: WiFiService

    var body: some View {
        TabView {
            GeneralSettings(wifi: wifi).tabItem { Label("General", systemImage: "gearshape") }
            NodeNamingView(wifi: wifi).tabItem { Label("Nodes", systemImage: "wifi.router") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    let wifi: WiFiService
    @State private var launchAtLogin = LoginItem.isEnabled
    @AppStorage(DebugLog.defaultsKey) private var diagnostics = false

    var body: some View {
        @Bindable var store = wifi.store
        Form {
            Picker("Show access points on", selection: $store.bandFilter) {
                ForEach(BandFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Both lists each node's 5 GHz and 2.4 GHz radio as separate rows.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }

            Toggle("Diagnostics log", isOn: $diagnostics)
            if diagnostics {
                Text("Switch attempts are written to \(DebugLog.path). No passwords are logged.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Text("Switching uses the Wi-Fi password macOS already saved. The first switch shows a keychain prompt; choose Always Allow.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}
