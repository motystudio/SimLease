// SimBar — menu bar companion for ~/.claude/bin/sim-lease.
// Shows booted iOS simulators / Android emulators, which Claude session holds each one,
// jumps to that session, shuts devices down, and runs `sim-lease reap` every 5 minutes.

import SwiftUI
import AppKit
import ServiceManagement

let home = FileManager.default.homeDirectoryForCurrentUser.path
let simLease = "\(home)/.claude/bin/sim-lease"
let desktopSessionsDir = "\(home)/Library/Application Support/Claude/claude-code-sessions"

// MARK: - Model

struct Device: Identifiable, Decodable, Equatable {
    let platform: String
    let id: String
    let name: String
    let session: String
    let host: String
    let live: Bool
    let lastActive: Int
    let shutdownInMin: Int
    let pinned: Bool

    var isIOS: Bool { platform == "ios" }
    var isUnmanaged: Bool { session == "unmanaged" || session.isEmpty }
    /// Key used by Sampler: iOS UDID, or AVD name for an emulator.
    var usageKey: String { isIOS ? id : name }
}

struct Usage: Equatable { var memory: UInt64 = 0; var cpu: Double? = nil; var rootPid: pid_t = 0 }

/// Measures memory (physical footprint, like Activity Monitor) and CPU of each simulator,
/// summing every process under its `launchd_sim` (iOS) or its `qemu-system` process (Android).
final class Sampler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTimes: [String: UInt64] = [:]
    private var lastCPU: [String: Double] = [:]
    private var lastDate: Date?
    private let ticksToNs: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    func sample() -> [String: Usage] {
        lock.lock(); defer { lock.unlock() }
        var count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))

        var parent: [pid_t: pid_t] = [:], footprint: [pid_t: UInt64] = [:], time: [pid_t: UInt64] = [:]
        var roots: [pid_t: String] = [:]
        for p in pids.prefix(Int(max(count, 0))) where p > 0 {
            var info = proc_bsdinfo()
            if proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                parent[p] = pid_t(info.pbi_ppid)
            }
            var ru = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V2, $0) }
            }
            if ok == 0 { footprint[p] = ru.ri_phys_footprint; time[p] = ru.ri_user_time + ru.ri_system_time }
            let name = Sampler.name(p)
            if name == "launchd_sim" || name.hasPrefix("qemu-system") {
                let a = Sampler.args(p)
                if let r = a.range(of: #"Devices/[0-9A-F-]{36}"#, options: .regularExpression) {
                    roots[p] = String(a[r].dropFirst(8))
                } else if let r = a.range(of: #"-avd [^ ]+"#, options: .regularExpression) {
                    roots[p] = String(a[r].dropFirst(5))
                }
            }
        }

        var result: [String: Usage] = [:], times: [String: UInt64] = [:]
        for (p, fp) in footprint {
            var q = p, depth = 0
            while roots[q] == nil, let pp = parent[q], pp > 1, depth < 64 { q = pp; depth += 1 }
            guard let key = roots[q] else { continue }
            result[key, default: Usage()].memory += fp
            result[key]?.rootPid = q
            times[key, default: 0] += time[p] ?? 0
        }
        let now = Date()
        if let last = lastDate, now.timeIntervalSince(last) > 0.5 {
            let wallNs = now.timeIntervalSince(last) * 1e9
            for (key, t) in times {
                guard let prev = lastTimes[key], t >= prev else { continue }
                lastCPU[key] = Double(t - prev) * ticksToNs / wallNs * 100
            }
            lastTimes = times; lastDate = now
        } else if lastDate == nil {
            lastTimes = times; lastDate = now
        }
        // a sample taken right after another one reuses the last measurement
        for key in result.keys { result[key]?.cpu = lastCPU[key] }
        return result
    }

    private static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }

    private static func args(_ pid: pid_t) -> String {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buf[4..<size].map { $0 == 0 ? 32 : $0 }, as: UTF8.self)
    }
}

func formatMemory(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return gb >= 1 ? "\(gb.formatted(.number.precision(.fractionLength(1)))) \(L("GB", "Go"))" : "\(bytes / 1_048_576) \(L("MB", "Mo"))"
}

/// English by default, French when the system's first language is French.
let isFrench = Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
func L(_ en: String, _ fr: String) -> String { isFrench ? fr : en }

struct DesktopSession { let localId: String; let title: String; let cwd: String }

@discardableResult
func run(_ args: [String]) -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [simLease] + args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:\(env["PATH"] ?? "")"
    env.removeValue(forKey: "CLAUDE_CODE_SESSION_ID")
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return Data() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}

