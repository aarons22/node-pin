import AppKit
import CoreWLAN
import Observation
import UserNotifications

/// CoreWLAN wrapper: current connection, scan results, and switching to a node's 5 GHz radio.
@Observable
final class WiFiService {
    struct Connection: Equatable {
        let bssid: String
        let ssid: String?
        let rssi: Int
        let noise: Int
        let txRate: Double
        let channel: Int
        let is5GHz: Bool
    }

    let store: NodeStore
    private(set) var radios: [ScannedRadio] = []
    private(set) var connection: Connection?
    private(set) var switchingTo: String?
    /// What the in-progress switch is doing right now, for the menu's status line.
    private(set) var switchStatus: String?
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    /// Networks came back but none had a BSSID: Location permission is missing.
    private(set) var bssidsHidden = false
    /// Last problem, shown in the menu as well as a notification (which the user may have muted).
    private(set) var notice: String?

    @ObservationIgnored private var networks: [String: CWNetwork] = [:]
    @ObservationIgnored private var scannedSSID: String?
    @ObservationIgnored private var lastKnownSSID: String?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var liveUpdates: Task<Void, Never>?
    @ObservationIgnored private let events = EventBridge()

    var nodes: [PhysicalNode] { NodeGrouping.merge(radios, names: store.nodeNames) }
    var rows: [RadioRow] { NodeGrouping.rows(nodes, filter: store.bandFilter) }

    func title(for row: RadioRow) -> String {
        let name = row.node.name ?? BSSID.shortLabel(row.node.id)
        return store.bandFilter == .both ? "\(name) \u{00B7} \(row.is5GHz ? "5" : "2.4") GHz" : name
    }

    /// The network we're on, read live: nodes listed and switched to are always on this SSID.
    var currentSSID: String? { connection?.ssid }

    /// Friendly name (or last two BSSID octets) of the node we're on.
    var currentName: String? {
        guard let c = connection else { return nil }
        return NodeGrouping.displayName(forBSSID: c.bssid, names: store.nodeNames)
    }

    var currentNodeKey: String? {
        guard let c = connection else { return nil }
        return NodeGrouping.nodeKey(forBSSID: c.bssid, in: nodes) ?? BSSID.normalize(c.bssid)
    }

    init(store: NodeStore) {
        self.store = store
    }

