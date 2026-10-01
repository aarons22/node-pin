import SwiftUI

struct SettingsView: View {
    let wifi: WiFiService
    let diagnostics: Diagnostics

    var body: some View {
        TabView {
            GeneralSettings(wifi: wifi).tabItem { Label("General", systemImage: "gearshape") }
            NodeNamingView(wifi: wifi).tabItem { Label("Nodes", systemImage: "wifi.router") }
            DiagnosticsSettings(diagnostics: diagnostics).tabItem { Label("Diagnostics", systemImage: "chart.xyaxis.line") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    let wifi: WiFiService
    @State private var launchAtLogin = LoginItem.isEnabled
    @AppStorage(DebugLog.defaultsKey) private var diagnostics = false
    @State private var savedSSIDs: [String] = []

    var body: some View {
        @Bindable var store = wifi.store
        Form {
            Picker("Show access points on", selection: $store.bandFilter) {
                ForEach(BandFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Both lists each node's 5 GHz and 2.4 GHz radio as separate rows.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Show node name in menu bar", isOn: $store.showNameInMenuBar)
            if !store.showNameInMenuBar {
                Text("The name still flashes briefly in the menu bar when you move to another node.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }

            Toggle("Diagnostics log", isOn: $diagnostics)
            if diagnostics {
                Text("Switch attempts are written to \(DebugLog.path). No passwords are logged.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section("Wi-Fi passwords") {
                Text("Switching uses the Wi-Fi password macOS already saved. The first switch shows a keychain prompt; choose Always Allow. If macOS won't share it (for example, without an admin account), NodePin asks for the password and keeps it in your login keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(savedSSIDs, id: \.self) { ssid in
                    LabeledContent(ssid) {
                        Button("Forget") {
                            FallbackWiFiPassword.forget(ssid: ssid)
                            savedSSIDs = FallbackWiFiPassword.savedSSIDs()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            savedSSIDs = FallbackWiFiPassword.savedSSIDs()
        }
    }
}

private struct DiagnosticsSettings: View {
    let diagnostics: Diagnostics
    @State private var newRoom = ""
    @State private var found: [String]?
    @State private var searching = false
    @State private var confirmClear = false

    var body: some View {
        @Bindable var d = diagnostics
        Form {
            Section {
                Toggle("Record diagnostics", isOn: $d.isEnabled)
                Text("Every 5 minutes NodePin notes the node, signal and link rate and pings the router over Wi-Fi. It never scans in the background. History is kept for 180 days.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Automatic speed test", selection: $d.speedTestMinutes) {
                    Text("Off").tag(0)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                    Text("Every 3 hours").tag(180)
                }
                .disabled(!d.isEnabled)
                Text("Speed tests run on the current node only and use the network at full speed for about 20 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Speed tests") {
                LabeledContent("LAN test server") {
                    HStack {
                        TextField("", text: $d.lanServer, prompt: Text("Bonjour name or host"))
                            .frame(maxWidth: 200)
                        Button(searching ? "Searching…" : "Find") { find() }.disabled(searching)
                    }
                }
                if let found {
                    if found.isEmpty {
                        Text("No servers found on this network.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Found", selection: $d.lanServer) {
                            ForEach(found, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                Text("Run `scripts/lan-test-server.sh install` on a Mac wired to your router (it uses macOS's built-in networkQuality server). Testing to it measures your Wi-Fi and mesh without your internet plan capping the result.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Toggle("Also test internet speed", isOn: $d.includeInternet)
            }

            Section("Rooms") {
                Text("Pick the room you're in from the menu so results from far away aren't blamed on a node.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(d.rooms, id: \.self) { room in
                    LabeledContent(room) { Button("Remove") { diagnostics.removeRoom(room) } }
                }
                HStack {
                    TextField("", text: $newRoom, prompt: Text("Office, Kitchen…"))
                        .onSubmit(addRoom)
                    Button("Add", action: addRoom).disabled(newRoom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("History") {
                LabeledContent("\(d.samples.count) samples") {
                    Button("Clear History…") { confirmClear = true }.disabled(d.samples.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all diagnostics history?", isPresented: $confirmClear) {
            Button("Delete History", role: .destructive) { diagnostics.clearHistory() }
        }
    }

    private func addRoom() {
        diagnostics.addRoom(newRoom)
        newRoom = ""
    }

    private func find() {
        searching = true
        Task {
            let names = await Probe.lanServers()
            found = names
            searching = false
            if diagnostics.lanServer.isEmpty, let first = names.first { diagnostics.lanServer = first }
        }
    }
}
