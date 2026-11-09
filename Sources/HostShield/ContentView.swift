import SwiftUI
import Charts
import HostShieldCore

enum Section: String, CaseIterable, Identifiable {
    case overview = "Protection", traffic = "Traffic", filters = "Filters", rules = "Allow & Block", check = "Check a Domain", activity = "Activity"
    var id: String { rawValue }
    static let main: [Section] = [.overview, .traffic, .filters, .rules, .check]
    static let footer: [Section] = [.activity]

    var symbol: String {
        switch self {
        case .overview: "shield.lefthalf.filled"
        case .traffic: "chart.bar.xaxis"
        case .filters: "line.3.horizontal.decrease.circle"
        case .rules: "hand.raised"
        case .check: "magnifyingglass"
        case .activity: "clock.arrow.circlepath"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: ""
        case .traffic: "Every DNS lookup on this Mac, as it happens."
        case .filters: "Choose what Ad-Owl blocks across every app on this Mac."
        case .rules: "Sites that must always work, and extra domains to block."
        case .check: "See whether a domain is blocked, and why."
        case .activity: "Updates, changes and errors."
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Section = Section(rawValue: ProcessInfo.processInfo.environment["ADOWL_SECTION"] ?? "") ?? .overview

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection)
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1).ignoresSafeArea()
            ZStack {
                switch selection {
                case .overview: OverviewView()
                case .traffic: Page(title: selection.rawValue, subtitle: selection.subtitle) { TrafficView() }
                case .filters: Page(title: selection.rawValue, subtitle: selection.subtitle) { FiltersView() }
                case .rules: Page(title: selection.rawValue, subtitle: selection.subtitle) { RulesView() }
                case .check: Page(title: selection.rawValue, subtitle: selection.subtitle) { CheckView() }
                case .activity: Page(title: selection.rawValue, subtitle: selection.subtitle) { ActivityView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selection != .overview { StatusBar() }
            }
            .overlay(alignment: .topTrailing) {
                Button { Task { await model.updateLists() } } label: {
                    Label("Update Lists", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PillButtonStyle())
                .help("Download the latest filter lists")
                .disabled(model.busy != nil)
                .padding(.top, 12).padding(.trailing, 16)
            }
        }
        .background(AppBackground())
        .tint(Color(hex: 0xE15BF5))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var selection: Section

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Section.main) { item($0) }
            Spacer()
            ForEach(Section.footer) { item($0) }
            SettingsLink {
                row(symbol: "gearshape", title: "Settings", selected: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.top, 52).padding(.bottom, 16)
        .frame(width: 220)
        .background(Color.black.opacity(0.16).ignoresSafeArea())
    }

    private func item(_ s: Section) -> some View {
        Button { selection = s } label: { row(symbol: s.symbol, title: s.rawValue, selected: s == selection) }
            .buttonStyle(.plain)
    }

    private func row(symbol: String, title: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 22)
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
        .padding(.horizontal, 12).frame(height: 40)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12)))
            }
        }
        .contentShape(Rectangle())
    }
}

/// Bottom bar on secondary pages: busy indicator, or a prompt to apply pending changes.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let busy = model.busy {
            bar { ProgressView().controlSize(.small); Text(busy); Spacer() }
        } else {
            switch model.protection {
            case .outdated(_, let desired):
                bar {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Owl.amber)
                    Text("Changes not applied yet — the hosts file will block \(desired.formatted()) domains.")
                    Spacer()
                    Button("Apply Changes") { Task { await model.apply() } }.buttonStyle(.borderedProminent)
                }
            case .switchPending(let m):
                bar {
                    Image(systemName: "arrow.left.arrow.right.circle.fill").foregroundStyle(Owl.amber)
                    Text(m == .dns ? "Switch from the hosts file to the DNS filter?" : "Switch from the DNS filter to the hosts file?")
                    Spacer()
                    Button("Switch Now") { Task { await model.apply() } }.buttonStyle(.borderedProminent)
                }
            case .removed:
                bar {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(model.config.method == .dns ? "The DNS filter is no longer in effect." : "Blocking was switched off outside Ad-Owl.")
                    Spacer()
                    Button("Turn Back On") { Task { await model.apply() } }.buttonStyle(.borderedProminent)
                }
            default: EmptyView()
            }
        }
    }

    private func bar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8, content: content)
            .font(.system(size: 13))
            .glassCard(padding: 12)
            .padding(.horizontal, 24).padding(.bottom, 16)
    }
}

