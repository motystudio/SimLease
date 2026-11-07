// SimBar — devices, the sim-lease script runner, and the Store the views observe.

import SwiftUI
import AppKit
import ServiceManagement

let home = FileManager.default.homeDirectoryForCurrentUser.path
/// The installed script. Debug: `--sim-lease PATH` points SimBar at another copy.
let simLease = argument("--sim-lease") ?? "\(home)/.claude/bin/sim-lease"
let desktopSessionsDir = "\(home)/Library/Application Support/Claude/claude-code-sessions"

/// The value following `flag` on the command line, if any.
func argument(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// `--snapshot` / `--setup` runs render or test, then exit, without touching the user's
/// preferences, showing the onboarding or starting the updater.
let debugRun = argument("--snapshot") != nil || argument("--setup") != nil || argument("--open") != nil

/// UserDefaults keys.
enum Defaults {
    static let autoReap = "autoReap"
    static let onboardingDone = "onboardingDone"
}

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

struct ScriptResult {
    var status: Int32
    var output: Data
    var error: String
    var ok: Bool { status == 0 }
}

/// Runs a program and waits for it (at most `timeout` seconds), collecting stdout and stderr.
/// Blocking: never call it from the main thread.
func execute(_ path: String, _ args: [String], environment: [String: String]? = nil, timeout: TimeInterval = 120) -> ScriptResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let environment { p.environment = environment }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return ScriptResult(status: -1, output: Data(), error: error.localizedDescription) }
    // stderr is read alongside stdout so a chatty process can't fill its pipe and block
    let errData = LockedData()
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) { errData.value = err.fileHandleForReading.readDataToEndOfFile() }
    let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    group.wait()
    watchdog.cancel()
    return ScriptResult(status: p.terminationStatus, output: data,
                        error: String(decoding: errData.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data {
        get { lock.withLock { data } }
        set { lock.withLock { data = newValue } }
    }
}

/// Runs `sim-lease ARGS`. Blocking: call it on `commandQueue`.
func runScript(_ args: [String]) -> ScriptResult {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:\(env["PATH"] ?? "")"
    env.removeValue(forKey: "CLAUDE_CODE_SESSION_ID")
    return execute("/bin/bash", [simLease] + args, environment: env, timeout: 900)
}

@discardableResult
func run(_ args: [String]) -> Data { runScript(args).output }

/// sim-lease commands run one at a time, in click order (pin before a bulk shutdown, a setting
/// written before it is read back, etc.)
let commandQueue = DispatchQueue(label: "com.motystudio.simbar.commands")

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
    @Published var pinOverride: [String: Bool] = [:]
    @Published var loading = false
    @Published var autoReap: Bool = UserDefaults.standard.object(forKey: Defaults.autoReap) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReap, forKey: Defaults.autoReap) }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var setupStates: [SetupItem: SetupState] = [:]
    var setupIncomplete: Bool { setupStates.values.contains { !$0.isInstalled } }
    /// Debug: `--claude-dir DIR` checks (and installs into) a stand-in for ~/.claude.
    nonisolated let setup = Setup(claudeDir: argument("--claude-dir") ?? "\(home)/.claude")

    private var sessions: [String: DesktopSession] = [:]   // cliSessionId -> desktop session
    private var timer: Timer?
    private var lastReap = Date.distantPast
    private var lastSessionScan = Date.distantPast
    private var pending = 0
    nonisolated private let sampler = Sampler()
    private var queue: DispatchQueue { commandQueue }
    private var installRun: InstallRun?

    init() {
        if let dir = argument("--setup") { Store.setupTest(claudeDir: dir) }
        refresh()
        if debugRun { return }   // a snapshot reads the list once, no timer
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

    /// Installs the given setup items on the command queue, then reloads. `completion` gets the
    /// error message of each item that failed (empty when all went well); without one, a
    /// failure is shown in an alert. `replacingRule`: see `Setup.install`.
    func install(_ items: [SetupItem], replacingRule: Bool = false, completion: (([SetupItem: String]) -> Void)? = nil) {
        let setup = self.setup
        queue.async {
            var failures: [SetupItem: String] = [:]
            for item in items {
                do { try setup.install(item, replacingRule: replacingRule) } catch { failures[item] = error.localizedDescription }
            }
            let result = failures
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let completion {
                        completion(result)
                    } else if !result.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = L("Installation failed", "L'installation a échoué")
                        alert.informativeText = result.map { "\($0.key.title): \($0.value)" }.joined(separator: "\n")
                        NSApp.activate()
                        alert.runModal()
                    }
                    self.refresh()
                    // a newer script may know `config`
                    if items.contains(.script) { SimLeaseConfig.shared.load() }
                }
            }
        }
    }

    /// Installs the given items from the gear menu, showing each step in a window. Only one at a
    /// time: a second click brings the window of the running install back to the front.
    func installShowingProgress(_ items: [SetupItem]) {
        if let installRun, !installRun.finished { Windows.shared.showInstallProgress(installRun); return }
        let run = InstallRun(items)
        installRun = run
        Windows.shared.showInstallProgress(run)
        runInstall(run)
    }

    /// Each item counts as done only once its state, read back from disk, says it is installed.
    func runInstall(_ run: InstallRun) {
        let setup = self.setup, items = run.items
        queue.async {
            for item in items {
                let started = Date()
                DispatchQueue.main.async { MainActor.assumeIsolated { run.set(item, .running) } }
                var failure: String?
                do {
                    try setup.install(item)
                    if !setup.state(item).isInstalled {
                        failure = L("Still not installed after the attempt.", "Toujours pas installé après la tentative.")
                    }
                } catch { failure = error.localizedDescription }
                // these steps take milliseconds: long enough to see each of them go by
                Thread.sleep(forTimeInterval: max(0, 0.4 - Date().timeIntervalSince(started)))
                let result: InstallRun.Status = failure.map { .failed($0) } ?? .done
                DispatchQueue.main.async { MainActor.assumeIsolated { run.set(item, result) } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    run.finished = true
                    self.refresh()
                    if items.contains(.script) { SimLeaseConfig.shared.load() }   // a newer script may know `config`
                }
            }
        }
    }

    /// Replaces a customized or malformed CLAUDE.md rule with the bundled one, once the user
    /// confirms. `completion` gets the error message, nil when it worked; it isn't called on cancel.
    func confirmReplaceRule(completion: ((String?) -> Void)? = nil) {
        let malformed = setupStates[.rule] == .malformed
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = malformed ? L("Fix the CLAUDE.md rule?", "Réparer la règle CLAUDE.md ?")
                                      : L("Replace your rule with the default one?", "Remplacer votre règle par celle par défaut ?")
        alert.informativeText = (malformed
            ? L("The <simulators> section in ~/.claude/CLAUDE.md has no closing </simulators> tag. SimBar will replace it, up to the next section tag or the end of the file, with the default rule.",
                "La section <simulators> de ~/.claude/CLAUDE.md n'a pas de balise de fermeture </simulators>. SimBar va la remplacer, jusqu'à la balise de section suivante ou la fin du fichier, par la règle par défaut.")
            : L("The <simulators> section in ~/.claude/CLAUDE.md was edited, so SimBar doesn't update it. Replacing it discards your changes.",
                "La section <simulators> de ~/.claude/CLAUDE.md a été modifiée, donc SimBar ne la met pas à jour. La remplacer efface vos modifications."))
            + "\n\n" + L("The previous file is saved as CLAUDE.md\(Setup.backupSuffix).",
                          "L'ancien fichier est enregistré sous CLAUDE.md\(Setup.backupSuffix).")
        alert.addButton(withTitle: malformed ? L("Fix", "Réparer") : L("Replace", "Remplacer"))
        alert.addButton(withTitle: L("Cancel", "Annuler"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        install([.rule], replacingRule: true, completion: completion.map { done in { done($0[.rule]) } })
    }

    /// Debug: `SimBar --setup DIR [--replace-rule]` checks, installs into DIR (a stand-in for ~/.claude),
    /// checks again, exits. `--replace-rule` also replaces a customized or malformed rule.
    private static func setupTest(claudeDir: String) -> Never {
        let s = Setup(claudeDir: claudeDir)
        for item in SetupItem.allCases { print("before", item, s.state(item)) }
        let replacingRule = CommandLine.arguments.contains("--replace-rule")   // as if confirmed
        for item in SetupItem.allCases {
            do { try s.install(item, replacingRule: replacingRule) } catch { print("install", item, "failed:", error) }
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

