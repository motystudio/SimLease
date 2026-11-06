// SimBar — the setup assistant: shown on first launch, and from ⚙ → Setup Assistant… later.
// Welcome → requirements → install into ~/.claude → preferences → done.

import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, requirements, install, preferences, done }

    @State private var step: Step

    init(start: Step = .welcome) { _step = State(initialValue: start) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .requirements: RequirementsStep()
                case .install: InstallStep()
                case .preferences: PreferencesStep()
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(step)
            .transition(.opacity)

            Divider()
            footer
        }
        .frame(width: 600, height: 520)
    }

    var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(L("Step \(step.rawValue + 1) of \(Step.allCases.count)", "Étape \(step.rawValue + 1) sur \(Step.allCases.count)"))
            Spacer()
            if step != .welcome && step != .done {
                Button(L("Back", "Retour")) { go(-1) }
                    .keyboardShortcut(.cancelAction)
            }
            Button(primaryTitle) {
                if step == .done { Windows.shared.closeOnboarding() } else { go(1) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    var primaryTitle: String {
        switch step {
        case .welcome: return L("Get Started", "Commencer")
        case .done: return L("Done", "Terminer")
        default: return L("Continue", "Continuer")
        }
    }

    func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }
}

// MARK: - Steps

/// Icon, title and subtitle at the top of a step, then its content.
struct StepPage<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            IconBadge(symbol: symbol, tint: tint, size: 52)
            Text(title).font(.title2.weight(.semibold)).padding(.top, 12)
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.top, 4)
            content
        }
        .padding(.top, 34)   // below the transparent title bar
    }
}

struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }
}

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            Text(L("Welcome to SimBar", "Bienvenue dans SimBar")).font(.largeTitle.weight(.semibold)).padding(.top, 22)
            VStack(spacing: 6) {
                Text(L("Parallel Claude Code sessions share iOS simulators and Android emulators instead of each booting its own.",
                       "Les sessions Claude Code parallèles se partagent les simulateurs iOS et émulateurs Android au lieu d'en démarrer chacune un."))
                Text(L("SimBar shows who uses which device, and shuts down the ones nobody needs.",
                       "SimBar montre qui utilise quel appareil et éteint ceux dont personne n'a besoin."))
                    .foregroundStyle(.secondary)
            }
            .font(.title3)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 470)
            .padding(.top, 12)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

struct RequirementsStep: View {
    @State private var items: [Requirement] = []

