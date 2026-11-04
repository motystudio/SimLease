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

    var isIOS: Bool { platform == "ios" }
    var isUnmanaged: Bool { session == "unmanaged" || session.isEmpty }
}

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
    @Published var devices: [Device] = []
    @Published var busy: Set<String> = []
    @Published var loading = false
    @Published var autoReap: Bool = UserDefaults.standard.object(forKey: "autoReap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReap, forKey: "autoReap") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var sessions: [String: DesktopSession] = [:]   // cliSessionId -> desktop session
    private var timer: Timer?
    private var lastReap = Date.distantPast

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
            await MainActor.run {
                if list != self.devices { self.devices = list }
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
        busy.formUnion(devices.filter { !$0.live }.map(\.id))
        Task.detached {
            run(["shutdown-idle"])
            await MainActor.run { self.busy.removeAll(); self.refresh() }
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

    func session(for d: Device) -> DesktopSession? {
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

    func show(_ d: Device) {
        if d.isIOS {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", d.id]
            try? p.run()
        } else {
            // bring the emulator window of that AVD forward
            for app in NSWorkspace.shared.runningApplications where (app.localizedName ?? "").contains("qemu") || (app.localizedName ?? "").hasPrefix("Android Emulator") {
                app.activate()
            }
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
        HStack(spacing: 10) {
            Image(systemName: device.isIOS ? "iphone" : "smartphone")
                .font(.system(size: 18))
                .foregroundStyle(device.live ? Color.green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.isEmpty ? device.id : device.name).font(.system(size: 13, weight: .medium))
                status(session).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.busy.contains(device.id) {
                ProgressView().controlSize(.small)
            } else {
                if let s = session {
                    iconButton("arrow.up.forward.app", help: "Ouvrir la session « \(s.title) »") { store.open(s) }
                }
                iconButton("macwindow", help: "Afficher le simulateur") { store.show(device) }
                if confirmKill {
                    Button("Éteindre ?") { store.kill(device); confirmKill = false }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                } else {
                    iconButton("power", help: "Éteindre") {
                        if device.live {
                            confirmKill = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmKill = false }
                        } else { store.kill(device) }
                    }
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .contextMenu {
            Button("Copier l'identifiant") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(device.id, forType: .string)
            }
        }
    }

    @ViewBuilder func status(_ s: DesktopSession?) -> some View {
        if device.live {
            let mins = max(0, (Int(Date().timeIntervalSince1970) - device.lastActive) / 60)
            Text("Utilisé par \(s?.title ?? "session \(device.session.prefix(8))")" + (mins > 1 ? " · actif il y a \(mins) min" : ""))
        } else if device.isUnmanaged {
            Text("Hors sim-lease" + (device.shutdownInMin >= 0 ? " · s'éteint dans \(device.shutdownInMin) min" : ""))
        } else {
            Text("Libre · s'éteint dans \(max(0, device.shutdownInMin)) min")
        }
    }

    func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 13)).frame(width: 22, height: 22) }
            .buttonStyle(.borderless).help(help)
    }
}

struct Panel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Simulateurs").font(.headline)
                Spacer()
                if store.loading { ProgressView().controlSize(.mini) }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rafraîchir")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            if store.devices.isEmpty {
                Text("Aucun simulateur démarré").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                section("iOS", store.devices.filter(\.isIOS))
                section("Android", store.devices.filter { !$0.isIOS })
            }

            Divider().padding(.top, 4)
            HStack {
                Button("Éteindre les inactifs") { store.killIdle() }
                    .disabled(!store.devices.contains { !$0.live })
                Button("Tout éteindre", role: .destructive) { store.killAll() }
                    .disabled(store.devices.isEmpty)
            }
            .controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Nettoyage auto toutes les 5 min", isOn: $store.autoReap)
                Toggle("Lancer à l'ouverture de session", isOn: Binding(
                    get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            }
            .toggleStyle(.checkbox).font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()
            HStack {
                Button("Journal") { NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/.claude/sim-leases/sim-lease.log")) }
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless).font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 400)
        .onAppear { store.refresh(); store.loadSessions() }
    }

    @ViewBuilder func section(_ title: String, _ list: [Device]) -> some View {
        if !list.isEmpty {
            Text("\(title) · \(list.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 6)
            ForEach(list) { DeviceRow(device: $0) }
        }
    }
}

@main
struct SimBarApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(store)
        } label: {
            let n = store.devices.count
            let idle = store.devices.filter { !$0.live }.count
            Image(systemName: idle > 0 ? "iphone.badge.exclamationmark" : "iphone")
            if n > 0 { Text("\(n)") }
        }
        .menuBarExtraStyle(.window)
    }
}
