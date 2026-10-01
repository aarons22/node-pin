import ServiceManagement
import SwiftUI

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("NodePin: login item change failed: \(error.localizedDescription)") }
    }
}

struct MenuBarLabel: View {
    let location: LocationGate
    let wifi: WiFiService

    var body: some View {
        if !location.isAuthorized || wifi.bssidsHidden {
            Image(systemName: "exclamationmark.triangle")
        } else if let name = wifi.currentName {
            HStack(spacing: 4) { Image(systemName: "wifi.router"); Text(name) }
        } else if wifi.connection != nil {
            Image(systemName: "wifi.router")
        } else {
            // No slash variant exists for this symbol, so dim it instead.
            Image(systemName: "wifi.router").opacity(0.45)
        }
    }
}

/// The menu bar panel. A window-style extra (not an NSMenu) so it stays open on clicks and redraws
/// live as scans, signal levels and switches change.
struct MenuContent: View {
    let location: LocationGate
    let wifi: WiFiService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !location.isAuthorized || wifi.bssidsHidden {
                MenuRow { location.openSettings() } label: {
                    Label("Location access needed — Open Settings", systemImage: "exclamationmark.triangle")
                }
            } else {
                header
                Divider().padding(.vertical, 4)
                if let status = wifi.switchStatus {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.callout)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
                if wifi.rows.isEmpty {
                    Text(wifi.isScanning ? "Looking for nodes…" : "No nodes found")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                ForEach(wifi.rows) { row in nodeRow(row) }
                if let notice = wifi.notice {
                    Divider().padding(.vertical, 4)
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                }
            }
            Divider().padding(.vertical, 4)
            MenuRow {
                NSApp.activate()
                openWindow(id: "settings")
                dismiss()
            } label: { Text("Settings…") }
            .keyboardShortcut(",")
            MenuRow { NSApplication.shared.terminate(nil) } label: { Text("Quit NodePin") }
                .keyboardShortcut("q")
        }
        .padding(6)
        .frame(width: 300)
        .background(PanelVisibility { wifi.setMenuOpen($0) })
        .onAppear {
            wifi.refreshCurrent()
            wifi.setMenuOpen(true)
        }
        .onDisappear { wifi.setMenuOpen(false) }
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if let c = wifi.connection {
                    Text("Connected: \(wifi.currentName ?? BSSID.shortLabel(c.bssid))").font(.headline)
                    Text("\(dBm(c.rssi)) · \(c.is5GHz ? "5" : "2.4") GHz ch \(c.channel) · \(Int(c.txRate.rounded())) Mbps")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Not connected").font(.headline)
                }
            }
            Spacer()
            if wifi.isScanning {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Scanning").font(.caption).foregroundStyle(.secondary)
                }
                .help("Scanning for nodes")
            } else {
                Button { Task { await wifi.scan(force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(wifi.switchingTo != nil)
                .help(wifi.lastScan.map { "Rescan (last scan \($0.formatted(.relative(presentation: .named))))" } ?? "Rescan")
            }
        }
        .padding(.horizontal, 8).padding(.top, 4)
    }

    private func nodeRow(_ row: RadioRow) -> some View {
        let isCurrent = row.bssid == wifi.connection?.bssid
        let isTarget = wifi.switchingTo == row.bssid
        return MenuRow { pick(row) } label: {
            HStack(spacing: 8) {
                Group {
                    if isTarget { ProgressView().controlSize(.mini) }
                    else if isCurrent { Image(systemName: "checkmark") }
                    else { Color.clear }
                }
                .frame(width: 14)
                Text(wifi.title(for: row)).lineLimit(1)
                Spacer()
                Text(rowDetail(row, isTarget: isTarget))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .disabled(!row.isSwitchable || wifi.switchingTo != nil)
        .opacity(row.isSwitchable || isTarget ? 1 : 0.5)
    }

    private func rowDetail(_ row: RadioRow, isTarget: Bool) -> String {
        if isTarget { return "Connecting…" }
        guard row.isSwitchable, let rssi = row.rssi else { return "not visible" }
        return dBm(rssi)
    }

    private func dBm(_ v: Int) -> String { "\u{2212}\(abs(v)) dBm" }

    private func pick(_ row: RadioRow) {
        guard row.bssid != wifi.connection?.bssid else { return }
        Task { await wifi.switchTo(row) }
    }
}

/// A full-width, menu-item-looking button that highlights on hover.
private struct MenuRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(hovering && isEnabled ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Reports when the menu bar panel is shown or hidden. The panel window is reused between openings,
/// so onAppear alone isn't a reliable signal; key status is.
private struct PanelVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Tracker { Tracker(onChange: onChange) }
    func updateNSView(_ view: Tracker, context: Context) { view.onChange = onChange }

    final class Tracker: NSView {
        var onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            for (name, open) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(open) }
                })
            }
        }
    }
}
