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
    private var lastTimes: [pid_t: UInt64] = [:]   // per process, so an exiting process doesn't skew the total
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
                if let m = a.firstMatch(of: #/Devices\/([0-9A-F-]{36})/#) {
                    roots[p] = String(m.1)
                } else if let m = a.firstMatch(of: #/(?:^| )(?:-avd |@)([^ ]+)/#) {   // `-avd NAME` or `@NAME`
                    roots[p] = String(m.1)
                }
            }
        }

        var result: [String: Usage] = [:], keyOf: [pid_t: String] = [:]
        for (p, fp) in footprint {
            var q = p, depth = 0
            while roots[q] == nil, let pp = parent[q], pp > 1, depth < 64 { q = pp; depth += 1 }
            guard let key = roots[q] else { continue }
            result[key, default: Usage()].memory += fp
            result[key]?.rootPid = q
            keyOf[p] = key
        }
        let now = Date()
        if lastDate == nil || now.timeIntervalSince(lastDate!) > 0.5 {
            if let last = lastDate {
                // CPU time each process used since the last sample; new processes start counting next time
                let wallNs = now.timeIntervalSince(last) * 1e9
                var ticks: [String: UInt64] = [:]
                for (p, key) in keyOf {
                    guard let t = time[p], let prev = lastTimes[p], t >= prev else { continue }
                    ticks[key, default: 0] += t - prev
                }
                lastCPU = ticks.mapValues { Double($0) * ticksToNs / wallNs * 100 }   // drops devices that are gone
            }
            lastTimes = time.filter { keyOf[$0.key] != nil }
            lastDate = now
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

// MARK: - Setup (what needs to be in ~/.claude for sim-lease to work)

enum SetupItem: CaseIterable {
    case script, rule, hook

    var title: String {
        switch self {
        case .script: return L("sim-lease script", "Script sim-lease")
        case .rule: return L("CLAUDE.md rule", "Règle CLAUDE.md")
        case .hook: return L("SessionEnd hook", "Hook SessionEnd")
        }
    }
}

enum SetupState: Equatable { case ok, missing, outdated }

/// Checks and installs the script, the CLAUDE.md rule and the SessionEnd hook, from the
/// copies bundled in the app. `claudeDir` is ~/.claude (another folder for `--setup` tests).
struct Setup {
    let claudeDir: String
    static let hookCommand = "$HOME/.claude/bin/sim-lease release-session"
    private static let ruleStart = "<simulators>", ruleEnd = "</simulators>"

    private var scriptPath: String { "\(claudeDir)/bin/sim-lease" }
    private var rulePath: String { "\(claudeDir)/CLAUDE.md" }
    private var settingsPath: String { "\(claudeDir)/settings.json" }
    private func bundled(_ name: String) -> String { Bundle.main.path(forResource: name, ofType: nil)! }

    func state(_ item: SetupItem) -> SetupState {
        let fm = FileManager.default
        switch item {
        case .script:
            guard fm.fileExists(atPath: scriptPath) else { return .missing }
            return fm.contentsEqual(atPath: scriptPath, andPath: bundled("sim-lease")) ? .ok : .outdated
        case .rule:
            guard let md = try? String(contentsOfFile: rulePath, encoding: .utf8),
                  let block = Setup.ruleBlock(in: md) else { return .missing }
            let snippet = (try? String(contentsOfFile: bundled("CLAUDE.snippet.md"), encoding: .utf8)) ?? ""
            return md[block].trimmingCharacters(in: .whitespacesAndNewlines)
                == snippet.trimmingCharacters(in: .whitespacesAndNewlines) ? .ok : .outdated
        case .hook:
            guard let data = fm.contents(atPath: settingsPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = json["hooks"] as? [String: Any],
                  let end = hooks["SessionEnd"] as? [[String: Any]] else { return .missing }
            let commands = end.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
            return commands.contains { $0.contains("sim-lease release-session") } ? .ok : .missing
        }
    }

    func install(_ item: SetupItem) throws {
        guard state(item) != .ok else { return }   // never add a second hook or rule
        let fm = FileManager.default
        switch item {
        case .script:
            try fm.createDirectory(atPath: "\(claudeDir)/bin", withIntermediateDirectories: true)
            try? fm.removeItem(atPath: scriptPath)   // also replaces an old symlink into the repo
            try fm.copyItem(atPath: bundled("sim-lease"), toPath: scriptPath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        case .rule:
            let snippet = try String(contentsOfFile: bundled("CLAUDE.snippet.md"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var md = (try? String(contentsOfFile: rulePath, encoding: .utf8)) ?? ""
            if let block = Setup.ruleBlock(in: md) {
                md.replaceSubrange(block, with: snippet)
            } else {
                md += (md.isEmpty || md.hasSuffix("\n\n") ? "" : md.hasSuffix("\n") ? "\n" : "\n\n") + snippet + "\n"
            }
            try md.write(toFile: rulePath, atomically: true, encoding: .utf8)
        case .hook:
            // jq keeps the user's key order and formatting; a backup is kept next to the file
            if !fm.fileExists(atPath: settingsPath) { try "{}\n".write(toFile: settingsPath, atomically: true, encoding: .utf8) }
            let backup = settingsPath + ".backup-simbar"
            try? fm.removeItem(atPath: backup)
            try fm.copyItem(atPath: settingsPath, toPath: backup)
            let filter = #".hooks.SessionEnd = ((.hooks.SessionEnd // []) + [{"hooks":[{"type":"command","command":$c,"timeout":30}]}])"#
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/jq")
            p.arguments = ["--arg", "c", Setup.hookCommand, filter, settingsPath]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, !data.isEmpty else {
                throw NSError(domain: "SimBar", code: Int(p.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "jq could not update settings.json"])
            }
            let perms = try fm.attributesOfItem(atPath: settingsPath)[.posixPermissions]
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            if let perms { try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: settingsPath) }
        }
    }

    private static func ruleBlock(in md: String) -> Range<String.Index>? {
        guard let start = md.range(of: ruleStart), let end = md.range(of: ruleEnd, range: start.upperBound..<md.endIndex)
        else { return nil }
        return start.lowerBound..<end.upperBound
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var devices: [Device] = []
    @Published var usage: [String: Usage] = [:]
    @Published var busy: Set<String> = []
    @Published var pinOverride: [String: Bool] = [:]
    @Published var loading = false
    @Published var autoReap: Bool = UserDefaults.standard.object(forKey: "autoReap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReap, forKey: "autoReap") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var setupStates: [SetupItem: SetupState] = [:]
    var setupIncomplete: Bool { setupStates.values.contains { $0 != .ok } }
    nonisolated let setup = Setup(claudeDir: "\(home)/.claude")

    private var sessions: [String: DesktopSession] = [:]   // cliSessionId -> desktop session
    private var timer: Timer?
    private var lastReap = Date.distantPast
    private var lastSessionScan = Date.distantPast
    private var pending = 0
    nonisolated private let sampler = Sampler()
    /// sim-lease commands run one at a time, in click order (pin before a bulk shutdown, etc.)
    nonisolated private let queue = DispatchQueue(label: "com.motystudio.simbar.commands")

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--setup"), i + 1 < CommandLine.arguments.count {
            Store.setupTest(claudeDir: CommandLine.arguments[i + 1])
        }
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
            perform([["reap"]])
        } else {
            refresh()
        }
    }

    func refresh() { perform([]) }

    /// Runs sim-lease commands on the serial queue, reloads the list, and only then clears
    /// `done` from busy / pin overrides, so the row never flickers back to its old state.
    /// Results are applied in the order the work was queued.
    private func perform(_ commands: [[String]], done ids: Set<String> = []) {
        pending += 1
        loading = true
        let sampler = self.sampler
        queue.async {
            for c in commands { run(c) }
            let data = run(["json"])
            let list = (try? JSONDecoder().decode([Device].self, from: data)) ?? []
            let usage = sampler.sample()
            let setup = Dictionary(uniqueKeysWithValues: SetupItem.allCases.map { ($0, self.setup.state($0)) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(list, usage, setup, done: ids) }
            }
        }
    }

    private func apply(_ list: [Device], _ usage: [String: Usage], _ setup: [SetupItem: SetupState], done ids: Set<String>) {
        if setup != setupStates { setupStates = setup }
        if list != devices { devices = list }
        if usage != self.usage { self.usage = usage }
        busy.subtract(ids)
        for id in ids { pinOverride.removeValue(forKey: id) }
        pending -= 1
        loading = pending > 0
        // a session missing from the desktop app's metadata (e.g. a terminal session) is
        // looked up again at most once a minute, not on every refresh
        if Date().timeIntervalSince(lastSessionScan) >= 60,
           list.contains(where: { $0.live && sessions[$0.session] == nil }) {
            loadSessions()
        }
    }

    func kill(_ d: Device) {
        busy.insert(d.id)
        perform([["kill", d.id]], done: [d.id])
    }

    func killIdle() {
        let ids = Set(devices.filter { !$0.live && !isPinned($0) }.map(\.id))
        busy.formUnion(ids)
        perform([["shutdown-idle"]], done: ids)
    }

    /// Pin state shown in the UI: flips immediately on click, before sim-lease confirms it.
    func isPinned(_ d: Device) -> Bool { pinOverride[d.id] ?? d.pinned }

    func togglePin(_ d: Device) {
        let on = !isPinned(d)
        pinOverride[d.id] = on
        perform([[on ? "pin" : "unpin", d.id]], done: [d.id])
    }

    func killAll() {
        let ids = Set(devices.map(\.id))
        busy.formUnion(ids)
        perform(ids.map { ["kill", $0] }, done: ids)
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
        lastSessionScan = Date()
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

    /// Installs the given setup items on the command queue, then reloads; shows an alert on failure.
    func install(_ items: [SetupItem]) {
        let setup = self.setup
        queue.async {
            var failure: String?
            for item in items {
                do { try setup.install(item) } catch { failure = "\(item.title): \(error.localizedDescription)" }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failure {
                        let alert = NSAlert()
                        alert.messageText = L("Installation failed", "L'installation a échoué")
                        alert.informativeText = failure
                        alert.runModal()
                    }
                    self.refresh()
                }
            }
        }
    }

    /// Debug: `SimBar --setup DIR` checks, installs into DIR (a stand-in for ~/.claude), checks again, exits.
    private static func setupTest(claudeDir: String) -> Never {
        let s = Setup(claudeDir: claudeDir)
        for item in SetupItem.allCases { print("before", item, s.state(item)) }
        for item in SetupItem.allCases {
            do { try s.install(item) } catch { print("install", item, "failed:", error) }
        }
        for item in SetupItem.allCases { print("after", item, s.state(item)) }
        exit(0)
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
            controls
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .contextMenu {
            Button(L("Copy identifier", "Copier l'identifiant")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(device.id, forType: .string)
            }
        }
    }

    /// Pin + power, in a fixed-size box: the spinner and the confirmation take exactly
    /// their place, so nothing on the left moves.
    var controls: some View {
        let pinned = store.isPinned(device)
        return ZStack {
            HStack(spacing: 6) {
                iconButton(pinned ? "pin.fill" : "pin",
                           help: pinned ? L("Stop keeping alive", "Ne plus garder allumé") : L("Keep alive: never shut down automatically", "Garder allumé : jamais éteint automatiquement"),
                           tint: pinned ? .accentColor : nil) { store.togglePin(device) }
                    .offset(y: 1)   // the pin glyph sits high; lines it up with the power icon
                iconButton(confirmKill ? "power.circle.fill" : "power",
                           help: confirmKill ? L("Click again to shut down", "Cliquer encore pour éteindre") : L("Shut down", "Éteindre"),
                           tint: confirmKill ? .red : nil) {
                    if confirmKill || !(device.live || pinned) {
                        confirmKill = false
                        store.kill(device)
                    } else {
                        confirmKill = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmKill = false }
                    }
                }
            }
            .opacity(store.busy.contains(device.id) ? 0 : 1)
            .allowsHitTesting(!store.busy.contains(device.id))
            if store.busy.contains(device.id) { ProgressView().controlSize(.small) }
        }
        .frame(width: 50, height: 22)
    }

    @ViewBuilder func status(_ s: DesktopSession?) -> some View {
        if device.live {
            let mins = max(0, (Int(Date().timeIntervalSince1970) - device.lastActive) / 60)
            Text(s?.title ?? "Session \(device.session.prefix(8))").foregroundColor(.blue)
                + Text(mins > 1 ? L(" · active \(mins) min ago", " · actif il y a \(mins) min") : "")
        } else if store.isPinned(device) {
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
            // only what still needs installing; the whole section disappears once everything is set up
            let todo = SetupItem.allCases.filter { (store.setupStates[$0] ?? .ok) != .ok }
            if !todo.isEmpty {
                Divider()
                Section(L("Setup", "Installation")) {
                    ForEach(todo, id: \.self) { item in
                        if store.setupStates[item] == .outdated {
                            Button { store.install([item]) } label: {
                                Label(L("Update \(item.title)", "Mettre à jour : \(item.title)"), systemImage: "arrow.triangle.2.circlepath")
                            }
                        } else {
                            Button { store.install([item]) } label: {
                                Label(L("Install \(item.title)", "Installer : \(item.title)"), systemImage: "exclamationmark.triangle.fill")
                            }
                        }
                    }
                    if todo.count > 1 {
                        Button(L("Install everything", "Tout installer")) { store.install(todo) }
                    }
                }
            }
            Divider()
            Button(L("Open log", "Ouvrir le journal")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/.claude/sim-leases/sim-lease.log"))
            }
            Divider()
            Button(L("Quit SimBar", "Quitter SimBar")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape").frame(width: 22, height: 22)
                .overlay(alignment: .topTrailing) {
                    if store.setupIncomplete {   // something from Setup still needs installing
                        Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: -1, y: 2)
                    }
                }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("Settings", "Réglages"))
    }

    /// Summary of what is idle, with the bulk shutdown actions.
    var actionBar: some View {
        let idleDevices = store.devices.filter { !$0.live && !store.isPinned($0) }
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
