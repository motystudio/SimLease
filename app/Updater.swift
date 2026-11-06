// SimBar — automatic updates with Sparkle.
//
// The updater only starts when Info.plist has both SUFeedURL and SUPublicEDKey (release builds).
// Builds from source don't have them: the update menu item and toggle are then hidden or
// disabled, and nothing is shown at launch.

import SwiftUI
import Sparkle

@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    @Published private(set) var canCheckForUpdates = false

    /// False in builds without a feed / signing key, and in `--snapshot` / `--setup` runs.
    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Whether the user (or the onboarding) already chose; until then Sparkle asks on its own.
    var hasAutomaticChecksChoice: Bool { UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") != nil }

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    private override init() {
        super.init()
        guard Updater.isConfigured, !debugRun else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.canCheckForUpdates = can } }
        }
    }

    func checkForUpdates() {
        NSApp.activate()   // a menu bar app: bring Sparkle's window to the front
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate
    // SimBar has no Dock icon: a scheduled check that finds an update while SimBar isn't in
    // front doesn't pop a window, it shows a dot on the gear and an "Update available" item.

    /// A scheduled check found an update the user hasn't looked at yet.
    @Published private(set) var updateAvailable = false

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let userInitiated = state.userInitiated
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if handleShowingUpdate { if userInitiated { NSApp.activate() } }
                else { self.updateAvailable = true }
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.updateAvailable = false } }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.updateAvailable = false } }
    }
}
