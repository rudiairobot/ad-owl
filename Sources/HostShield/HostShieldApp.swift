import SwiftUI

/// Quitting while the DNS sinkhole is active would leave macOS pointing at a dead resolver,
/// so restore DNS first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the dashboard must never quit: blocking lives in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Developer tool for README screenshots (scripts/screenshots.sh): with ADOWL_SNAPSHOT=<file.png>
    /// the app renders its own window at 2x after a few seconds, then exits.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let out = ProcessInfo.processInfo.environment["ADOWL_SNAPSHOT"] else { return }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if let win = NSApp.windows.first(where: { $0.isVisible && $0.title == "Ad-Owl" }),
               let view = win.contentView?.superview,
               let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                                          pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                win.makeKeyAndOrderFront(nil)
                rep.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            exit(0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.markCleanExit("app quit")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.proxyRunning || model.dnsPointed else { model.stats.save(); return .terminateNow }
        Task { @MainActor in
            if await model.restoreForQuit() {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            let alert = NSAlert()
            alert.messageText = "DNS settings weren't restored"
            alert.informativeText = "If you quit now, this Mac keeps sending DNS to Ad-Owl, which will no longer be running. Internet access may stop working until you reopen Ad-Owl and turn blocking off."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit Anyway")
            NSApp.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
        }
        return .terminateLater
    }
}

@main
struct HostShieldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Ad-Owl", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 680)

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            Image(nsImage: model.isOn ? OwlGlyph.awake : OwlGlyph.asleep)
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusTitle)
        if model.config.method == .dns, model.proxyRunning {
            Text("Blocked today: \(model.snapshot.blockedToday.formatted()) of \(model.snapshot.totalToday.formatted())")
        }
        Divider()
        if model.isOn {
            Button("Turn Off Blocking…") { Task { await model.turnOff() } }
        }
        Button(model.isOn ? "Apply Changes…" : "Turn On Blocking…") { Task { await model.apply() } }
            .disabled(model.protection == .off && model.desired.isEmpty)
        Button("Update Filter Lists") { Task { await model.updateLists() } }
            .disabled(model.busy != nil)
        Divider()
        Button("Open Dashboard") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Ad-Owl") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension AppModel {
    var statusTitle: String {
        switch protection {
        case .off: "Blocking is off"
        case .active(let n): config.method == .dns ? "DNS filter on · \(n.formatted()) domains" : "Blocking \(n.formatted()) domains"
        case .outdated: "Changes not applied"
        case .removed: "Protection was removed"
        case .switchPending(let m): m == .dns ? "Switch to DNS filter pending" : "Switch to hosts file pending"
        }
    }
}
