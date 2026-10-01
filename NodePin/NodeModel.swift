import Foundation

/// One radio (BSSID) seen in a scan.
nonisolated struct ScannedRadio: Identifiable, Equatable {
    var id: String { bssid }
    let bssid: String
    let rssi: Int
    let channel: Int
    let is5GHz: Bool
}

/// One physical access point: its 5 GHz radio (the switch target) and its paired 2.4 GHz radio.
/// `id` is the 5 GHz BSSID, which is also the key nodes are named by.
nonisolated struct PhysicalNode: Identifiable, Equatable {
    let id: String
    var radio5: ScannedRadio?
    var radio24: ScannedRadio?
    var name: String?

    var bssid24: String { radio24?.bssid ?? BSSID.adjacent(id, by: 1) }
    /// Signal shown in the menu: the 5 GHz radio's, falling back to the 2.4 GHz one.
    var rssi: Int? { radio5?.rssi ?? radio24?.rssi }
    /// Can be switched to (its 5 GHz radio is in the latest scan).
    var isSwitchable: Bool { radio5 != nil }
}

nonisolated enum BandFilter: String, CaseIterable, Identifiable {
    case five, twoFour, both
    var id: String { rawValue }
    var title: String {
        switch self { case .five: "5 GHz"; case .twoFour: "2.4 GHz"; case .both: "Both" }
    }
}

/// One menu row: a single radio of a node.
nonisolated struct RadioRow: Identifiable, Equatable {
    let node: PhysicalNode
    let is5GHz: Bool
    var radio: ScannedRadio? { is5GHz ? node.radio5 : node.radio24 }
    var bssid: String { radio?.bssid ?? (is5GHz ? node.id : node.bssid24) }
    var id: String { bssid }
    var rssi: Int? { radio?.rssi }
    var isSwitchable: Bool { radio != nil }

    /// The radio rows of a single node that the band filter includes (5 GHz first).
    static func rows(for node: PhysicalNode, filter: BandFilter) -> [RadioRow] {
        switch filter {
        case .five: [RadioRow(node: node, is5GHz: true)]
        case .twoFour: [RadioRow(node: node, is5GHz: false)]
        case .both: [RadioRow(node: node, is5GHz: true), RadioRow(node: node, is5GHz: false)]
        }
    }
}

nonisolated enum BSSID {
    /// Lowercases and zero-pads each octet ("aa:bb:cc:dd:e:3" -> "aa:bb:cc:dd:0e:03").
    static func normalize(_ raw: String) -> String {
        raw.lowercased().split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }
            .joined(separator: ":")
    }

    private static func octets(_ b: String) -> [UInt8]? {
        let parts = normalize(b).split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return parts.count == 6 ? parts : nil
    }

    /// The BSSID whose last octet differs by `delta` (first five octets unchanged).
    static func adjacent(_ b: String, by delta: Int) -> String {
        guard var o = octets(b) else { return b }
        o[5] = UInt8(truncatingIfNeeded: Int(o[5]) + delta)
        return o.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Same first five octets and last octets differing by exactly one: the two radios of one node.
    static func arePaired(_ a: String, _ b: String) -> Bool {
        guard let x = octets(a), let y = octets(b), x[0..<5] == y[0..<5] else { return false }
        return abs(Int(x[5]) - Int(y[5])) == 1
    }

    /// "9e:33" style label for unnamed nodes.
    static func shortLabel(_ b: String) -> String {
        normalize(b).split(separator: ":").suffix(2).joined(separator: ":")
    }
}

nonisolated enum NodeGrouping {
    /// Pairs 5 GHz and 2.4 GHz radios into physical nodes. The band (not the BSSID number) decides
    /// which radio is which, since channels and BSSIDs change with hardware. A 2.4 GHz radio
    /// whose 5 GHz partner wasn't seen becomes a node keyed by its presumed 5 GHz BSSID.
    static func group(_ radios: [ScannedRadio]) -> [PhysicalNode] {
        let fives = radios.filter(\.is5GHz)
        var unpaired24 = radios.filter { !$0.is5GHz }
        var nodes: [PhysicalNode] = []
        for r5 in fives {
            var node = PhysicalNode(id: r5.bssid, radio5: r5)
            // Prefer the conventional "+1" partner if several 2.4 GHz radios sit next to it.
            let candidates = unpaired24.filter { BSSID.arePaired(r5.bssid, $0.bssid) }
            if let p = candidates.first(where: { $0.bssid == BSSID.adjacent(r5.bssid, by: 1) }) ?? candidates.first {
                node.radio24 = p
                unpaired24.removeAll { $0.bssid == p.bssid }
            }
            nodes.append(node)
        }
        for r24 in unpaired24 {
            nodes.append(PhysicalNode(id: BSSID.adjacent(r24.bssid, by: -1), radio24: r24))
        }
        return nodes
    }

    /// Scan results plus every saved-name node that wasn't seen (shown disabled), strongest first.
    static func merge(_ radios: [ScannedRadio], names: [String: String]) -> [PhysicalNode] {
        var nodes = group(radios)
        for i in nodes.indices { nodes[i].name = names[nodes[i].id] }
        for (key, name) in names where !nodes.contains(where: { $0.id == key }) {
            nodes.append(PhysicalNode(id: key, name: name))
        }
        return nodes.sorted {
            switch ($0.rssi, $1.rssi) {
            case let (a?, b?): return a == b ? $0.id < $1.id : a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return ($0.name ?? $0.id) < ($1.name ?? $1.id)
            }
        }
    }

    /// Rows to list for the chosen band filter. One band: one row per node, strongest first.
    /// Both: a 5 GHz and a 2.4 GHz row per node, nodes kept together.
    static func rows(_ nodes: [PhysicalNode], filter: BandFilter) -> [RadioRow] {
        switch filter {
        case .both:
            return nodes.flatMap { RadioRow.rows(for: $0, filter: .both) }
        case .five, .twoFour:
            let rows = nodes.map { RadioRow(node: $0, is5GHz: filter == .five) }
            return rows.sorted {
                switch ($0.rssi, $1.rssi) {
                case let (a?, b?): return a == b ? $0.id < $1.id : a > b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.id < $1.id
                }
            }
        }
    }

    /// Menu bar / header label for whichever radio we're currently on.
    static func displayName(forBSSID raw: String, names: [String: String]) -> String {
        let b = BSSID.normalize(raw)
        if let n = names[b] { return n }
        for delta in [-1, 1] { if let n = names[BSSID.adjacent(b, by: delta)], BSSID.arePaired(b, BSSID.adjacent(b, by: delta)) { return n } }
        return BSSID.shortLabel(b)
    }

    /// The node key (5 GHz BSSID) for a radio we're connected to, if we know it's a named node.
    static func nodeKey(forBSSID raw: String, in nodes: [PhysicalNode]) -> String? {
        let b = BSSID.normalize(raw)
        return nodes.first { $0.radio5?.bssid == b || $0.radio24?.bssid == b || $0.id == b || $0.bssid24 == b }?.id
    }
}