    /// Starts roaming-event monitoring and runs the first scan. Call once at launch.
    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        SystemWiFiPassword.deleteLegacyCopy()
        events.onChange = { [weak self] in self?.refreshCurrent() }
        let client = CWWiFiClient.shared()
        client.delegate = events
        for type in [CWEventType.bssidDidChange, .linkDidChange, .linkQualityDidChange] {
            try? client.startMonitoringEvent(with: type)
        }
        refreshCurrent()
        Task { await scan() }
    }

    /// While the menu is open, keep the connection fresh and rescan (throttled) so signal levels move.
    func setMenuOpen(_ open: Bool) {
        if !open { liveUpdates?.cancel(); liveUpdates = nil; return }
        guard liveUpdates == nil else { return }
        liveUpdates = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshCurrent()
                // A switch runs its own scans; don't interrupt it.
                if self.switchingTo == nil { await self.scan() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshCurrent() {
        guard let iface = CWWiFiClient.shared().interface(), let bssid = iface.bssid() else {
            connection = nil
            return
        }
        let channel = iface.wlanChannel()
        let new = Connection(bssid: BSSID.normalize(bssid), ssid: iface.ssid(),
                             rssi: iface.rssiValue(), noise: iface.noiseMeasurement(),
                             txRate: iface.transmitRate(), channel: channel?.channelNumber ?? 0,
                             is5GHz: channel?.channelBand == .band5GHz)
        if new != connection { connection = new }
        if let ssid = new.ssid { lastKnownSSID = ssid }
        // Joined a different network: old scan results belong to the previous one.
        if let ssid = new.ssid, let scanned = scannedSSID, ssid != scanned {
            radios = []
            networks = [:]
            scannedSSID = nil
            lastScan = nil
        }
    }

    /// Scans at most once every 10 s unless forced (scans briefly interrupt traffic).
    /// If a scan is already running, waits for it instead of starting another.
    func scan(force: Bool = false) async {
        if let scanTask { await scanTask.value; return }
        if !force, let t = lastScan, Date().timeIntervalSince(t) < 10 { return }
        let task = Task { await performScan() }
        scanTask = task
        isScanning = true
        await task.value
        scanTask = nil
        isScanning = false
    }

    private func performScan() async {
        guard let iface = CWWiFiClient.shared().interface() else { notice = "No Wi-Fi interface"; return }
        guard let ssid = iface.ssid() else { notice = "Join a Wi-Fi network to see its nodes."; return }
        lastScan = Date()
        // Broadcast scan filtered by SSID: directed scans can return nothing on some APs.
        let result = await Task.detached { () -> Result<Set<CWNetwork>, Error> in
            Result { try iface.scanForNetworks(withName: nil) }
        }.value
        let found: Set<CWNetwork>
        switch result {
        case .success(let f): found = f
        case .failure(let e): notice = "Scan failed: \(describe(e))"; return
        }
        let ours = found.filter { $0.ssid == ssid }
        let withBSSID = found.filter { $0.bssid != nil }
        bssidsHidden = !found.isEmpty && withBSSID.isEmpty
        var map: [String: CWNetwork] = [:]
        for n in ours { if let b = n.bssid { map[BSSID.normalize(b)] = n } }
        networks = map
        scannedSSID = ssid
        radios = map.map { b, n in
            ScannedRadio(bssid: b, rssi: n.rssiValue, channel: n.wlanChannel?.channelNumber ?? 0,
                         is5GHz: n.wlanChannel?.channelBand == .band5GHz)
        }
        if !bssidsHidden { notice = nil }
        refreshCurrent()
    }

    /// Switches to one radio of a node, using the password macOS saved for the network.
    func switchTo(_ row: RadioRow) async {
        DebugLog.write("switch requested: target=\(row.bssid) current=\(connection?.bssid ?? "nil")")
        guard switchingTo == nil, row.isSwitchable, row.bssid != connection?.bssid else { return }
        let target = row.bssid
        switchingTo = target
        defer { switchingTo = nil; switchStatus = nil }
        let label = title(for: row)
        notice = nil
        switchStatus = "Connecting to \(label)…"

        // Read before any attempt: a failed association can drop the connection, and with it the SSID.
        guard let ssid = currentSSID ?? lastKnownSSID else { fail("Not connected to a Wi-Fi network."); return }
        lastKnownSSID = ssid

        // macOS refuses passwordless joins (tmpErr -3900), so use the password it already saved.
        let password: String
        switch await Task.detached(operation: { SystemWiFiPassword.lookup(ssid: ssid) }).value {
        case .success(let pw): password = pw
        case .failure(let e): fail(e.localizedDescription); return
        }

        // CWNetwork objects from an old scan can fail to associate, so refresh first.
        if lastScan.map({ Date().timeIntervalSince($0) > 20 }) ?? true {
            switchStatus = "Scanning for \(label)…"
            await scan(force: true)
        }

        for attempt in 0..<2 {
            guard let network = networks[target] else {
                if attempt == 1 { break }
                switchStatus = "Scanning for \(label)…"
                await scan(force: true)
                continue
            }
            guard let iface = CWWiFiClient.shared().interface() else { fail("No Wi-Fi interface"); return }
            DebugLog.write("associating to \(target) on ssid \(ssid)")
            switchStatus = attempt == 0 ? "Joining \(label)…" : "Retrying \(label)…"
            let error = await Task.detached { Self.associate(iface, to: network, password: password) }.value
            guard let error else {
                await confirm(target: target, label: label)
                return
            }
            DebugLog.write("associate threw: \(describe(error))")
            if attempt == 1 { fail("Couldn't switch to \(label): \(describe(error))"); return }
            switchStatus = "Scanning for \(label)…"
            await scan(force: true)
        }
        fail("\(label) isn't visible right now.")
    }

    /// The public `associate(to:password:)` lets macOS pick the best AP for the SSID and ignores which
    /// BSSID we chose. CoreWLAN's private `associateToNetwork:password:forceBSSID:remember:error:`
    /// honors it, so call that through the Objective-C runtime and fall back to the public call.
    nonisolated private static func associate(_ iface: CWInterface, to network: CWNetwork, password: String?) -> Error? {
        // For A/B testing: defaults write com.tinyvlogllc.NodePin usePublicAssociate -bool YES
        if UserDefaults.standard.bool(forKey: "usePublicAssociate") {
            DebugLog.write("using public associate (usePublicAssociate set)")
            return associatePublic(iface, to: network, password: password)
        }
        switch associatePrivate(iface, to: network, password: password) {
        case .ok: return nil
        case .failed(let error): return error
        case .missing:
            DebugLog.write("private forceBSSID call missing; using public associate")
            return associatePublic(iface, to: network, password: password)
        }
    }

    nonisolated private static func associatePublic(_ iface: CWInterface, to network: CWNetwork, password: String?) -> Error? {
        do { try iface.associate(to: network, password: password); return nil } catch { return error }
    }

    nonisolated private enum PrivateResult { case missing, ok, failed(Error) }

    nonisolated private static func associatePrivate(_ iface: CWInterface, to network: CWNetwork, password: String?) -> PrivateResult {
        let sel = NSSelectorFromString("associateToNetwork:password:forceBSSID:remember:error:")
        guard iface.responds(to: sel) else { return .missing }
        typealias Fn = @convention(c) (AnyObject, Selector, CWNetwork, NSString?, ObjCBool, ObjCBool,
                                       UnsafeMutablePointer<Unmanaged<NSError>?>?) -> ObjCBool
        let fn = unsafeBitCast(iface.method(for: sel), to: Fn.self)
        var err: Unmanaged<NSError>?
        let ok = fn(iface, sel, network, password.map { $0 as NSString }, ObjCBool(true), ObjCBool(false), &err)
        if ok.boolValue { return .ok }
        return .failed(err?.takeUnretainedValue() ?? NSError(domain: "NodePin", code: -1,
                                                             userInfo: [NSLocalizedDescriptionKey: "Association failed"]))
    }

    /// Waits for the Mac to actually land on the target BSSID rather than trusting "no error".
    private func landed(on target: String, seconds: Double) async -> Bool {
        for _ in 0..<Int(seconds * 2) {
            refreshCurrent()
            Self.logRadioState("poll", target: target)
            if connection?.bssid == target { notice = nil; return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        refreshCurrent()
        return connection?.bssid == target
    }

    /// Diagnostics: the BSSID as read by the shared client and by a brand-new client, plus signal.
    nonisolated private static func logRadioState(_ tag: String, target: String) {
        let shared = CWWiFiClient.shared().interface()
        let fresh = CWWiFiClient().interface()
        DebugLog.write("\(tag): target=\(target) shared=\(shared?.bssid() ?? "nil") fresh=\(fresh?.bssid() ?? "nil") rssi=\(fresh?.rssiValue() ?? 0) ch=\(fresh?.wlanChannel()?.channelNumber ?? 0)")
    }

    private func confirm(target: String, label: String) async {
        switchStatus = "Waiting for \(label) to take over…"
        if await landed(on: target, seconds: 6) { return }
        guard let c = connection else { fail("Asked for \(label), but the Mac isn't connected."); return }
        let actual = NodeGrouping.displayName(forBSSID: c.bssid, names: store.nodeNames)
        let targetRSSI = radios.first { $0.bssid == target }?.rssi
        let signals = targetRSSI.map { " (\(label) \($0) dBm, \(actual) \(c.rssi) dBm)" } ?? ""
        DebugLog.write("steered back\(signals)")
        fail("Moved back to \(actual): it has the stronger signal.")
    }

    private func fail(_ text: String) {
        DebugLog.write("FAIL: \(text)")
        notice = text
        let content = UNMutableNotificationContent()
        content.title = "NodePin"
        content.body = text
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func describe(_ error: Error) -> String {
        "\(error.localizedDescription) (\((error as NSError).code))"
    }
}

/// Receives CoreWLAN events (on arbitrary threads) and hops to the main actor.
private final class EventBridge: NSObject, CWEventDelegate, @unchecked Sendable {
    @MainActor var onChange: (() -> Void)?

    private func fire() { Task { @MainActor in self.onChange?() } }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) { fire() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { fire() }
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) { fire() }
}