// MARK: - Protection (main screen)

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 36)
            HStack(spacing: 44) {
                OwlArt().frame(width: 270, height: 270)
                VStack(alignment: .leading, spacing: 12) {
                    Text(heroTitle).font(.system(size: 40, weight: .light))
                    Text(heroDetail)
                        .font(.system(size: 14)).foregroundStyle(Owl.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    features.padding(.top, 10)
                }
                .frame(maxWidth: 400, alignment: .leading)
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 20)
            controls.padding(.horizontal, 32)
            VStack(spacing: 8) {
                orb
                Text(model.busy ?? " ").font(.system(size: 12)).foregroundStyle(Owl.secondaryText)
            }
            .padding(.top, 22).padding(.bottom, 12)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("Ad-Owl").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                .padding(.trailing, 20).padding(.bottom, 16)
        }
    }

    // Enabled filters, shown as a feature list.
    @ViewBuilder private var features: some View {
        let on = BlockCategory.allCases.filter { model.config.enabled.contains($0) }
        if on.isEmpty {
            Text("No filters are on. Pick some under Filters.").font(.system(size: 13)).foregroundStyle(Owl.secondaryText)
        }
        ForEach(on) { c in
            HStack(spacing: 14) {
                IconTile(symbol: c.symbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title).font(.system(size: 14, weight: .semibold))
                    Text("\((model.domainCount(c) ?? 0).formatted()) domains")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Method", selection: Binding(get: { model.config.method }, set: { model.setMethod($0) })) {
                    Text("Hosts file").tag(BlockMethod.hosts)
                    Text("DNS filter (live stats)").tag(BlockMethod.dns)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                .disabled(model.busy != nil)
                Text(model.config.method == .hosts
                     ? "Edits /etc/hosts once. Can't count what gets blocked."
                     : "Local resolver with live stats. Keep Ad-Owl open; closing the window is fine.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            ForEach(stats, id: \.0) { label, value in
                VStack(spacing: 2) {
                    Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                    Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(minWidth: 84)
            }
        }
        .glassCard(padding: 14)
    }

    private var stats: [(String, String)] {
        let s = model.snapshot
        if model.config.method == .dns, model.proxyRunning {
            return [("Blocked today", s.blockedToday.formatted()),
                    ("Queries today", s.totalToday.formatted()),
                    ("Block rate", s.blockRate.formatted(.percent.precision(.fractionLength(1))))]
        }
        let updated = model.meta.values.map(\.updated).max()?.formatted(.relative(presentation: .named)) ?? "Never"
        return [("Domains", model.desired.count.formatted()),
                ("Filters on", "\(model.config.enabled.count) of \(BlockCategory.allCases.count)"),
                ("Lists updated", updated)]
    }

    @ViewBuilder private var orb: some View {
        let busy = model.busy != nil
        switch model.protection {
        case .off, .removed:
            OrbButton(title: "Turn On", busy: busy) { Task { await model.apply() } }
                .disabled(model.desired.isEmpty || busy)
        case .outdated:
            OrbButton(title: "Apply", busy: busy) { Task { await model.apply() } }.disabled(busy)
        case .switchPending:
            OrbButton(title: "Switch", busy: busy) { Task { await model.apply() } }.disabled(busy)
        case .active:
            OrbButton(title: "Turn Off", busy: busy) { Task { await model.turnOff() } }.disabled(busy)
        }
    }

    private var heroTitle: String {
        switch model.protection {
        case .off: "Protection is off"
        case .active: "You're protected"
        case .outdated: "Changes waiting"
        case .switchPending: "Ready to switch"
        case .removed: "Protection removed"
        }
    }

    private var heroDetail: String {
        switch model.protection {
        case .off: model.desired.isEmpty ? "Update the filter lists to get started." : "Ready to block \(model.desired.count.formatted()) ad, tracker and malware domains in every app. macOS asks for your password when you turn it on."
        case .active(let n): model.config.method == .dns
            ? "The DNS filter is blocking \(n.formatted()) domains in every app on this Mac."
            : "The hosts file is blocking \(n.formatted()) domains in every app on this Mac."
        case .outdated: "Your settings or lists changed since blocking was last applied."
        case .switchPending(let m): m == .dns
            ? "The hosts file is still blocking. Switch asks for your password once and moves blocking to the DNS filter."
            : "The DNS filter is still blocking. Switch asks for your password once and moves blocking to the hosts file."
        case .removed: model.config.method == .dns ? "macOS is no longer sending DNS to Ad-Owl, or the resolver stopped." : "Something removed Ad-Owl's entries from \(model.hostsPath)."
        }
    }
}

struct StatCard: View {
    let title: String, value: String, symbol: String
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                Text(title).font(.system(size: 12)).foregroundStyle(Owl.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }
}

// MARK: - Traffic (DNS mode)

struct TrafficView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        if model.config.method != .dns || !model.proxyRunning {
            ContentUnavailableView {
                Label("Traffic needs the DNS filter", systemImage: "chart.bar.xaxis")
            } description: {
                Text("The hosts file can't see what gets blocked. Choose “DNS filter” on the Protection page and turn it on to watch lookups as they happen.")
            }
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        StatCard(title: "Queries today", value: s.totalToday.formatted(), symbol: "arrow.left.arrow.right")
                        StatCard(title: "Blocked today", value: s.blockedToday.formatted(), symbol: "xmark.shield")
                        StatCard(title: "Block rate", value: s.blockRate.formatted(.percent.precision(.fractionLength(1))), symbol: "percent")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Last 24 hours").font(.system(size: 13, weight: .semibold))
                        Chart {
                            ForEach(s.hours) { h in
                                BarMark(x: .value("Hour", h.start, unit: .hour), y: .value("Queries", h.allowed))
                                    .foregroundStyle(by: .value("Result", "Allowed"))
                                BarMark(x: .value("Hour", h.start, unit: .hour), y: .value("Queries", h.blocked))
                                    .foregroundStyle(by: .value("Result", "Blocked"))
                            }
                        }
                        .chartForegroundStyleScale(["Allowed": Color.white.opacity(0.35), "Blocked": Owl.pink])
                        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                        .frame(height: 150)
                    }
                    .glassCard()
                    HStack(alignment: .top, spacing: 14) {
                        topBlocked(s).frame(width: 260)
                        recent(s)
                    }
                }
                .padding(.horizontal, 32).padding(.bottom, 24)
            }
        }
    }

    private func topBlocked(_ s: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top blocked today").font(.system(size: 13, weight: .semibold))
            if s.topBlocked.isEmpty {
                Text("Nothing blocked yet today.").font(.system(size: 12)).foregroundStyle(Owl.secondaryText)
            }
            ForEach(Array(s.topBlocked.prefix(10).enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.domain).font(.system(size: 12)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(row.count.formatted()).font(.system(size: 12)).monospacedDigit().foregroundStyle(Owl.secondaryText)
                }
                .padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func recent(_ s: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live queries").font(.system(size: 13, weight: .semibold))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(s.recent.prefix(150)) { e in
                        HStack(spacing: 10) {
                            Text(e.date.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                                .frame(width: 74, alignment: .leading)
                            Text(e.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Text(e.blocked ? "Blocked" : "Allowed")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(e.blocked ? Owl.pink.opacity(0.85) : Color.white.opacity(0.12), in: Capsule())
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(height: 260)
            .overlay {
                if s.recent.isEmpty {
                    Text("Waiting for queries…").font(.system(size: 12)).foregroundStyle(Owl.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
