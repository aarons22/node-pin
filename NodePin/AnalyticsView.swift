import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Per-node history: a summary table, speed against signal (the placement question) and speed over time.
struct AnalyticsView: View {
    let diagnostics: Diagnostics
    @State private var range: TimeRange = .week
    @State private var room = ""
    @State private var metric: Metric = .lanDown
    @State private var hovered: Point?
    @State private var selectedDate: Date?

    enum TimeRange: String, CaseIterable, Identifiable {
        case day = "24 Hours", week = "7 Days", month = "30 Days", all = "All"
        var id: String { rawValue }
        var start: Date? {
            switch self {
            case .day: Date().addingTimeInterval(-86400)
            case .week: Date().addingTimeInterval(-7 * 86400)
            case .month: Date().addingTimeInterval(-30 * 86400)
            case .all: nil
            }
        }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case lanDown, lanUp, wanDown, wanUp, ping, linkRate
        var id: String { rawValue }
        var title: String {
            switch self {
            case .lanDown: "LAN download"
            case .lanUp: "LAN upload"
            case .wanDown: "Internet download"
            case .wanUp: "Internet upload"
            case .ping: "Router ping"
            case .linkRate: "Link rate"
            }
        }
        var unit: String { self == .ping ? "ms" : "Mbps" }
        func value(_ s: Sample) -> Double? {
            switch self {
            case .lanDown: s.lanDown
            case .lanUp: s.lanUp
            case .wanDown: s.wanDown
            case .wanUp: s.wanUp
            case .ping: s.pingMs
            case .linkRate: s.txRate
            }
        }
    }

    struct Point: Identifiable, Equatable {
        let id: Int
        let date: Date
        let node: String
        let rssi: Int
        let value: Double
        let room: String?
    }

    // MARK: Data

    private var filtered: [Sample] {
        let start = range.start
        return diagnostics.samples.filter { s in
            (start.map { s.date >= $0 } ?? true) && (room.isEmpty || s.room == room)
        }
    }

    /// Every node ever recorded, in a fixed order, so a node keeps its color when filters change.
    private var allNodes: [String] { Array(Set(diagnostics.samples.map(\.node))).sorted() }

    private var nodeNames: [String] { allNodes.map(diagnostics.nodeName) }

    private var points: [Point] {
        filtered.enumerated().compactMap { i, s in
            guard s.error?.contains("roamed") != true, let v = metric.value(s), v.isFinite else { return nil }
            return Point(id: i, date: s.date, node: diagnostics.nodeName(s.node), rssi: s.rssi, value: v, room: s.room)
        }
    }

    /// Median per node per hour (24-hour range) or day, drawn as the trend line.
    private var trend: [Point] {
        let cal = Calendar.current
        let unit: Calendar.Component = range == .day ? .hour : .day
        let buckets = Dictionary(grouping: points) { p in
            "\(p.node)|\(cal.dateInterval(of: unit, for: p.date)?.start.timeIntervalSince1970 ?? 0)"
        }
        return buckets.values.enumerated().compactMap { i, group in
            guard let first = group.first, let v = median(group.map(\.value)),
                  let start = cal.dateInterval(of: unit, for: first.date) else { return nil }
            return Point(id: i, date: start.start.addingTimeInterval(start.duration / 2), node: first.node,
                         rssi: 0, value: v, room: nil)
        }
        .sorted { $0.date < $1.date }
    }

    private var signalDomain: ClosedRange<Int> {
        let r = points.map(\.rssi)
        return ((r.min() ?? -90) - 3)...((r.max() ?? -30) + 3)
    }

    private var rooms: [String] {
        Array(Set(diagnostics.samples.compactMap(\.room)).union(diagnostics.rooms)).sorted()
    }

