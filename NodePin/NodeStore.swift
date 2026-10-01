import Foundation
import Observation

/// Persisted settings: band filter, menu bar name visibility and node names keyed by lowercased 5 GHz BSSID.
@Observable
final class NodeStore {
    var bandFilter: BandFilter { didSet { defaults.set(bandFilter.rawValue, forKey: "bandFilter") } }
    /// When off, the menu bar shows only the icon and briefly flashes the name after a node change.
    var showNameInMenuBar: Bool { didSet { defaults.set(showNameInMenuBar, forKey: "showNameInMenuBar") } }
    private(set) var nodeNames: [String: String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateFromEeroPin(into: defaults)
        bandFilter = defaults.string(forKey: "bandFilter").flatMap(BandFilter.init) ?? .five
        showNameInMenuBar = defaults.object(forKey: "showNameInMenuBar") as? Bool ?? true
        nodeNames = defaults.dictionary(forKey: "nodeNames") as? [String: String] ?? [:]
    }

    func name(for key: String) -> String { nodeNames[BSSID.normalize(key)] ?? "" }

    func setName(_ name: String, for key: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let k = BSSID.normalize(key)
        if trimmed.isEmpty { nodeNames.removeValue(forKey: k) } else { nodeNames[k] = trimmed }
        defaults.set(nodeNames, forKey: "nodeNames")
    }

    /// One-time copy of settings saved under the app's old bundle ID (com.tinyvlogllc.EeroPin).
    /// Keys already set under the new ID win, so this never overwrites anything.
    private static func migrateFromEeroPin(into defaults: UserDefaults) {
        let doneKey = "migratedFromEeroPin"
        guard !defaults.bool(forKey: doneKey),
              let old = UserDefaults(suiteName: "com.tinyvlogllc.EeroPin") else { return }
        for key in ["nodeNames", "bandFilter", DebugLog.defaultsKey, "usePublicAssociate"]
        where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: doneKey)
    }
}