func scanDesktopSessions() -> [String: DesktopSession] {
    var map: [String: DesktopSession] = [:]
    let fm = FileManager.default
    let paths = (fm.subpaths(atPath: desktopSessionsDir) ?? []).filter { $0.hasSuffix(".json") && $0.contains("local_") }
    for rel in paths {
        guard let data = fm.contents(atPath: "\(desktopSessionsDir)/\(rel)"),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cli = j["cliSessionId"] as? String,
              let local = j["sessionId"] as? String else { continue }
        let cwd = j["cwd"] as? String ?? ""
        let title = (j["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (cwd as NSString).lastPathComponent
        map[cli] = DesktopSession(localId: local, title: title, cwd: cwd)
    }
    return map
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var devices: [Device] = []
    @Published var usage: [String: Usage] = [:]
    @Published var busy: Set<String> = []
    @Published var loading = false
    @Published var autoReap: Bool = UserDefaults.standard.object(forKey: "autoReap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReap, forKey: "autoReap") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var sessions: [String: DesktopSession] = [:]   // cliSessionId -> desktop session
    private var timer: Timer?
    private var lastReap = Date.distantPast
    nonisolated private let sampler = Sampler()

    init() {
        refresh()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshot(to: CommandLine.arguments[i + 1])
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        if autoReap, Date().timeIntervalSince(lastReap) >= 300 {
            lastReap = Date()
            Task.detached { run(["reap"]); await MainActor.run { self.refresh() } }
        } else {
            refresh()
        }
    }

    func refresh() {
        loading = true
        Task.detached {
            let data = run(["json"])
            let list = (try? JSONDecoder().decode([Device].self, from: data)) ?? []
            let usage = self.sampler.sample()
            await MainActor.run {
                if list != self.devices { self.devices = list }
                if usage != self.usage { self.usage = usage }
                self.loading = false
                if list.contains(where: { !$0.isUnmanaged && $0.session != "none" && self.sessions[$0.session] == nil }) {
                    self.loadSessions()
                }
            }
        }
    }

    func kill(_ d: Device) {
        busy.insert(d.id)
        Task.detached {
            run(["kill", d.id])
            await MainActor.run { self.busy.remove(d.id); self.refresh() }
        }
    }

    func killIdle() {
        busy.formUnion(devices.filter { !$0.live && !$0.pinned }.map(\.id))
        Task.detached {
            run(["shutdown-idle"])
            await MainActor.run { self.busy.removeAll(); self.refresh() }
        }
    }

    func togglePin(_ d: Device) {
        busy.insert(d.id)
        Task.detached {
            run([d.pinned ? "unpin" : "pin", d.id])
            await MainActor.run { self.busy.remove(d.id); self.refresh() }
        }
    }

    func killAll() {
        let ids = devices.map(\.id)
        busy.formUnion(ids)
        Task.detached {
            for id in ids { run(["kill", id]) }
            await MainActor.run { self.busy.removeAll(); self.refresh() }
        }
    }

    /// The session currently holding the device; nil once it released it or went idle.
    func session(for d: Device) -> DesktopSession? {
        guard d.live else { return nil }
        if let s = sessions[d.session] { return s }
        if !d.host.isEmpty { return sessions.values.first { $0.localId == d.host } }
        return nil
    }

    /// Reads the desktop app's session metadata to map CLI session ids to titles / deep links.
    func loadSessions() {
        Task.detached {
            let map = scanDesktopSessions()
            await MainActor.run { self.sessions = map; self.objectWillChange.send() }
        }
    }

    func open(_ s: DesktopSession) {
        if let url = URL(string: "claude://code/continue?session=\(s.localId)&source=simbar") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Brings the device's window forward. Android: the emulator's own window.
    /// iOS: Simulator.app on that device; Xcode 27+ has DeviceHub instead, which can't be told which device to show.
    func show(_ d: Device) {
        if !d.isIOS {
            if let pid = usage[d.usageKey]?.rootPid, pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
            }
            return
        }
        let ws = NSWorkspace.shared
        if let sim = ws.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator") {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["-CurrentDeviceUDID", d.id]
            ws.openApplication(at: sim, configuration: config)
        } else if let hub = ws.urlForApplication(withBundleIdentifier: "com.apple.dt.Devices") {
            ws.openApplication(at: hub, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Debug: `SimBar --snapshot out.png` renders the panel with live data and exits.
    private func snapshot(to path: String) {
        loadSessions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let r = ImageRenderer(content: Panel().environmentObject(self)
                .background(Color(nsColor: .windowBackgroundColor)))
            r.scale = 2
            if let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("SimBar login item: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Views

struct DeviceRow: View {
    @EnvironmentObject var store: Store
    let device: Device
    @State private var confirmKill = false

    var body: some View {
        let session = store.session(for: device)
        HStack(spacing: 6) {
            // device icon: shows the simulator
            Image(systemName: device.isIOS ? "iphone" : "smartphone")
                .font(.system(size: 18))
                .foregroundStyle(device.live ? Color.blue : .secondary)
                .frame(width: 30, height: 40)
                .hoverTarget(help: L("Show the simulator", "Afficher le simulateur")) { store.show(device) }
            // name + status: opens the session using it, if any
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.isEmpty ? device.id : device.name).font(.system(size: 13, weight: .medium))
                status(session).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .hoverTarget(enabled: session != nil,
                         help: session.map { L("Open session “\($0.title)”", "Ouvrir la session « \($0.title) »") } ?? "") {
                if let s = session { store.open(s) }
            }
            Spacer(minLength: 4)
            usageView
            if store.busy.contains(device.id) {
                ProgressView().controlSize(.small).frame(width: 70)
            } else {
                iconButton(device.pinned ? "pin.fill" : "pin",
                           help: device.pinned ? L("Stop keeping alive", "Ne plus garder allumé") : L("Keep alive: never shut down automatically", "Garder allumé : jamais éteint automatiquement"),
                           tint: device.pinned ? .accentColor : nil) { store.togglePin(device) }
                if confirmKill {
                    Button(L("Shut down?", "Éteindre ?")) { store.kill(device); confirmKill = false }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                } else {
                    iconButton("power", help: L("Shut down", "Éteindre")) {
                        if device.live || device.pinned {
                            confirmKill = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmKill = false }
                        } else { store.kill(device) }
                    }
                }
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .contextMenu {
            Button(L("Copy identifier", "Copier l'identifiant")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(device.id, forType: .string)
            }
        }
    }

    @ViewBuilder func status(_ s: DesktopSession?) -> some View {
        if device.live {
            let mins = max(0, (Int(Date().timeIntervalSince1970) - device.lastActive) / 60)
            Text(s?.title ?? "Session \(device.session.prefix(8))").foregroundColor(.blue)
                + Text(mins > 1 ? L(" · active \(mins) min ago", " · actif il y a \(mins) min") : "")
        } else if device.pinned {
            Text(L("Kept alive", "Gardé allumé"))
        } else if device.isUnmanaged {
            Text(L("Unmanaged", "Hors sim-lease") + (device.shutdownInMin >= 0 ? L(" · shuts down in \(device.shutdownInMin) min", " · s'éteint dans \(device.shutdownInMin) min") : ""))
        } else {
            Text(L("Free · shuts down in \(max(0, device.shutdownInMin)) min", "Libre · s'éteint dans \(max(0, device.shutdownInMin)) min"))
        }
    }

    /// RAM and CPU of the whole simulator (all its processes).
    @ViewBuilder var usageView: some View {
        if let u = store.usage[device.usageKey] {
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatMemory(u.memory))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(u.memory >= 4 << 30 ? Color.orange : .primary)
                Text(u.cpu.map { String(format: "%.0f %% CPU", $0) } ?? "— CPU")
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle((u.cpu ?? 0) >= 50 ? Color.orange : .secondary)
            }
            .frame(width: 62, alignment: .trailing)
            .help(L("Memory and CPU used by this simulator (all its processes)", "Mémoire et processeur utilisés par ce simulateur (tous ses processus)"))
        }
    }

    func iconButton(_ name: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13)).frame(width: 22, height: 22)
                .foregroundStyle(tint ?? .primary)
        }
        .buttonStyle(.borderless).help(help)
    }
}

/// A clickable part of a row that highlights on its own when hovered.
struct HoverTarget: ViewModifier {
    let enabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(enabled && hovering ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering = $0 }
            .onTapGesture { if enabled { action() } }
            .help(help)
    }
}

extension View {
    func hoverTarget(enabled: Bool = true, help: String, action: @escaping () -> Void) -> some View {
        modifier(HoverTarget(enabled: enabled, help: help, action: action))
    }
}

struct PillButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.3 : 0.16)))
            .contentShape(Capsule())
    }
}

