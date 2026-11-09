import SwiftUI
import HostShieldCore

// MARK: - Filters

struct FiltersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach(BlockCategory.allCases.filter { !$0.isPremiumEquivalent }) { row($0) }
            } header: { Text("Core protection") }
            SwiftUI.Section {
                ForEach(BlockCategory.allCases.filter(\.isPremiumEquivalent)) { row($0) }
            } header: { Text("Premium-style extras") } footer: {
                Text("These are paid features in Adblock Plus. Here they are free, but limited to blocking whole domains.")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ c: BlockCategory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { model.config.enabled.contains(c) },
                set: { on in Task { await model.setEnabled(c, on) } }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title)
                        Text(c.summary).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: c.symbol).foregroundStyle(.tint) }
            }
            HStack(spacing: 6) {
                if let n = model.domainCount(c) { Text("\(n.formatted()) domains") }
                if let m = model.meta[c] { Text("· updated \(m.updated.formatted(.relative(presentation: .named)))") }
                else { Text("· built-in only, update to download lists") }
            }
            .font(.caption).foregroundStyle(.tertiary).padding(.leading, 28)
            if let caution = c.caution, model.config.enabled.contains(c) {
                Label(caution, systemImage: "info.circle").font(.caption).foregroundStyle(.orange).padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Allow & Block

struct RulesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            DomainListSection(
                title: "Never block", symbol: "checkmark.circle",
                footer: "Use this when a site breaks. Takes priority over every filter.",
                placeholder: "example.com",
                domains: model.config.allowlist,
                add: model.addAllow, remove: { model.remove($0, from: \.allowlist) })
            DomainListSection(
                title: "Always block", symbol: "nosign",
                footer: "Exact host names only; hosts files don't support wildcards, so block ads.example.com separately from example.com.",
                placeholder: "ads.example.com",
                domains: model.config.customBlocks,
                add: model.addBlock, remove: { model.remove($0, from: \.customBlocks) })
        }
        .formStyle(.grouped)
    }
}

struct DomainListSection: View {
    let title: String, symbol: String, footer: String, placeholder: String
    let domains: [String]
    let add: (String) -> Void
    let remove: (String) -> Void
    @State private var text = ""

    var body: some View {
        SwiftUI.Section {
            HStack {
                TextField(placeholder, text: $text).onSubmit(commit).autocorrectionDisabled()
                Button("Add", action: commit).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if domains.isEmpty {
                Text("Nothing here yet").foregroundStyle(.tertiary)
            }
            ForEach(domains, id: \.self) { d in
                HStack {
                    Text(d).textSelection(.enabled)
                    Spacer()
                    Button { remove(d) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove \(d)")
                }
            }
        } header: { Label(title, systemImage: symbol) } footer: { Text(footer) }
    }

    private func commit() { add(text); text = "" }
}

// MARK: - Check a domain

struct CheckView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var result: CheckResult?
    @State private var invalid = false
    @State private var working = false

    var body: some View {
        Form {
            SwiftUI.Section {
                HStack {
                    TextField("Domain or URL, e.g. doubleclick.net", text: $text).onSubmit(run).autocorrectionDisabled()
                    Button("Check", action: run).disabled(text.isEmpty || working)
                }
            } footer: { Text("Shows which filters list the domain and what macOS actually resolves it to right now.") }
            if invalid {
                SwiftUI.Section { Label("That doesn't look like a valid host name.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if let r = result { details(r) }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func details(_ r: CheckResult) -> some View {
        SwiftUI.Section(r.lookup.domain) {
            LabeledContent("Verdict") {
                if r.blockedNow { Label("Blocked right now", systemImage: "xmark.shield.fill").foregroundStyle(.green) }
                else if r.lookup.allowlisted { Label("Allowed by you", systemImage: "checkmark.circle.fill").foregroundStyle(.blue) }
                else if r.lookup.isProtected { Label("Protected (list provider)", systemImage: "lock.fill").foregroundStyle(.blue) }
                else if !r.lookup.categories.isEmpty || r.lookup.custom { Label("Listed, but not applied yet", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                else { Label("Not blocked", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            LabeledContent("Listed in") {
                let names = r.lookup.categories.map(\.title) + (r.lookup.custom ? ["Your block list"] : [])
                Text(names.isEmpty ? "No filter" : names.joined(separator: ", ")).multilineTextAlignment(.trailing)
            }
            LabeledContent("In hosts file", value: r.inHostsFile ? "Yes" : "No")
            if r.viaSinkhole {
                LabeledContent("Mode", value: r.lookup.categories.isEmpty && !r.lookup.custom ? "DNS filter (checks parent domains too)" : "DNS filter")
            }
            LabeledContent("Resolves to") {
                Text(r.addresses.isEmpty ? "Not resolvable" : r.addresses.joined(separator: ", ")).textSelection(.enabled)
            }
        }
    }

    private func run() {
        invalid = false; result = nil
        working = true
        Task {
            if let r = await model.check(text) { result = r } else { invalid = true }
            working = false
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.log.isEmpty {
            ContentUnavailableView("No activity yet", systemImage: "clock", description: Text("Updates, changes and errors show up here."))
        } else {
            List(model.log) { e in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: e.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(e.isError ? .orange : .secondary)
                    Text(e.text)
                    Spacer()
                    Text(e.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        Form {
            Toggle("Update filter lists daily", isOn: Binding(get: { model.config.autoUpdate }, set: model.setAutoUpdate))
            Toggle("Open Ad-Owl at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
            Toggle("Keep DNS working if Ad-Owl stops", isOn: Binding(get: { model.config.dnsFallback }, set: model.setFallback))
            Text("DNS filter mode: also lists your original DNS servers as a backup. If Ad-Owl crashes, the internet keeps working (a few ads can slip through while it is up). Takes effect the next time blocking is applied.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Hosts file", value: model.hostsPath)
            LabeledContent("Data folder") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.directory]) }
            }
            Text("The first time blocking is applied, your original hosts file is copied to /etc/hosts.hostshield-backup.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