    // MARK: Layout

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(12)
            Divider()
            if diagnostics.samples.isEmpty {
                ContentUnavailableView("No diagnostics yet", systemImage: "chart.xyaxis.line",
                    description: Text("Turn on Record diagnostics in Settings → Diagnostics, or choose Test This Node in the menu."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        summary
                        signalChart
                        timeChart
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear(perform: pickDefaultMetric)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("Room", selection: $room) {
                Text("All rooms").tag("")
                ForEach(rooms, id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            Picker("Metric", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Spacer()
            Menu("Export") {
                Button("Export CSV…", action: exportCSV)
                Button("Show Data File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.fileURL])
                }
            }
            .fixedSize()
        }
    }

    // MARK: Summary table

    private var summary: some View {
        let groups = Dictionary(grouping: filtered, by: \.node)
        let keys = allNodes.filter { groups[$0] != nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Nodes").font(.headline)
            Text("Medians for the selected range and room. Speed tests only count samples where the Mac stayed on one node.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Node").gridColumnAlignment(.leading)
                    Text("Samples"); Text("Signal"); Text("Link"); Text("Ping"); Text("Loss")
                    Text("LAN ↓ / ↑"); Text("Internet ↓ / ↑")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(keys, id: \.self) { key in
                    let rows = groups[key]!.filter { $0.error?.contains("roamed") != true }
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(color(forNode: key)).frame(width: 8, height: 8)
                            Text(diagnostics.nodeName(key))
                        }
                        Text("\(rows.count)")
                        Text(median(rows.map { Double($0.rssi) }).map { "\u{2212}\(Int(abs($0).rounded())) dBm" } ?? "–")
                        Text(fmt(median(rows.map(\.txRate)), "Mbps"))
                        Text(fmt(median(rows.compactMap(\.pingMs)), "ms", digits: 1))
                        Text(fmt(median(rows.compactMap(\.lossPct)), "%", digits: 1))
                        Text(pair(rows.compactMap(\.lanDown), rows.compactMap(\.lanUp)))
                        Text(pair(rows.compactMap(\.wanDown), rows.compactMap(\.wanUp)))
                    }
                    .monospacedDigit()
                }
            }
            .font(.callout)
        }
    }

    // MARK: Charts

    private var signalChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(metric.title) vs. signal").font(.headline)
            Text("Signal is between this Mac and the node. A node whose points sit below the others at the same signal has a weak link back to the router: try moving it closer or wiring it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if points.isEmpty {
                noData
            } else {
                Chart {
                    ForEach(points) { p in
                        PointMark(x: .value("Signal (dBm)", p.rssi), y: .value(metric.unit, p.value))
                            .foregroundStyle(by: .value("Node", p.node))
                            .symbolSize(40)
                    }
                    if let h = hovered {
                        PointMark(x: .value("Signal (dBm)", h.rssi), y: .value(metric.unit, h.value))
                            .symbolSize(120)
                            .foregroundStyle(.clear)
                            .annotation(position: .top, spacing: 6) { tooltip(for: h) }
                    }
                }
                .chartForegroundStyleScale(domain: nodeNames, range: allNodes.map(color(forNode:)))
                .chartXScale(domain: signalDomain)
                .chartXAxisLabel("Signal (dBm), stronger to the right")
                .chartYAxisLabel(metric.unit)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard case .active(let loc) = phase, let frame = proxy.plotFrame else { hovered = nil; return }
                                let origin = geo[frame].origin
                                hovered = nearest(to: CGPoint(x: loc.x - origin.x, y: loc.y - origin.y), proxy: proxy)
                            }
                    }
                }
                .frame(height: 260)
            }
        }
    }

    private var timeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(metric.title) over time").font(.headline)
            Text("Line: \(range == .day ? "hourly" : "daily") median per node. Dots: individual samples.")
                .font(.caption).foregroundStyle(.secondary)
            if points.isEmpty {
                noData
            } else {
                Chart {
                    ForEach(points) { p in
                        PointMark(x: .value("Time", p.date), y: .value(metric.unit, p.value))
                            .foregroundStyle(by: .value("Node", p.node))
                            .symbolSize(14)
                            .opacity(0.5)
                    }
                    ForEach(trend) { t in
                        LineMark(x: .value("Time", t.date), y: .value(metric.unit, t.value), series: .value("Node", t.node))
                            .foregroundStyle(by: .value("Node", t.node))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let d = selectedDate, let p = points.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) {
                        RuleMark(x: .value("Time", p.date))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) { tooltip(for: p) }
                    }
                }
                .chartForegroundStyleScale(domain: nodeNames, range: allNodes.map(color(forNode:)))
                .chartXSelection(value: $selectedDate)
                .chartYAxisLabel(metric.unit)
                .frame(height: 220)
            }
        }
    }

    private var noData: some View {
        Text(metric == .lanDown || metric == .lanUp
             ? "No LAN speed tests in this range. Set a LAN test server in Settings → Diagnostics."
             : "No \(metric.title.lowercased()) data in this range.")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }

    private func tooltip(for p: Point) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.node).font(.caption.weight(.semibold))
            Text("\(fmt(p.value, metric.unit, digits: metric == .ping ? 1 : 0)) · \u{2212}\(abs(p.rssi)) dBm")
            Text([p.room, p.date.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
        }
        .font(.caption).monospacedDigit()
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func nearest(to loc: CGPoint, proxy: ChartProxy) -> Point? {
        var best: (Point, CGFloat)?
        for p in points {
            guard let pos = proxy.position(for: (x: p.rssi, y: p.value)) else { continue }
            let d = hypot(pos.x - loc.x, pos.y - loc.y)
            if d < 16, d < (best?.1 ?? .infinity) { best = (p, d) }
        }
        return best?.0
    }

    // MARK: Helpers

    /// Validated categorical palette (light / dark steps), assigned in fixed order by node key.
    private static let palette: [(UInt32, UInt32)] = [
        (0x2a78d6, 0x3987e5), (0xeb6834, 0xd95926), (0x1baf7a, 0x199e70), (0xeda100, 0xc98500),
        (0xe87ba4, 0xd55181), (0x008300, 0x008300), (0x4a3aa7, 0x9085e9), (0xe34948, 0xe66767),
    ]

    private func color(forNode key: String) -> Color {
        let i = allNodes.firstIndex(of: key) ?? 0
        guard i < Self.palette.count else { return .gray }
        let (light, dark) = Self.palette[i]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }

    private func median(_ v: [Double]) -> Double? {
        let s = v.filter(\.isFinite).sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private func fmt(_ v: Double?, _ unit: String, digits: Int = 0) -> String {
        guard let v else { return "–" }
        return "\(v.formatted(.number.precision(.fractionLength(digits)))) \(unit)"
    }

    private func pair(_ down: [Double], _ up: [Double]) -> String {
        guard let d = median(down) else { return "–" }
        return "\(Int(d.rounded())) / \(median(up).map { "\(Int($0.rounded()))" } ?? "–") Mbps"
    }

    private func pickDefaultMetric() {
        if !diagnostics.samples.contains(where: { $0.lanDown != nil }) {
            metric = diagnostics.samples.contains { $0.wanDown != nil } ? .wanDown : .ping
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "NodePin Diagnostics.csv"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? diagnostics.csv().write(to: url, atomically: true, encoding: .utf8)
    }
}