struct Panel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Simulators", "Simulateurs")).font(.headline)
                Spacer()
                if store.loading { ProgressView().controlSize(.mini) }
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless).help(L("Refresh", "Rafraîchir"))
                settingsMenu
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            if store.devices.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 24)).foregroundStyle(.green)
                    Text(L("No simulator running", "Aucun simulateur démarré")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                section("iOS", store.devices.filter(\.isIOS))
                section("Android", store.devices.filter { !$0.isIOS })
                actionBar.padding(10)
            }
        }
        .frame(width: 460)
        .onAppear { store.refresh(); store.loadSessions() }
    }

    var settingsMenu: some View {
        Menu {
            Toggle(L("Auto cleanup every 5 min", "Nettoyage auto toutes les 5 min"), isOn: $store.autoReap)
            Toggle(L("Launch at login", "Lancer à l'ouverture de session"), isOn: Binding(
                get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            Divider()
            Button(L("Open log", "Ouvrir le journal")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/.claude/sim-leases/sim-lease.log"))
            }
            Divider()
            Button(L("Quit SimBar", "Quitter SimBar")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape").frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("Settings", "Réglages"))
    }

    /// Summary of what is idle, with the bulk shutdown actions.
    var actionBar: some View {
        let idleDevices = store.devices.filter { !$0.live && !$0.pinned }
        let idle = idleDevices.count
        let used = store.devices.filter(\.live).count
        let idleMemory = idleDevices.reduce(UInt64(0)) { $0 + (store.usage[$1.usageKey]?.memory ?? 0) }
        return HStack(spacing: 10) {
            Image(systemName: idle > 0 ? "moon.zzz.fill" : "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(idle > 0 ? Color.orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(idle > 0 ? plural(idle, L("idle device", "appareil inactif"), L("idle devices", "appareils inactifs")) : L("Everything is in use", "Tout est utilisé"))
                    .font(.system(size: 12, weight: .semibold))
                Text(idle > 0 && idleMemory > 0 ? L("\(formatMemory(idleMemory)) of RAM to reclaim", "\(formatMemory(idleMemory)) de RAM à récupérer")
                     : used > 0 ? L("\(used) used by a session", "\(plural(used, "utilisé", "utilisés")) par une session") : L("No session is using them", "Aucune session ne les utilise"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if idle > 0 {
                Button { store.killIdle() } label: {
                    Label(L("Shut down", "Éteindre"), systemImage: "power").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle(tint: .orange))
                .help(L("Shut down devices no session is using", "Éteindre les appareils qu'aucune session n'utilise"))
            }
            Menu {
                Button(role: .destructive) { store.killAll() } label: {
                    Label(L("Shut down all, even in use (\(store.devices.count))", "Tout éteindre, même ceux utilisés (\(store.devices.count))"), systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n > 1 ? many : one)" }

    @ViewBuilder func section(_ title: String, _ list: [Device]) -> some View {
        if !list.isEmpty {
            let memory = list.reduce(UInt64(0)) { $0 + (store.usage[$1.usageKey]?.memory ?? 0) }
            Text("\(title) · \(list.count)" + (memory > 0 ? L(" · \(formatMemory(memory)) total", " · \(formatMemory(memory)) au total") : ""))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 6)
            ForEach(list) { DeviceRow(device: $0) }
        }
    }
}

/// Opening the app again (Spotlight, Finder, `open`) shows the panel in a normal window,
/// for when the menu bar icon is hidden.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { showWindow() }
        return false
    }

    @MainActor func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Panel().environmentObject(Store.shared)))
            w.title = "SimBar"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@main
struct SimBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(store)
        } label: {
            Image(nsImage: menuBarIcon(count: store.devices.count))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Icon + count drawn as one tight template image (an Image + Text label gets extra spacing).
func menuBarIcon(count: Int) -> NSImage {
    let symbol = NSImage(systemSymbolName: "iphone", accessibilityDescription: L("Simulators", "Simulateurs"))!
        .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!
    let text = count > 0 ? NSAttributedString(string: "\(count)", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black,
    ]) : nil
    let gap: CGFloat = text == nil ? 0 : 2
    let textSize = text?.size() ?? .zero
    let size = NSSize(width: ceil(symbol.size.width + gap + textSize.width), height: max(symbol.size.height, textSize.height))
    let image = NSImage(size: size, flipped: false) { _ in
        symbol.draw(in: NSRect(x: 0, y: (size.height - symbol.size.height) / 2,
                               width: symbol.size.width, height: symbol.size.height))
        text?.draw(at: NSPoint(x: symbol.size.width + gap, y: (size.height - textSize.height) / 2))
        return true
    }
    image.isTemplate = true
    return image
}