    var body: some View {
        StepPage(symbol: "checklist", tint: .indigo,
                 title: L("Requirements", "Prérequis"),
                 subtitle: L("sim-lease relies on a few tools. This list updates as you install them.",
                             "sim-lease s'appuie sur quelques outils. Cette liste se met à jour à mesure que vous les installez.")) {
            Form {
                Section {
                    if items.isEmpty {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    }
                    ForEach(items) { RequirementRow(item: $0) }
                } footer: {
                    if items.contains(where: { $0.required && !$0.met }) {
                        Footnote(L("You can continue and install what's missing later: SimBar picks it up on its own.",
                                   "Vous pouvez continuer et installer ce qui manque plus tard : SimBar le détectera tout seul."))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
        }
        .task {
            // live: checked again every few seconds while this step is shown
            while !Task.isCancelled {
                let checked = await Task.detached { Requirement.checkAll() }.value
                if checked != items { items = checked }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct RequirementRow: View {
    let item: Requirement

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusIcon(kind: item.met ? .ok : item.required ? .error : .neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !item.met, let link = item.link {
                Button(L("Get…", "Obtenir…")) { NSWorkspace.shared.open(link) }
            }
        }
    }
}

struct StatusIcon: View {
    enum Kind { case ok, warning, error, neutral }
    let kind: Kind

    var body: some View {
        let (symbol, color): (String, Color) = switch kind {
        case .ok: ("checkmark.circle.fill", .green)
        case .warning: ("arrow.triangle.2.circlepath.circle.fill", .orange)
        case .error: ("xmark.circle.fill", .red)
        case .neutral: ("minus.circle.fill", .secondary)
        }
        Image(systemName: symbol).foregroundStyle(color).font(.system(size: 15)).frame(width: 18)
    }
}

struct InstallStep: View {
    @ObservedObject private var store = Store.shared
    @State private var installing = false
    /// Error message per item that failed during the last install, nil before any.
    @State private var failures: [SetupItem: String]? = nil

    var allInstalled: Bool { SetupItem.allCases.allSatisfy { store.setupStates[$0] == .ok } }

    var body: some View {
        StepPage(symbol: "square.and.arrow.down", tint: .blue,
                 title: L("Install", "Installation"),
                 subtitle: L("SimBar sets up three things in ~/.claude. Nothing else on your Mac is changed.",
                             "SimBar installe trois éléments dans ~/.claude. Rien d'autre n'est modifié sur votre Mac.")) {
            Form {
                Section {
                    ForEach(SetupItem.allCases, id: \.self) { row($0) }
                }
                Section {
                    HStack {
                        summary
                        Spacer()
                        if installing { ProgressView().controlSize(.small) }
                        Button(allInstalled ? L("Installed", "Installé") : L("Install", "Installer")) { install() }
                            .disabled(installing || allInstalled || store.setupStates.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
        }
        .onAppear { store.refresh() }
    }

    @ViewBuilder var summary: some View {
        if let failures, !failures.isEmpty {
            Label(L("Some items couldn't be installed.", "Certains éléments n'ont pas pu être installés."),
                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        } else if allInstalled {
            Footnote(L("Everything is in place. Claude Code sessions started from now on use sim-lease.",
                       "Tout est en place. Les sessions Claude Code démarrées à partir de maintenant utilisent sim-lease."))
        } else {
            Footnote(L("The hook is added with jq; your other settings are kept.",
                       "Le hook est ajouté avec jq ; vos autres réglages sont conservés."))
        }
    }

    func row(_ item: SetupItem) -> some View {
        let state = store.setupStates[item]
        let error = failures?[item]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusIcon(kind: error != nil ? .error : state == .ok ? .ok : state == .outdated ? .warning : .neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(error != nil ? L("Failed", "Échec")
                 : state == .ok ? (failures != nil ? L("Done", "Fait") : L("Installed", "Installé"))
                 : state == .outdated ? L("Update available", "Mise à jour dispo.")
                 : state == nil ? "" : L("Not installed", "Non installé"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    func install() {
        installing = true
        let todo = SetupItem.allCases.filter { store.setupStates[$0] != .ok }
        store.install(todo) { result in
            failures = result
            installing = false
        }
    }
}

struct PreferencesStep: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var config = SimLeaseConfig.shared

    var body: some View {
        StepPage(symbol: "gearshape.fill", tint: .gray,
                 title: L("Preferences", "Préférences"),
                 subtitle: L("You can change these, and the device limits, at any time in Settings.",
                             "Vous pourrez les modifier, ainsi que les limites d'appareils, à tout moment dans les Réglages.")) {
            Form {
                Section {
                    Toggle(L("Launch SimBar at login", "Lancer SimBar à l'ouverture de session"), isOn: Binding(
                        get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                    if updater.isAvailable {
                        Toggle(L("Check for updates automatically", "Rechercher les mises à jour automatiquement"), isOn: Binding(
                            get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                    }
                }
                Section {
                    if config.status == .ready { UnmanagedRows() } else { ConfigUnavailable() }
                } header: {
                    Text(L("Devices started by hand", "Appareils démarrés à la main"))
                } footer: {
                    Footnote(L("Simulators you open yourself, outside sim-lease, are shut down once nobody has used them for this long.",
                               "Les simulateurs que vous ouvrez vous-même, hors sim-lease, sont éteints quand personne ne s'en est servi depuis ce délai."))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
        }
        .onAppear {
            config.load()
            // updates on by default: deciding here spares the user Sparkle's own prompt later
            if updater.isAvailable && !updater.hasAutomaticChecksChoice { updater.automaticallyChecks = true }
        }
    }
}

struct DoneStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            IconBadge(symbol: "checkmark", tint: .green, size: 80)
            Text(L("You're All Set", "Tout est prêt")).font(.largeTitle.weight(.semibold)).padding(.top, 20)
            Text(L("SimBar lives in the menu bar, behind the iPhone icon. New Claude Code sessions now lease their simulators through sim-lease.",
                   "SimBar se trouve dans la barre des menus, derrière l'icône d'iPhone. Les nouvelles sessions Claude Code louent désormais leurs simulateurs via sim-lease."))
                .font(.title3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 470).padding(.top, 10)
            (Text(L("Settings and this assistant are in the panel's ", "Les réglages et cet assistant se trouvent dans le menu "))
             + Text(Image(systemName: "gearshape"))
             + Text(L(" menu.", " du panneau.")))
                .font(.callout).foregroundStyle(.secondary).padding(.top, 18)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 40)
    }
}
