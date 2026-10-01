import AppKit
import Observation

/// One diagnostics measurement taken on whichever node the Mac was on. Throughput is in Mbps.
/// Signal is recorded with every sample so speed can be compared at equal signal: a node that is
/// slow even with a strong signal has a weak link back to the router.
nonisolated struct Sample: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case passive, speedTest }
    let date: Date
    let kind: Kind
    let ssid: String?
    /// Node key (5 GHz BSSID), the same key node names use.
    let node: String
    let bssid: String
    let is5GHz: Bool
    let channel: Int
    let rssi: Int
    let noise: Int
    let txRate: Double
    let room: String?
    var pingMs: Double?
    var jitterMs: Double?
    var lossPct: Double?
    var lanDown: Double?
    var lanUp: Double?
    var lanRPM: Double?
    var wanDown: Double?
    var wanUp: Double?
    var wanRPM: Double?
    var error: String?
}

/// Runs the command-line probes bound to the Wi-Fi interface, so a wired connection can't skew them.
nonisolated enum Probe {
    struct Ping { let avg, jitter, loss: Double }
    struct Throughput { let down, up, rpm: Double }

    static let lanServerPort = 4443

    /// The router address DHCP gave the Wi-Fi interface.
    static func router(interface: String) async -> String? {
        let out = await run("/usr/sbin/ipconfig", ["getoption", interface, "router"], timeout: 5)
        let ip = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.isEmpty ? nil : ip
    }

    /// 20 pings over about 4 s. The router is the eero gateway, so from a satellite this crosses the backhaul.
    static func ping(_ host: String, interface: String) async -> Ping? {
        let out = await run("/sbin/ping", ["-c", "20", "-i", "0.2", "-t", "10", "-b", interface, host], timeout: 15)
        guard let lossLine = out.split(separator: "\n").first(where: { $0.contains("packet loss") }),
              let loss = lossLine.split(separator: ",").first(where: { $0.contains("packet loss") })
                .flatMap({ Double($0.trimmingCharacters(in: .whitespaces).split(separator: "%")[0]) })
        else { return nil }
        // "round-trip min/avg/max/stddev = 0.594/0.723/0.872/0.111 ms" (missing when every ping was lost)
        let stats = out.split(separator: "\n").first { $0.hasPrefix("round-trip") }?
            .split(separator: "=").last?.split(separator: " ").first?.split(separator: "/").compactMap { Double($0) }
        guard let stats, stats.count == 4 else { return Ping(avg: .nan, jitter: .nan, loss: loss) }
        return Ping(avg: stats[1], jitter: stats[3], loss: loss)
    }

    /// macOS's `networkQuality`. `server` nil tests to Apple's servers (internet). Otherwise it is a
    /// Bonjour name or a host running `networkQuality -S 4443` on the LAN.
    static func throughput(interface: String, server: String?) async -> Throughput? {
        var args = ["-c", "-M", "10", "-I", interface]
        if let server {
            if server.contains(".") || server.contains(":") {
                let host = server.contains(":") ? server : "\(server):\(lanServerPort)"
                args += ["-C", "https://\(host)/config", "-k"]
            } else {
                args += ["-B", server]
            }
        }
        let out = await run("/usr/bin/networkQuality", args, timeout: 40)
        guard let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let down = json["dl_throughput"] as? Double, let up = json["ul_throughput"] as? Double,
              down > 0 || up > 0
        else { return nil }
        return Throughput(down: down / 1e6, up: up / 1e6, rpm: json["responsiveness"] as? Double ?? 0)
    }

    /// Names of `networkQuality` servers advertised over Bonjour on the LAN.
    static func lanServers() async -> [String] {
        let out = await run("/usr/bin/networkQuality", ["-b"], timeout: 10)
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let dashes = lines.firstIndex(where: { $0.hasPrefix("---") }) else { return [] }
        return lines[(dashes + 1)...].filter { !$0.isEmpty }
    }

    /// Stdout of a command, or "" if it can't start. Killed after `timeout` seconds.
    private static func run(_ path: String, _ args: [String], timeout: Double) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

/// Opt-in per-node history: a ping every 5 minutes, scheduled speed tests on the current node, and
/// on-demand tests of this node or every node. Never scans in the background; only "Test All Nodes"
/// switches, and it returns to the starting node afterwards.
@Observable
final class Diagnostics {
    static let sampleInterval: Duration = .seconds(300)
    /// Older samples are dropped at launch.
    static let retentionDays = 180.0

    let wifi: WiFiService
    private(set) var samples: [Sample] = []
    private(set) var status: String?
    private(set) var isTesting = false

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "diagEnabled"); restartLoop() } }
    /// Minutes between automatic speed tests of the current node; 0 = manual only.
    var speedTestMinutes: Int { didSet { defaults.set(speedTestMinutes, forKey: "diagSpeedTestMinutes") } }
    var includeInternet: Bool { didSet { defaults.set(includeInternet, forKey: "diagIncludeInternet") } }
    /// Bonjour name or host of a wired Mac running `networkQuality -S 4443`. Empty = no LAN test.
    var lanServer: String { didSet { defaults.set(lanServer, forKey: "diagLANServer") } }
    /// Where the Mac is right now. Tagged on every sample so "far from the node" can be told apart
    /// from "the node is badly placed".
    var room: String { didSet { defaults.set(room, forKey: "diagRoom") } }
    private(set) var rooms: [String]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var manualTest: Task<Void, Never>?
    @ObservationIgnored private var lastSpeedTest: Date?

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NodePin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.jsonl")
    }()

    init(wifi: WiFiService, defaults: UserDefaults = .standard) {
        self.wifi = wifi
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "diagEnabled")
        speedTestMinutes = defaults.object(forKey: "diagSpeedTestMinutes") as? Int ?? 60
        includeInternet = defaults.object(forKey: "diagIncludeInternet") as? Bool ?? true
        lanServer = defaults.string(forKey: "diagLANServer") ?? ""
        room = defaults.string(forKey: "diagRoom") ?? ""
        rooms = defaults.stringArray(forKey: "diagRooms") ?? []
        samples = Self.load()
        lastSpeedTest = samples.last { $0.kind == .speedTest }?.date
        restartLoop()
    }

    var lastSample: Sample? { samples.last }

    func addRoom(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !rooms.contains(n) else { return }
        rooms.append(n)
        defaults.set(rooms, forKey: "diagRooms")
    }

    func removeRoom(_ name: String) {
        rooms.removeAll { $0 == name }
        defaults.set(rooms, forKey: "diagRooms")
        if room == name { room = "" }
    }

    func nodeName(_ key: String) -> String { wifi.store.nodeNames[key] ?? BSSID.shortLabel(key) }

    // MARK: - Running tests

    private func restartLoop() {
        loop?.cancel()
        loop = nil
        guard isEnabled else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = Double(self.speedTestMinutes * 60)
                let due = self.speedTestMinutes > 0
                    && self.lastSpeedTest.map { Date().timeIntervalSince($0) >= interval } ?? true
                if !self.isTesting, self.wifi.switchingTo == nil {
                    self.isTesting = true
                    await self.record(speedTest: due)
                    self.isTesting = false
                    self.status = nil
                }
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    /// Ping plus LAN and internet speed tests on the node the Mac is on now.
    func testCurrentNode() {
        startManual { [weak self] in await self?.record(speedTest: true) }
    }

    /// Switches to each visible node's 5 GHz radio in turn and tests it from where the Mac sits,
    /// then goes back. One room, every node: the cleanest comparison of the nodes themselves.
    func testAllNodes() {
        startManual { [weak self] in
            guard let self else { return }
            self.status = "Scanning for nodes…"
            await self.wifi.scan(force: true)
            let origin = self.wifi.connection?.bssid
            let targets = self.wifi.nodes.filter(\.isSwitchable)
            var skipped: [String] = []
            for (i, node) in targets.enumerated() {
                guard !Task.isCancelled else { break }
                let name = self.nodeName(node.id)
                let row = RadioRow(node: node, is5GHz: true)
                if self.wifi.connection?.bssid != row.bssid {
                    self.status = "\(i + 1)/\(targets.count): switching to \(name)…"
                    await self.wifi.switchTo(row)
                    guard self.wifi.connection?.bssid == row.bssid else { skipped.append(name); continue }
                    // Let DHCP and the new link settle before measuring.
                    try? await Task.sleep(for: .seconds(3))
                }
                await self.record(speedTest: true, prefix: "\(i + 1)/\(targets.count) \(name): ")
            }
            if let origin, self.wifi.connection?.bssid != origin,
               let node = self.wifi.nodes.first(where: { $0.radio5?.bssid == origin || $0.radio24?.bssid == origin }) {
                self.status = "Returning to \(self.nodeName(node.id))…"
                await self.wifi.switchTo(RadioRow(node: node, is5GHz: node.radio5?.bssid == origin))
            }
            if !skipped.isEmpty {
                DebugLog.write("diagnostics: couldn't stay on \(skipped.joined(separator: ", "))")
            }
        }
    }

    func cancel() {
        manualTest?.cancel()
    }

    private func startManual(_ work: @escaping () async -> Void) {
        guard !isTesting, wifi.switchingTo == nil else { return }
        isTesting = true
        manualTest = Task { [weak self] in
            await work()
            self?.isTesting = false
            self?.status = nil
            self?.manualTest = nil
        }
    }

    private func record(speedTest: Bool, prefix: String = "") async {
        wifi.refreshCurrent()
        guard let c = wifi.connection, let node = wifi.currentNodeKey, let iface = wifi.interfaceName else { return }
        var s = Sample(date: Date(), kind: speedTest ? .speedTest : .passive, ssid: c.ssid, node: node,
                       bssid: c.bssid, is5GHz: c.is5GHz, channel: c.channel, rssi: c.rssi, noise: c.noise,
                       txRate: c.txRate, room: room.isEmpty ? nil : room)
        var problems: [String] = []
        status = prefix + "Pinging the router…"
        if let router = await Probe.router(interface: iface), let p = await Probe.ping(router, interface: iface) {
            s.pingMs = p.avg.isNaN ? nil : p.avg
            s.jitterMs = p.jitter.isNaN ? nil : p.jitter
            s.lossPct = p.loss
        } else {
            problems.append("ping failed")
        }
        if speedTest, !Task.isCancelled {
            wifi.holdScans = true
            defer { wifi.holdScans = false }
            let server = lanServer.trimmingCharacters(in: .whitespaces)
            if !server.isEmpty {
                status = prefix + "Testing LAN speed…"
                if let t = await Probe.throughput(interface: iface, server: server) {
                    s.lanDown = t.down; s.lanUp = t.up; s.lanRPM = t.rpm
                } else {
                    problems.append("LAN server \(server) unreachable")
                }
            }
            if includeInternet, !Task.isCancelled {
                status = prefix + "Testing internet speed…"
                if let t = await Probe.throughput(interface: iface, server: nil) {
                    s.wanDown = t.down; s.wanUp = t.up; s.wanRPM = t.rpm
                } else {
                    problems.append("internet test failed")
                }
            }
            lastSpeedTest = Date()
        }
        // macOS may roam mid-test; the numbers then mix two nodes.
        if let now = wifi.connection?.bssid, now != c.bssid, !BSSID.arePaired(now, c.bssid) {
            problems.append("roamed to \(nodeName(wifi.currentNodeKey ?? now)) during the test")
        }
        if !problems.isEmpty {
            s.error = problems.joined(separator: "; ")
            DebugLog.write("diagnostics: \(s.error!)")
        }
        append(s)
    }

    // MARK: - Storage (JSON lines in Application Support)

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }

    private static func load() -> [Sample] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let all = data.split(separator: UInt8(ascii: "\n")).compactMap { try? d.decode(Sample.self, from: Data($0)) }
        let cutoff = Date().addingTimeInterval(-retentionDays * 86400)
        let kept = all.filter { $0.date >= cutoff }
        if kept.count != all.count { rewrite(kept) }
        return kept
    }

    private static func rewrite(_ samples: [Sample]) {
        let e = encoder()
        let text = samples.compactMap { try? e.encode($0) }.map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
        try? Data(text.utf8).write(to: fileURL, options: .atomic)
    }

    private func append(_ s: Sample) {
        samples.append(s)
        guard var line = try? Self.encoder().encode(s) else { return }
        line.append(UInt8(ascii: "\n"))
        if let h = try? FileHandle(forWritingTo: Self.fileURL) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: Self.fileURL)
        }
    }

    func clearHistory() {
        samples = []
        lastSpeedTest = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    /// CSV of every sample, for a spreadsheet.
    func csv() -> String {
        let header = "date,kind,ssid,node,node_name,bssid,band,channel,rssi,noise,link_mbps,room,ping_ms,jitter_ms,loss_pct,lan_down,lan_up,lan_rpm,wan_down,wan_up,wan_rpm,error"
        let f = ISO8601DateFormatter()
        func n(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        func q(_ v: String?) -> String { "\"\((v ?? "").replacingOccurrences(of: "\"", with: "\"\""))\"" }
        let rows = samples.map { s in
            [f.string(from: s.date), s.kind.rawValue, q(s.ssid), s.node, q(nodeName(s.node)), s.bssid,
             s.is5GHz ? "5" : "2.4", "\(s.channel)", "\(s.rssi)", "\(s.noise)", n(s.txRate), q(s.room),
             n(s.pingMs), n(s.jitterMs), n(s.lossPct), n(s.lanDown), n(s.lanUp), n(s.lanRPM),
             n(s.wanDown), n(s.wanUp), n(s.wanRPM), q(s.error)].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}
