// SimBar — the Settings window: sim-lease's limits and delays, and SimBar's own options.

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var config = SimLeaseConfig.shared
    @ObservedObject private var store = Store.shared
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            if config.status == .ready {
                Section {
                    NumberRow(L("iOS simulators", "Simulateurs iOS"), key: .maxIOS)
                    NumberRow(L("Android emulators", "Émulateurs Android"), key: .maxAndroid)
                } header: {
                    Text(L("Devices booted at the same time, at most", "Appareils démarrés en même temps, au maximum"))
                } footer: {
                    Footnote(L("Past this limit, a session waits for a device to free up.",
                               "Au-delà, une session attend qu'un appareil se libère."))
                }
                Section {
                    NumberRow(L("Free a device when its session is idle for", "Libérer un appareil quand sa session est inactive depuis"),
                              key: .staleMin, unit: "min")
                    NumberRow(L("Then keep it on for", "Puis le garder allumé pendant"), key: .graceMin, unit: "min")
                } header: {
                    Text(L("Idle devices", "Appareils inactifs"))
                } footer: {
                    Footnote(L("A freed device stays on so the next session can reuse it right away, then it is shut down.",
                               "Un appareil libéré reste allumé pour que la session suivante le reprenne aussitôt, puis il est éteint."))
                }
                Section {
                    UnmanagedRows()
                } header: {
                    Text(L("Devices started by hand", "Appareils démarrés à la main"))
                } footer: {
                    Footnote(L("Simulators you open yourself, outside sim-lease. Pinned devices are never shut down.",
                               "Les simulateurs que vous ouvrez vous-même, hors sim-lease. Les appareils épinglés ne sont jamais éteints."))
                }
            } else {
                Section { ConfigUnavailable() }
            }

            Section("SimBar") {
                Toggle(L("Launch at login", "Lancer à l'ouverture de session"), isOn: Binding(
                    get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                Toggle(L("Clean up idle devices every 5 min", "Nettoyer les appareils inactifs toutes les 5 min"), isOn: $store.autoReap)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L("Check for updates automatically", "Rechercher les mises à jour automatiquement"), isOn: Binding(
                        get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                        .disabled(!updater.isAvailable)
                    if !updater.isAvailable {
                        Footnote(L("Not available in builds from source.", "Indisponible dans les versions compilées depuis les sources."))
                    }
                }
            }

            if config.status == .ready {
                Section {
                    HStack {
                        if let error = config.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.callout)
                        } else {
                            Footnote(L("Saved in ~/.claude/sim-lease.conf", "Enregistré dans ~/.claude/sim-lease.conf"))
                        }
                        Spacer()
                        Button(L("Restore Defaults", "Réglages par défaut")) { config.resetAll() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { config.load() }
    }
}

/// A setting in minutes or a count: a text field with a stepper, written back to sim-lease.
struct NumberRow: View {
    @ObservedObject private var config = SimLeaseConfig.shared
    let title: String
    let key: SimLeaseConfig.Key
    var unit: String? = nil

    init(_ title: String, key: SimLeaseConfig.Key, unit: String? = nil) {
        self.title = title; self.key = key; self.unit = unit
    }

    var body: some View {
        let value = config.binding(key, fallback: key.range.lowerBound)
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Stepper(title, value: value, in: key.range).labelsHidden()
                if let unit {
                    Text(unit).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                }
            }
        }
    }
}

/// "Also shut down devices started outside sim-lease" + its delay. In Settings and in the assistant.
struct UnmanagedRows: View {
    @ObservedObject private var config = SimLeaseConfig.shared

    var body: some View {
        Toggle(L("Also shut down devices started outside sim-lease", "Éteindre aussi les appareils démarrés hors sim-lease"),
               isOn: config.adoptUnmanaged)
        NumberRow(L("Shut them down when unused for", "Les éteindre après une inactivité de"), key: .unmanagedGraceMin, unit: "min")
            .disabled(!config.adoptUnmanaged.wrappedValue)
    }
}

/// Shown instead of sim-lease's settings when the installed script can't provide them.
struct ConfigUnavailable: View {
    @ObservedObject private var config = SimLeaseConfig.shared
    @ObservedObject private var store = Store.shared
    @State private var installing = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: config.status == .loading ? "hourglass" : "exclamationmark.triangle.fill")
                .font(.title2).foregroundStyle(config.status == .loading ? Color.secondary : .orange)
            VStack(alignment: .leading, spacing: 4) {
                switch config.status {
                case .loading:
                    Text(L("Reading sim-lease's settings…", "Lecture des réglages de sim-lease…"))
                case .noScript:
                    Text(L("sim-lease isn't installed", "sim-lease n'est pas installé")).font(.headline)
                    Footnote(L("Install it to change its limits and delays here.",
                               "Installez-le pour régler ici ses limites et ses délais."))
                default:
                    Text(L("The installed sim-lease is out of date", "Le sim-lease installé n'est pas à jour")).font(.headline)
                    Footnote(L("This version can't be configured from SimBar. Update it, or edit ~/.claude/sim-lease.conf by hand.",
                               "Cette version ne se règle pas depuis SimBar. Mettez-la à jour, ou modifiez ~/.claude/sim-lease.conf à la main."))
                }
                if let error = config.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            Spacer()
            // offered only when SimBar carries a different copy than the one installed
            if config.status != .loading, store.setupStates[.script] != .ok {
                if installing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(config.status == .noScript ? L("Install", "Installer") : L("Update", "Mettre à jour")) {
                        installing = true
                        config.lastError = nil
                        store.install([.script]) { failures in
                            installing = false
                            config.lastError = failures[.script]
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
