import SwiftUI

/// One name per physical node (both radios share it), with a line per radio for the chosen band filter.
struct NodeNamingView: View {
    let wifi: WiFiService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(wifi.nodes) { node in
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: Binding(
                        get: { wifi.store.name(for: node.id) },
                        set: { wifi.store.setName($0, for: node.id) }))
                        .textFieldStyle(.roundedBorder)
                    ForEach(RadioRow.rows(for: node, filter: wifi.store.bandFilter)) { row in
                        radioLine(row)
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack {
                Button("Rescan") { Task { await wifi.scan(force: true) } }
                Spacer()
            }
            .padding(12)
        }
        .frame(minHeight: 280)
        .task { await wifi.scan() }
    }

    private func radioLine(_ row: RadioRow) -> some View {
        HStack(spacing: 8) {
            Text(row.is5GHz ? "5 GHz" : "2.4 GHz").frame(width: 48, alignment: .leading)
            Text(row.bssid).textSelection(.enabled)
            Spacer()
            if row.bssid == wifi.connection?.bssid { Text("connected").foregroundStyle(.green) }
            Text(row.rssi.map { "\u{2212}\(abs($0)) dBm" } ?? "not visible")
                .foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
        .font(.caption.monospaced())
    }
}
