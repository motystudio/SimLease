// SimBar — sim-lease's settings (~/.claude/sim-lease.conf), read and written through
// `sim-lease config json|set|reset` so the script stays the only one that knows the file.

import SwiftUI

@MainActor
final class SimLeaseConfig: ObservableObject {
    static let shared = SimLeaseConfig()

    enum Key: String, CaseIterable {
        case maxIOS = "SIM_LEASE_MAX_IOS"
        case maxAndroid = "SIM_LEASE_MAX_ANDROID"
        case staleMin = "SIM_LEASE_STALE_MIN"
        case graceMin = "SIM_LEASE_GRACE_MIN"
        case adoptUnmanaged = "SIM_LEASE_ADOPT_UNMANAGED"
        case unmanagedGraceMin = "SIM_LEASE_UNMANAGED_GRACE_MIN"

        /// Values the script accepts.
        var range: ClosedRange<Int> {
            switch self {
            case .maxIOS, .maxAndroid: return 0...10
            case .adoptUnmanaged: return 0...1
            case .staleMin, .graceMin, .unmanagedGraceMin: return 1...1440
            }
        }
    }

    enum Status: Equatable {
        case loading
        case ready
        /// No script at ~/.claude/bin/sim-lease.
        case noScript
        /// The installed script predates `sim-lease config`.
        case outdatedScript
    }

    @Published private(set) var values: [Key: Int] = [:]
    @Published private(set) var status: Status = .loading
    /// The last write the script refused, shown under the settings.
    @Published var lastError: String?

    private var pendingWrites: [Key: DispatchWorkItem] = [:]
    private var loads = 0

    private init() {}

    /// Reads the effective values (defaults included) from the script.
    func load() {
        loads += 1
        let generation = loads
        commandQueue.async {
            let (status, values) = SimLeaseConfig.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.loads else { return }   // a newer read is on its way
                    self.status = status
                    // keep what the user is typing until its write has gone through
                    var merged = values
                    for key in self.pendingWrites.keys { merged[key] = self.values[key] }
                    if merged != self.values { self.values = merged }
                }
            }
        }
    }

    /// Blocking: runs on the command queue.
    nonisolated private static func read() -> (Status, [Key: Int]) {
        guard FileManager.default.fileExists(atPath: simLease) else { return (.noScript, [:]) }
        let r = runScript(["config", "json"])
        // an older script prints its usage and exits 1 on an unknown command
        guard r.ok, let json = try? JSONSerialization.jsonObject(with: r.output) as? [String: Any] else {
            return (.outdatedScript, [:])
        }
        var values: [Key: Int] = [:]
        for key in Key.allCases {
            if let n = json[key.rawValue] as? NSNumber { values[key] = n.intValue }
            else if let s = json[key.rawValue] as? String, let n = Int(s) { values[key] = n }
        }
        return (values.isEmpty ? .outdatedScript : .ready, values)
    }

    func value(_ key: Key) -> Int? { values[key] }

    /// A binding that shows the new value at once and writes it shortly after the last change
    /// (a stepper clicked ten times makes one `config set`).
    func binding(_ key: Key, fallback: Int) -> Binding<Int> {
        Binding(get: { self.values[key] ?? fallback },
                set: { self.set(key, $0) })
    }

    var adoptUnmanaged: Binding<Bool> {
        Binding(get: { (self.values[.adoptUnmanaged] ?? 0) == 1 },
                set: { self.set(.adoptUnmanaged, $0 ? 1 : 0, delay: 0) })
    }

    func set(_ key: Key, _ newValue: Int, delay: TimeInterval = 0.5) {
        let value = min(max(newValue, key.range.lowerBound), key.range.upperBound)
        values[key] = value
        if value != newValue { objectWillChange.send() }   // a clamped text field shows the real value again
        lastError = nil
        pendingWrites[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(key, value) }
        pendingWrites[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func write(_ key: Key, _ value: Int) {
        pendingWrites[key] = nil
        commandQueue.async {
            let r = runScript(["config", "set", key.rawValue, String(value)])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !r.ok { self.lastError = SimLeaseConfig.message(r) }
                    self.load()   // the script has the last word on the effective value
                }
            }
        }
    }

    func resetAll() {
        for work in pendingWrites.values { work.cancel() }
        pendingWrites = [:]
        lastError = nil
        commandQueue.async {
            let r = runScript(["config", "reset"])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !r.ok { self.lastError = SimLeaseConfig.message(r) }
                    self.load()
                }
            }
        }
    }

    nonisolated private static func message(_ r: ScriptResult) -> String {
        let text = r.error.hasPrefix("sim-lease: ") ? String(r.error.dropFirst("sim-lease: ".count)) : r.error
        return text.isEmpty ? L("sim-lease couldn't save this setting.", "sim-lease n'a pas pu enregistrer ce réglage.") : text
    }
}
